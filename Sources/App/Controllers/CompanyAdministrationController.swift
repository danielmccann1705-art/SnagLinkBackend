import Vapor
import Fluent
import FluentSQL

/// Read models for customer company administration. Existing mutation services
/// remain the authority; personal workspaces and ordinary Members are excluded.
struct CompanyAdministrationController: RouteCollection {
    struct MemberPage: Content {
        let workspace: WorkspaceResponse
        let items: [WorkspaceMemberResponse]
        let page: Int
        let hasMore: Bool
    }
    struct Invitation: Content {
        let id: UUID
        let email: String
        let role: String
        let status: String
        let expiresAt: Date
        let createdAt: Date?
        let invitedByName: String?
        let projectCount: Int
        let canRevoke: Bool
    }
    struct InvitationPage: Content {
        let workspace: WorkspaceResponse
        let items: [Invitation]
        let page: Int
        let hasMore: Bool
    }
    struct Activity: Content {
        let id: UUID
        let action: String
        let actorName: String?
        let targetName: String?
        let projectName: String?
        let role: String?
        let createdAt: Date
    }
    struct ActivityPage: Content {
        let workspace: WorkspaceResponse
        let items: [Activity]
        let page: Int
        let hasMore: Bool
    }
    struct MemberProject: Content {
        let id: UUID
        let name: String
        let access: ProjectGrantResponse
    }
    struct MemberProjectPage: Content {
        let workspace: WorkspaceResponse
        let member: WorkspaceMemberResponse
        let items: [MemberProject]
        let page: Int
        let hasMore: Bool
    }
    struct Query {
        let page: Int
        let search: String
        let state: String
        init(_ req: Request, states: [String]) throws {
            page = try req.query.get(Int?.self, at: "page") ?? 1
            search = (try req.query.get(String?.self, at: "q") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            state = try req.query.get(String?.self, at: "state") ?? "all"
            guard (1...10000).contains(page), search.count <= 120, states.contains(state) else {
                throw Abort(.badRequest, reason: "Check the search, filter and page")
            }
        }
    }
    func boot(routes: RoutesBuilder) throws {
        let company = routes.grouped("api", "v2", "workspaces", ":workspaceId").grouped(PlatformAuthMiddleware())
        company.get("administration", "members", use: members)
        company.get("invitations", use: invitations)
        company.get("administration", "activity", use: activity)
        company.get("administration", "members", ":userId", "projects", use: memberProjects)
    }
    private func context(_ req: Request, on db: Database) async throws -> WorkspaceResponse {
        guard let raw = req.parameters.get("workspaceId"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        let actor = try req.requireAuthenticatedUserId()
        let team = try await WorkspaceAccessService.requireCompany(id, actorID: actor, admin: true, on: db)
        return try await .init(id: id, name: team.name, kind: team.kind,
                              role: WorkspaceAccessService.role(actorID: actor, workspace: team, on: db),
                              revision: team.revision, timezone: team.timezone)
    }
    @Sendable func members(req: Request) async throws -> MemberPage {
        let query = try Query(req, states: ["all", "active", "removed"])
        return try await req.db.transaction { db in
            let workspace = try await context(req, on: db)
            let rows = try await VerifiedIdentityService.sql(db).raw("""
                SELECT m.user_id, u.name, m.role, m.state, m.revision,
                    (SELECT min(subject) FROM user_identities WHERE user_id = m.user_id AND provider = 'email') AS verified_email
                FROM workspace_memberships m JOIN users u ON u.id = m.user_id
                WHERE m.workspace_id = \(bind: workspace.id)
                    AND (\(bind: query.state) = 'all' OR m.state = \(bind: query.state))
                    AND (position(lower(\(bind: query.search)) in lower(coalesce(u.name, 'Unnamed member'))) > 0
                         OR EXISTS (SELECT 1 FROM user_identities WHERE user_id = m.user_id AND provider = 'email'
                             AND position(lower(\(bind: query.search)) in lower(subject)) > 0))
                ORDER BY CASE WHEN m.state = 'active' THEN 0 ELSE 1 END,
                    CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, lower(coalesce(u.name, '')), m.user_id
                LIMIT 51 OFFSET \(bind: (query.page - 1) * 50)
                """).all()
            let items = try rows.prefix(50).map { row in
                try WorkspaceMemberResponse(userId: row.decode(column: "user_id", as: UUID.self), name: row.decode(column: "name", as: String?.self), role: row.decode(column: "role", as: String.self), state: row.decode(column: "state", as: String.self), revision: row.decode(column: "revision", as: Int64.self), verifiedEmail: row.decode(column: "verified_email", as: String?.self))
            }
            return .init(workspace: workspace, items: items, page: query.page, hasMore: rows.count > 50)
        }
    }
    @Sendable func invitations(req: Request) async throws -> InvitationPage {
        let query = try Query(req, states: ["all", "pending", "accepted", "expired", "revoked", "declined"])
        return try await req.db.transaction { db in
            let workspace = try await context(req, on: db)
            let now = Date()
            // No token/hash, profile email of members or invitation URL is selected.
            let rows = try await VerifiedIdentityService.sql(db).raw("""
                SELECT i.id, i.email, i.role, i.status, i.expires_at, i.created_at, i.invited_by_name,
                    (SELECT count(*) FROM invitation_project_grants g WHERE g.invitation_id = i.id) AS project_count
                FROM team_invites i WHERE i.team_id = \(bind: workspace.id)
                    AND (\(bind: query.state) = 'all' OR
                        CASE WHEN i.status = 'pending' AND i.expires_at <= \(bind: now) THEN 'expired' ELSE i.status END = \(bind: query.state))
                    AND position(lower(\(bind: query.search)) in lower(i.email)) > 0
                ORDER BY i.created_at DESC NULLS LAST, i.id DESC LIMIT 51 OFFSET \(bind: (query.page - 1) * 50)
                """).all()
            let items = try rows.prefix(50).map { row in
                let status = try row.decode(column: "status", as: String.self)
                let expiry = try row.decode(column: "expires_at", as: Date.self)
                let role = try row.decode(column: "role", as: String.self)
                return try Invitation(id: row.decode(column: "id", as: UUID.self), email: row.decode(column: "email", as: String.self), role: role == "editor" ? "member" : role,
                                      status: status == "pending" && expiry <= now ? "expired" : status,
                                      expiresAt: expiry, createdAt: row.decode(column: "created_at", as: Date?.self), invitedByName: row.decode(column: "invited_by_name", as: String?.self), projectCount: row.decode(column: "project_count", as: Int.self), canRevoke: status == "pending")
            }
            return .init(workspace: workspace, items: items, page: query.page, hasMore: rows.count > 50)
        }
    }
    @Sendable func memberProjects(req: Request) async throws -> MemberProjectPage {
        let query = try Query(req, states: ["all"])
        guard let raw = req.parameters.get("userId"), let target = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return try await req.db.transaction { db in
            let workspace = try await context(req, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            guard let row = try await sql.raw("SELECT m.user_id, u.name, m.role, m.state, m.revision FROM workspace_memberships m JOIN users u ON u.id = m.user_id WHERE m.workspace_id = \(bind: workspace.id) AND m.user_id = \(bind: target) AND m.state = 'active'").first() else {
                throw Abort(.notFound, reason: "Company member unavailable")
            }
            let member = try WorkspaceMemberResponse(userId: target, name: row.decode(column: "name", as: String?.self), role: row.decode(column: "role", as: String.self), state: row.decode(column: "state", as: String.self), revision: row.decode(column: "revision", as: Int64.self))
            let rows = try await sql.raw("""
                SELECT p.id, p.name, a.role, a.state, coalesce(a.revision, 0) AS revision
                FROM projects p LEFT JOIN project_access a ON a.project_id = p.id
                    AND a.workspace_id = p.workspace_id AND a.user_id = \(bind: target)
                WHERE p.workspace_id = \(bind: workspace.id) AND p.archived_at IS NULL
                    AND position(lower(\(bind: query.search)) in lower(p.name)) > 0
                ORDER BY lower(p.name), p.id LIMIT 51 OFFSET \(bind: (query.page - 1) * 50)
                """).all()
            let items = try rows.prefix(50).map { row in
                let id = try row.decode(column: "id", as: UUID.self)
                let state = try row.decode(column: "state", as: String?.self) ?? "absent"
                return try MemberProject(id: id, name: row.decode(column: "name", as: String.self), access: .init(projectId: id, userId: target, role: state == "active" ? row.decode(column: "role", as: String?.self) : nil, state: state, revision: row.decode(column: "revision", as: Int64.self)))
            }
            return .init(workspace: workspace, member: member, items: items, page: query.page, hasMore: rows.count > 50)
        }
    }
    @Sendable func activity(req: Request) async throws -> ActivityPage {
        let query = try Query(req, states: ["all"])
        return try await req.db.transaction { db in
            let workspace = try await context(req, on: db)
            // Explicit administration allowlist. Arbitrary detail, snag content,
            // Contractor link actors, credentials and tokens never enter this DTO.
            let rows = try await VerifiedIdentityService.sql(db).raw("""
                SELECT a.id, a.action,
                    COALESCE(actor.name,CASE WHEN actor.lifecycle_state='deleted' THEN 'Former member' END) AS actor_name,
                    p.name AS project_name,
                    CASE WHEN a.action LIKE 'invitation_%' THEN i.email
                         WHEN a.action = 'company_created' THEN t.name
                         ELSE COALESCE(target.name,CASE WHEN target.lifecycle_state='deleted' THEN 'Former member' END) END AS target_name,
                    CASE WHEN a.action = 'member_role_changed' AND a.detail IN ('admin', 'member') THEN a.detail
                         WHEN a.action IN ('project_access_granted', 'project_access_removed') AND split_part(a.detail, ':', 4) IN ('manager', 'member', 'none') THEN split_part(a.detail, ':', 4)
                         ELSE NULL END AS role,
                    a.created_at
                FROM workspace_activity a
                LEFT JOIN users actor ON actor.id = a.actor_user_id
                LEFT JOIN users target ON target.id = a.target_id
                LEFT JOIN team_invites i ON i.id = a.target_id AND i.team_id = a.workspace_id
                LEFT JOIN teams t ON t.id = a.target_id AND t.id = a.workspace_id
                LEFT JOIN projects p ON p.workspace_id = a.workspace_id AND lower(p.id::text) = lower(split_part(a.detail, ':', 1))
                    AND a.action IN ('project_access_granted', 'project_access_removed')
                WHERE a.workspace_id = \(bind: workspace.id) AND a.action IN
                    ('company_created', 'member_removed', 'member_role_changed', 'ownership_transferred', 'invitation_created', 'invitation_accepted', 'invitation_revoked', 'project_access_granted', 'project_access_removed')
                ORDER BY a.created_at DESC, a.id DESC LIMIT 51 OFFSET \(bind: (query.page - 1) * 50)
                """).all()
            let items = try rows.prefix(50).map { row in
                try Activity(id: row.decode(column: "id", as: UUID.self), action: row.decode(column: "action", as: String.self), actorName: row.decode(column: "actor_name", as: String?.self), targetName: row.decode(column: "target_name", as: String?.self), projectName: row.decode(column: "project_name", as: String?.self), role: row.decode(column: "role", as: String?.self), createdAt: row.decode(column: "created_at", as: Date.self))
            }
            return .init(workspace: workspace, items: items, page: query.page, hasMore: rows.count > 50)
        }
    }
}
