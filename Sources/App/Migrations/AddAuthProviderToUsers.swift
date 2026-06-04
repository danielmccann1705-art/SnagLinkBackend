import Fluent
import FluentSQL

/// Supports passwordless (magic-link) Project Manager accounts alongside Sign in with Apple.
///
/// Magic-link users have no Apple identifier, so `apple_user_id` is made nullable and a
/// non-null `auth_provider` column records how the account was created. Existing rows are
/// all Apple accounts and default to `'apple'`.
struct AddAuthProviderToUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Allow accounts with no Apple identity (magic-link / future providers).
        try await sql.raw("ALTER TABLE users ALTER COLUMN apple_user_id DROP NOT NULL").run()

        // Record the account's auth provider. Existing rows are Apple sign-ins.
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS auth_provider TEXT NOT NULL DEFAULT 'apple'").run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS auth_provider").run()
        // Note: re-imposing NOT NULL on apple_user_id is unsafe if magic-link rows exist;
        // intentionally left nullable on revert.
    }
}
