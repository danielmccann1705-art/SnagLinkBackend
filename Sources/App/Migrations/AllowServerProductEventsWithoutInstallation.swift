import Fluent
import FluentSQL
import Vapor

/// Server-issued product funnel events (`sign_in_succeeded`, `contractor_link_create_failed`,
/// `report_failed`) have no client installation. The ledger column becomes optional for
/// them; client uploads and the original outcome events still always supply one
/// (`MeasurementRelayService.acceptProductEvent` decodes a non-optional UUID). Additive:
/// existing rows are untouched. Follows `AddSignupAppleEvidenceSlot`.
struct AllowServerProductEventsWithoutInstallation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE measurement_product_events ALTER COLUMN installation_id DROP NOT NULL").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Server product events without an installation must survive rollback; use a compatible image")
    }
}
