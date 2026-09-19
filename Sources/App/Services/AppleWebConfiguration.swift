import Vapor

struct AppleWebConfiguration: Sendable {
    let clientID: String
    let redirectURI: String
    let exchange: AppleTokenExchange
    static let callbackPath = "/api/v2/auth/apple/callback"

    static func load(platform: PlatformConfiguration, app: Application) throws -> Self {
        let result: Self
        if app.environment == .testing, let configured = app.storage[AppleWebConfigurationKey.self] {
            result = configured
        } else {
            guard Environment.get("APPLE_WEB_ENABLED") == "true",
                  Environment.get("APPLE_WEB_AUTH_ENVIRONMENT") == platform.environment,
                  let client = Environment.get("APPLE_WEB_CLIENT_ID"),
                  let native = AppleTokenExchange.load() else { throw unavailable() }
            result = .init(clientID: client, redirectURI: platform.origin + callbackPath,
                exchange: .init(teamID: native.teamID, keyID: native.keyID, privateKeyPEM: native.privateKeyPEM, clientID: client))
        }
        let expected: (String, String)
        switch platform.environment {
        case "production": expected = ("https://app.usesnaglist.com", "com.snaglist.app.web")
        case "staging": expected = ("https://staging-app.usesnaglist.com", "com.snaglist.app.staging.web")
        default: throw unavailable()
        }
        guard platform.origin == expected.0, result.clientID == expected.1,
              result.redirectURI == expected.0 + callbackPath,
              result.exchange.clientID == result.clientID else { throw unavailable() }
        do {
            _ = try AppleCredentialService.keys(app)
            _ = try result.exchange.clientSecret()
        } catch { throw unavailable() }
        return result
    }
    static func unavailable() -> Abort {
        Abort(.serviceUnavailable, reason: "Apple web sign-in is not configured", identifier: "apple_web_unavailable")
    }
}
struct AppleWebConfigurationKey: StorageKey { typealias Value = AppleWebConfiguration }
