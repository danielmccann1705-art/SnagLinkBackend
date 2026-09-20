import Vapor
import Fluent
import FluentSQL

/// Test doubles are accepted only in .testing, never as production fallbacks.
struct AccountDeletionWorkerDependencies: Sendable {
    var revokeApple: @Sendable (UUID, String, String) async throws -> AppleTokenService.RevocationOutcome
    var deleteObject: @Sendable (String, String) async throws -> Void
}
struct AccountDeletionWorkerDependenciesKey: StorageKey { typealias Value = AccountDeletionWorkerDependencies }

/// External operations follow a committed database manifest. Every progress write
/// is fenced by a fresh lease UUID, so a crashed or delayed worker cannot complete
/// a later worker's lease. External deletion/revocation must be idempotent.
enum AccountDeletionWorker {
    enum TransactionMode: Sendable {
        case managed
        /// Only CleanupService's exclusively held, autocommit withConnection
        /// handle. Never select this for a handle from Database.transaction.
        case maintenanceConnection
    }

    struct Counts: Codable, Sendable {
        var processed = 0
        var completed = 0
        var blocked = 0
        var retrying = 0
    }
    struct Lease: Sendable {
        let id: UUID
        let userID: UUID
        let token: UUID
        let attempt: Int
    }
    static func claim(on db: Database, now: Date = Date()) async throws -> Lease? {
        let token = UUID()
        let row = try await VerifiedIdentityService.sql(db).raw("""
            UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),
                lease_expires_at=\(bind: now.addingTimeInterval(300)),attempts=attempts+1
            WHERE id=(SELECT id FROM account_deletion_jobs
                WHERE ((state IN ('ready','blocked') AND available_at<=\(bind: now))
                    OR (state='leased' AND lease_expires_at<=\(bind: now)))
                ORDER BY requested_at,id FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING id,user_id,attempts
            """).first()
        guard let row else { return nil }
        return try .init(id: row.decode(column: "id", as: UUID.self), userID: row.decode(column: "user_id", as: UUID.self), token: token,
                         attempt: row.decode(column: "attempts", as: Int.self))
    }
    static func renew(_ lease: Lease, on db: Database) async throws -> Bool {
        try await VerifiedIdentityService.sql(db).raw("""
            UPDATE account_deletion_jobs SET lease_expires_at=\(bind: Date().addingTimeInterval(300))
            WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW() RETURNING id
            """).first() != nil
    }
    static func run(app: Application, on database: Database? = nil, transactionMode: TransactionMode = .managed, limit: Int = 8) async throws -> Counts {
        let db = database ?? app.db
        var counts = Counts()
        for _ in 0..<max(0, min(limit, 32)) {
            guard let lease = try await claim(on: db) else { break }
            counts.processed += 1
            do {
                try await perform(lease, app: app, on: db, transactionMode: transactionMode)
                let state = try await finish(lease, on: db)
                if state == "completed" { counts.completed += 1 }
                else if state == "blocked" { counts.blocked += 1 }
                else { counts.retrying += 1 }
            } catch {
                // Never log errors containing provider tokens, object addresses or PII.
                try await VerifiedIdentityService.sql(db).raw("""
                    UPDATE account_deletion_jobs SET state='ready',lease_token=NULL,lease_expires_at=NULL,
                        available_at=\(bind: Date().addingTimeInterval(300)),last_error_kind='worker_unavailable'
                    WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW()
                    """).run()
                counts.retrying += 1
            }
        }
        return counts
    }
    /// Hold the parent row while writing child progress. A snapshot-only EXISTS
    /// predicate can otherwise race a replacement lease while awaiting a row lock.
    @discardableResult
    static func writeIfCurrent(_ lease: Lease, on db: Database, transactionMode: TransactionMode = .managed,
                               operation: @escaping @Sendable (SQLDatabase) async throws -> Void) async throws -> Bool {
        try await withCurrentLease(lease, on: db, transactionMode: transactionMode) { transaction in
            try await operation(VerifiedIdentityService.sql(transaction))
        }
    }
    /// Shared transaction boundary for graph work and individual progress writes.
    /// The pinned maintenance mode is only valid on CleanupService's autocommit handle.
    @discardableResult
    static func withCurrentLease(_ lease: Lease, on db: Database, transactionMode: TransactionMode = .managed,
                                 operation: @escaping @Sendable (Database) async throws -> Void) async throws -> Bool {
        let write: @Sendable (Database) async throws -> Bool = { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            _ = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) FOR UPDATE").first()
            // Evaluate wall time after acquiring the lock, not transaction start.
            guard try await sql.raw("""
                SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token)
                    AND state='leased' AND lease_expires_at>clock_timestamp()
                """).first() != nil else { return false }
            try await operation(transaction)
            // Graph erasure can run longer than a single progress write. Roll it
            // back if its lease expired, even though this transaction held the row.
            guard try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>clock_timestamp()").first() != nil else {
                throw Abort(.conflict, reason: "Deletion work lease expired", identifier: "deletion_lease_expired")
            }
            return true
        }
        return try await AccountDeletionTransaction.run(transactionMode, on: db, write)
    }

    static func perform(_ lease: Lease, app: Application, on db: Database,
                        transactionMode: TransactionMode = .managed) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        guard try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW()").first() != nil else { return }
        try await AccountDeletionAppleRevocationService.perform(lease, app: app, on: db, transactionMode: transactionMode)
        // Never delete evidence until the graph transaction has demonstrated it
        // is no longer referenced and recorded the exact deletion manifest.
        guard try await CompanyClosureLifecycleService.prepareObjects(lease, on: db, transactionMode: transactionMode) else { return }
        // Before any physical delete. A key whose writers use the create-only
        // protocol is fenced, never deleted, even when its known intents are all
        // settled: the ordinary branch below excludes anything that has a fence row
        // precisely so the two can never both act on one key.
        try await AccountDeletionObjectFenceService.perform(lease, app: app, on: db, transactionMode: transactionMode)
        let objects = try await sql.raw("""
            SELECT o.storage_kind,o.object_key FROM account_deletion_objects o
            WHERE o.job_id=\(bind:lease.id) AND o.completed_at IS NULL
              AND NOT EXISTS(SELECT 1 FROM object_erasure_fences f WHERE ltrim(f.object_key,'/')=ltrim(o.object_key,'/'))
              AND NOT EXISTS(
                SELECT 1 FROM account_deletion_write_intents d
                JOIN object_write_intents i ON i.id=d.intent_id
                WHERE d.job_id=o.job_id AND i.storage_kind=o.storage_kind
                  AND i.object_key=o.object_key AND i.state<>'settled')
              -- A create-only key is fenced, never deleted, even when every intent
              -- it has is settled and even when this pass ran out of time before
              -- reaching it. Settled says the bytes arrived; it does not say no
              -- other writer can still arrive, and only the fence says that.
              AND NOT EXISTS(
                SELECT 1 FROM account_deletion_write_intents dc
                JOIN object_write_intents ic ON ic.id=dc.intent_id
                WHERE dc.job_id=o.job_id AND ic.storage_kind=o.storage_kind
                  AND ic.object_key=o.object_key AND ic.write_protocol='create_only_v1')
            ORDER BY o.attempts,o.storage_kind,o.object_key LIMIT 16
            """).all()
        for object in objects {
            guard try await renew(lease, on: db) else { return }
            let kind = try object.decode(column: "storage_kind", as: String.self)
            let key = try object.decode(column: "object_key", as: String.self)
            var completed: Date?
            var failureKind: String?
            do {
                guard try await !AccountDeletionGraphService.objectIsReferenced(kind: kind, key: key,
                                                                                 excludingJobID: lease.id, on: db) else {
                    try await writeIfCurrent(lease, on: db, transactionMode: transactionMode) { sql in
                    try await sql.raw("""
                        UPDATE account_deletion_objects SET attempts=attempts+1,last_error_kind='object_still_referenced'
                        WHERE job_id=\(bind: lease.id) AND storage_kind=\(bind: kind) AND object_key=\(bind: key)
                            AND EXISTS(SELECT 1 FROM account_deletion_jobs WHERE id=\(bind: lease.id)
                                AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW())
                        """).run()
                    }
                    continue
                }
                if app.environment == .testing, let dependencies = app.storage[AccountDeletionWorkerDependenciesKey.self] {
                    try await dependencies.deleteObject(kind, key)
                } else { try await StorageService.deleteAccountObject(kind: kind, key: key, app: app) }
                completed = Date()
            } catch { failureKind = "storage_unavailable" }
            let completedAt = completed, objectFailure = failureKind
            try await writeIfCurrent(lease, on: db, transactionMode: transactionMode) { sql in
            try await sql.raw("""
                UPDATE account_deletion_objects SET completed_at=\(bind: completedAt),attempts=attempts+1,last_error_kind=\(bind: objectFailure)
                WHERE job_id=\(bind: lease.id) AND storage_kind=\(bind: kind) AND object_key=\(bind: key)
                    AND EXISTS(SELECT 1 FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW())
                """).run()
            }
        }
        try await sql.raw("""
            UPDATE account_deletion_jobs SET object_cleanup_state=CASE WHEN
                EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind: lease.id)) THEN 'blocked' WHEN
                EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                    WHERE d.job_id=\(bind:lease.id) AND i.state='uncertain' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'blocked' WHEN
                EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                    WHERE d.job_id=\(bind:lease.id) AND i.state='active' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'blocked' WHEN
                EXISTS(SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND completed_at IS NULL AND last_error_kind='object_still_referenced')
                THEN 'blocked' WHEN EXISTS(SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND completed_at IS NULL)
                THEN 'pending' ELSE 'completed' END
            WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW()
            """).run()
        try await CompanyClosureLifecycleService.completeObjectPhase(lease, on: db, transactionMode: transactionMode)
    }
    static func finish(_ lease: Lease, on db: Database) async throws -> String? {
        try await AccountDeletionAppleRevocationService.refreshSummary(lease, on: db)
        let delay = min(3600.0, 30.0 * pow(2.0, Double(min(lease.attempt, 7))))
        let row = try await VerifiedIdentityService.sql(db).raw("""
            UPDATE account_deletion_jobs SET
                state=CASE WHEN database_cleanup_state='completed' AND object_cleanup_state='completed'
                        AND apple_revocation_state IN ('not_applicable','revoked','already_revoked')
                        AND NOT EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND state<>'completed') THEN 'completed'
                    WHEN (database_cleanup_state<>'completed' AND NOT EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state IN ('pending','erasing'))) OR object_cleanup_state='blocked'
                        OR EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND state='blocked')
                        OR apple_revocation_state IN ('misconfigured','unavailable') THEN 'blocked' ELSE 'ready' END,
                completed_at=CASE WHEN database_cleanup_state='completed' AND object_cleanup_state='completed'
                        AND apple_revocation_state IN ('not_applicable','revoked','already_revoked')
                        AND NOT EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND state<>'completed') THEN NOW() ELSE NULL END,
                last_error_kind=CASE WHEN EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind: lease.id)) THEN 'unresolved_legacy_object_ownership'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:lease.id) AND i.state='uncertain' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'object_write_uncertain'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:lease.id) AND i.state='active' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'object_write_pending'
                    WHEN database_cleanup_state<>'completed' AND EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state<>'completed') THEN 'company_closure_pending'
                    WHEN database_cleanup_state<>'completed' THEN 'database_erasure_pending'
                    WHEN apple_revocation_state='unavailable' THEN 'apple_credential_unavailable'
                    WHEN apple_revocation_state='misconfigured' THEN 'apple_configuration'
                    WHEN apple_revocation_state='failing' THEN 'apple_unavailable'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind: lease.id)) THEN 'unresolved_legacy_object_ownership'
                    WHEN object_cleanup_state<>'completed' THEN 'object_cleanup_pending' ELSE NULL END,
                available_at=\(bind: Date().addingTimeInterval(delay)),lease_token=NULL,lease_expires_at=NULL
            WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW() RETURNING state
            """).first()
        return try row?.decode(column: "state", as: String.self)
    }
}
