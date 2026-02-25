import Vapor
import Fluent
@preconcurrency import JWT

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("apple", use: appleSignIn)
    }

    @Sendable
    func appleSignIn(req: Request) async throws -> AuthResponse {
        let input = try req.content.decode(AppleSignInRequest.self)

        // Verify Apple identity token using JWKS (signature + issuer + expiry)
        let appleToken: AppleIdentityToken
        do {
            appleToken = try await req.jwt.apple.verify(
                input.identityToken,
                applicationIdentifier: Environment.get("APPLE_APP_ID")
            ).get()
        } catch {
            throw Abort(.unauthorized, reason: "Invalid Apple identity token")
        }

        let appleUserId = appleToken.subject.value
        let email = appleToken.email

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
