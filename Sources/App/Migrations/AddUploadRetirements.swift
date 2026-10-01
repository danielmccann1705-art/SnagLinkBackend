import Fluent
import FluentSQL
import Vapor

/// Lane A WP4 (FABLE-DESIGN-A-AMENDMENT §4.4–4.5), staging first. Schema only, additive: an older image ignores both.
///
/// - `media_assets.retired_at`: when an unattached upload was retired — removed by its uploader, discarded with its
///   draft, or swept after expiry. The row stays, as `retired`: it is the admission control every later allocate, PUT
///   and attachment re-authorises against (`PrivateMediaService.requireUploader` → 410 "This upload was retired").
/// - `upload_retirements`: one row per object key of a retired upload, waiting for (`pending`) or carrying (`fenced`)
///   the erasure fence that replaces its bytes. No token, no body, no tenant parsing of keys. Its rows live and die
///   with the media row (`ON DELETE CASCADE`): a deletion graph that removes the media row has already taken its keys
///   into its own manifest and fences them itself, so nothing here can hold a deletion up or outlive it.
struct AddUploadRetirements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE media_assets ADD COLUMN retired_at TIMESTAMPTZ").run()
            try await sql.raw("""
                CREATE TABLE upload_retirements (
                    asset_id UUID NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('original', 'rendition')),
                    object_key TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending', 'fenced')),
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
                    last_kind TEXT, etag TEXT,
                    created_at TIMESTAMPTZ NOT NULL, fenced_at TIMESTAMPTZ,
                    PRIMARY KEY(asset_id, role),
                    CHECK((state = 'fenced') = (fenced_at IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE INDEX upload_retirements_pending ON upload_retirements(created_at) WHERE state = 'pending'").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retired uploads stay retired; use a compatible rollback image")
    }
}
