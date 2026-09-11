import Vapor
import Fluent
import FluentSQL

enum GoogleIdentityPurpose: String, Sendable { case signIn = "signin", link }

struct GoogleIdentityChallengeService {
    static let lifetime: TimeInterval = 600
    struct Issued: Sendable {
        let token: String
        let nonce: String
    }
    struct Context: Sendable {
        let id: UUID
        let nonceHash: String
        let createdAt: Date
    }

    static func issue(purpose: GoogleIdentityPurpose, surface: GoogleIdentitySurface,
                      binding: String, targetUserID: UUID? = nil, browserSessionID: UUID? = nil,
                      platform: PlatformConfiguration, provider: GoogleIdentityConfiguration,
                      on db: Database) async throws -> Issued {
        guard (32...160).contains(binding.utf8.count),
              (purpose == .link) == (targetUserID != nil),
              surface == .web || browserSessionID == nil,
              purpose == .link || browserSessionID == nil else { throw Abort(.badRequest) }
        let version: Int?
        if let targetUserID { version = try await VerifiedIdentityService.activeUser(targetUserID, on: db).authVersion }
        else { version = nil }
        let token = try SecureTokenGenerator.generate(byteCount: 32)
        let nonce = try SecureTokenGenerator.generate(byteCount: 32)
        let now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO google_identity_challenges
              (id, token_hash, nonce_hash, purpose, surface, target_user_id, target_auth_version, browser_session_id,
               binding_hash, environment, origin, web_client_id, ios_client_id, created_at, expires_at)
            VALUES (\(bind: UUID()), \(bind: SHA256Hasher.hash(token: token)), \(bind: SHA256Hasher.hash(token: nonce)),
                    \(bind: purpose.rawValue), \(bind: surface.rawValue), \(bind: targetUserID), \(bind: version), \(bind: browserSessionID),
                    \(bind: SHA256Hasher.hash(token: binding)), \(bind: platform.environment), \(bind: platform.origin),
                    \(bind: provider.webClientID), \(bind: provider.iosClientID), \(bind: now), \(bind: now.addingTimeInterval(lifetime)))
            """).run()
        return Issued(token: token, nonce: nonce)
    }

    /// Read context before the provider verification network call. Recheck it
    /// under the transaction lock before committing an identity or session.
    static func context(_ raw: String, purpose: GoogleIdentityPurpose, surface: GoogleIdentitySurface,
                        binding: String, targetUserID: UUID? = nil, browserSessionID: UUID? = nil,
                        platform: PlatformConfiguration, provider: GoogleIdentityConfiguration,
                        on db: Database) async throws -> Context {
        guard (32...128).contains(raw.utf8.count), (32...160).contains(binding.utf8.count) else { throw Abort(.badRequest) }
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT id, nonce_hash, binding_hash, target_user_id, target_auth_version, browser_session_id, created_at
            FROM google_identity_challenges
            WHERE token_hash = \(bind: SHA256Hasher.hash(token: raw)) AND purpose = \(bind: purpose.rawValue)
              AND surface = \(bind: surface.rawValue) AND environment = \(bind: platform.environment) AND origin = \(bind: platform.origin)
              AND web_client_id = \(bind: provider.webClientID) AND ios_client_id = \(bind: provider.iosClientID)
              AND consumed_at IS NULL AND expires_at > \(bind: Date())
            """).first() else {
            throw Abort(.gone, reason: "This Google sign-in has expired or has already been used. Start again", identifier: "google_challenge_expired")
        }
        guard BrowserSessionService.constantTimeEqual(try row.decode(column: "binding_hash", as: String.self), SHA256Hasher.hash(token: binding)),
              try row.decode(column: "target_user_id", as: UUID?.self) == targetUserID,
              try row.decode(column: "browser_session_id", as: UUID?.self) == browserSessionID else {
            throw Abort(.conflict, reason: "Return to the browser or app that started Google sign-in", identifier: "verification_context_mismatch")
        }
        if let targetUserID {
            let user = try await VerifiedIdentityService.activeUser(targetUserID, on: db)
            guard user.authVersion == (try row.decode(column: "target_auth_version", as: Int?.self)) else { throw Abort(.unauthorized) }
        }
        if let browserSessionID, let targetUserID {
            guard try await VerifiedIdentityService.sql(db).raw("""
                SELECT id FROM browser_sessions WHERE id = \(bind: browserSessionID) AND user_id = \(bind: targetUserID)
                  AND revoked_at IS NULL AND expires_at > \(bind: Date())
                  AND environment = \(bind: platform.environment) AND origin = \(bind: platform.origin)
                """).first() != nil else { throw Abort(.unauthorized) }
        }
        return try Context(id: row.decode(column: "id", as: UUID.self), nonceHash: row.decode(column: "nonce_hash", as: String.self), createdAt: row.decode(column: "created_at", as: Date.self))
    }

    /// Caller owns the database transaction covering this consumption and all
    /// identity/session writes. Failed proof or identity collision rolls it back.
    static func consume(_ raw: String, purpose: GoogleIdentityPurpose, surface: GoogleIdentitySurface,
                        binding: String, targetUserID: UUID? = nil, browserSessionID: UUID? = nil,
                        platform: PlatformConfiguration, provider: GoogleIdentityConfiguration,
                        on db: Database) async throws -> Context {
        guard (32...128).contains(raw.utf8.count) else { throw Abort(.badRequest) }
        try await VerifiedIdentityService.lock("google-challenge:" + SHA256Hasher.hash(token: raw), on: db)
        // Match revocation's user -> session lock order. A logout racing this
        // transaction must serialise before or after the linked-identity write.
        if let targetUserID {
            _ = try await VerifiedIdentityService.sql(db).raw("SELECT id FROM users WHERE id = \(bind: targetUserID) FOR NO KEY UPDATE").first()
        }
        if let browserSessionID {
            _ = try await VerifiedIdentityService.sql(db).raw("SELECT id FROM browser_sessions WHERE id = \(bind: browserSessionID) FOR NO KEY UPDATE").first()
        }
        let context = try await Self.context(raw, purpose: purpose, surface: surface, binding: binding,
            targetUserID: targetUserID, browserSessionID: browserSessionID, platform: platform, provider: provider, on: db)
        try await VerifiedIdentityService.sql(db).raw("UPDATE google_identity_challenges SET consumed_at = \(bind: Date()) WHERE id = \(bind: context.id)").run()
        return context
    }
}
