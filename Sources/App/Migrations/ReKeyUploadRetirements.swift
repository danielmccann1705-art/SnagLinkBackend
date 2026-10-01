import Fluent
import FluentSQL
import Vapor

/// Lane A WP4, Fable §8.3 (1 Oct): an upload can hold more than one key per role — a rendition whose readiness never
/// committed is known only to `object_write_intents`, and a re-processed original yields a rendition at a new digest —
/// so a retirement is keyed by the object, `(asset_id, object_key)`, with `role` kept as a description. Additive in
/// effect: the table is new in 6753b12 and holds only staging rows.
struct ReKeyUploadRetirements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await VerifiedIdentityService.sql(database).raw("""
            ALTER TABLE upload_retirements DROP CONSTRAINT upload_retirements_pkey, ADD PRIMARY KEY (asset_id, object_key)
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retirement keys stay per object; use a compatible rollback image")
    }
}
