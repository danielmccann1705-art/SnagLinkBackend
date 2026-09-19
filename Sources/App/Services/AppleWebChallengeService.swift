import Vapor
import Fluent
import FluentSQL

struct AppleWebChallengeService {
    static let lifetime: TimeInterval = 600
    struct Issued: Sendable { let state: String; let nonce: String }
    struct Context: Sendable { let id: UUID; let nonceHash: String; let createdAt: Date }
    static func issue(binding: String, platform: PlatformConfiguration, provider: AppleWebConfiguration, on db: Database) async throws -> Issued {
        let state = try SecureTokenGenerator.generate(byteCount: 32), nonce = try SecureTokenGenerator.generate(byteCount: 32), now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO apple_web_challenges(id,state_hash,nonce_hash,binding_hash,environment,origin,client_id,redirect_uri,created_at,expires_at)
            VALUES(\(bind: UUID()),\(bind: SHA256Hasher.hash(token: state)),\(bind: SHA256Hasher.hash(token: nonce)),
                \(bind: SHA256Hasher.hash(token: binding)),\(bind: platform.environment),\(bind: platform.origin),
                \(bind: provider.clientID),\(bind: provider.redirectURI),\(bind: now),\(bind: now.addingTimeInterval(lifetime)))
            """).run()
        return .init(state: state, nonce: nonce)
    }
    static func validOpaque(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    /// Committed before the provider exchange. A spent code or ambiguous network
    /// result requires a fresh sign-in; neither callback replay nor parallel tabs
    /// can exchange the same challenge twice.
    static func consume(state: String, binding: String, platform: PlatformConfiguration,
                        provider: AppleWebConfiguration, on db: Database) async throws -> Context {
        guard validOpaque(state), validOpaque(binding) else { throw contextMismatch() }
        return try await db.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            guard let row = try await sql.raw("""
                SELECT id,nonce_hash,binding_hash,created_at,consumed_at,expires_at,environment,origin,client_id,redirect_uri
                FROM apple_web_challenges WHERE state_hash=\(bind: SHA256Hasher.hash(token: state)) FOR UPDATE
                """).first() else { throw expired() }
            guard try row.decode(column: "consumed_at", as: Date?.self) == nil,
                  try row.decode(column: "expires_at", as: Date.self) > Date() else { throw expired() }
            guard try row.decode(column: "environment", as: String.self) == platform.environment,
                  try row.decode(column: "origin", as: String.self) == platform.origin,
                  try row.decode(column: "client_id", as: String.self) == provider.clientID,
                  try row.decode(column: "redirect_uri", as: String.self) == provider.redirectURI,
                  BrowserSessionService.constantTimeEqual(try row.decode(column: "binding_hash", as: String.self), SHA256Hasher.hash(token: binding)) else {
                throw contextMismatch()
            }
            let context = try Context(id: row.decode(column: "id", as: UUID.self), nonceHash: row.decode(column: "nonce_hash", as: String.self), createdAt: row.decode(column: "created_at", as: Date.self))
            try await sql.raw("UPDATE apple_web_challenges SET consumed_at=NOW() WHERE id=\(bind: context.id)").run()
            return context
        }
    }
    static func expired() -> Abort { Abort(.gone, reason: "This Apple sign-in has expired or was already used. Start again", identifier: "apple_challenge_expired") }
    static func contextMismatch() -> Abort { Abort(.conflict, reason: "Return to the browser that started Apple sign-in", identifier: "verification_context_mismatch") }
}
