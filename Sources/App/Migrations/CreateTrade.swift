import Fluent
import FluentSQL

struct CreateTrade: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS trades (
                id UUID PRIMARY KEY,
                name TEXT NOT NULL,
                color_hex TEXT NOT NULL,
                sort_order BIGINT NOT NULL DEFAULT 0,
                is_archived BOOLEAN NOT NULL DEFAULT false,
                is_default BOOLEAN NOT NULL DEFAULT false,
                owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_trades_owner_id ON trades(owner_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("trades").delete()
    }
}
