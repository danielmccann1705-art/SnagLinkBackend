import Fluent
import FluentSQL

struct CreateMagicLinkAccess: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Use raw SQL with IF NOT EXISTS to handle partial migration state
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS magic_link_accesses (
                id UUID PRIMARY KEY,
                magic_link_id UUID NOT NULL REFERENCES magic_links(id) ON DELETE CASCADE,
                ip_address TEXT NOT NULL,
                user_agent TEXT,
                country TEXT,
                city TEXT,
                pin_verified BOOLEAN NOT NULL DEFAULT false,
                accessed_at TIMESTAMPTZ
            )
            """).run()

        // Create index on magic_link_id for fast lookups
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_link_accesses_magic_link_id ON magic_link_accesses(magic_link_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_link_accesses").delete()
    }
}
