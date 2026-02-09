import Fluent
import FluentSQL

struct CreateSyncedDrawing: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS synced_drawings (
                id UUID PRIMARY KEY,
                magic_link_token TEXT NOT NULL,
                drawing_id UUID NOT NULL,
                file_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                created_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_synced_drawings_token ON synced_drawings(magic_link_token)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("synced_drawings").delete()
    }
}
