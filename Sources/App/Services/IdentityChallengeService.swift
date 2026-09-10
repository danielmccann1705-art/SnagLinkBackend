import Vapor
import Fluent
import FluentSQL

struct IdentityChallengeService {
    enum Purpose: String { case browserSignIn = "browser_signin", verifyEmail = "verify_email", reauthenticate }
    struct Challenge {
        let id: UUID
        let email: String
        let targetUserID: UUID?
        let requestedName: String?
    }

    static func issue(email: String, purpose: Purpose, targetUserID: UUID?, binding: String,
                      name: String? = nil, config: PlatformConfiguration, on db: Database) async throws -> String {
        let raw = try SecureTokenGenerator.generate(byteCount: 32), now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO identity_challenges (id, token_hash, purpose, email, target_user_id, binding_hash, origin, environment, requested_name, created_at, expires_at)
            VALUES (\(bind: UUID()), \(bind: SHA256Hasher.hash(token: raw)), \(bind: purpose.rawValue),
                    \(bind: EmailValidator.normalize(email)), \(bind: targetUserID), \(bind: SHA256Hasher.hash(token: binding)),
                    \(bind: config.origin), \(bind: config.environment), \(bind: name), \(bind: now), \(bind: now.addingTimeInterval(900)))
            """).run()
        return raw
    }

    /// Must execute in the same transaction as identity/session changes. Failed
    /// proof, wrong browser, expired tokens and identity collisions consume nothing.
    static func consume(_ raw: String, purpose: Purpose, binding: String, targetUserID: UUID?,
                        config: PlatformConfiguration, on db: Database) async throws -> Challenge {
        guard !raw.isEmpty, raw.count <= 128 else { throw Abort(.badRequest, reason: "Invalid verification code") }
        let hash = SHA256Hasher.hash(token: raw)
        try await VerifiedIdentityService.lock("identity-challenge:" + hash, on: db)
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT id, email, target_user_id, requested_name, binding_hash FROM identity_challenges
            WHERE token_hash = \(bind: hash) AND purpose = \(bind: purpose.rawValue)
              AND environment = \(bind: config.environment) AND origin = \(bind: config.origin)
              AND expires_at > \(bind: Date()) AND consumed_at IS NULL
            """).first() else { throw Abort(.gone, reason: "This verification link has expired or has already been used") }
        guard BrowserSessionService.constantTimeEqual(try row.decode(column: "binding_hash", as: String.self), SHA256Hasher.hash(token: binding)),
              try row.decode(column: "target_user_id", as: UUID?.self) == targetUserID else {
            throw Abort(.conflict, reason: "Return to the browser or app that requested this link, or request a new link here", identifier: "verification_context_mismatch")
        }
        let id = try row.decode(column: "id", as: UUID.self)
        try await VerifiedIdentityService.sql(db).raw("UPDATE identity_challenges SET consumed_at = \(bind: Date()) WHERE id = \(bind: id)").run()
        return try Challenge(id: id, email: row.decode(column: "email", as: String.self), targetUserID: targetUserID, requestedName: row.decode(column: "requested_name", as: String?.self))
    }
}
