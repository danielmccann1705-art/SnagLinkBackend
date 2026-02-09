import Vapor
import Fluent
import JWT

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("apple", use: appleSignIn)
    }

    @Sendable
    func appleSignIn(req: Request) async throws -> AuthResponse {
        let input = try req.content.decode(AppleSignInRequest.self)

        // Decode JWT payload (middle segment)
        let segments = input.identityToken.split(separator: ".")
        guard segments.count == 3 else {
            throw Abort(.unauthorized, reason: "Invalid token format")
        }

        // Base64URL decode the payload
        var payload = String(segments[1])
        while payload.count % 4 != 0 { payload += "=" }
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appleUserId = json["sub"] as? String else {
            throw Abort(.unauthorized, reason: "Invalid token payload")
        }

        let email = json["email"] as? String

        // Find or create user
        let user: User
        if let existing = try await User.query(on: req.db).filter(\.$appleUserId == appleUserId).first() {
            user = existing
        } else {
            user = User(appleUserId: appleUserId, email: email, name: input.firstName)
            try await user.save(on: req.db)
        }

        // Generate signed JWT
        let jwtPayload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(30 * 24 * 60 * 60)), // 30 days
            userId: user.id!
        )
        let token = try req.jwt.sign(jwtPayload)

        return AuthResponse(
            token: token,
            user: AuthUserResponse(id: user.id!, email: user.email, name: user.name, appleUserId: user.appleUserId),
            isNewUser: user.createdAt == user.updatedAt
        )
    }
}

struct AppleSignInRequest: Content {
    let identityToken: String
    let firstName: String?
    let lastName: String?
}

struct AuthResponse: Content {
    let token: String
    let user: AuthUserResponse
    let isNewUser: Bool
}

struct AuthUserResponse: Content {
    let id: UUID
    let email: String?
    let name: String?
    let appleUserId: String
}
