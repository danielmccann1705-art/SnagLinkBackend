import Vapor
import Crypto
@preconcurrency import JWT

/// Sign in with Apple configuration.
///
/// Two separate concerns, deliberately not coupled:
///
/// 1. **Audience validation** — which bundle identifiers this server will accept an
///    identity token for. This has a safe default so an existing deployment keeps
///    working with no new configuration, and it is never widened implicitly: an extra
///    audience has to be named, and it has to match the environment it belongs to.
/// 2. **Token exchange** — the Apple team, key and private key needed to turn an
///    authorization code into a refresh token. Absent by default. Without it the app
///    signs in exactly as before; with it we hold the credential account deletion
///    needs in order to revoke.
///
/// Never relax audience validation to make an environment work. Name the audience.
struct AppleIdentityConfiguration: Sendable {
    /// The shipping app. Always accepted.
    static let releaseAudience = "com.snaglist.app"
    static let stagingAudience = "com.snaglist.app.staging"

    let audiences: [String]
    let exchange: AppleTokenExchange?

    /// Never throws. Sign-in must not start failing because a new, optional
    /// credential is absent — that would take the release path down to add a
    /// staging capability.
    static func load(on app: Application) -> Self {
        if app.environment == .testing, let configured = app.storage[AppleIdentityConfigurationKey.self] { return configured }
        return Self(audiences: audiences(), exchange: AppleTokenExchange.load())
    }

    private static func audiences() -> [String] {
        guard let named = Environment.get("APPLE_BUNDLE_ID"), !named.isEmpty else { return [releaseAudience] }
        // An environment may name exactly one additional audience, and only the one
        // that belongs to it. `PLATFORM_ENVIRONMENT` is the same switch the rest of
        // the platform configuration keys off.
        let environment = Environment.get("PLATFORM_ENVIRONMENT")
        switch (environment, named) {
        case (_, releaseAudience):
            return [releaseAudience]
        case ("staging", stagingAudience), ("local", stagingAudience):
            return [releaseAudience, stagingAudience]
        default:
            // An unrecognised pairing is configuration error, not licence to accept
            // the token. Fall back to the release audience alone.
            return [releaseAudience]
        }
    }

    /// Verifies against each accepted audience in turn. JWTKit checks one audience per
    /// call, so a list means a loop; the failure of the last one is the failure reported.
    func verify(_ identityToken: String, on req: Request) async throws -> AppleIdentityToken {
        var lastError: Error?
        for audience in audiences {
            do {
                return try await req.jwt.apple.verify(identityToken, applicationIdentifier: audience).get()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Abort(.unauthorized, reason: "Invalid Apple identity token")
    }
}

struct AppleIdentityConfigurationKey: StorageKey { typealias Value = AppleIdentityConfiguration }

/// What Apple's `/auth/token` and `/auth/revoke` endpoints need. All four parts are
/// required together — a partial configuration is refused rather than half-applied,
/// because a half-configured exchange fails at sign-in time rather than at boot.
struct AppleTokenExchange: Sendable {
    let teamID: String
    let keyID: String
    /// PKCS#8 PEM, as downloaded from Apple. Held only in memory, never logged.
    let privateKeyPEM: String
    /// The `client_id` Apple expects, which is the app's bundle identifier.
    let clientID: String

    static func load() -> Self? {
        guard let team = Environment.get("APPLE_TEAM_ID"), !team.isEmpty,
              let key = Environment.get("APPLE_KEY_ID"), !key.isEmpty,
              let pem = Environment.get("APPLE_PRIVATE_KEY"), pem.contains("BEGIN PRIVATE KEY"),
              let client = Environment.get("APPLE_CLIENT_ID"), !client.isEmpty else { return nil }
        guard team.count <= 20, key.count <= 20, client.count <= 200,
              team.allSatisfy(\.isAlphanumeric), key.allSatisfy(\.isAlphanumeric) else { return nil }
        return Self(teamID: team, keyID: key, privateKeyPEM: pem, clientID: client)
    }

    /// Apple's client secret is a short-lived ES256 JWT signed with the team's key.
    /// Apple caps its lifetime at six months; minutes is all we need, and a short one
    /// limits what a leaked secret is worth.
    func clientSecret(now: Date = Date()) throws -> String {
        let signers = JWTSigners()
        do {
            try signers.use(.es256(key: ECDSAKey.private(pem: privateKeyPEM)), kid: JWKIdentifier(string: keyID))
        } catch {
            throw AppleCredentialError.misconfigured("The Apple sign-in key could not be read")
        }
        let payload = AppleClientSecret(
            issuer: .init(value: teamID),
            issuedAt: .init(value: now),
            expiration: .init(value: now.addingTimeInterval(300)),
            audience: .init(value: "https://appleid.apple.com"),
            subject: .init(value: clientID)
        )
        do {
            return try signers.sign(payload, kid: JWKIdentifier(string: keyID))
        } catch {
            throw AppleCredentialError.misconfigured("The Apple client secret could not be signed")
        }
    }
}

struct AppleClientSecret: JWTPayload {
    let issuer: IssuerClaim
    let issuedAt: IssuedAtClaim
    let expiration: ExpirationClaim
    let audience: AudienceClaim
    let subject: SubjectClaim

    enum CodingKeys: String, CodingKey {
        case issuer = "iss", issuedAt = "iat", expiration = "exp", audience = "aud", subject = "sub"
    }

    func verify(using signer: JWTSigner) throws { try expiration.verifyNotExpired() }
}

/// Deliberately separates *our* configuration being wrong from *Apple* being
/// unavailable and from the credential already being gone. Account deletion reports
/// these differently, and collapsing them would report success while a user stayed
/// linked to the app in their Apple ID settings.
enum AppleCredentialError: Error, Sendable {
    /// Our team, key, private key or client identifier is wrong. Not the user's problem.
    case misconfigured(String)
    /// Apple answered, and the credential is already invalid. For revocation this is success.
    case alreadyInvalid
    /// Apple did not answer, or answered with a server error. Retry.
    case unavailable
}

private extension Character {
    var isAlphanumeric: Bool { isLetter || isNumber }
}
