import Vapor

struct MeasurementPrivacyController: RouteCollection {
    private static let installationHeader = HTTPHeaders.Name("X-Measurement-Installation-ID")

    func boot(routes: RoutesBuilder) throws {
        let permissions = routes.grouped("api", "v2", "measurement", "permissions").grouped(PlatformAuthMiddleware())
        permissions.get(use: read)
        permissions.put(":purpose", use: update)
    }

    @Sendable func read(req: Request) async throws -> MeasurementPermissionsEnvelope {
        try await MeasurementPrivacyService.read(accountID: req.requireAuthenticatedUserId(),
            installationID: try installationID(req), on: req.db)
    }

    @Sendable func update(req: Request) async throws -> MeasurementPermissionsEnvelope {
        guard let raw = req.parameters.get("purpose"), let purpose = MeasurementPurpose(rawValue: raw) else {
            throw Abort(.badRequest, reason: "Choose a valid measurement purpose", identifier: "measurement_purpose_invalid")
        }
        let body: MeasurementPermissionUpdate
        do { body = try req.content.decode(MeasurementPermissionUpdate.self) }
        catch { throw Abort(.badRequest, reason: "Use a valid measurement permission request", identifier: "measurement_request_invalid") }
        return try await MeasurementPrivacyService.update(accountID: req.requireAuthenticatedUserId(), purpose: purpose,
                                                            input: body, on: req.db)
    }

    private func installationID(_ req: Request) throws -> UUID? {
        guard let raw = req.headers.first(name: Self.installationHeader) else { return nil }
        guard raw.utf8.count == 36, let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Use a valid measurement installation", identifier: "measurement_installation_invalid")
        }
        return id
    }
}
