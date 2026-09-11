import Vapor
import Fluent
import FluentSQL

struct WorkspaceResponse: Content {
    let id: UUID
    let name: String
    let kind: String
    let role: String
    let revision: Int64
    let timezone: String
}
struct WorkspaceMemberResponse: Content {
    let userId: UUID
    let name: String?
    let role: String
    let state: String
    let revision: Int64
    // Admin directory only; never fill from mutable users.email.
    var verifiedEmail: String? = nil
}

struct WorkspaceAccessService {
    /// All workspace mutations and project commands lock this same scope and
    /// re-read authority in their transaction. Removal cannot race a later write.
    static func lock(_ id: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.lock("workspace:" + id.uuidString, on: db)
    }

    static func personal(for userID: UUID, on db: Database) async throws -> Team {
        try await VerifiedIdentityService.lock("personal-workspace:" + userID.uuidString, on: db)
        _ = try await VerifiedIdentityService.activeUser(userID, on: db)
        if let existing = try await Team.query(on: db).filter(\.$ownerUserId == userID).filter(\.$kind == "personal").first() { return existing }
        let team = Team(name: "Personal projects", ownerUserId: userID)
        team.kind = "personal"
        try await team.save(on: db)
        return team
    }

    static func createCompany(id: UUID, name: String, actorID: UUID, on db: Database) async throws -> Team {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw Abort(.badRequest, reason: "Enter a company name, up to 120 characters") }
        try await lock(id, on: db)
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        if let existing = try await Team.find(id, on: db) {
            guard existing.ownerUserId == actorID, existing.kind == "company", existing.name == name else { throw Abort(.conflict, reason: "That workspace ID is already in use") }
            _ = try await role(actorID: actorID, workspace: existing, on: db)
            return existing
        }
        let team = Team(id: id, name: name, ownerUserId: actorID)
        try await team.save(on: db)
        try await putMembership(workspaceID: id, userID: actorID, role: "owner", on: db)
        try await activity(workspaceID: id, actorID: actorID, action: "company_created", targetID: id, on: db)
        return team
    }

    static func role(actorID: UUID, workspace: Team, on db: Database) async throws -> String {
        guard workspace.lifecycleState == "active" else { throw Abort(.notFound, reason: "Workspace unavailable") }
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        if workspace.kind == "personal" {
            guard workspace.ownerUserId == actorID else { throw Abort(.notFound, reason: "Workspace unavailable") }
            return "owner"
        }
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT role FROM workspace_memberships WHERE workspace_id = \(bind: workspace.requireID()) AND user_id = \(bind: actorID) AND state = 'active'").first() else {
            throw Abort(.notFound, reason: "Workspace unavailable")
        }
        let role = try row.decode(column: "role", as: String.self)
        guard role != "owner" || workspace.ownerUserId == actorID else { throw Abort(.forbidden) }
        return role
    }

    static func requireCompany(_ id: UUID, actorID: UUID, admin: Bool = false, on db: Database) async throws -> Team {
        try await lock(id, on: db)
        guard let team = try await Team.find(id, on: db), team.kind == "company" else { throw Abort(.notFound, reason: "Company unavailable") }
        let actorRole = try await role(actorID: actorID, workspace: team, on: db)
        guard !admin || ["owner", "admin"].contains(actorRole) else { throw Abort(.forbidden, reason: "Ask a company owner or admin to do this") }
        return team
    }

    static func list(actorID: UUID, on db: Database) async throws -> [WorkspaceResponse] {
        _ = try await personal(for: actorID, on: db)
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            SELECT t.id, t.name, t.kind, t.revision, t.timezone,
                CASE WHEN t.kind = 'personal' THEN 'owner' ELSE m.role END AS role
            FROM teams t LEFT JOIN workspace_memberships m ON m.workspace_id = t.id AND m.user_id = \(bind: actorID) AND m.state = 'active'
            WHERE t.lifecycle_state = 'active' AND ((t.kind = 'personal' AND t.owner_user_id = \(bind: actorID))
                OR (t.kind = 'company' AND m.user_id IS NOT NULL AND (m.role <> 'owner' OR t.owner_user_id = \(bind: actorID))))
            ORDER BY t.kind DESC, lower(t.name), t.id LIMIT 100
            """).all()
        return try rows.map { row in
            try WorkspaceResponse(id: row.decode(column: "id", as: UUID.self), name: row.decode(column: "name", as: String.self), kind: row.decode(column: "kind", as: String.self), role: row.decode(column: "role", as: String.self), revision: row.decode(column: "revision", as: Int64.self), timezone: row.decode(column: "timezone", as: String.self))
        }
    }

    static func changeMember(workspaceID: UUID, targetID: UUID, newRole: String?, expectedRevision: Int64,
                             actorID: UUID, on db: Database) async throws {
        let team = try await requireCompany(workspaceID, actorID: actorID, admin: actorID != targetID || newRole != nil, on: db)
        guard targetID != team.ownerUserId else { throw Abort(.conflict, reason: "Transfer company ownership before changing or removing the owner") }
        guard let member = try await VerifiedIdentityService.sql(db).raw("SELECT revision FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: targetID) AND state = 'active'").first() else { throw Abort(.notFound, reason: "Member unavailable") }
        guard try member.decode(column: "revision", as: Int64.self) == expectedRevision else { throw Abort(.conflict, reason: "This membership has changed. Refresh before trying again") }
        if let newRole {
            guard ["admin", "member"].contains(newRole) else { throw Abort(.badRequest, reason: "Choose Admin or Member") }
            try await putMembership(workspaceID: workspaceID, userID: targetID, role: newRole, on: db)
        } else {
            try await VerifiedIdentityService.sql(db).raw("UPDATE workspace_memberships SET state = 'removed', revision = revision + 1, updated_at = \(bind: Date()) WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: targetID)").run()
            try await VerifiedIdentityService.sql(db).raw("UPDATE project_access SET state = 'removed', revision = revision + 1, updated_at = NOW() WHERE state = 'active' AND workspace_id = \(bind: workspaceID) AND user_id = \(bind: targetID)").run()
            try await VerifiedIdentityService.sql(db).raw("UPDATE team_invites SET status = 'revoked', updated_at = \(bind: Date()) WHERE team_id = \(bind: workspaceID) AND status = 'pending' AND email IN (SELECT subject FROM user_identities WHERE user_id = \(bind: targetID) AND provider = 'email')").run()
        }
        try await activity(workspaceID: workspaceID, actorID: actorID, action: newRole == nil ? "member_removed" : "member_role_changed", targetID: targetID, detail: newRole, on: db)
    }

    static func transferOwnership(workspaceID: UUID, targetID: UUID, expectedRevision: Int64, actorID: UUID, on db: Database) async throws {
        let team = try await requireCompany(workspaceID, actorID: actorID, admin: true, on: db)
        guard team.ownerUserId == actorID else { throw Abort(.forbidden, reason: "Only the owner can transfer ownership") }
        guard team.revision == expectedRevision else { throw Abort(.conflict, reason: "Company details changed. Refresh before transferring ownership") }
        guard targetID != actorID,
              try await VerifiedIdentityService.sql(db).raw("SELECT user_id FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: targetID) AND state = 'active'").first() != nil else {
            throw Abort(.badRequest, reason: "Choose an existing active company member")
        }
        _ = try await VerifiedIdentityService.activeUser(targetID, on: db)
        try await putMembership(workspaceID: workspaceID, userID: actorID, role: "admin", on: db)
        try await putMembership(workspaceID: workspaceID, userID: targetID, role: "owner", on: db)
        team.ownerUserId = targetID; team.revision += 1
        try await team.save(on: db)
        try await activity(workspaceID: workspaceID, actorID: actorID, action: "ownership_transferred", targetID: targetID, on: db)
    }

    static func putMembership(workspaceID: UUID, userID: UUID, role: String, on db: Database) async throws {
        _ = try await VerifiedIdentityService.activeUser(userID, on: db)
        let now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO workspace_memberships (workspace_id, user_id, role, state, revision, created_at, updated_at)
            VALUES (\(bind: workspaceID), \(bind: userID), \(bind: role), 'active', 1, \(bind: now), \(bind: now))
            ON CONFLICT (workspace_id, user_id) DO UPDATE SET role = EXCLUDED.role, state = 'active', revision = workspace_memberships.revision + 1, updated_at = EXCLUDED.updated_at
            """).run()
    }

    static func activity(workspaceID: UUID, actorID: UUID?, grantID: UUID? = nil, action: String, targetID: UUID?, detail: String? = nil, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO workspace_activity (id, workspace_id, actor_user_id, actor_grant_id, action, target_id, detail, created_at) VALUES (\(bind: UUID()), \(bind: workspaceID), \(bind: actorID), \(bind: grantID), \(bind: action), \(bind: targetID), \(bind: detail), \(bind: Date()))").run()
    }
}

struct ProjectAccessService {
    /// Caller holds a DB transaction. The workspace lock is shared by membership,
    /// transfer, grant and project commands; re-read project after taking it.
    static func require(_ action: ProjectAccessPolicy.Action, projectID: UUID, actorID: UUID, on db: Database) async throws -> (Project, Set<ProjectAccessPolicy.Action>) {
        guard var project = try await Project.find(projectID, on: db) else { throw Abort(.notFound, reason: "Project unavailable") }
        if project.workspaceId == nil {
            guard project.ownerId == actorID else { throw Abort(.notFound, reason: "Project unavailable") }
            let personal = try await WorkspaceAccessService.personal(for: actorID, on: db)
            project.workspaceId = try personal.requireID()
            try await project.save(on: db)
        }
        let workspaceID = project.workspaceId!
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        guard let fresh = try await Project.find(projectID, on: db), fresh.workspaceId == workspaceID,
              let team = try await Team.find(workspaceID, on: db) else { throw Abort(.conflict, reason: "Project access changed. Refresh to continue") }
        project = fresh
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        let member = try await sql.raw("SELECT role, state FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: actorID)").first()
        let grant = try await sql.raw("SELECT role FROM project_access WHERE state = 'active' AND workspace_id = \(bind: workspaceID) AND project_id = \(bind: projectID) AND user_id = \(bind: actorID)").first()
        let membership: ProjectAccessPolicy.Membership? = try member.flatMap { row in
            guard let role = ProjectAccessPolicy.WorkspaceRole(rawValue: try row.decode(column: "role", as: String.self)) else { return nil }
            return .init(workspaceID: workspaceID, userID: actorID, role: role, active: try row.decode(column: "state", as: String.self) == "active")
        }
        let access: ProjectAccessPolicy.Grant? = try grant.flatMap { row in
            guard let role = ProjectAccessPolicy.ProjectRole(rawValue: try row.decode(column: "role", as: String.self)) else { return nil }
            return .init(workspaceID: workspaceID, projectID: projectID, userID: actorID, role: role)
        }
        guard let kind = ProjectAccessPolicy.WorkspaceKind(rawValue: team.kind) else { throw Abort(.forbidden) }
        let actions = ProjectAccessPolicy.allowedActions(actorID: actorID, workspace: .init(id: workspaceID, kind: kind, ownerID: team.ownerUserId, active: team.lifecycleState == "active"), project: .init(id: projectID, workspaceID: workspaceID, creatorID: project.ownerId), membership: membership, grant: access)
        guard actions.contains(.read) else { throw Abort(.notFound, reason: "Project unavailable") }
        guard actions.contains(action) else { throw Abort(.forbidden, reason: "Your project role does not allow this action") }
        return (project, actions)
    }

    static func grant(projectID: UUID, targetID: UUID, role: String, actorID: UUID, on db: Database) async throws {
        let (project, actions) = try await require(.addProjectMember, projectID: projectID, actorID: actorID, on: db)
        let current = try await ProjectGrantService.current(projectID: projectID, targetID: targetID, on: db)
        let command = ProjectGrantCommand(mutation: .init(operationId: UUID(), deviceId: UUID()), userId: targetID, role: role, expectedRevision: current.revision)
        _ = try await ProjectGrantService.set(command, project: project, actorID: actorID, actions: actions, on: db)
    }
}
