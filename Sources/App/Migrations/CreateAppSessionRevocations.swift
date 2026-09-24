import Vapor
import Fluent

/// Per-device sign-out for app sessions (`AppSessionRevocationService`).
///
/// One row per signed-out app session, and only until that session's token would have
/// expired anyway (30 days at most), after which the scheduled cleanup pass removes it.
/// `session_id` is the token's `jti`, or for a token issued before `jti` existed, the
/// version 8 UUID derived from its signed part. Nothing here is a credential: the token
/// is never stored, only which session was ended and when it stops mattering.
///
/// `ON DELETE CASCADE`: a row only ever narrows what its own account can do, so it has
/// no reason to outlive the account row. Account deletion also removes the account's
/// rows in its request transaction (it bumps `auth_version`, which already refuses every
/// session the account has).
///
/// An image older than this migration ignores the table: a session signed out under
/// this revision would be accepted again by an older image until its token expires.
/// Tokens this revision issues carry `jti`, which an older image ignores, so a rollback
/// does not sign anyone out.
struct CreateAppSessionRevocations: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE app_session_revocations (
                    session_id UUID PRIMARY KEY,
                    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    expires_at TIMESTAMPTZ NOT NULL,
                    revoked_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """).run()
            try await sql.raw("CREATE INDEX app_session_revocations_expiry ON app_session_revocations(expires_at)").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Sign-out revocations must survive rollback; use a compatible image")
    }
}
