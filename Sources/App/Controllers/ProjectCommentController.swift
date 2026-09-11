import Vapor
import Fluent
import FluentSQL

struct ProjectCommentController: RouteCollection {
    struct Page: Content { let items: [ProjectCommentResponse]; let nextAfter: UUID? }
    func boot(routes: RoutesBuilder) throws {
        let comments = routes.grouped("api", "v2", "projects", ":projectId", "snags", ":snagId", "comments").grouped(PlatformAuthMiddleware())
        comments.get(use: list)
        comments.post(use: create)
        comments.post(":commentId", "redact", use: redact)
    }
    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func list(req: Request) async throws -> Page {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let after = try req.query.get(UUID?.self, at: "after")
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            _ = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            let anchor: ProjectCommentResponse?
            if let after { anchor = try await ProjectCommentService.find(after, snagID: snagID, projectID: projectID, on: db) }
            else { anchor = nil }
            let rows: [SQLRow]
            if let anchor {
                rows = try await sql.raw("SELECT * FROM project_comments WHERE project_id = \(bind: projectID) AND snag_id = \(bind: snagID) AND (created_at, id) > (\(bind: anchor.createdAt), \(bind: anchor.id)) ORDER BY created_at, id LIMIT 101").all()
            } else {
                rows = try await sql.raw("SELECT * FROM project_comments WHERE project_id = \(bind: projectID) AND snag_id = \(bind: snagID) ORDER BY created_at, id LIMIT 101").all()
            }
            let items = try rows.prefix(100).map(ProjectCommentResponse.init)
            return .init(items: items, nextAfter: rows.count > 100 ? items.last?.id : nil)
        }
    }
    private func mutate<C: Content>(req: Request, command: C, mutation: MutationMetadata,
        perform: @escaping @Sendable (Database, Project, Snag, Set<ProjectAccessPolicy.Action>, UUID) async throws -> ProjectCommentResponse) async throws -> ProjectCommentResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let hash = try PlatformMutationService.requestHash(command, route: "\(req.method):\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: mutation, on: db)
            let (project, actions) = try await ProjectAccessService.require(.edit, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            if let old = try await PlatformMutationService.replay(ProjectCommentResponse.self, actorID: actorID, mutation: mutation, hash: hash, on: db) {
                // A creation receipt is not a way to retrieve subsequently removed text.
                let current = try await ProjectCommentService.find(old.id, snagID: snagID, projectID: projectID, on: db)
                return current.redactedAt == nil ? old : current
            }
            let result = try await perform(db, project, snag, actions, actorID)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: mutation, hash: hash, on: db)
            return result
        }
    }
    @Sendable func create(req: Request) async throws -> ProjectCommentResponse {
        let body = try req.content.decode(ProjectCommentCreateCommand.self)
        return try await mutate(req: req, command: body, mutation: body.mutation) { db, project, snag, _, actor in
            try await ProjectCommentService.create(body, project: project, snag: snag, actorID: actor, on: db)
        }
    }
    @Sendable func redact(req: Request) async throws -> ProjectCommentResponse {
        let body = try req.content.decode(ProjectCommentRedactCommand.self), commentID = try id("commentId", req)
        return try await mutate(req: req, command: body, mutation: body.mutation) { db, project, snag, actions, actor in
            let comment = try await ProjectCommentService.find(commentID, snagID: snag.requireID(), projectID: project.requireID(), on: db)
            return try await ProjectCommentService.redact(body, comment: comment, project: project, actions: actions, actorID: actor, on: db)
        }
    }
}
