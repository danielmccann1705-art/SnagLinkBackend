import Fluent
import FluentSQL
import Vapor

/// Holds the Apple refresh token an account deletion needs in order to revoke the
/// user's Sign in with Apple grant.
///
/// Its own table, not a column on `users`: `users` is read on every authenticated
/// request and this value has no business travelling with it. One row per user,
/// replaced on each sign-in, removed when the credential is spent.
struct CreateAppleCredentials: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS apple_credentials (
                user_id UUID PRIMARY KEY REFERENCES users(id),
                refresh_token_ciphertext TEXT NOT NULL,
                client_id TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL
            )
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("DROP TABLE IF EXISTS apple_credentials").run()
    }
}
