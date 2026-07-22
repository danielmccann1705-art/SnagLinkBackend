import Vapor
import Fluent

struct UserProfileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let users = routes.grouped("api", "v1", "users")
            .grouped(JWTAuthMiddleware())

        users.get("me", use: getProfile)
        users.patch("me", use: updateProfile)
        users.get("me", "usage", use: getUsage)  // B4
    }

    /// GET /api/v1/users/me/usage — magic-link allowance snapshot for the free-tier meter (B4).
    @Sendable
    func getUsage(req: Request) async throws -> UsageResponse {
        let userId = try req.requireAuthenticatedUserId()
        guard let user = try await User.find(userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }
        return try await UsageService.buildUsage(user: user, on: req.db)
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
        if let tierRaw = updateReq.subscriptionTier {
            guard let tier = SubscriptionTier(rawValue: tierRaw) else {
                throw Abort(.badRequest, reason: "Invalid subscription tier. Must be 'free' or 'pro'")
            }
            user.subscriptionTier = tier.rawValue
        }

        try await user.save(on: req.db)
        return UserProfileResponse(from: user)
    }
}
