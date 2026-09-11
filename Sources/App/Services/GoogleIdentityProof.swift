import Vapor
@preconcurrency import JWT

/// Configuration is explicit per environment. A test client must never silently
/// become the production audience. This foundation is not yet exposed as a route.
struct GoogleIdentityConfiguration: Sendable {
    let webClientID: String
    let iosClientID: String

    static func load(platform: PlatformConfiguration) throws -> Self {
        guard Environment.get("GOOGLE_AUTH_ENVIRONMENT") == platform.environment,
              let web = Environment.get("GOOGLE_WEB_CLIENT_ID"),
              let ios = Environment.get("GOOGLE_IOS_CLIENT_ID"),
              validClientID(web), validClientID(ios), web != ios else {
            throw Abort(.serviceUnavailable, reason: "Google sign-in is not configured")
        }
        return Self(webClientID: web, iosClientID: ios)
    }

    static func validClientID(_ value: String) -> Bool {
        value.count <= 200 && value.range(of: #"^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    }
}

struct GoogleIdentityProof: Sendable {
    let subject: String
    /// Contact hints only. Google sign-in never creates an email-provider identity
    /// or selects an existing Snaglist account by matching these fields.
    let contactEmail: String?
    let displayName: String?
}

enum GoogleIdentitySurface: String, Codable, Sendable { case web, ios }

struct GoogleIdentityClaims: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let azp: String?
    let nonce: String?
    let email: String?
    let name: String?

    func verify(using signer: JWTSigner) throws {
        guard ["https://accounts.google.com", "accounts.google.com"].contains(iss.value),
              !sub.value.isEmpty, sub.value.utf8.count <= 255,
              sub.value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw Abort(.unauthorized, reason: "Invalid Google identity")
        }
        try exp.verifyNotExpired()
    }
}

struct GoogleIdentityVerifier {
    /// Uses Vapor's fixed Google JWKS endpoint/cache, not an untrusted token URL.
    /// The caller must consume its one-use challenge in the same transaction as
    /// account/session creation after this proof succeeds.
    static func verify(_ token: String, surface: GoogleIdentitySurface,
                       nonceHash: String, challengeCreatedAt: Date,
                       config: GoogleIdentityConfiguration, on req: Request) async throws -> GoogleIdentityProof {
        try validateEnvelope(token)
        let signers: JWTSigners = try await req.application.jwt.google.signers(on: req)
        return try verify(token, signers: signers, surface: surface, nonceHash: nonceHash,
                          challengeCreatedAt: challengeCreatedAt, config: config)
    }

    /// Separate cryptographic boundary permits signed synthetic-key tests. Never
    /// supplies test signers to the production request entry above.
    static func verify(_ token: String, signers: JWTSigners, surface: GoogleIdentitySurface,
                       nonceHash: String, challengeCreatedAt: Date,
                       config: GoogleIdentityConfiguration, now: Date = Date()) throws -> GoogleIdentityProof {
        do {
            try validateEnvelope(token)
            let claims = try signers.verify(token, as: GoogleIdentityClaims.self)
            guard GoogleIdentityConfiguration.validClientID(config.webClientID),
                  GoogleIdentityConfiguration.validClientID(config.iosClientID),
                  config.webClientID != config.iosClientID,
                  claims.aud.value == [config.webClientID],
                  claims.iat.value <= now.addingTimeInterval(30),
                  claims.iat.value >= challengeCreatedAt.addingTimeInterval(-30),
                  claims.exp.value > now,
                  let nonce = claims.nonce, (32...128).contains(nonce.utf8.count),
                  BrowserSessionService.constantTimeEqual(SHA256Hasher.hash(token: nonce), nonceHash) else {
                throw Abort(.unauthorized)
            }
            switch surface {
            case .web:
                guard claims.azp == nil || claims.azp == config.webClientID else { throw Abort(.unauthorized) }
            case .ios:
                guard claims.azp == config.iosClientID else { throw Abort(.unauthorized) }
            }
            let email = claims.email.map(EmailValidator.normalize).flatMap {
                $0.count <= 254 && EmailValidator.isValidFormat($0) ? $0 : nil
            }
            let name = claims.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GoogleIdentityProof(subject: claims.sub.value, contactEmail: email,
                                       displayName: name.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) })
        } catch {
            // JWT library diagnostics can contain claim values. Keep those out of
            // the response and logs; a provider credential is never diagnostic text.
            throw Abort(.unauthorized, reason: "Google sign-in could not be verified. Start sign-in again", identifier: "google_identity_invalid")
        }
    }

    private static func validateEnvelope(_ token: String) throws {
        guard token.utf8.count <= 16_384 else { throw Abort(.unauthorized) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), parts[0].count <= 2048 else { throw Abort(.unauthorized) }
        var encoded = String(parts[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        struct Header: Decodable { let alg: String; let kid: String }
        guard let data = Data(base64Encoded: encoded), let header = try? JSONDecoder().decode(Header.self, from: data),
              header.alg == "RS256", !header.kid.isEmpty, header.kid.utf8.count <= 128 else {
            throw Abort(.unauthorized, reason: "Invalid Google identity token")
        }
    }
}
