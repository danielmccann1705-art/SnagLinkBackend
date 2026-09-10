import Vapor

struct RegisterSyncController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let project = routes.grouped("api", "v2", "projects", ":projectId").grouped(PlatformAuthMiddleware())
        project.post("register-snapshots", use: create)
        project.get("register-snapshots", use: page)
        project.get("changes", use: changes)
    }
    private func id(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("projectId"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func create(req: Request) async throws -> RegisterSnapshotPage {
        let projectID = try id(req), actorID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in try await RegisterSyncService.create(projectID: projectID, actorID: actorID, on: db) }
    }
    @Sendable func page(req: Request) async throws -> RegisterSnapshotPage {
        let projectID = try id(req), actorID = try req.requireAuthenticatedUserId()
        let token = try req.query.get(String.self, at: "snapshot"), offset = try req.query.get(Int.self, at: "offset")
        return try await req.db.transaction { db in try await RegisterSyncService.page(token: token, offset: offset, projectID: projectID, actorID: actorID, on: db) }
    }
    @Sendable func changes(req: Request) async throws -> ProjectChangePage {
        let projectID = try id(req), actorID = try req.requireAuthenticatedUserId(), cursor = try req.query.get(String.self, at: "cursor")
        return try await req.db.transaction { db in try await RegisterSyncService.changes(cursor: cursor, projectID: projectID, actorID: actorID, on: db) }
    }
}
