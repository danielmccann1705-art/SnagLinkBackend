import Fluent
import FluentSQL

struct CreateRateLimitEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Use raw SQL with IF NOT EXISTS to handle partial migration state
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS rate_limit_entries (
                id UUID PRIMARY KEY,
                key TEXT NOT NULL,
                action TEXT NOT NULL,
                count BIGINT NOT NULL DEFAULT 1,
                window_start TIMESTAMPTZ NOT NULL,
                window_end TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        // Create composite index for fast lookups
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_rate_limit_entries_key_action ON rate_limit_entries(key, action)").run()

        // Create index on window_end for cleanup queries
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_rate_limit_entries_window_end ON rate_limit_entries(window_end)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("rate_limit_entries").delete()
    }
}
