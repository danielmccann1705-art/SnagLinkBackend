import Vapor
import Fluent

struct UserProfileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let users = routes.grouped("api", "v1", "users")
            .grouped(JWTAuthMiddleware())

        users.get("me", use: getProfile)
        users.patch("me", use: updateProfile)
    }

    @Sendable
    func getProfile(req: Request) async throws -> UserProfileResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let user = try await User.find(userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return UserProfileResponse(from: user)
    }

    @Sendable
    func updateProfile(req: Request) async throws -> UserProfileResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let user = try await User.find(userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        let updateReq = try req.content.decode(UpdateUserProfileRequest.self)

        if let name = updateReq.name { user.name = name }
        if let email = updateReq.email { user.email = email }

        try await user.save(on: req.db)
        return UserProfileResponse(from: user)
    }
}
