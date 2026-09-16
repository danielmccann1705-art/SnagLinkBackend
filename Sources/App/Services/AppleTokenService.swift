import Vapor

/// Talks to Apple's token endpoints.
///
/// Two calls, one at each end of an account's life: exchange the authorization code
/// the app already sends for a refresh token at sign-in, and revoke that refresh token
/// when the account is deleted. Apple requires the second of apps that offer Sign in
/// with Apple and account deletion, and it cannot be made without the first.
enum AppleTokenService {
    static let tokenEndpoint = URI(string: "https://appleid.apple.com/auth/token")
    static let revokeEndpoint = URI(string: "https://appleid.apple.com/auth/revoke")

    // MARK: - Exchange

    /// Returns the refresh token, or nil when Apple accepted the request but returned
    /// none. Never throws for a bad code: a user should not be refused sign-in because
    /// the code was already spent, which happens routinely on a retried request.
    static func exchange(authorizationCode: String, exchange config: AppleTokenExchange, on client: Client, logger: Logger) async -> String? {
        let secret: String
        do {
            secret = try config.clientSecret()
        } catch {
            logger.error("Apple token exchange is misconfigured; sign-in continues without a revocation credential")
            return nil
        }

        let response: ClientResponse
        do {
            response = try await client.post(tokenEndpoint) { request in
                try request.content.encode([
                    "client_id": config.clientID,
                    "client_secret": secret,
                    "code": authorizationCode,
                    "grant_type": "authorization_code"
                ], as: .urlEncodedForm)
            }
        } catch {
            logger.warning("Apple token exchange did not complete; sign-in continues without a revocation credential")
            return nil
        }

        guard response.status == .ok else {
            // Apple's error body names the reason. Log the classification only —
            // never the body, which echoes the code.
            let kind = (try? response.content.decode(AppleErrorResponse.self))?.error ?? "unknown"
            logger.warning("Apple token exchange refused: \(kind)")
            return nil
        }
        return (try? response.content.decode(AppleTokenResponse.self))?.refreshToken
    }

    // MARK: - Revocation

    enum RevocationOutcome: String, Sendable {
        case revoked
        case alreadyRevoked = "already_revoked"
        case misconfigured
        case failing
    }

    /// Distinguishes the four outcomes account deletion has to report differently.
    /// A refusal is not a completion: `misconfigured` means our key or team is wrong,
    /// which is an operational problem, not a finished deletion.
    static func revoke(refreshToken: String, clientID: String, exchange config: AppleTokenExchange, on client: Client, logger: Logger) async -> RevocationOutcome {
        let secret: String
        do {
            secret = try config.clientSecret()
        } catch {
            logger.error("Apple revocation is misconfigured")
            return .misconfigured
        }

        let response: ClientResponse
        do {
            response = try await client.post(revokeEndpoint) { request in
                try request.content.encode([
                    "client_id": clientID,
                    "client_secret": secret,
                    "token": refreshToken,
                    "token_type_hint": "refresh_token"
                ], as: .urlEncodedForm)
            }
        } catch {
            return .failing
        }

        if response.status == .ok { return .revoked }

        let kind = (try? response.content.decode(AppleErrorResponse.self))?.error ?? "unknown"
        switch kind {
        case "invalid_grant":
            // The token is already gone. The user is not linked to us any more, which
            // is the state revocation exists to reach.
            return .alreadyRevoked
        case "invalid_client", "invalid_request":
            logger.error("Apple revocation refused our client configuration: \(kind)")
            return .misconfigured
        default:
            logger.warning("Apple revocation did not succeed: \(kind)")
            return .failing
        }
    }
}

struct AppleTokenResponse: Content {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
    }
}

struct AppleErrorResponse: Content {
    let error: String
}
