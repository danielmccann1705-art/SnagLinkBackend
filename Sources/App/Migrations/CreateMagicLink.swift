import Fluent
import FluentSQL

struct CreateMagicLink: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Use raw SQL with IF NOT EXISTS to handle partial migration state
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS magic_links (
                id UUID PRIMARY KEY,
                token TEXT NOT NULL,
                access_level TEXT NOT NULL,
                pin_hash TEXT,
                pin_salt TEXT,
                expires_at TIMESTAMPTZ NOT NULL,
                revoked_at TIMESTAMPTZ,
                open_count BIGINT NOT NULL DEFAULT 0,
                last_opened_at TIMESTAMPTZ,
                failed_pin_attempts BIGINT NOT NULL DEFAULT 0,
                locked_until TIMESTAMPTZ,
                snag_ids UUID[] NOT NULL,
                project_id UUID NOT NULL,
                contractor_id UUID,
                created_by_id UUID NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:magic_links.token" UNIQUE (token)
            )
            """).run()

        // Create index on token for fast lookups
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_links_token ON magic_links(token)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_links").delete()
    }
}
