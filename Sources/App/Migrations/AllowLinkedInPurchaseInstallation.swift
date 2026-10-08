import Fluent
import FluentSQL
import Vapor

/// Extends the originating-installation invariant to LinkedIn purchase jobs.
/// Product analytics remains installation-free, and no Singular adapter is
/// activated by this schema change.
struct AllowLinkedInPurchaseInstallation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE measurement_dispatch_jobs DROP CONSTRAINT measurement_dispatch_singular_installation").run()
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_ad_installation CHECK (
                    ((destination IN ('singular','linkedin') AND source_kind='revenueCatLifecycle') =
                     (installation_id IS NOT NULL)))
                """).run()
            // Existing provider facts and witnesses deliberately remain false so
            // enabling LinkedIn cannot promote activity observed before this gate.
            try await sql.raw("""
                ALTER TABLE measurement_revenuecat_events
                  ADD COLUMN linkedin_ingest_eligible BOOLEAN NOT NULL DEFAULT FALSE
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents
                  ADD COLUMN linkedin_witness_eligible BOOLEAN NOT NULL DEFAULT FALSE,
                  ADD COLUMN att_asserted_at TIMESTAMPTZ,
                  ADD COLUMN att_expires_at TIMESTAMPTZ,
                  ADD COLUMN att_continuity_started_at TIMESTAMPTZ,
                  ADD COLUMN att_continuity_id UUID
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_att_assertions
                  ADD COLUMN continuity_started_at TIMESTAMPTZ,
                  ADD COLUMN continuity_id UUID
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Originating-installation dispatch evidence must survive rollback; use a compatible image")
    }
}
