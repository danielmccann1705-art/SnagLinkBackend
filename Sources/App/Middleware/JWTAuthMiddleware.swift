import Vapor
import JWT
import Fluent

struct UserJWTPayload: JWTPayload, Authenticatable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var userId: UUID
    var authVersion: Int? = nil
    var authenticatedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case userId = "user_id"
        case authVersion = "auth_version"
        case authenticatedAt = "authenticated_at"
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
        guard let user = try await User.find(payload.userId, on: database ?? request.db),
              user.lifecycleState == "active", user.authVersion == (payload.authVersion ?? 0),
              payload.subject.value == payload.userId.uuidString else {
            throw Abort(.unauthorized, reason: "Account is no longer available")
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
