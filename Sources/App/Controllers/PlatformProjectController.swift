import Vapor
import Fluent
import FluentSQL

struct PlatformProjectResponse: Content {
    let project: ProjectResponse
    let workspaceId: UUID
    let revision: Int64
    var capabilities: [String]
    let archivedAt: Date?
    let platformManaged: Bool
    // Optional only for decoding old immutable manifests and receipts. A fresh
    // projectMetadataV2 snapshot always includes this object, even with nil dates.
    let canonical: CanonicalProjectValues?
    init(_ project: Project, actions: Set<ProjectAccessPolicy.Action>) throws {
        self.project = ProjectResponse(from: project)
        guard let workspaceID = project.workspaceId else { throw Abort(.conflict, reason: "Project ownership needs reconciliation") }
        self.workspaceId = workspaceID
        self.revision = project.revision
        self.capabilities = actions.map(\.rawValue).sorted()
        self.archivedAt = project.archivedAt
        self.platformManaged = project.platformManaged
        self.canonical = CanonicalProjectValues(project)
    }
    func withCapabilities(_ actions: Set<ProjectAccessPolicy.Action>) -> Self {
        var copy = self
        copy.capabilities = actions.map(\.rawValue).sorted()
        return copy
    }
}

struct PlatformProjectController: RouteCollection {
    struct CreateBody: Content { let mutation: MutationMetadata; let workspaceId: UUID; let project: CreateProjectRequest }
    struct Page: Content { let items: [PlatformProjectResponse]; let page: Int; let hasMore: Bool }
    func boot(routes: RoutesBuilder) throws {
        let projects = routes.grouped("api", "v2", "projects").grouped(PlatformAuthMiddleware())
        projects.get(use: list)
        projects.post(use: create)
        projects.get(":projectId", use: get)
        projects.patch(":projectId", use: edit)
    }
    @Sendable func get(req: Request) async throws -> PlatformProjectResponse {
        guard let raw = req.parameters.get("projectId"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        let actor = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            let (project, actions) = try await ProjectAccessService.require(.read, projectID: id, actorID: actor, on: db)
            return try PlatformProjectResponse(project, actions: actions)
        }
    }
    @Sendable func edit(req: Request) async throws -> PlatformProjectResponse {
        guard let raw = req.parameters.get("projectId"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        let actor = try req.requireAuthenticatedUserId(), body = try req.content.decode(ProjectEditCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "PATCH:/api/v2/projects/\(id)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            let (project, actions) = try await ProjectAccessService.require(.assign, projectID: id, actorID: actor, on: db)
            try PlatformMutationService.requireManaged(project)
            if let old = try await PlatformMutationService.replay(PlatformProjectResponse.self, actorID: actor, mutation: body.mutation, hash: hash, on: db) { return old.withCapabilities(actions) }
            let response = try await PlatformProjectMetadataService.edit(body, project: project, actions: actions, actorID: actor, on: db)
            try await PlatformMutationService.record(response, actorID: actor, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return response
        }
    }
    @Sendable func list(req: Request) async throws -> Page {
        let actor = try req.requireAuthenticatedUserId()
        guard let workspaceID = try? req.query.get(UUID.self, at: "workspaceId") else { throw Abort(.badRequest, reason: "Choose a workspace") }
        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        guard (1...10000).contains(page) else { throw Abort(.badRequest, reason: "Invalid page") }
        return try await req.db.transaction { db in
            try await WorkspaceAccessService.lock(workspaceID, on: db)
            guard let workspace = try await Team.find(workspaceID, on: db) else { throw Abort(.notFound) }
            let role = try await WorkspaceAccessService.role(actorID: actor, workspace: workspace, on: db)
            var query = Project.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$archivedAt == nil)
            if workspace.kind == "company", role == "member" {
                let ids = try await VerifiedIdentityService.sql(db).raw("SELECT project_id FROM project_access WHERE state = 'active' AND workspace_id = \(bind: workspaceID) AND user_id = \(bind: actor)").all().map { try $0.decode(column: "project_id", as: UUID.self) }
                guard !ids.isEmpty else { return Page(items: [], page: page, hasMore: false) }
                query = query.filter(\.$id ~~ ids)
            }
            let projects = try await query.sort(\.$updatedAt, .descending).sort(\.$id).range(((page - 1) * 50)..<(page * 50 + 1)).all()
            var items: [PlatformProjectResponse] = []
            for project in projects.prefix(50) {
                let (allowed, actions) = try await ProjectAccessService.require(.read, projectID: project.requireID(), actorID: actor, on: db)
                items.append(try PlatformProjectResponse(allowed, actions: actions))
            }
            return Page(items: items, page: page, hasMore: projects.count > 50)
        }
    }
    @Sendable func create(req: Request) async throws -> PlatformProjectResponse {
        let actor = try req.requireAuthenticatedUserId(), body = try req.content.decode(CreateBody.self)
        try body.project.validate()
        guard let id = body.project.id else { throw Abort(.badRequest, reason: "A stable project ID is required") }
        let hash = try PlatformMutationService.requestHash(body, route: "POST:/api/v2/projects")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            try await WorkspaceAccessService.lock(body.workspaceId, on: db)
            guard let workspace = try await Team.find(body.workspaceId, on: db) else { throw Abort(.notFound) }
            let role = try await WorkspaceAccessService.role(actorID: actor, workspace: workspace, on: db)
            guard ["owner", "admin"].contains(role) else { throw Abort(.forbidden, reason: "Ask a company owner or admin to create this project") }
            if let replay = try await PlatformMutationService.replay(PlatformProjectResponse.self, actorID: actor, mutation: body.mutation, hash: hash, on: db) {
                let (current, actions) = try await ProjectAccessService.require(.read, projectID: id, actorID: actor, on: db)
                try PlatformMutationService.requireManaged(current)
                guard current.workspaceId == body.workspaceId else { throw Abort(.conflict, reason: "This project moved. Refresh its current workspace", identifier: "project_scope_changed") }
                return replay.withCapabilities(actions)
            }
            try await VerifiedIdentityService.lock("entity:project:" + id.uuidString, on: db)
            if let existing = try await Project.find(id, on: db) {
                guard existing.workspaceId == body.workspaceId else { throw Abort(.conflict, reason: "The project ID already exists") }
                throw Abort(.conflict, reason: "This project already exists. Refresh to open it")
            }
            let input = body.project
            let project = Project(id: id, name: input.name, reference: input.reference, clientName: input.clientName,
                                  clientEmail: input.clientEmail, clientPhone: input.clientPhone, address: input.address,
                                  notes: input.notes, projectType: input.projectType, status: input.status ?? "active",
                                  isFavorite: input.isFavorite ?? false, latitude: input.latitude, longitude: input.longitude, ownerId: actor)
            project.workspaceId = body.workspaceId
            project.platformManaged = true
            try await PlatformProjectMetadataService.applyCreate(input, to: project, on: db)
            try await project.save(on: db)
            try await WorkspaceAccessService.activity(workspaceID: body.workspaceId, actorID: actor, action: "project_created", targetID: id, on: db)
            let (created, actions) = try await ProjectAccessService.require(.read, projectID: id, actorID: actor, on: db)
            let response = try PlatformProjectResponse(created, actions: actions)
            try await PlatformMutationService.change(workspaceID: body.workspaceId, projectID: id, type: "project", entityID: id, revision: 1, kind: "created", fields: ["project"], payload: response, actorID: actor, on: db)
            try await PlatformMutationService.record(response, actorID: actor, workspaceID: body.workspaceId, mutation: body.mutation, hash: hash, on: db)
            return response
        }
    }
}
