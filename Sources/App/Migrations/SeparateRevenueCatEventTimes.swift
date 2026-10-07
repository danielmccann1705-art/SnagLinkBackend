import Fluent
import FluentSQL
import Vapor

/// Keeps RevenueCat's event-generation time separate from the subscription
/// period start. Apple can charge a renewal before that new period begins.
struct SeparateRevenueCatEventTimes: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE measurement_revenuecat_events ADD COLUMN purchased_at TIMESTAMPTZ").run()
            try await sql.raw("UPDATE measurement_revenuecat_events SET purchased_at=occurred_at").run()
            try await sql.raw("ALTER TABLE measurement_revenuecat_events ALTER COLUMN purchased_at SET NOT NULL").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "RevenueCat event-time evidence must survive rollback; use a compatible image")
    }
}
