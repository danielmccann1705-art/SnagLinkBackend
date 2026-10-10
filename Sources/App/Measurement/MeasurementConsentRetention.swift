import Vapor
import Fluent
import FluentSQL

/// A finite lifecycle for the measurement consent, withdrawal and erasure receipts of a DELETED
/// account (outputs/measurement-2026-10-07/CONSENT-RETENTION-LIFECYCLE.md; ASTRA-REVIEW-2026-10-09b.md,
/// correction 3).
///
/// Account deletion (`MeasurementPrivacyService.eraseAccount`) stops optional processing and removes
/// payloads at once. Until this cleanup, only these rows stay linked to the deleted `users` row. They are
/// pseudonymous records, never anonymous:
/// - consent receipts, in `measurement_consent_events` (grants): which notice, purpose and time each
///   provider record was collected under, and for cross-company the installation and ATT observation;
/// - withdrawal receipts, in `measurement_consent_events` (withdrawals, including the one deletion
///   records) and `measurement_permission_current`: that processing stopped, and when;
/// - erasure receipts: `measurement_subjects` (the opaque provider address and the in-flight send bound),
///   `measurement_erasure_jobs` and, through their cascades, the PostHog receipts, passes and manual
///   resolutions, plus a held Singular device binding (the address of a Singular deletion).
///
/// Trigger: the account is deleted, its deletion barrier has run on this image (no
/// `MeasurementReconciliation.residue` is left), and every provider-erasure job of the account is
/// settled: `completed`, or for LinkedIn `provider_retention_bound` (LinkedInErasureResolution). The
/// trigger time is the latest of the deletion request, the last completion and the date each LinkedIn
/// copy is due to age out under LinkedIn's terms: the consent receipt shows which notice a provider-held
/// record was collected under while that record may still exist.
/// Cleanup: `receiptRetention` after the trigger, the hourly pass deletes exactly those rows for that
/// account. A `failing` or `manual_required` erasure job keeps all of them until a person resolves it;
/// nothing here completes, skips or deletes unfinished erasure work. A live account's history is not
/// touched here: it stays while the account exists.
enum MeasurementConsentRetention {
    /// A proposed operational limit (not a statutory period): one month in which the person, or we,
    /// can confirm from the receipts that provider erasure finished, and in which a rollback or a late
    /// provider finding can still be reconciled against them (CONSENT-RETENTION-LIFECYCLE.md).
    static let receiptRetention: TimeInterval = 30 * 86_400

    /// Counts only; never which accounts (cleanup records are logged).
    struct Counts: Codable, Sendable, Equatable {
        /// Deleted accounts whose receipts this pass removed.
        var accounts = 0
        /// Rows removed, all tables (cascaded PostHog evidence not counted separately).
        var rows = 0
        /// Deleted accounts kept because an erasure job is `failing` or `manual_required`.
        var blocked = 0
        /// Deleted accounts whose erasure is settled but kept until a LinkedIn copy is due to age out
        /// (`provider_retention_bound`) plus `receiptRetention`. Finite; no person is needed.
        var providerRetentionBound = 0
        /// Deleted accounts kept because their deletion barrier has not run on this image
        /// (rollback residue; `App measurement-reconcile`).
        var unreconciled = 0
        /// Accounts whose removal failed and was rolled back; retried next pass.
        var failed = 0
    }

    /// The trigger, as a condition on the account expression `account` at `cutoff`.
    static func eligible(_ account: String) -> String {
        """
        NOT \(MeasurementReconciliation.unreconciled(account))
        AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.account_id=\(account)
            AND e.state NOT IN \(LinkedInErasureResolution.settledStates))
        AND NOT EXISTS(SELECT 1 FROM measurement_subjects s WHERE s.account_id=\(account) AND (
            (s.purpose='productAnalytics' AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e
                WHERE e.subject_id=s.id AND e.destination='posthog'))
            OR (s.purpose='crossCompanyAds' AND (
                NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.destination='linkedin')
                OR NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.destination='singular')))))
        """
    }

    private static func triggerAt(_ account: String) -> String {
        """
        GREATEST((SELECT d.requested_at FROM account_deletion_jobs d WHERE d.user_id=\(account)),
                 (SELECT MAX(e.completed_at) FROM measurement_erasure_jobs e WHERE e.account_id=\(account)),
                 (SELECT MAX(e.provider_copy_expires_at) FROM measurement_erasure_jobs e WHERE e.account_id=\(account)))
        """
    }

    private static let holdsReceipts = """
        (EXISTS(SELECT 1 FROM measurement_consent_events c WHERE c.account_id=u.id)
         OR EXISTS(SELECT 1 FROM measurement_subjects s WHERE s.account_id=u.id)
         OR EXISTS(SELECT 1 FROM measurement_permission_current p WHERE p.account_id=u.id))
        """

    /// The hourly pass (`CleanupService.perform`).
    static func cleanup(now: Date = Date(), limit: Int = 500, on db: Database) async throws -> Counts {
        let sql = try VerifiedIdentityService.sql(db)
        let cutoff = now.addingTimeInterval(-receiptRetention)
        var counts = Counts()
        let due = try await sql.raw("""
            SELECT u.id FROM users u JOIN account_deletion_jobs d ON d.user_id=u.id
            WHERE u.lifecycle_state='deleted' AND \(unsafeRaw: holdsReceipts)
              AND \(unsafeRaw: eligible("u.id")) AND \(unsafeRaw: triggerAt("u.id"))<=\(bind:cutoff)
            ORDER BY d.requested_at LIMIT \(bind:max(0, min(limit, 5_000)))
            """).all().map { try $0.decode(column: "id", as: UUID.self) }
        for account in due {
            do {
                let removed = try await remove(account, cutoff: cutoff, on: db)
                if removed > 0 { counts.accounts += 1; counts.rows += removed }
            } catch {
                counts.failed += 1
            }
        }
        if let row = try await sql.raw("""
            SELECT
              count(*) FILTER (WHERE EXISTS(SELECT 1 FROM measurement_erasure_jobs e
                  WHERE e.account_id=u.id AND e.state IN ('failing','manual_required'))) AS blocked,
              count(*) FILTER (WHERE EXISTS(SELECT 1 FROM measurement_erasure_jobs e
                  WHERE e.account_id=u.id AND e.state='provider_retention_bound')
                  AND \(unsafeRaw: eligible("u.id"))) AS retention_bound,
              count(*) FILTER (WHERE \(unsafeRaw: MeasurementReconciliation.unreconciled("u.id"))) AS unreconciled
            FROM users u WHERE u.lifecycle_state='deleted' AND \(unsafeRaw: holdsReceipts)
            """).first() {
            counts.blocked = try row.decode(column: "blocked", as: Int.self)
            counts.providerRetentionBound = try row.decode(column: "retention_bound", as: Int.self)
            counts.unreconciled = try row.decode(column: "unreconciled", as: Int.self)
        }
        return counts
    }

    /// One account, in one transaction, under the account row and the fixed purpose barriers (the order
    /// permission mutation, deletion and dispatch use). The trigger is checked again under those locks.
    private static func remove(_ account: UUID, cutoff: Date, on db: Database) async throws -> Int {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let user = try await sql.raw("SELECT lifecycle_state FROM users WHERE id=\(bind:account) FOR UPDATE").first(),
                  try user.decode(column: "lifecycle_state", as: String.self) == "deleted" else { return 0 }
            for purpose in [MeasurementPurpose.productAnalytics, .crossCompanyAds, .appleAds] {
                try await VerifiedIdentityService.lock("measurement-permission:\(account.uuidString):\(purpose.rawValue)", on: tx)
            }
            guard try await sql.raw("""
                SELECT 1 AS due FROM users u WHERE u.id=\(bind:account)
                  AND \(unsafeRaw: eligible("u.id")) AND \(unsafeRaw: triggerAt("u.id"))<=\(bind:cutoff)
                """).first() != nil else { return 0 }
            var total = 0
            // Children first: every reference to a revision or subject goes before it.
            for table in ["measurement_permission_current", "measurement_device_bindings", "measurement_product_events",
                          "measurement_erasure_jobs", "measurement_subjects", "measurement_consent_events"] {
                total += try await sql.raw("""
                    WITH gone AS (DELETE FROM \(unsafeRaw: table) WHERE account_id=\(bind:account) RETURNING 1)
                    SELECT count(*) AS n FROM gone
                    """).first()?.decode(column: "n", as: Int.self) ?? 0
            }
            return total
        }
    }
}
