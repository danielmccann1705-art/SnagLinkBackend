import Vapor
import Fluent
import FluentSQL
import Crypto

/// Signing out of the app on one device (`POST /api/v1/auth/logout`).
///
/// App sessions are bearer JWTs that live for 30 days. Until now the only way to end
/// one early was `POST /api/v2/auth/logout-all`, which bumps `auth_version` and so ends
/// every session the account has: the portal, and every other phone. Signing out of
/// the app itself revoked nothing on the server.
///
/// Each app session now has an identifier:
///
/// * Tokens issued from this revision on carry a random UUID as `jti`
///   (`UserJWTPayload.sessionID`), set by `AuthController.issueAuthResponse`, the only
///   issuer of app tokens.
/// * Tokens issued before it carry no `jti`. They keep working until they expire, so a
///   deploy signs nobody out. Their session is named by a UUID derived from the token
///   itself (`legacySessionID`): SHA-256 over the token's signed header and payload,
///   never over its signature segment. HS256 has one valid signature per signed input,
///   so this is the same for every spelling of the token that verifies, and a stolen
///   copy cannot escape a revocation by re-encoding its signature.
///
/// A sign-out writes one row to `app_session_revocations`, keyed by that identifier and
/// kept until the token's own expiry. `JWTAuthMiddleware.authenticate` reads it in the
/// same query as the account (one primary-key probe per request). Nothing else about
/// authentication changes: `auth_version` still ends every session at once, and account
/// deletion still bumps it.
enum AppSessionRevocationService {
    /// Rows are kept this long after the token they name has expired, then removed by the
    /// scheduled cleanup pass. The token itself is refused from its `exp` on; the margin
    /// only absorbs clock differences between instances and the database.
    static let retentionAfterExpiry: TimeInterval = 24 * 60 * 60

    struct AccountState: Sendable {
        let lifecycleState: String
        let authVersion: Int
        let sessionRevoked: Bool
    }

    /// The session a verified app token belongs to: its `jti`, or for a token issued
    /// before per-session sign-out, the identifier derived from the token.
    static func sessionID(for payload: UserJWTPayload, token: String) -> UUID {
        payload.sessionID ?? legacySessionID(token: token)
    }

    /// A version 8 (RFC 9562, implementation-defined) UUID from the token's signed part,
    /// `header.payload`. Random `jti` values are version 4, so the two never collide.
    static func legacySessionID(token: String) -> UUID {
        let signed = token.lastIndex(of: ".").map { token[..<$0] } ?? Substring(token)
        let digest = SHA256.hash(data: Data(("snaglist-app-session-v1:" + String(signed)).utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The account and this session's revocation, in one round trip. Nil when the
    /// account does not exist.
    static func accountState(userID: UUID, sessionID: UUID, on db: Database) async throws -> AccountState? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT u.lifecycle_state, u.auth_version,
                   EXISTS (SELECT 1 FROM app_session_revocations r
                           WHERE r.session_id = \(bind: sessionID) AND r.user_id = u.id) AS revoked
            FROM users u WHERE u.id = \(bind: userID)
            """).first() else { return nil }
        return try AccountState(lifecycleState: row.decode(column: "lifecycle_state", as: String.self),
                                authVersion: row.decode(column: "auth_version", as: Int.self),
                                sessionRevoked: row.decode(column: "revoked", as: Bool.self))
    }

    /// Ends the presented session only. Idempotent: a second write for the same session
    /// changes nothing (in practice the caller is refused first, with 401).
    static func revoke(_ payload: UserJWTPayload, token: String, on db: Database, now: Date = Date()) async throws {
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO app_session_revocations (session_id, user_id, expires_at, revoked_at)
            VALUES (\(bind: sessionID(for: payload, token: token)), \(bind: payload.userId),
                    \(bind: payload.expiration.value), \(bind: now))
            ON CONFLICT (session_id) DO NOTHING
            """).run()
    }

    /// Scheduled cleanup: rows whose token expired more than `retentionAfterExpiry` ago.
    /// Returns a count only.
    static func removeExpired(on db: Database, now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-retentionAfterExpiry)
        let row = try await VerifiedIdentityService.sql(db).raw("""
            WITH removed AS (DELETE FROM app_session_revocations WHERE expires_at < \(bind: cutoff) RETURNING 1)
            SELECT count(*) AS total FROM removed
            """).first()
        return try row?.decode(column: "total", as: Int.self) ?? 0
    }
}
