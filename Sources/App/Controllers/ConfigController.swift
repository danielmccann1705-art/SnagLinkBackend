import Vapor
import Fluent

/// B6: remote configuration. Auth is optional — unauthenticated clients get the same flag set
/// (flags here are global, not user-specific).
struct ConfigController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let config = routes.grouped("api", "v1", "config")
        config.get("feature-flags", use: featureFlags)
    }

    @Sendable
    func featureFlags(req: Request) async throws -> FeatureFlagsResponse {
        let flags = try await FeatureFlagService.resolve(on: req.db)
        return FeatureFlagsResponse(flags: flags)
    }
}

struct FeatureFlagsResponse: Content {
    let flags: [String: Bool]
}
