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
        try await VerifiedIdentityService.sql(db).raw("""
            SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "workspace:" + id.uuidString), 0)) IS NULL AS locked
            FROM (SELECT set_config('lock_timeout', \(bind: commandLockTimeout), true) AS applied) AS bound WHERE bound.applied IS NOT NULL
            """).run()
    }

    /// Bounded lock waits (Fable, final remediation design §5 F-L4). A transaction queued for a
    /// workspace lock holds a pooled connection while it waits; without a bound, one long read plus
    /// one queued command plus a few new reads could hold the whole pool. The first statement that
    /// takes a workspace lock sets `lock_timeout` for the rest of its transaction (`set_config(...,
    /// true)` is `SET LOCAL`), in the same statement so it costs no round trip: the bound is applied
    /// in the FROM clause, which PostgreSQL evaluates before the lock in the select list. A wait
    /// that reaches the bound fails with SQLSTATE 55P03, answered as 503 `workspace_busy` with
    /// Retry-After (`PrivateRequestLoggingMiddleware`). Every client already retries a 503.
    static let readLockTimeout = "8s"
    static let commandLockTimeout = "15s"

    /// The same scope, shared (wave 3, 28 Sep 2026). Reads of one workspace used to queue
    /// behind each other on the exclusive lock above, so a busy workspace served about one
    /// register read a second whatever the pool size. A shared holder still excludes every
    /// exclusive holder — a membership, access or content change never overlaps a read, and
    /// a read never overlaps such a change — but readers no longer wait for one another.
    /// Only for a transaction that writes nothing and never asks for the exclusive lock
    /// afterwards: two shared holders both upgrading would deadlock.
    static func readLock(_ id: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("""
            SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: "workspace:" + id.uuidString), 0)) IS NULL AS locked
            FROM (SELECT set_config('lock_timeout', \(bind: readLockTimeout), true) AS applied) AS bound WHERE bound.applied IS NOT NULL
            """).run()
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
        try await check(action, projectID: projectID, actorID: actorID, shared: false, on: db)
    }

    /// Read access for a transaction that only reads (register, snag, photo, comment,
    /// history and report reads): exactly the checks above, under the shared workspace lock,
    /// so reads of one workspace run side by side while any change to access still excludes
    /// them. A transaction that writes, or that locks the workspace exclusively later, must
    /// use `require` instead.
    static func requireRead(projectID: UUID, actorID: UUID, on db: Database) async throws -> (Project, Set<ProjectAccessPolicy.Action>) {
        let context = try await readContext(projectID: projectID, actorID: actorID, on: db)
        return (context.project, context.actions)
    }

    /// What one read needs to know, loaded in two statements instead of seven (Lane 2, 28 Sep 2026).
    /// Staging's container sits a 40 ms database round trip from Neon, and the seven sequential
    /// statements of `check` cost about 300 ms of every read before it read anything. The rules are
    /// exactly `check(.read, shared: true)`'s — the same shared `workspace:<id>` key, taken before
    /// any access fact is read; project, workspace, account, membership and grant then re-read in
    /// one statement under it; the same `allowedActions`; the same errors in the same order. A
    /// project that predates workspaces (or does not exist) goes through `check` unchanged.
    struct ReadContext {
        let project: Project
        let actions: Set<ProjectAccessPolicy.Action>
        /// The workspace's calendar (`teams.timezone`), read in the same statement.
        let workspaceTimezone: String
    }

    static func readContext(projectID: UUID, actorID: UUID, on db: Database) async throws -> ReadContext {
        try await readContext(projectID: projectID, actorID: actorID, located: try await locateForRead(projectID: projectID, on: db), on: db)
    }

    /// The project's workspace, found by the statement that takes that workspace's shared lock, and the workspace
    /// calendar as read by that same statement: a hint only (its snapshot predates the lock); whoever uses it
    /// compares it with the calendar re-read under the lock (Lane 2, 28 Sep 2026, evening).
    struct Located: Sendable { let workspaceID: UUID; let timezoneHint: String? }

    /// readContext's first statement. nil: no such project, or it predates workspaces (`check` handles both).
    static func locateForRead(projectID: UUID, on db: Database) async throws -> Located? {
        // The key is byte-for-byte `WorkspaceAccessService.readLock`'s: "workspace:" + the upper-case UUID
        // string Swift's `uuidString` produces (PostgreSQL's uuid text is lower-case, hence upper()).
        guard let located = try await VerifiedIdentityService.sql(db).raw("""
            SELECT p.workspace_id, pg_advisory_xact_lock_shared(hashtextextended('workspace:' || upper(p.workspace_id::text), 0)) IS NULL AS lock_result,
                   (SELECT t.timezone FROM teams t WHERE t.id = p.workspace_id) AS timezone_hint
            FROM projects p, (SELECT set_config('lock_timeout', \(bind: WorkspaceAccessService.readLockTimeout), true) AS applied) AS bound
            WHERE p.id = \(bind: projectID) AND p.workspace_id IS NOT NULL AND bound.applied IS NOT NULL
            """).first() else { return nil }
        return .init(workspaceID: try located.decode(column: "workspace_id", as: UUID.self), timezoneHint: try located.decode(column: "timezone_hint", as: String?.self))
    }

    /// readContext after its first statement (`located` = that statement's answer).
    static func readContext(projectID: UUID, actorID: UUID, located: Located?, on db: Database) async throws -> ReadContext {
        // 1. No workspace found: a project that predates workspaces (or does not exist) goes through `check` unchanged.
        guard let located else {
            let (project, actions) = try await check(.read, projectID: projectID, actorID: actorID, shared: true, on: db)
            guard let workspaceID = project.workspaceId, let team = try await Team.find(workspaceID, on: db) else { throw Abort(.conflict, reason: "Project access changed. Refresh to continue") }
            return .init(project: project, actions: actions, workspaceTimezone: team.timezone)
        }
        let workspaceID = located.workspaceID
        // 2. Everything the decision reads, re-read under the lock (a new statement, so a new snapshot).
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT p.*, t.kind AS access_workspace_kind, t.owner_user_id AS access_workspace_owner,
                   t.lifecycle_state AS access_workspace_state, t.timezone AS access_workspace_timezone,
                   (SELECT u.lifecycle_state FROM users u WHERE u.id = \(bind: actorID)) AS access_user_state,
                   (SELECT m.role FROM workspace_memberships m WHERE m.workspace_id = p.workspace_id AND m.user_id = \(bind: actorID)) AS access_member_role,
                   (SELECT m.state FROM workspace_memberships m WHERE m.workspace_id = p.workspace_id AND m.user_id = \(bind: actorID)) AS access_member_state,
                   (SELECT g.role FROM project_access g WHERE g.state = 'active' AND g.workspace_id = p.workspace_id AND g.project_id = p.id AND g.user_id = \(bind: actorID) LIMIT 1) AS access_grant_role
            FROM projects p JOIN teams t ON t.id = p.workspace_id
            WHERE p.id = \(bind: projectID)
            """).first(), try row.decode(column: "workspace_id", as: UUID?.self) == workspaceID else {
            throw Abort(.conflict, reason: "Project access changed. Refresh to continue")
        }
        let project = try row.decode(fluentModel: Project.self)
        let actions = try readDecision(row, projectID: projectID, workspaceID: workspaceID, actorID: actorID, ownerID: project.ownerId)
        return .init(project: project, actions: actions, workspaceTimezone: try row.decode(column: "access_workspace_timezone", as: String.self))
    }

    /// readContext's decision from one row's access facts (`access_*` columns), with its errors in its order:
    /// the account (401), the workspace kind (403), then `.read` (404). Shared by the one-statement register read.
    static func readDecision(_ row: any SQLRow, projectID: UUID, workspaceID: UUID, actorID: UUID, ownerID: UUID) throws -> Set<ProjectAccessPolicy.Action> {
        guard try row.decode(column: "access_user_state", as: String?.self) == "active" else {
            throw Abort(.unauthorized, reason: "Account is no longer available")
        }
        let membership: ProjectAccessPolicy.Membership? = try row.decode(column: "access_member_role", as: String?.self).flatMap { raw in
            guard let role = ProjectAccessPolicy.WorkspaceRole(rawValue: raw) else { return nil }
            return .init(workspaceID: workspaceID, userID: actorID, role: role, active: try row.decode(column: "access_member_state", as: String?.self) == "active")
        }
        let grant: ProjectAccessPolicy.Grant? = try row.decode(column: "access_grant_role", as: String?.self).flatMap { raw in
            guard let role = ProjectAccessPolicy.ProjectRole(rawValue: raw) else { return nil }
            return .init(workspaceID: workspaceID, projectID: projectID, userID: actorID, role: role)
        }
        guard let kind = ProjectAccessPolicy.WorkspaceKind(rawValue: try row.decode(column: "access_workspace_kind", as: String.self)) else { throw Abort(.forbidden) }
        let actions = ProjectAccessPolicy.allowedActions(actorID: actorID,
            workspace: .init(id: workspaceID, kind: kind, ownerID: try row.decode(column: "access_workspace_owner", as: UUID.self),
                             active: try row.decode(column: "access_workspace_state", as: String.self) == "active"),
            project: .init(id: projectID, workspaceID: workspaceID, creatorID: ownerID), membership: membership, grant: grant)
        guard actions.contains(.read) else { throw Abort(.notFound, reason: "Project unavailable") }
        return actions
    }

    private static func check(_ action: ProjectAccessPolicy.Action, projectID: UUID, actorID: UUID, shared: Bool, on db: Database) async throws -> (Project, Set<ProjectAccessPolicy.Action>) {
        guard var project = try await Project.find(projectID, on: db) else { throw Abort(.notFound, reason: "Project unavailable") }
        var shared = shared
        if project.workspaceId == nil {
            // Fable §5 F-L3: attaching a pre-workspace project is a write, so this call takes the
            // workspace lock exclusively even when a read asked for the shared path.
            shared = false
            guard project.ownerId == actorID else { throw Abort(.notFound, reason: "Project unavailable") }
            let personal = try await WorkspaceAccessService.personal(for: actorID, on: db)
            project.workspaceId = try personal.requireID()
            try await project.save(on: db)
        }
        let workspaceID = project.workspaceId!
        if shared { try await WorkspaceAccessService.readLock(workspaceID, on: db) }
        else { try await WorkspaceAccessService.lock(workspaceID, on: db) }
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


/// One workspace's readable projects for one actor, decided under the workspace's shared lock with a
/// constant number of statements (Lane 2, 28 Sep 2026). The project list used to run the seven-statement
/// `ProjectAccessService.check` once per project (about 140 statements for 20 projects); the workspace
/// summary and register need the same set. Every rule is the existing one: `WorkspaceAccessService.role`
/// for the workspace (same errors), the project list's own set of candidate projects, and
/// `ProjectAccessPolicy.allowedActions` for each project with that actor's membership and project grant.
struct WorkspaceReadScope {
    let team: Team
    let workspaceID: UUID
    /// The actor's workspace role as `WorkspaceAccessService.role` returns it.
    let role: String
    /// The project list's candidates in its order (most recently updated first: `updated_at DESC, id`),
    /// each with the actions `allowedActions` gives this actor. A candidate may lack `.read` (for
    /// example a grant whose role no longer parses): the project list refuses as it always did, and
    /// the workspace summary and register leave it out.
    let projects: [(project: Project, actions: Set<ProjectAccessPolicy.Action>)]
    var readable: [(project: Project, actions: Set<ProjectAccessPolicy.Action>)] { projects.filter { $0.actions.contains(.read) } }

    /// Caller holds a transaction. `candidateLimit` bounds the rows read (the project list reads
    /// one page plus one); nil reads every active project of the workspace.
    static func load(workspaceID: UUID, actorID: UUID, offset: Int = 0, candidateLimit: Int? = nil, on db: Database) async throws -> WorkspaceReadScope {
        try await WorkspaceAccessService.readLock(workspaceID, on: db)
        // Everything else in ONE statement under the lock (Lane 2, 28 Sep 2026, evening; was three to five: the
        // workspace, the account, the membership for `role`, the candidates, the membership again for the policy).
        // The same rows, read from one snapshot; `WorkspaceAccessService.role`'s checks are made below in its order
        // with its errors, and the candidates are the project list's: active projects of the workspace, and for a
        // company Member only those with an active grant, most recently updated first.
        let limit = candidateLimit.map { "LIMIT \($0) OFFSET \(offset)" } ?? ""
        let teamColumns = Team.keys.map { key -> SQLQueryString in "t.\(ident: key.description) AS \(ident: "scope_team_" + key.description)" }.joined(separator: ", ")
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            WITH head AS (
                SELECT \(teamColumns),
                       (SELECT u.lifecycle_state FROM users u WHERE u.id = \(bind: actorID)) AS scope_user_state,
                       (SELECT m.role FROM workspace_memberships m WHERE m.workspace_id = t.id AND m.user_id = \(bind: actorID)) AS scope_member_role,
                       (SELECT m.state FROM workspace_memberships m WHERE m.workspace_id = t.id AND m.user_id = \(bind: actorID)) AS scope_member_state
                FROM teams t WHERE t.id = \(bind: workspaceID)
            )
            SELECT head.*, candidate.*
            FROM head LEFT JOIN LATERAL (
                SELECT p.*,
                       (SELECT g.role FROM project_access g WHERE g.state = 'active' AND g.workspace_id = p.workspace_id AND g.project_id = p.id AND g.user_id = \(bind: actorID) LIMIT 1) AS access_grant_role
                FROM projects p
                WHERE p.workspace_id = \(bind: workspaceID) AND p.archived_at IS NULL
                  AND (NOT COALESCE(head.scope_team_kind = 'company' AND head.scope_member_state = 'active' AND head.scope_member_role = 'member', FALSE)
                       OR p.id IN (SELECT project_id FROM project_access WHERE state = 'active' AND workspace_id = \(bind: workspaceID) AND user_id = \(bind: actorID)))
                ORDER BY p.updated_at DESC, p.id
                \(unsafeRaw: limit)
            ) candidate ON TRUE
            ORDER BY candidate.updated_at DESC, candidate.id
            """).all()
        guard let first = rows.first else { throw Abort(.notFound) }
        let team = try PrefixedSQLRow(base: first, prefix: "scope_team_").decode(fluentModel: Team.self)
        // `WorkspaceAccessService.role`, check for check.
        guard team.lifecycleState == "active" else { throw Abort(.notFound, reason: "Workspace unavailable") }
        guard try first.decode(column: "scope_user_state", as: String?.self) == "active" else { throw Abort(.unauthorized, reason: "Account is no longer available") }
        let memberRole = try first.decode(column: "scope_member_role", as: String?.self)
        let memberState = try first.decode(column: "scope_member_state", as: String?.self)
        let role: String
        if team.kind == "personal" {
            guard team.ownerUserId == actorID else { throw Abort(.notFound, reason: "Workspace unavailable") }
            role = "owner"
        } else {
            guard memberState == "active", let active = memberRole else { throw Abort(.notFound, reason: "Workspace unavailable") }
            guard active != "owner" || team.ownerUserId == actorID else { throw Abort(.forbidden) }
            role = active
        }
        // The membership the policy reads (any state), for a company workspace only, as before.
        var membership: ProjectAccessPolicy.Membership? = nil
        if team.kind == "company", let raw = memberRole, let parsed = ProjectAccessPolicy.WorkspaceRole(rawValue: raw) {
            membership = .init(workspaceID: workspaceID, userID: actorID, role: parsed, active: memberState == "active")
        }
        guard let kind = ProjectAccessPolicy.WorkspaceKind(rawValue: team.kind) else { throw Abort(.forbidden) }
        let workspace = ProjectAccessPolicy.Workspace(id: workspaceID, kind: kind, ownerID: team.ownerUserId, active: team.lifecycleState == "active")
        var projects: [(project: Project, actions: Set<ProjectAccessPolicy.Action>)] = []
        for row in rows {
            guard !(try row.decodeNil(column: "id")) else { continue }
            let project = try row.decode(fluentModel: Project.self)
            let projectID = try project.requireID()
            let grant: ProjectAccessPolicy.Grant? = try row.decode(column: "access_grant_role", as: String?.self).flatMap { raw in
                guard let parsed = ProjectAccessPolicy.ProjectRole(rawValue: raw) else { return nil }
                return .init(workspaceID: workspaceID, projectID: projectID, userID: actorID, role: parsed)
            }
            let actions = ProjectAccessPolicy.allowedActions(actorID: actorID, workspace: workspace,
                project: .init(id: projectID, workspaceID: workspaceID, creatorID: project.ownerId), membership: membership, grant: grant)
            projects.append((project, actions))
        }
        return .init(team: team, workspaceID: workspaceID, role: role, projects: projects)
    }
}
