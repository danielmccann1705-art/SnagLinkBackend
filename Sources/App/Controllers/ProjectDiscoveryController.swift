import Vapor

struct ProjectDiscoveryController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let snapshots = routes.grouped("api", "v2", "project-discovery-snapshots").grouped(PlatformAuthMiddleware())
        snapshots.post(use: create)
        snapshots.get(use: page)
    }
    @Sendable func create(req: Request) async throws -> ProjectDiscoveryPage {
        let actorID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in try await ProjectDiscoveryService.create(actorID: actorID, on: db) }
    }
    @Sendable func page(req: Request) async throws -> ProjectDiscoveryPage {
        let actorID = try req.requireAuthenticatedUserId(), token = try req.query.get(String.self, at: "snapshot"), offset = try req.query.get(Int.self, at: "offset")
        return try await req.db.transaction { db in try await ProjectDiscoveryService.page(token: token, offset: offset, actorID: actorID, on: db) }
    }
}
