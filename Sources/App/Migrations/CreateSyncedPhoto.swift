import Fluent
import FluentSQL

struct CreateSyncedPhoto: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS synced_photos (
                id UUID PRIMARY KEY,
                magic_link_token TEXT NOT NULL,
                snag_id UUID NOT NULL,
                label TEXT NOT NULL,
                file_path TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_synced_photos_token ON synced_photos(magic_link_token)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("synced_photos").delete()
    }
}
