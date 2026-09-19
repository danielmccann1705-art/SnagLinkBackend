import Vapor
import Fluent
import FluentSQL
@preconcurrency import JWT

struct AppleWebTokenResponse: Content {
    let idToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case idToken = "id_token", refreshToken = "refresh_token" }
}
struct AppleWebProof: Sendable { let subject: String; let email: String?; let emailVerified: Bool }

enum AppleWebIdentityService {
    static func exchange(code: String, configuration: AppleWebConfiguration, req: Request) async throws -> AppleWebTokenResponse {
        let secret: String
        do { secret = try configuration.exchange.clientSecret() }
        catch { throw AppleWebConfiguration.unavailable() }
        let response: ClientResponse
        do {
            response = try await req.client.post(AppleTokenService.tokenEndpoint) { request in
                try request.content.encode(["client_id": configuration.clientID,"client_secret": secret,"code": code,
                    "grant_type": "authorization_code","redirect_uri": configuration.redirectURI], as: .urlEncodedForm)
            }
        } catch { throw exchangeUnavailable() }
        guard response.status == .ok else {
            if response.status == .badRequest,
               (try? response.content.decode(AppleErrorResponse.self))?.error == "invalid_grant" {
                throw invalidIdentity()
            }
            throw exchangeUnavailable()
        }
        guard let tokens = try? response.content.decode(AppleWebTokenResponse.self),
              (1...16384).contains(tokens.idToken.utf8.count), (1...4096).contains(tokens.refreshToken.utf8.count) else {
            throw exchangeUnavailable()
        }
        return tokens
    }
    static func verify(_ token: String, context: AppleWebChallengeService.Context, configuration: AppleWebConfiguration, req: Request) async throws -> AppleWebProof {
        do { try validateEnvelope(token) } catch { throw invalidIdentity() }
        let signers: JWTSigners
        do { signers = try await req.application.jwt.apple.signers(on: req) }
        catch { throw exchangeUnavailable() }
        do {
            let claims = try signers.verify(token, as: AppleIdentityToken.self)
            let now = Date()
            guard claims.issuer.value == "https://appleid.apple.com", claims.audience.value == [configuration.clientID],
                  claims.expires.value > now, claims.issuedAt.value <= now.addingTimeInterval(30),
                  claims.issuedAt.value >= context.createdAt.addingTimeInterval(-30),
                  !claims.subject.value.isEmpty, claims.subject.value.utf8.count <= 255,
                  claims.subject.value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
                  let nonce = claims.nonce, AppleWebChallengeService.validOpaque(nonce),
                  BrowserSessionService.constantTimeEqual(SHA256Hasher.hash(token: nonce), context.nonceHash) else { throw invalidIdentity() }
            let email = claims.email.map(EmailValidator.normalize).flatMap {
                $0.count <= 254 && EmailValidator.isValidFormat($0) ? $0 : nil
            }
            return .init(subject: claims.subject.value, email: email, emailVerified: email != nil && claims.emailVerified?.value == true)
        } catch { throw invalidIdentity() }
    }
    private static func validateEnvelope(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16384, parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), parts[0].count <= 2048 else { throw invalidIdentity() }
        var base64 = String(parts[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4-base64.count%4)%4)
        struct Header: Decodable { let alg: String; let kid: String }
        guard let data = Data(base64Encoded: base64), let header = try? JSONDecoder().decode(Header.self, from: data),
              header.alg == "RS256", !header.kid.isEmpty, header.kid.utf8.count <= 128 else { throw invalidIdentity() }
    }
    /// The verified Apple subject selects the account. An equal contact email
    /// never merges an Apple identity into an existing email/Google account.
    static func resolve(_ proof: AppleWebProof, name: String?, on db: Database) async throws -> User {
        try await VerifiedIdentityService.lock("identity-apple:" + proof.subject, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        let existing = try await sql.raw("""
            SELECT user_id AS id FROM user_identities WHERE provider='apple' AND subject=\(bind: proof.subject)
            UNION SELECT id FROM users WHERE apple_user_id=\(bind: proof.subject) LIMIT 1
            """).first()
        if let existing {
            let id = try existing.decode(column: "id", as: UUID.self)
            _ = try await sql.raw("SELECT id FROM users WHERE id=\(bind: id) FOR UPDATE").first()
            let user = try await VerifiedIdentityService.resolveApple(subject: proof.subject, email: proof.email, name: name, on: db)
            return user
        }
        if let email = proof.email {
            try await VerifiedIdentityService.lock("identity-email:" + email, on: db)
            guard try await sql.raw("""
                SELECT id FROM users WHERE lower(btrim(email))=\(bind: email)
                UNION SELECT user_id AS id FROM user_identities WHERE provider='email' AND subject=\(bind: email) LIMIT 1
                """).first() == nil else {
                throw Abort(.conflict, reason: "Use your existing Snaglist sign-in to access that account", identifier: "identity_proof_required")
            }
        }
        return try await VerifiedIdentityService.resolveApple(subject: proof.subject, email: proof.email, name: name, on: db)
    }
    static func invalidIdentity() -> Abort { Abort(.unauthorized, reason: "Apple sign-in could not be verified. Start again", identifier: "apple_identity_invalid") }
    static func exchangeUnavailable() -> Abort { Abort(.serviceUnavailable, reason: "Apple sign-in is temporarily unavailable. Start again shortly", identifier: "apple_exchange_unavailable") }
}
