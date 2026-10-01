import Vapor
import Fluent
import FluentSQL

/// Retention maintenance packet M1 (A4 §5, accepted by Dan 25 Sep; audit F17).
///
/// Runs inside the hourly maintenance pass, after the existing work. Every sweep is
/// bounded (`batch` rows per table per pass), deletes or redacts by predicate so a
/// pass stopped part-way is finished by the next, records counts only, and touches
/// only rows whose workspace is `active`: the company-closure write guard refuses
/// writes to a closing or deleted workspace, whose rows the closure/deletion graphs
/// own. A sweep that fails is recorded by name and does not stop the others or the
/// pass, so one table can never block account deletion.
///
/// Periods are the accepted A4 ones and nothing else:
/// - browser sessions: 24 h after `expires_at` (I-04)
/// - Contractor-link PIN unlock sessions: after `expires_at` (I-16)
/// - project download copies and cursors, project discovery copies: after `expires_at` (I-14)
/// - invitations never accepted: 30 days after `expires_at`, address and token erased,
///   the decision kept (I-27)
/// - Contractor links: sealed token, PIN hash and issuance copy removed 30 days after
///   expiry or revocation (I-15); link retry receipts deleted 7 days after (§1.4.5)
/// - cached mutation responses: body replaced by a sentinel after the configured
///   window, recognition kept; **off** unless `MUTATION_RECEIPT_RETENTION_DAYS` is
///   set (≥ 30, the app-session lifetime) (I-12, I-13, §1.4)
/// - `workflow_outbox` rows 30 days old (no consumer exists, I-18); `cleanup_runs`
///   13 months old (I-24)
/// - unattached uploads 7 days past expiry are counted and then **retired** (Lane A WP4,
///   FABLE-DESIGN-A-AMENDMENT §4.5): the row stays as `retired` (every later write or
///   attachment is refused 410) and its object keys are queued in `upload_retirements`;
///   a second bounded step replaces each queued key with the same zero-byte erasure
///   fence account deletion writes and reads it back. An upload with an `active` write
///   intent is left for the next pass. Without a fence store the keys stay `pending`.
enum RetentionMaintenanceService {
    struct Counts: Codable, Sendable, Equatable {
        var browserSessions = 0
        var linkSessions = 0
        var registerSnapshots = 0
        var projectChangeCursors = 0
        var projectDiscoverySnapshots = 0
        var invitationsErased = 0
        var linkSecretsPurged = 0
        var linkReceiptsDeleted = 0
        var mutationReceiptsPurged = 0
        var linkReceiptBodiesPurged = 0
        /// Absent when the purge is switched off, so "off" and "nothing to do" differ.
        var receiptPurgeWindowDays: Int? = nil
        var workflowOutbox = 0
        var cleanupRuns = 0
        var orphanUploadsAwaitingFence = 0
        /// WP4. Optional so a cleanup record written by an older image still decodes.
        var uploadsRetired: Int? = nil
        var uploadRetirementsDeferred: Int? = nil
        var uploadFencesWritten: Int? = nil
        var uploadFenceFailures: Int? = nil
        var uploadFencesPending: Int? = nil
        var failed: [String] = []
    }

    static let batch = 5_000
    static let day: TimeInterval = 24 * 60 * 60
    static let minimumReceiptWindowDays = 30

    /// The receipt-purge window, or nil (off). Only an integer of at least 30 days is
    /// accepted: a device may retry for as long as its 30-day session lasts.
    static func receiptWindowDays(lookup: (String) -> String? = Environment.get) -> Int? {
        guard let raw = lookup("MUTATION_RECEIPT_RETENTION_DAYS"), let days = Int(raw), days >= minimumReceiptWindowDays, days <= 3650 else { return nil }
        return days
    }

    /// Fences written per pass (WP4 §4.5: 100 objects) and the retirement batch per pass.
    static let fenceBatch = 100
    static let retireBatch = 500
    /// A retirement whose fence has failed this many passes in a row is left for an operator (still counted as pending).
    static let fenceAttemptCeiling = 24

    static func run(on db: Database, now: Date = Date(), limit: Int = batch,
                    receiptWindowDays: Int? = receiptWindowDays(), fenceStore: (any ObjectErasureFenceStorage)? = nil,
                    logger: Logger? = nil) async throws -> Counts {
        let sql = try VerifiedIdentityService.sql(db)
        let n = max(0, limit)
        var counts = Counts()
        counts.receiptPurgeWindowDays = receiptWindowDays
        func total(_ query: SQLQueryString) async throws -> Int {
            try await sql.raw(query).first()?.decode(column: "total", as: Int.self) ?? 0
        }
        func step(_ name: String, _ body: () async throws -> Void) async {
            do { try await body() }
            catch {
                counts.failed.append(name)
                logger?.warning("Retention sweep failed", metadata: ["sweep": .string(name), "kind": .string("\(type(of: error))")])
            }
        }
        let dayAgo = now.addingTimeInterval(-day), weekAgo = now.addingTimeInterval(-7 * day), monthAgo = now.addingTimeInterval(-30 * day)
        let thirteenMonthsAgo = Calendar(identifier: .gregorian).date(byAdding: .month, value: -13, to: now)!

        await step("browserSessions") {
            counts.browserSessions = try await total("""
                WITH removed AS (DELETE FROM browser_sessions WHERE id IN (
                    SELECT id FROM browser_sessions WHERE expires_at < \(bind: dayAgo) ORDER BY expires_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("linkSessions") {
            counts.linkSessions = try await total("""
                WITH removed AS (DELETE FROM link_sessions WHERE token_hash IN (
                    SELECT s.token_hash FROM link_sessions s JOIN link_grants g ON g.id = s.grant_id JOIN teams t ON t.id = g.workspace_id
                    WHERE s.expires_at < \(bind: now) AND t.lifecycle_state = 'active' ORDER BY s.expires_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("registerSnapshots") {
            // Items first, while their snapshot still resolves its workspace for the
            // closure write guard; then the emptied snapshots.
            let ids = try await sql.raw("""
                SELECT r.id FROM register_snapshots r JOIN teams t ON t.id = r.workspace_id
                WHERE r.expires_at < \(bind: now) AND t.lifecycle_state = 'active' ORDER BY r.expires_at LIMIT \(bind: n)
                """).all().map { try $0.decode(column: "id", as: UUID.self) }
            guard !ids.isEmpty else { return }
            try await sql.raw("DELETE FROM register_snapshot_items WHERE snapshot_id = ANY(\(bind: ids))").run()
            counts.registerSnapshots = try await total("""
                WITH removed AS (DELETE FROM register_snapshots WHERE id = ANY(\(bind: ids)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("projectChangeCursors") {
            counts.projectChangeCursors = try await total("""
                WITH removed AS (DELETE FROM project_change_cursors WHERE token_hash IN (
                    SELECT c.token_hash FROM project_change_cursors c JOIN teams t ON t.id = c.workspace_id
                    WHERE c.expires_at < \(bind: now) AND t.lifecycle_state = 'active' ORDER BY c.expires_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("projectDiscoverySnapshots") {
            // A discovery copy can span workspaces. Only a copy whose every item names a
            // project in an active workspace is removed here; the rest go with their
            // workspace (the closure/deletion graphs own those rows).
            let ids = try await sql.raw("""
                SELECT s.id FROM project_discovery_snapshots s
                WHERE s.expires_at < \(bind: now) AND NOT EXISTS (
                    SELECT 1 FROM project_discovery_items i LEFT JOIN projects p ON p.id = i.project_id LEFT JOIN teams t ON t.id = p.workspace_id
                    WHERE i.snapshot_id = s.id AND (t.id IS NULL OR t.lifecycle_state <> 'active'))
                ORDER BY s.expires_at LIMIT \(bind: n)
                """).all().map { try $0.decode(column: "id", as: UUID.self) }
            guard !ids.isEmpty else { return }
            try await sql.raw("DELETE FROM project_discovery_items WHERE snapshot_id = ANY(\(bind: ids))").run()
            counts.projectDiscoverySnapshots = try await total("""
                WITH removed AS (DELETE FROM project_discovery_snapshots WHERE id = ANY(\(bind: ids)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("invitations") {
            // Never accepted, 30 days past expiry: keep the decision and its references,
            // erase the address and make the capability unusable, exactly as account
            // deletion erases an invitee (`AccountDeletionService`).
            counts.invitationsErased = try await total("""
                WITH changed AS (UPDATE team_invites SET email = 'expired-' || id::text || '@invalid.invalid',
                        status = CASE WHEN status = 'pending' THEN 'expired' ELSE status END,
                        token = 'erased:' || id::text, token_hash = NULL, updated_at = \(bind: now)
                    WHERE id IN (
                        SELECT i.id FROM team_invites i JOIN teams t ON t.id = i.team_id
                        WHERE i.accepted_user_id IS NULL AND i.status <> 'accepted' AND i.expires_at < \(bind: monthAgo)
                          AND i.email NOT LIKE '%@invalid.invalid' AND t.lifecycle_state = 'active'
                        ORDER BY i.expires_at LIMIT \(bind: n))
                    RETURNING 1)
                SELECT count(*) AS total FROM changed
                """)
        }
        await step("linkSecrets") {
            counts.linkSecretsPurged = try await total("""
                WITH changed AS (UPDATE link_grants SET token_ciphertext = NULL, pin_hash = NULL, issuance_json = NULL,
                        secrets_purged_at = \(bind: now)
                    WHERE id IN (
                        SELECT g.id FROM link_grants g JOIN teams t ON t.id = g.workspace_id
                        WHERE g.secrets_purged_at IS NULL AND t.lifecycle_state = 'active'
                          AND LEAST(g.expires_at, COALESCE(g.revoked_at, g.expires_at)) < \(bind: monthAgo)
                        ORDER BY g.expires_at LIMIT \(bind: n))
                    RETURNING 1)
                SELECT count(*) AS total FROM changed
                """)
        }
        await step("linkReceipts") {
            // Nothing can retry through a link that has ended; a week of slack.
            counts.linkReceiptsDeleted = try await total("""
                WITH removed AS (DELETE FROM link_mutation_receipts WHERE (grant_id, operation_id) IN (
                    SELECT r.grant_id, r.operation_id FROM link_mutation_receipts r JOIN link_grants g ON g.id = r.grant_id
                    JOIN teams t ON t.id = g.workspace_id
                    WHERE t.lifecycle_state = 'active' AND LEAST(g.expires_at, COALESCE(g.revoked_at, g.expires_at)) < \(bind: weekAgo)
                    ORDER BY r.created_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        if let window = receiptWindowDays {
            let cutoff = now.addingTimeInterval(-Double(window) * day)
            await step("mutationReceipts") {
                counts.mutationReceiptsPurged = try await total("""
                    WITH changed AS (UPDATE mutation_receipts SET result_json = '{"resultPurged":true}', result_purged_at = \(bind: now)
                        WHERE (actor_id, operation_id) IN (
                            SELECT r.actor_id, r.operation_id FROM mutation_receipts r JOIN teams t ON t.id = r.workspace_id
                            WHERE r.created_at < \(bind: cutoff) AND r.result_purged_at IS NULL AND r.account_deletion_redacted_at IS NULL
                              AND t.lifecycle_state = 'active'
                            ORDER BY r.created_at LIMIT \(bind: n))
                        RETURNING 1)
                    SELECT count(*) AS total FROM changed
                    """)
            }
            await step("linkReceiptBodies") {
                counts.linkReceiptBodiesPurged = try await total("""
                    WITH changed AS (UPDATE link_mutation_receipts SET result_json = '{"resultPurged":true}', result_purged_at = \(bind: now)
                        WHERE (grant_id, operation_id) IN (
                            SELECT r.grant_id, r.operation_id FROM link_mutation_receipts r JOIN link_grants g ON g.id = r.grant_id
                            JOIN teams t ON t.id = g.workspace_id
                            WHERE r.created_at < \(bind: cutoff) AND r.result_purged_at IS NULL AND r.account_deletion_redacted_at IS NULL
                              AND t.lifecycle_state = 'active'
                            ORDER BY r.created_at LIMIT \(bind: n))
                        RETURNING 1)
                    SELECT count(*) AS total FROM changed
                    """)
            }
        }
        await step("workflowOutbox") {
            counts.workflowOutbox = try await total("""
                WITH removed AS (DELETE FROM workflow_outbox WHERE id IN (
                    SELECT o.id FROM workflow_outbox o JOIN teams t ON t.id = o.workspace_id
                    WHERE o.created_at < \(bind: monthAgo) AND t.lifecycle_state = 'active' ORDER BY o.created_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("cleanupRuns") {
            counts.cleanupRuns = try await total("""
                WITH removed AS (DELETE FROM cleanup_runs WHERE id IN (
                    SELECT id FROM cleanup_runs WHERE started_at < \(bind: thirteenMonthsAgo) ORDER BY started_at LIMIT \(bind: n)) RETURNING 1)
                SELECT count(*) AS total FROM removed
                """)
        }
        await step("orphanUploads") {
            counts.orphanUploadsAwaitingFence = try await total("""
                SELECT count(*) AS total FROM media_assets
                WHERE attached_at IS NULL AND state <> 'retired' AND expires_at < \(bind: weekAgo)
                """)
        }
        await step("orphanUploadRetirement") {
            // One short transaction per asset: workspace lock, asset lock, the predicate again, then retire — unless a
            // write intent for it is still `active` (a PUT may be in flight), which leaves it for the next pass.
            let candidates = try await sql.raw("""
                SELECT a.id, a.workspace_id FROM media_assets a JOIN teams t ON t.id = a.workspace_id
                WHERE a.attached_at IS NULL AND a.state <> 'retired' AND a.expires_at < \(bind: weekAgo) AND t.lifecycle_state = 'active'
                ORDER BY a.expires_at, a.id LIMIT \(bind: min(n, retireBatch))
                """).all()
            var retired = 0, deferred = 0
            for candidate in candidates {
                let id = try candidate.decode(column: "id", as: UUID.self), workspaceID = try candidate.decode(column: "workspace_id", as: UUID.self)
                let outcome: Int = try await db.transaction { tx in
                    let txSQL = try VerifiedIdentityService.sql(tx)
                    try await WorkspaceAccessService.lock(workspaceID, on: tx)
                    try await VerifiedIdentityService.lock("entity:media:\(id)", on: tx)
                    guard let row = try await txSQL.raw("""
                        SELECT * FROM media_assets WHERE id = \(bind: id) AND attached_at IS NULL AND state <> 'retired' AND expires_at < \(bind: weekAgo)
                        """).first() else { return 0 }
                    if try await txSQL.raw("SELECT 1 AS active FROM object_write_intents WHERE source_kind = 'media_asset' AND source_id = \(bind: id) AND state = 'active' LIMIT 1").first() != nil { return 2 }
                    try await UploadRetirementService.retire(row, now: now, on: tx)
                    return 1
                }
                if outcome == 1 { retired += 1 } else if outcome == 2 { deferred += 1 }
            }
            counts.uploadsRetired = retired; counts.uploadRetirementsDeferred = deferred
        }
        await step("uploadFences") {
            // Same object, same adapter, same readback as account deletion's fence; unconditional and repeatable, so a
            // pass stopped part-way is finished by the next. Without a store nothing is written and the keys stay pending.
            var written = 0, failures = 0
            if let fenceStore {
                let pending = try await sql.raw("""
                    SELECT r.asset_id, r.role, r.object_key FROM upload_retirements r
                    JOIN media_assets a ON a.id = r.asset_id JOIN teams t ON t.id = a.workspace_id
                    WHERE r.state = 'pending' AND r.attempts < \(bind: fenceAttemptCeiling) AND t.lifecycle_state = 'active'
                    ORDER BY r.attempts, r.created_at LIMIT \(bind: min(n, fenceBatch))
                    """).all()
                for entry in pending {
                    let assetID = try entry.decode(column: "asset_id", as: UUID.self), role = try entry.decode(column: "role", as: String.self)
                    let key = try entry.decode(column: "object_key", as: String.self)
                    do {
                        _ = try await fenceStore.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType,
                                                                       metadata: ["snaglist-erasure": ObjectErasureFenceService.marker])
                        let readback = try await fenceStore.readFence(key: key, maximumBytes: 1)
                        try await sql.raw("""
                            UPDATE upload_retirements SET state = 'fenced', etag = \(bind: readback.etag), fenced_at = \(bind: now), last_kind = NULL
                            WHERE asset_id = \(bind: assetID) AND role = \(bind: role) AND state = 'pending'
                            """).run()
                        written += 1
                    } catch {
                        try await sql.raw("""
                            UPDATE upload_retirements SET attempts = attempts + 1, last_kind = \(bind: String(describing: type(of: error)))
                            WHERE asset_id = \(bind: assetID) AND role = \(bind: role) AND state = 'pending'
                            """).run()
                        failures += 1
                    }
                }
            }
            counts.uploadFencesWritten = written; counts.uploadFenceFailures = failures
            counts.uploadFencesPending = try await total("SELECT count(*) AS total FROM upload_retirements WHERE state = 'pending'")
        }
        return counts
    }
}
