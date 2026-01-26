import Vapor
import JWT

struct UserJWTPayload: JWTPayload, Authenticatable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var userId: UUID

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case userId = "user_id"
    }

    func verify(using signer: JWTSigner) throws {
        try self.expiration.verifyNotExpired()
    }
}

struct JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Check for Authorization header
        guard let authHeader = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing authorization header")
        }

        do {
            // Verify the JWT token
            let payload = try request.jwt.verify(authHeader.token, as: UserJWTPayload.self)
            request.auth.login(payload)
            return try await next.respond(to: request)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
    }
}

extension Request {
    /// Gets the authenticated user ID from the JWT payload
    var authenticatedUserId: UUID? {
        return auth.get(UserJWTPayload.self)?.userId
    }

    /// Requires the user to be authenticated and returns their ID
    func requireAuthenticatedUserId() throws -> UUID {
        guard let userId = authenticatedUserId else {
            throw Abort(.unauthorized, reason: "Authentication required")
        }
        return userId
    }
}
