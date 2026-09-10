import Vapor
import Fluent
import FluentSQL

struct WorkspaceController: RouteCollection {
    struct CreateBody: Content { let id: UUID; let name: String }
    struct MemberBody: Content { let role: String?; let expectedRevision: Int64 }
    struct OwnerBody: Content { let userId: UUID; let expectedRevision: Int64 }
    struct InviteBody: Content { let email: String; let role: String; let projects: [InvitationProjectGrant] }
    struct InviteResult: Content { let invitation: TeamInviteResponse; let invitationURL: String }

    func boot(routes: RoutesBuilder) throws {
        let workspaces = routes.grouped("api", "v2", "workspaces").grouped(PlatformAuthMiddleware())
        workspaces.get(use: list)
        workspaces.post(use: create)
        workspaces.get(":workspaceId", "members", use: members)
        workspaces.patch(":workspaceId", "members", ":userId", use: changeMember)
        workspaces.post(":workspaceId", "owner", use: transferOwner)
        workspaces.post(":workspaceId", "invitations", use: invite)
        let invitations = routes.grouped("api", "v2", "invitations").grouped(PlatformAuthMiddleware())
        invitations.post("accept", use: accept)
        invitations.post("preview", use: previewInvitation)
        invitations.delete(":invitationId", use: revoke)
        let projects = routes.grouped("api", "v2", "projects").grouped(PlatformAuthMiddleware())
        projects.post(":projectId", "members", use: grant)
        projects.get(":projectId", "members", use: projectMembers)
    }

    @Sendable func list(req: Request) async throws -> [WorkspaceResponse] {
        let id = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in try await WorkspaceAccessService.list(actorID: id, on: db) }
    }
    @Sendable func create(req: Request) async throws -> WorkspaceResponse {
        let actor = try req.requireAuthenticatedUserId(), body = try req.content.decode(CreateBody.self)
        return try await req.db.transaction { db in
            let team = try await WorkspaceAccessService.createCompany(id: body.id, name: body.name, actorID: actor, on: db)
            return WorkspaceResponse(id: try team.requireID(), name: team.name, kind: team.kind, role: "owner", revision: team.revision, timezone: team.timezone)
        }
    }
    @Sendable func members(req: Request) async throws -> [WorkspaceMemberResponse] {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("workspaceId", req)
        return try await req.db.transaction { db in
            _ = try await WorkspaceAccessService.requireCompany(id, actorID: actor, admin: true, on: db)
            return try await VerifiedIdentityService.sql(db).raw("SELECT m.user_id, u.name, m.role, m.state, m.revision FROM workspace_memberships m JOIN users u ON m.user_id = u.id WHERE m.workspace_id = \(bind: id) ORDER BY m.state, u.name, m.user_id LIMIT 200").all().map { row in
                try WorkspaceMemberResponse(userId: row.decode(column: "user_id", as: UUID.self), name: row.decode(column: "name", as: String?.self), role: row.decode(column: "role", as: String.self), state: row.decode(column: "state", as: String.self), revision: row.decode(column: "revision", as: Int64.self))
            }
        }
    }
    @Sendable func changeMember(req: Request) async throws -> HTTPStatus {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("workspaceId", req), target = try parameter("userId", req)
        let body = try req.content.decode(MemberBody.self)
        try await req.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: id, targetID: target, newRole: body.role, expectedRevision: body.expectedRevision, actorID: actor, on: db) }
        return .noContent
    }
    @Sendable func transferOwner(req: Request) async throws -> HTTPStatus {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("workspaceId", req), body = try req.content.decode(OwnerBody.self)
        try await req.db.transaction { db in try await WorkspaceAccessService.transferOwnership(workspaceID: id, targetID: body.userId, expectedRevision: body.expectedRevision, actorID: actor, on: db) }
        return .noContent
    }
    @Sendable func invite(req: Request) async throws -> InviteResult {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("workspaceId", req), body = try req.content.decode(InviteBody.self)
        let config = try PlatformConfiguration.load(on: req.application)
        let result = try await req.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: id, email: body.email, role: body.role, projects: body.projects, actorID: actor, on: db) }
        // Explicit copy/share flow; this endpoint does not imply email delivery.
        return InviteResult(invitation: TeamInviteResponse(from: result.0), invitationURL: config.origin + "/invitation#token=" + result.1)
    }
    @Sendable func previewInvitation(req: Request) async throws -> InvitationPreview {
        let actor = try req.requireAuthenticatedUserId(), body = try req.content.decode(MagicLinkVerifyBody.self)
        return try await req.db.transaction { db in try await WorkspaceInvitationService.preview(token: body.token, actorID: actor, on: db) }
    }
    @Sendable func accept(req: Request) async throws -> TeamInviteActionResponse {
        let actor = try req.requireAuthenticatedUserId(), body = try req.content.decode(MagicLinkVerifyBody.self)
        let invite = try await req.db.transaction { db in try await WorkspaceInvitationService.accept(token: body.token, actorID: actor, on: db) }
        return TeamInviteActionResponse(success: true, message: "You have joined the company", teamId: invite.teamId, role: invite.role)
    }
    @Sendable func revoke(req: Request) async throws -> HTTPStatus {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("invitationId", req)
        try await req.db.transaction { db in try await WorkspaceInvitationService.revoke(invitationID: id, actorID: actor, on: db) }
        return .noContent
    }
    struct ProjectMemberPage: Content {
        struct Member: Content { let access: ProjectGrantResponse; let name: String? }
        let items: [Member]; let page: Int; let hasMore: Bool
    }
    @Sendable func projectMembers(req: Request) async throws -> ProjectMemberPage {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("projectId", req)
        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        guard (1...10000).contains(page) else { throw Abort(.badRequest, reason: "Invalid page") }
        return try await req.db.transaction { db in
            _ = try await ProjectAccessService.require(.addProjectMember, projectID: id, actorID: actor, on: db)
            let rows = try await VerifiedIdentityService.sql(db).raw("SELECT a.user_id, u.name FROM project_access a JOIN users u ON u.id = a.user_id WHERE a.project_id = \(bind: id) ORDER BY a.user_id LIMIT 51 OFFSET \(bind: (page - 1) * 50)").all()
            var items: [ProjectMemberPage.Member] = []
            for row in rows.prefix(50) {
                let target = try row.decode(column: "user_id", as: UUID.self)
                items.append(try await .init(access: ProjectGrantService.current(projectID: id, targetID: target, on: db), name: row.decode(column: "name", as: String?.self)))
            }
            return ProjectMemberPage(items: items, page: page, hasMore: rows.count > 50)
        }
    }
    @Sendable func grant(req: Request) async throws -> ProjectGrantResponse {
        let actor = try req.requireAuthenticatedUserId(), id = try parameter("projectId", req), body = try req.content.decode(ProjectGrantCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "POST:\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            let required: ProjectAccessPolicy.Action = body.role == "member" ? .addProjectMember : .manageProjectGrants
            let (project, actions) = try await ProjectAccessService.require(required, projectID: id, actorID: actor, on: db)
            if let old = try await PlatformMutationService.replay(ProjectGrantResponse.self, actorID: actor, mutation: body.mutation, hash: hash, on: db) { return old }
            let result = try await ProjectGrantService.set(body, project: project, actorID: actor, actions: actions, on: db)
            try await PlatformMutationService.record(result, actorID: actor, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    private func parameter(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid identifier") }
        return id
    }
}
