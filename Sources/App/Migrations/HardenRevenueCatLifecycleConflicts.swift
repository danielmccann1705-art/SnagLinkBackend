import Fluent
import FluentSQL
import Vapor

/// Persists a conflicting provider replay so RevenueCat can receive HTTP 200
/// without allowing the changed body to mutate economic state.
struct HardenRevenueCatLifecycleConflicts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            ALTER TABLE measurement_revenuecat_lifecycle_events
              ADD COLUMN conflict_hash TEXT CHECK (conflict_hash IS NULL OR char_length(conflict_hash)=64),
              ADD COLUMN conflicted_at TIMESTAMPTZ
            """).run()
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "RevenueCat conflict evidence must survive rollback; use a compatible image")
    }
}
