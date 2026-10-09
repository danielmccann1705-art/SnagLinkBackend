import Vapor
import Fluent
import FluentSQL

/// Recovery after an image rollback (outputs/measurement-2026-10-07/ROLLBACK-RECONCILIATION.md).
///
/// The rollback image (`4d04a16`) has no measurement code. An account it deletes keeps every measurement
/// row, and no provider-erasure work is created for it; a deletion this image started with measurement
/// erasure pending cannot finish there. When this image returns, `App measurement-reconcile` lists both,
/// and with `--apply` runs this image's own deletion barrier for each such account (which creates the
/// missing erasure work and removes queued events) and re-arms the pending deletion jobs, which the
/// ordinary erasure and deletion workers then finish. It never calls a provider and never sends an event.
/// Even before reconciliation, dispatch refuses every job of an account that is not active.
enum MeasurementReconciliation {
    /// What this image's deletion barrier (`MeasurementPrivacyService.eraseAccount` and
    /// `AdAttributionStore.eraseAccount`) removes, revokes or unlinks. On a deleted account, any of these
    /// means that an image without the barrier deleted it. `$A` is the account expression.
    static let residue: [(label: String, condition: String)] = [
        ("active_subjects", "EXISTS(SELECT 1 FROM measurement_subjects x WHERE x.account_id=$A AND x.state='active')"),
        ("granted_permissions", "EXISTS(SELECT 1 FROM measurement_permission_current x WHERE x.account_id=$A AND x.decision='granted')"),
        ("dispatch_jobs", "EXISTS(SELECT 1 FROM measurement_dispatch_jobs x WHERE x.account_id=$A)"),
        ("att_assertions", "EXISTS(SELECT 1 FROM measurement_att_assertions x WHERE x.account_id=$A)"),
        ("product_event_content", "EXISTS(SELECT 1 FROM measurement_product_events x WHERE x.account_id=$A AND x.revoked_at IS NULL)"),
        ("device_bindings", "EXISTS(SELECT 1 FROM measurement_device_bindings x WHERE x.account_id=$A AND x.revoked_at IS NULL)"),
        ("signup_facts", "EXISTS(SELECT 1 FROM measurement_signup_facts x WHERE x.account_id=$A)"),
        ("signup_intents", "EXISTS(SELECT 1 FROM measurement_signup_intents x WHERE x.account_id=$A)"),
        ("purchase_intents", "EXISTS(SELECT 1 FROM measurement_purchase_intents x WHERE x.account_id=$A)"),
        ("purchase_acquisitions", "EXISTS(SELECT 1 FROM measurement_purchase_acquisitions x WHERE x.account_id=$A)"),
        ("revenuecat_ledger", "(EXISTS(SELECT 1 FROM measurement_revenuecat_events x WHERE x.account_id=$A)"
            + " OR EXISTS(SELECT 1 FROM measurement_revenuecat_lifecycle_events x WHERE x.account_id=$A)"
            + " OR EXISTS(SELECT 1 FROM measurement_revenuecat_adjustments x WHERE x.account_id=$A))"),
        ("apple_attribution", "EXISTS(SELECT 1 FROM ad_attribution_records x WHERE x.canonical_account_id=$A"
            + " OR x.rc_app_user_id=upper(CAST($A AS TEXT)))"),
    ]

    static func unreconciled(_ account: String) -> String {
        "(" + residue.map { $0.condition.replacingOccurrences(of: "$A", with: account) }.joined(separator: " OR ") + ")"
    }

    struct DeletedAccount: Codable, Sendable, Equatable {
        let accountId: UUID
        let deletionJobId: UUID?
        let deletionJobState: String?
        let residue: [String]
    }

    struct PendingDeletion: Codable, Sendable, Equatable {
        let deletionJobId: UUID
        let accountId: UUID
        let state: String
        let measurementErasureState: String
        /// `destination:state[:reason]` for each erasure job linked to the deletion.
        let erasureJobs: [String]
    }

    struct OpenErasure: Codable, Sendable, Equatable {
        let erasureJobId: UUID
        let accountId: UUID
        let destination: String
        let state: String
        let reason: String?
        let createdAt: Date
        let accountDeleted: Bool
    }

    struct Report: Codable, Sendable {
        /// Deleted accounts whose deletion barrier has not run on this image.
        var unreconciledDeletedAccounts: [DeletedAccount] = []
        /// Deletion jobs not completed while their measurement erasure is not settled.
        var pendingMeasurementDeletions: [PendingDeletion] = []
        /// Erasure jobs that need a person (`failing`, `manual_required`). They also block receipt cleanup.
        var openErasureJobs: [OpenErasure] = []
        /// Pending or retrying optional events of active accounts: what dispatch offers to providers once
        /// it is switched on again (their permission is re-checked first).
        var queuedEventsOfActiveAccounts = 0
        /// The measurement switches as this image resolves them now.
        var switches: [String: Bool] = [:]
        /// Accounts this run reconciled (`--apply` only).
        var reconciledAccounts: [UUID] = []
        /// Deletion jobs this run re-armed (`--apply` only).
        var rearmedDeletionJobs: [UUID] = []
    }

    static let switchKeys = ["productAnalyticsEnabled", "portalProductAnalyticsEnabled", "crossCompanyAdsEnabled",
                             "linkedInConversionsEnabled", "adMeasurementEnabled", "measurementChoicesEnabled"]

    static func report(limit: Int = 500, on db: Database) async throws -> Report {
        let sql = try VerifiedIdentityService.sql(db)
        let bounded = max(1, min(limit, 5_000))
        var report = Report()
        let labels = residue.enumerated().map { "\(unsafeRawString($0.element.condition, "u.id")) AS r\($0.offset)" }
            .joined(separator: ",")
        let rows = try await sql.raw("""
            SELECT u.id,d.id AS job_id,d.state AS job_state,\(unsafeRaw: labels)
            FROM users u LEFT JOIN account_deletion_jobs d ON d.user_id=u.id
            WHERE u.lifecycle_state='deleted' AND \(unsafeRaw: unreconciled("u.id"))
            ORDER BY d.requested_at NULLS FIRST,u.id LIMIT \(bind:bounded)
            """).all()
        for row in rows {
            var present: [String] = []
            for (index, check) in residue.enumerated() {
                if try row.decode(column: "r\(index)", as: Bool.self) { present.append(check.label) }
            }
            report.unreconciledDeletedAccounts.append(.init(
                accountId: try row.decode(column: "id", as: UUID.self),
                deletionJobId: try row.decode(column: "job_id", as: UUID?.self),
                deletionJobState: try row.decode(column: "job_state", as: String?.self), residue: present))
        }
        let pending = try await sql.raw("""
            SELECT d.id,d.user_id,d.state,d.measurement_erasure_state,
                   COALESCE((SELECT string_agg(e.destination||':'||e.state||COALESCE(':'||e.last_error_kind,''),','
                             ORDER BY e.destination,e.created_at)
                             FROM measurement_erasure_jobs e WHERE e.account_deletion_job_id=d.id),'') AS jobs
            FROM account_deletion_jobs d
            WHERE d.state<>'completed' AND d.measurement_erasure_state NOT IN ('not_requested','completed')
            ORDER BY d.requested_at LIMIT \(bind:bounded)
            """).all()
        for row in pending {
            let jobs = try row.decode(column: "jobs", as: String.self)
            report.pendingMeasurementDeletions.append(.init(
                deletionJobId: try row.decode(column: "id", as: UUID.self),
                accountId: try row.decode(column: "user_id", as: UUID.self),
                state: try row.decode(column: "state", as: String.self),
                measurementErasureState: try row.decode(column: "measurement_erasure_state", as: String.self),
                erasureJobs: jobs.isEmpty ? [] : jobs.split(separator: ",").map(String.init)))
        }
        let open = try await sql.raw("""
            SELECT e.id,e.account_id,e.destination,e.state,e.last_error_kind,e.created_at,u.lifecycle_state
            FROM measurement_erasure_jobs e JOIN users u ON u.id=e.account_id
            WHERE e.state IN ('failing','manual_required') ORDER BY e.created_at LIMIT \(bind:bounded)
            """).all()
        for row in open {
            report.openErasureJobs.append(.init(
                erasureJobId: try row.decode(column: "id", as: UUID.self),
                accountId: try row.decode(column: "account_id", as: UUID.self),
                destination: try row.decode(column: "destination", as: String.self),
                state: try row.decode(column: "state", as: String.self),
                reason: try row.decode(column: "last_error_kind", as: String?.self),
                createdAt: try row.decode(column: "created_at", as: Date.self),
                accountDeleted: try row.decode(column: "lifecycle_state", as: String.self) != "active"))
        }
        report.queuedEventsOfActiveAccounts = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs j JOIN users u ON u.id=j.account_id
            WHERE u.lifecycle_state='active' AND j.state IN ('pending','failing','leased')
            """).first()?.decode(column: "n", as: Int.self) ?? 0
        let flags = try await FeatureFlagService.resolve(on: db)
        report.switches = flags.filter { switchKeys.contains($0.key) }
        return report
    }

    /// Runs this image's deletion barrier for one account an earlier image deleted. Idempotent: an
    /// account without residue is left alone. The erasure work is linked to the deletion job only while
    /// that job is unfinished; a completed job cannot return to a pending measurement state.
    @discardableResult
    static func reconcile(accountID: UUID, now: Date = Date(), on db: Database) async throws -> Bool {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let user = try await sql.raw("SELECT lifecycle_state FROM users WHERE id=\(bind:accountID) FOR UPDATE").first(),
                  try user.decode(column: "lifecycle_state", as: String.self) == "deleted",
                  try await sql.raw("""
                    SELECT 1 AS hit FROM users u WHERE u.id=\(bind:accountID) AND \(unsafeRaw: unreconciled("u.id"))
                    """).first() != nil else { return false }
            let job = try await sql.raw("SELECT id,state FROM account_deletion_jobs WHERE user_id=\(bind:accountID)").first()
            var link: UUID?
            if let job, try job.decode(column: "state", as: String.self) != "completed" {
                link = try job.decode(column: "id", as: UUID.self)
            }
            try await MeasurementPrivacyService.eraseAccount(accountID, accountDeletionJobID: link, now: now, on: tx)
            _ = try await AdAttributionStore.eraseAccount(accountID, on: tx)
            return true
        }
    }

    /// Recomputes a pending deletion's measurement state from its erasure jobs and makes it available
    /// to the next deletion-worker pass. The workers finish it; nothing here completes it.
    static func rearm(deletionJobID: UUID, accountID: UUID, now: Date = Date(), on db: Database) async throws {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await MeasurementErasureService.settleAccountDeletionState(accountID: accountID, on: sql)
            try await sql.raw("""
                UPDATE account_deletion_jobs SET available_at=LEAST(available_at,\(bind:now))
                WHERE id=\(bind:deletionJobID) AND state IN ('ready','blocked')
                """).run()
        }
    }

    /// The command's whole behaviour, callable from tests.
    static func execute(apply: Bool, now: Date = Date(), on db: Database) async throws -> Report {
        let before = try await report(on: db)
        guard apply else { return before }
        var reconciled: [UUID] = []
        for account in before.unreconciledDeletedAccounts {
            if try await reconcile(accountID: account.accountId, now: now, on: db) { reconciled.append(account.accountId) }
        }
        let listed = try await report(on: db)
        var rearmed: [UUID] = []
        for job in listed.pendingMeasurementDeletions {
            try await rearm(deletionJobID: job.deletionJobId, accountID: job.accountId, now: now, on: db)
            rearmed.append(job.deletionJobId)
        }
        var after = try await report(on: db)
        after.reconciledAccounts = reconciled
        after.rearmedDeletionJobs = rearmed
        return after
    }

    private static func unsafeRawString(_ condition: String, _ account: String) -> String {
        condition.replacingOccurrences(of: "$A", with: account)
    }
}

/// `App measurement-reconcile [--apply]`: prints the report as JSON. Without `--apply` nothing is changed.
struct MeasurementReconcileCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "apply", help: "Run the deletion barrier for listed accounts and re-arm pending deletions")
        var apply: Bool
        init() {}
    }

    var help: String { "List and reconcile measurement and deletion work left by an image rollback (never calls a provider)" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let report = try await MeasurementReconciliation.execute(apply: signature.apply, on: context.application.db)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        context.console.print(String(decoding: try encoder.encode(report), as: UTF8.self))
        if !signature.apply { context.console.print("Listed only. Nothing was changed; pass --apply to reconcile.") }
    }
}
