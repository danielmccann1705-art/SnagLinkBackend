import Fluent
import FluentSQL

struct CreateMagicLinkAuthTokens: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS magic_link_auth_tokens (
                id UUID PRIMARY KEY,
                token_hash TEXT NOT NULL,
                email TEXT NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL,
                consumed_at TIMESTAMPTZ,
                requested_name TEXT,
                requesting_ip TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """).run()

        // Primary lookup path: hash on verify.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_link_auth_tokens_token_hash ON magic_link_auth_tokens(token_hash)").run()
        // Supports per-email rate-limit / abuse review and cleanup scans.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_link_auth_tokens_email ON magic_link_auth_tokens(email)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_link_auth_tokens_created_at ON magic_link_auth_tokens(created_at)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_link_auth_tokens").delete()
    }
}
