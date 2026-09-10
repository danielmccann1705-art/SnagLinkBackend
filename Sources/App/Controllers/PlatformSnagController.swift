import Vapor
import Fluent

struct PlatformSnagController: RouteCollection {
    typealias Page = SnagRegisterService.Page
    func boot(routes: RoutesBuilder) throws {
        let snags = routes.grouped("api", "v2", "projects", ":projectId", "snags").grouped(PlatformAuthMiddleware())
        snags.get(use: list)
        snags.post(use: create)
        snags.get(":snagId", use: get)
        snags.patch(":snagId", use: edit)
        snags.post(":snagId", "publish", use: publish)
        snags.post(":snagId", "assignment", use: assign)
        snags.post(":snagId", "archive", use: archive)
        snags.post(":snagId", "restore", use: restore)
    }
    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func list(req: Request) async throws -> Page {
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let filters = try req.query.decode(SnagRegisterQuery.self)
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            return try await SnagRegisterService.list(filters, project: project, on: db)
        }
    }
    @Sendable func get(req: Request) async throws -> PlatformSnagResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            return try await PlatformSnagResponse(PlatformSnagService.find(snagID, projectID: projectID, on: db))
        }
    }
    /// Access is checked before a receipt can return data. Removed users cannot
    /// retrieve stored responses by replaying a previously successful operation.
    private func mutate<C: Content>(req: Request, command: C, metadata: MutationMetadata, action: ProjectAccessPolicy.Action,
                                    perform: @escaping @Sendable (Database, Project, Set<ProjectAccessPolicy.Action>, UUID) async throws -> PlatformSnagResponse) async throws -> PlatformSnagResponse {
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let hash = try PlatformMutationService.requestHash(command, route: "\(req.method):\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: metadata, on: db)
            let (project, actions) = try await ProjectAccessService.require(action, projectID: projectID, actorID: actorID, on: db)
            if let old = try await PlatformMutationService.replay(PlatformSnagResponse.self, actorID: actorID, mutation: metadata, hash: hash, on: db) { return old }
            let result = try await perform(db, project, actions, actorID)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: metadata, hash: hash, on: db)
            return result
        }
    }
    @Sendable func create(req: Request) async throws -> PlatformSnagResponse {
        let body = try req.content.decode(SnagCreateCommand.self)
        return try await mutate(req: req, command: body, metadata: body.mutation, action: body.fields["dueDate"] == nil && body.fields["dueOn"] == nil ? .edit : .assign) { db, project, actions, actorID in
            guard body.fields["dueDate"] == nil && body.fields["dueOn"] == nil || actions.contains(.assign) else { throw Abort(.forbidden, reason: "Only a project manager can set or clear deadlines") }
            return try await PlatformSnagService.create(body, project: project, actorID: actorID, on: db)
        }
    }
    @Sendable func edit(req: Request) async throws -> PlatformSnagResponse {
        let body = try req.content.decode(SnagEditCommand.self), snagID = try id("snagId", req)
        return try await mutate(req: req, command: body, metadata: body.mutation, action: body.fields["dueDate"] == nil && body.fields["dueOn"] == nil ? .edit : .assign) { db, project, actions, actorID in
            guard body.fields["dueDate"] == nil && body.fields["dueOn"] == nil || actions.contains(.assign) else { throw Abort(.forbidden, reason: "Only a project manager can set or clear deadlines") }
            let snag = try await PlatformSnagService.find(snagID, projectID: project.requireID(), on: db)
            return try await PlatformSnagService.edit(body, snag: snag, project: project, actorID: actorID, on: db)
        }
    }
    @Sendable func assign(req: Request) async throws -> PlatformSnagResponse {
        let body = try req.content.decode(SnagEditCommand.self), snagID = try id("snagId", req)
        return try await mutate(req: req, command: body, metadata: body.mutation, action: .assign) { db, project, _, actorID in
            let snag = try await PlatformSnagService.find(snagID, projectID: project.requireID(), on: db)
            return try await PlatformSnagService.assign(body, snag: snag, project: project, actorID: actorID, on: db)
        }
    }
    @Sendable func publish(req: Request) async throws -> PlatformSnagResponse {
        let body = try req.content.decode(SnagPublishCommand.self), snagID = try id("snagId", req)
        return try await mutate(req: req, command: body, metadata: body.mutation, action: .edit) { db, project, _, actorID in
            let snag = try await PlatformSnagService.find(snagID, projectID: project.requireID(), on: db)
            return try await PlatformSnagService.publish(body, snag: snag, project: project, actorID: actorID, on: db)
        }
    }
    @Sendable func archive(req: Request) async throws -> PlatformSnagResponse { try await archive(req, restore: false) }
    @Sendable func restore(req: Request) async throws -> PlatformSnagResponse { try await archive(req, restore: true) }
    private func archive(_ req: Request, restore: Bool) async throws -> PlatformSnagResponse {
        let body = try req.content.decode(SnagArchiveCommand.self), snagID = try id("snagId", req)
        return try await mutate(req: req, command: body, metadata: body.mutation, action: restore ? .archive : .edit) { db, project, actions, actorID in
            let snag = try await PlatformSnagService.find(snagID, projectID: project.requireID(), on: db)
            return try await PlatformSnagService.archive(body, snag: snag, project: project, actions: actions, actorID: actorID, restore: restore, on: db)
        }
    }
}
