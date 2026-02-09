import Fluent
import FluentSQL

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY,
                apple_user_id TEXT NOT NULL,
                email TEXT,
                name TEXT,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:users.apple_user_id" UNIQUE (apple_user_id)
            )
            """).run()

        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_user_id ON users(apple_user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
    }
}
