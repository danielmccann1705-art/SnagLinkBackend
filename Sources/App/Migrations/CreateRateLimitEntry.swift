import Fluent

struct CreateRateLimitEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("rate_limit_entries")
            .id()
            .field("key", .string, .required)
            .field("action", .string, .required)
            .field("count", .int, .required, .custom("DEFAULT 1"))
            .field("window_start", .datetime, .required)
            .field("window_end", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // Create composite index for fast lookups
        try await database.schema("rate_limit_entries")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_rate_limit_entries_key_action ON rate_limit_entries(key, action)"))
            .update()

        // Create index on window_end for cleanup queries
        try await database.schema("rate_limit_entries")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_rate_limit_entries_window_end ON rate_limit_entries(window_end)"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("rate_limit_entries").delete()
    }
}
