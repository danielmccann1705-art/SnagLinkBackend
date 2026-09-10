import Vapor
import Fluent

struct WorkspaceDirectoryController: RouteCollection {
    struct Page: Content { let items: [DirectoryResponse]; let page: Int; let hasMore: Bool }
    func boot(routes: RoutesBuilder) throws {
        let workspace = routes.grouped("api", "v2", "workspaces", ":workspaceId").grouped(PlatformAuthMiddleware())
        for kind in [WorkspaceDirectoryService.Kind.contractor, .trade] {
            let path: PathComponent = kind == .contractor ? "contractors" : "trades"
            let directory = workspace.grouped(path)
            directory.get { req async throws -> Page in try await list(req, kind: kind) }
            directory.get(":entryId") { req async throws -> DirectoryResponse in try await get(req, kind: kind) }
            directory.post { req async throws -> DirectoryResponse in try await change(req, kind: kind, create: true) }
            directory.patch(":entryId") { req async throws -> DirectoryResponse in try await change(req, kind: kind, create: false) }
        }
    }
    private func id(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid identifier") }
        return id
    }
    private func context(_ req: Request) throws -> UUID? {
        guard let raw = try? req.query.get(String.self, at: "projectId") else { return nil }
        guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid project context") }
        return id
    }
    @Sendable private func list(_ req: Request, kind: WorkspaceDirectoryService.Kind) async throws -> Page {
        let workspaceID = try id("workspaceId", req), actorID = try req.requireAuthenticatedUserId(), projectID = try context(req)
        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        guard (1...10000).contains(page) else { throw Abort(.badRequest, reason: "Invalid page") }
        let archived = (try? req.query.get(Bool.self, at: "includeArchived")) ?? false
        return try await req.db.transaction { db in
            try await WorkspaceDirectoryService.require(workspaceID: workspaceID, projectID: projectID, actorID: actorID, write: false, on: db)
            let items: [DirectoryResponse]
            if kind == .contractor {
                var query = Contractor.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true)
                if !archived { query = query.filter(\.$isArchived == false) }
                items = try await query.sort(\.$companyName).sort(\.$id).range(((page - 1) * 50)..<(page * 50 + 1)).all().map(WorkspaceDirectoryService.response)
            } else {
                var query = Trade.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true)
                if !archived { query = query.filter(\.$isArchived == false) }
                items = try await query.sort(\.$sortOrder).sort(\.$id).range(((page - 1) * 50)..<(page * 50 + 1)).all().map(WorkspaceDirectoryService.response)
            }
            return Page(items: Array(items.prefix(50)), page: page, hasMore: items.count > 50)
        }
    }
    @Sendable private func get(_ req: Request, kind: WorkspaceDirectoryService.Kind) async throws -> DirectoryResponse {
        let workspaceID = try id("workspaceId", req), entryID = try id("entryId", req), actorID = try req.requireAuthenticatedUserId(), projectID = try context(req)
        return try await req.db.transaction { db in
            try await WorkspaceDirectoryService.require(workspaceID: workspaceID, projectID: projectID, actorID: actorID, write: false, on: db)
            if kind == .contractor {
                guard let value = try await Contractor.find(entryID, on: db), value.workspaceId == workspaceID, value.platformManaged else { throw Abort(.notFound, reason: "Contractor unavailable") }
                return try WorkspaceDirectoryService.response(value)
            }
            guard let value = try await Trade.find(entryID, on: db), value.workspaceId == workspaceID, value.platformManaged else { throw Abort(.notFound, reason: "Trade unavailable") }
            return try WorkspaceDirectoryService.response(value)
        }
    }
    @Sendable private func change(_ req: Request, kind: WorkspaceDirectoryService.Kind, create: Bool) async throws -> DirectoryResponse {
        let workspaceID = try id("workspaceId", req), actorID = try req.requireAuthenticatedUserId(), command = try req.content.decode(DirectoryCommand.self)
        if create { guard command.expectedRevision == 0 else { throw Abort(.badRequest, reason: "New entries require revision zero") } }
        else { guard command.expectedRevision > 0, command.id == (try id("entryId", req)) else { throw Abort(.badRequest, reason: "The entry ID and base revision must match this update") } }
        return try await req.db.transaction { db in try await WorkspaceDirectoryService.change(kind: kind, command: command, workspaceID: workspaceID, actorID: actorID, on: db) }
    }
}
