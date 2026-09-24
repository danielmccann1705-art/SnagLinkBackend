import Vapor
import JWT
import Fluent

struct UserJWTPayload: JWTPayload, Authenticatable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var userId: UUID
    var authVersion: Int? = nil
    var authenticatedAt: Date? = nil
    /// Names this app session so it can be signed out on its own
    /// (`POST /api/v1/auth/logout`, `AppSessionRevocationService`). Every token issued
    /// from per-session sign-out on carries one; tokens issued before it do not, and
    /// keep working until they expire.
    var sessionID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case userId = "user_id"
        case authVersion = "auth_version"
        case authenticatedAt = "authenticated_at"
        case sessionID = "jti"
    }

    func verify(using signer: JWTSigner) throws {
        try self.expiration.verifyNotExpired()
    }
}

struct JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let payload = try await Self.authenticate(request)
        request.auth.login(payload)
        return try await next.respond(to: request)
    }

    static func authenticate(_ request: Request, on database: Database? = nil) async throws -> UserJWTPayload {
        // Check for Authorization header
        guard let authHeader = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing authorization header")
        }

        let payload: UserJWTPayload
        do {
            // Verify the JWT token
            payload = try request.jwt.verify(authHeader.token, as: UserJWTPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
        // The account and this session's sign-out are read together: one query, one
        // primary-key probe for the session. `auth_version` still ends every session
        // at once (sign out everywhere, account deletion); a revocation row ends one.
        let sessionID = AppSessionRevocationService.sessionID(for: payload, token: authHeader.token)
        guard payload.subject.value == payload.userId.uuidString,
              let account = try await AppSessionRevocationService.accountState(
                  userID: payload.userId, sessionID: sessionID, on: database ?? request.db),
              account.lifecycleState == "active", account.authVersion == (payload.authVersion ?? 0) else {
            throw Abort(.unauthorized, reason: "Account is no longer available")
        }
        guard !account.sessionRevoked else {
            throw Abort(.unauthorized, reason: "This session has been signed out")
        }
        return payload
    }
}

extension Request {
    /// Gets the authenticated user ID from the JWT payload
    var authenticatedUserId: UUID? {
        return auth.get(UserJWTPayload.self)?.userId ?? auth.get(BrowserPrincipal.self)?.userID
    }

    /// Requires the user to be authenticated and returns their ID
    func requireAuthenticatedUserId() throws -> UUID {
        guard let userId = authenticatedUserId else {
            throw Abort(.unauthorized, reason: "Authentication required")
        }
        return userId
    }
}
