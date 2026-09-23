import Vapor
import Fluent

/// Account deletion gains its RevenueCat step (`RevenueCatCustomerDeletionService`).
///
/// One job, one customer, so the progress lives on the job row rather than in a child
/// table. `revenuecat_state`:
///
/// * `pending` — every job the request path creates from now on. Not yet attempted.
/// * `deleted`, `not_found` — RevenueCat answered 200 or 404. Done.
/// * `skipped_environment` — the deployment has no purchase provider by design
///   (staging, local, tests). Recorded under its own name, never as a deletion.
/// * `misconfigured` — the key is absent where it is required, or RevenueCat refused
///   it. The job is blocked and retried every pass.
/// * `failing` — transient. The job stays `ready` and is retried.
/// * `not_requested` — the column default: jobs that existed before this migration.
///   The request path always writes `pending` explicitly, and a test pins that.
///
/// The completion rule is also a constraint, as it is for Apple: a job cannot be
/// `completed` while its RevenueCat step is `pending`, `failing` or `misconfigured`.
/// An image older than this migration, running against this schema, cannot complete
/// a job this revision created (its step is `pending`): the write is refused, which
/// is the safe direction, and the job waits for a compatible image. Jobs the older
/// image creates itself take the default, `not_requested`, and complete as before.
struct AddRevenueCatCustomerDeletion: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                ALTER TABLE account_deletion_jobs
                    ADD COLUMN revenuecat_state TEXT NOT NULL DEFAULT 'not_requested'
                        CONSTRAINT account_deletion_revenuecat_state CHECK (revenuecat_state IN
                            ('not_requested','pending','deleted','not_found','skipped_environment','misconfigured','failing')),
                    ADD COLUMN revenuecat_attempts INTEGER NOT NULL DEFAULT 0
                        CONSTRAINT account_deletion_revenuecat_attempts CHECK (revenuecat_attempts >= 0),
                    ADD COLUMN revenuecat_last_attempt_at TIMESTAMPTZ,
                    ADD COLUMN revenuecat_completed_at TIMESTAMPTZ,
                    ADD CONSTRAINT account_deletion_completion_settles_revenuecat
                        CHECK (state <> 'completed' OR revenuecat_state IN ('not_requested','deleted','not_found','skipped_environment'))
                """).run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Deletion jobs must survive rollback; use a compatible image")
    }
}
