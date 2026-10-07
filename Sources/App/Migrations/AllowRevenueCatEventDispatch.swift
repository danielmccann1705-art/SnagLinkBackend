import Fluent
import FluentSQL
import Vapor

/// Allows normalized non-charge lifecycle facts into the existing PostHog outbox.
struct AllowRevenueCatEventDispatch: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE measurement_dispatch_jobs DROP CONSTRAINT measurement_dispatch_jobs_source_kind_check").run()
        try await sql.raw("""
            ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_jobs_source_kind_check
            CHECK (source_kind IN ('productEvent','revenueCatLifecycle','revenueCatEvent'))
            """).run()
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "RevenueCat lifecycle outbox facts must survive rollback; use a compatible image")
    }
}
