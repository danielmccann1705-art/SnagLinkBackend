import Fluent
import FluentSQL
import Vapor

struct CreateDeviceToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS device_tokens (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                device_token TEXT NOT NULL,
                platform TEXT NOT NULL DEFAULT 'ios',
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT "uq:device_tokens.device_token" UNIQUE (device_token)
            )
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id)
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("DROP TABLE IF EXISTS device_tokens").run()
    }
}
