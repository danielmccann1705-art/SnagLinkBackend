import Fluent
import Vapor

struct DeviceController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped("api", "v1", "devices")
            .grouped(JWTAuthMiddleware())

        authenticated.post("register", use: registerDevice)
        authenticated.delete("unregister", use: unregisterDevice)
    }

    // MARK: - Register Device Token

    /// POST /api/v1/devices/register
    /// Registers or updates a device token for push notifications
    @Sendable
    func registerDevice(req: Request) async throws -> DeviceRegistrationResponse {
        let userId = try req.requireAuthenticatedUserId()
        let input = try req.content.decode(RegisterDeviceRequest.self)

        // Validate device token format (hex string, minimum 64 chars)
        guard input.deviceToken.count >= 64,
              input.deviceToken.allSatisfy({ $0.isHexDigit }) else {
            throw Abort(.badRequest, reason: "Invalid device token format")
        }

        // If this token already exists (possibly for another user), delete it
        try await DeviceToken.query(on: req.db)
            .filter(\.$deviceToken == input.deviceToken)
            .delete()

        // Delete existing tokens for this user on the same platform (one device per user per platform)
        try await DeviceToken.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$platform == input.platform)
            .delete()

        // Create new device token
        let deviceToken = DeviceToken(
            userId: userId,
            deviceToken: input.deviceToken,
            platform: input.platform
        )
        try await deviceToken.save(on: req.db)

        return DeviceRegistrationResponse(
            success: true,
            id: deviceToken.id!,
            message: "Device registered successfully"
        )
    }

    // MARK: - Unregister Device Token

    /// DELETE /api/v1/devices/unregister
    /// Removes a device token (e.g., on logout)
    @Sendable
    func unregisterDevice(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(UnregisterDeviceRequest.self)

        try await DeviceToken.query(on: req.db)
            .filter(\.$deviceToken == input.deviceToken)
            .delete()

        return .noContent
    }
}

// MARK: - DTOs

struct RegisterDeviceRequest: Content {
    let deviceToken: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case deviceToken
        case platform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceToken = try container.decode(String.self, forKey: .deviceToken)
        self.platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "ios"
    }
}

struct UnregisterDeviceRequest: Content {
    let deviceToken: String
}

struct DeviceRegistrationResponse: Content {
    let success: Bool
    let id: UUID
    let message: String
}
