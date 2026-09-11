import Fluent
import FluentSQL
import Vapor

/// Additive Google proof storage. Existing Apple/email identities and all user,
/// purchase and workspace IDs remain unchanged; there is no email-based backfill.
struct CreateGoogleIdentity: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("ALTER TABLE user_identities DROP CONSTRAINT user_identities_provider_check, ADD CONSTRAINT user_identities_provider_check CHECK (provider IN ('apple', 'email', 'google'))").run()
            try await sql.raw("CREATE UNIQUE INDEX user_identities_one_google_per_user ON user_identities(user_id) WHERE provider = 'google'").run()
            try await sql.raw("""
                CREATE TABLE google_identity_challenges (
                    id UUID PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, nonce_hash TEXT NOT NULL UNIQUE,
                    purpose TEXT NOT NULL CHECK (purpose IN ('signin', 'link')),
                    surface TEXT NOT NULL CHECK (surface IN ('web', 'ios')),
                    target_user_id UUID REFERENCES users(id) ON DELETE CASCADE,
                    target_auth_version INTEGER, browser_session_id UUID REFERENCES browser_sessions(id) ON DELETE CASCADE,
                    binding_hash TEXT NOT NULL, environment TEXT NOT NULL, origin TEXT NOT NULL,
                    web_client_id TEXT NOT NULL, ios_client_id TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL, consumed_at TIMESTAMPTZ,
                    CHECK ((purpose = 'signin' AND target_user_id IS NULL AND target_auth_version IS NULL AND browser_session_id IS NULL)
                        OR (purpose = 'link' AND target_user_id IS NOT NULL AND target_auth_version IS NOT NULL)),
                    CHECK (surface <> 'ios' OR browser_session_id IS NULL)
                )
                """).run()
            try await sql.raw("CREATE INDEX google_identity_challenges_expiry ON google_identity_challenges(expires_at)").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep verified identities and restore the previous compatible application image; schema rollback requires a recovery migration")
    }
}
