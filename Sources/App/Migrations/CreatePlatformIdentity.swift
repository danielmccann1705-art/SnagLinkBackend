import Fluent
import FluentSQL
import Vapor

/// Additive identity/session foundation. Legacy profile emails are deliberately not
/// backfilled as verified identities: older clients could edit those values.
struct CreatePlatformIdentity: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users ADD COLUMN lifecycle_state TEXT NOT NULL DEFAULT 'active', ADD COLUMN auth_version INTEGER NOT NULL DEFAULT 0").run()
        try await sql.raw("""
            CREATE TABLE user_identities (
                id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id),
                provider TEXT NOT NULL CHECK (provider IN ('apple', 'email')),
                subject TEXT NOT NULL, verified_at TIMESTAMPTZ NOT NULL,
                UNIQUE(provider, subject)
            )
            """).run()
        try await sql.raw("CREATE INDEX user_identities_user ON user_identities(user_id)").run()
        try await sql.raw("""
            CREATE TABLE browser_sessions (
                id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id),
                token_hash TEXT NOT NULL UNIQUE, csrf_hash TEXT NOT NULL,
                environment TEXT NOT NULL, origin TEXT NOT NULL,
                auth_version INTEGER NOT NULL, authenticated_at TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                revoked_at TIMESTAMPTZ
            )
            """).run()
        try await sql.raw("CREATE INDEX browser_sessions_user ON browser_sessions(user_id)").run()
        try await sql.raw("""
            CREATE TABLE identity_challenges (
                id UUID PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
                purpose TEXT NOT NULL CHECK (purpose IN ('browser_signin', 'verify_email', 'reauthenticate')),
                email TEXT NOT NULL, target_user_id UUID REFERENCES users(id),
                binding_hash TEXT NOT NULL, origin TEXT NOT NULL, environment TEXT NOT NULL,
                requested_name TEXT, created_at TIMESTAMPTZ NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL, consumed_at TIMESTAMPTZ
            )
            """).run()
        try await sql.raw("CREATE INDEX identity_challenges_expiry ON identity_challenges(expires_at)").run()
    }

    func revert(on database: Database) async throws {
        // Sessions may be removed in disposable tests. User identities must never be
        // silently destroyed as an operational rollback of a deployed platform.
        throw Abort(.conflict, reason: "Restore the previous compatible image; identity schema rollback requires an explicit recovery migration")
    }
}
