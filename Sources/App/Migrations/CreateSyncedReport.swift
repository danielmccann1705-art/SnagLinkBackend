import Fluent
import FluentSQL

struct CreateSyncedReport: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS synced_reports (
                id UUID PRIMARY KEY,
                magic_link_token TEXT NOT NULL,
                report_json TEXT NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:synced_reports.magic_link_token" UNIQUE (magic_link_token)
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_synced_reports_token ON synced_reports(magic_link_token)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("synced_reports").delete()
    }
}
