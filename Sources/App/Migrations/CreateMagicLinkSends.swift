import Fluent
import FluentSQL

/// B4: records counted magic-link sends for the monthly free-tier allowance.
struct CreateMagicLinkSends: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS magic_link_sends (
                id UUID PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                magic_link_id UUID NOT NULL,
                sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """).run()

        // Supports the "sends this calendar month for user" count.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_link_sends_user_sent ON magic_link_sends(user_id, sent_at)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_link_sends").delete()
    }
}
