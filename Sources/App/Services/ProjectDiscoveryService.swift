import Vapor
import Fluent
import FluentSQL

/// An immutable, actor-bound inventory. The old offset-based project list remains
/// useful for browsing, but must not be used to reconcile an account's local cache.
struct ProjectDiscoveryService {
    private struct Scope {
        let workspaceIDs: [UUID]
        let projectIDs: [UUID]
        let actions: [UUID: Set<ProjectAccessPolicy.Action>]
        let fingerprint: String
    }

    /// Lock current and previously captured workspaces in UUID order. A second
    /// directory read detects membership additions/removals while acquiring locks;
    /// no HTTP-spanning transaction or mutable offset list is involved.
    private static func scope(actorID: UUID, previous: [UUID] = [], on db: Database) async throws -> Scope {
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        // V1 can still create owner-bound records without a workspace. Do not
        // report a complete inventory that silently omits this known legacy work,
        // and do not claim/import it merely because discovery was requested.
        if try await sql.raw("SELECT id FROM projects WHERE owner_id = \(bind: actorID) AND workspace_id IS NULL LIMIT 1").first() != nil {
            throw Abort(.conflict, reason: "Some older projects need ownership reconciliation. Keep local work and complete reconciliation before refreshing the account inventory", identifier: "project_ownership_reconciliation_required")
        }
        func workspaces() async throws -> [SQLRow] {
            try await sql.raw("""
                SELECT t.id, t.kind, t.owner_user_id, t.lifecycle_state,
                    COALESCE(m.role, '') AS role, COALESCE(m.state, '') AS membership_state,
                    COALESCE(m.revision, 0) AS membership_revision
                FROM teams t LEFT JOIN workspace_memberships m ON m.workspace_id = t.id AND m.user_id = \(bind: actorID)
                WHERE t.lifecycle_state = 'active' AND
                    ((t.kind = 'personal' AND t.owner_user_id = \(bind: actorID)) OR
                    (t.kind = 'company' AND m.state = 'active' AND (m.role <> 'owner' OR t.owner_user_id = \(bind: actorID))))
                ORDER BY t.id LIMIT 101
                """).all()
        }
        let initial = try await workspaces()
        guard initial.count <= 100, previous.count <= 100 else {
            throw Abort(.payloadTooLarge, reason: "This account needs a background project inventory. No partial inventory was created", identifier: "discovery_job_required")
        }
        let initialIDs = try initial.map { try $0.decode(column: "id", as: UUID.self) }
        for id in Set(initialIDs + previous).sorted(by: { $0.uuidString < $1.uuidString }) {
            try await WorkspaceAccessService.lock(id, on: db)
        }
        let directory = try await workspaces()
        let ids = try directory.map { try $0.decode(column: "id", as: UUID.self) }
        guard ids == initialIDs else { throw changed() }
        var fingerprint: [String] = [], projects: [UUID] = [], actions: [UUID: Set<ProjectAccessPolicy.Action>] = [:]
        for row in directory {
            let id = try row.decode(column: "id", as: UUID.self)
            let kind = try row.decode(column: "kind", as: String.self), owner = try row.decode(column: "owner_user_id", as: UUID.self)
            let role = try row.decode(column: "role", as: String.self), state = try row.decode(column: "membership_state", as: String.self)
            let revision = try row.decode(column: "membership_revision", as: Int64.self)
            fingerprint += [id.uuidString, kind, owner.uuidString, role, state, String(revision)]
            let rows = try await sql.raw("""
                SELECT p.id, p.owner_id, p.platform_managed, p.archived_at,
                    COALESCE(g.role, '') AS project_role, COALESCE(g.state, '') AS grant_state,
                    COALESCE(g.revision, 0) AS grant_revision
                FROM projects p LEFT JOIN project_access g ON g.project_id = p.id AND g.workspace_id = p.workspace_id AND g.user_id = \(bind: actorID)
                WHERE p.workspace_id = \(bind: id) AND
                    (\(bind: kind) = 'personal' OR \(bind: role) IN ('owner', 'admin') OR g.state = 'active')
                ORDER BY p.id LIMIT 2001
                """).all()
            guard projects.count + rows.count <= 2000 else {
                throw Abort(.payloadTooLarge, reason: "This account needs a background project inventory. No partial inventory was created", identifier: "discovery_job_required")
            }
            for project in rows {
                let projectID = try project.decode(column: "id", as: UUID.self)
                let projectRole = try project.decode(column: "project_role", as: String.self)
                let grantState = try project.decode(column: "grant_state", as: String.self)
                let granted = ProjectAccessPolicy.ProjectRole(rawValue: projectRole).map {
                    ProjectAccessPolicy.Grant(workspaceID: id, projectID: projectID, userID: actorID, role: $0)
                }
                let member = ProjectAccessPolicy.WorkspaceRole(rawValue: role).map {
                    ProjectAccessPolicy.Membership(workspaceID: id, userID: actorID, role: $0, active: state == "active")
                }
                guard let workspaceKind = ProjectAccessPolicy.WorkspaceKind(rawValue: kind) else { throw Abort(.forbidden) }
                let permitted = try ProjectAccessPolicy.allowedActions(actorID: actorID,
                    workspace: .init(id: id, kind: workspaceKind, ownerID: owner, active: true),
                    project: .init(id: projectID, workspaceID: id, creatorID: project.decode(column: "owner_id", as: UUID.self)),
                    membership: member, grant: grantState == "active" ? granted : nil)
                guard permitted.contains(.read) else { continue }
                projects.append(projectID); actions[projectID] = permitted
                fingerprint += [projectID.uuidString, projectRole, grantState,
                    String(try project.decode(column: "grant_revision", as: Int64.self)),
                    String(try project.decode(column: "platform_managed", as: Bool.self)),
                    try project.decode(column: "archived_at", as: Date?.self).map { String($0.timeIntervalSince1970) } ?? "active"]
            }
        }
        return .init(workspaceIDs: ids, projectIDs: projects, actions: actions,
                     fingerprint: SHA256Hasher.hash(token: fingerprint.joined(separator: ":")))
    }

    private static func changed() -> Abort {
        Abort(.conflict, reason: "Your available projects or permissions changed. Start a new inventory and keep unsent work private", identifier: "discovery_restart_required")
    }

    static func create(actorID: UUID, on db: Database) async throws -> ProjectDiscoveryPage {
        try await VerifiedIdentityService.lock("project-discovery:" + actorID.uuidString, on: db)
        let scope = try await scope(actorID: actorID, on: db), sql = try VerifiedIdentityService.sql(db), now = Date()
        // Discard only private, invalid inventory caches. Repeated access changes
        // must not use all five slots and prevent a newly authorised bootstrap.
        try await sql.raw("DELETE FROM project_discovery_snapshots WHERE actor_id = \(bind: actorID) AND (expires_at <= \(bind: now) OR access_fingerprint <> \(bind: scope.fingerprint))").run()
        let active = try await sql.raw("SELECT count(*) AS n FROM project_discovery_snapshots WHERE actor_id = \(bind: actorID)").first()!.decode(column: "n", as: Int.self)
        guard active < 5 else { throw Abort(.tooManyRequests, reason: "Reuse an open project inventory or wait for it to expire", identifier: "discovery_limit") }
        let token = try SecureTokenGenerator.generate(byteCount: 32), id = UUID(), expiry = now.addingTimeInterval(1800)
        try await sql.raw("INSERT INTO project_discovery_snapshots (id, token_hash, actor_id, access_fingerprint, workspace_ids, item_count, created_at, expires_at) VALUES (\(bind: id), \(bind: SHA256Hasher.hash(token: token)), \(bind: actorID), \(bind: scope.fingerprint), \(bind: scope.workspaceIDs), \(bind: scope.projectIDs.count), \(bind: now), \(bind: expiry))").run()
        let projects = scope.projectIDs.isEmpty ? [] : try await Project.query(on: db).filter(\.$id ~~ scope.projectIDs).all()
        let byID = try Dictionary(uniqueKeysWithValues: projects.map { (try $0.requireID(), $0) })
        for (position, projectID) in scope.projectIDs.enumerated() {
            guard let project = byID[projectID], let actions = scope.actions[projectID] else { throw changed() }
            let state = project.archivedAt != nil ? "archived" : project.platformManaged ? "register_available" : "import_required"
            let item = try ProjectDiscoveryPage.Item(project: PlatformProjectResponse(project, actions: actions),
                bootstrapState: state, coverage: state == "register_available" ? RegisterSyncService.coverage : [])
            try await sql.raw("INSERT INTO project_discovery_items (snapshot_id, position, project_id, payload_json) VALUES (\(bind: id), \(bind: position), \(bind: projectID), \(bind: PlatformMutationService.encode(item)))").run()
        }
        return try await page(token: token, offset: 0, actorID: actorID, on: db)
    }

    static func page(token: String, offset: Int, actorID: UUID, on db: Database) async throws -> ProjectDiscoveryPage {
        guard !token.isEmpty, token.count <= 100, offset >= 0, offset % 50 == 0 else { throw Abort(.badRequest, reason: "Invalid inventory page") }
        let sql = try VerifiedIdentityService.sql(db)
        guard let saved = try await sql.raw("SELECT * FROM project_discovery_snapshots WHERE token_hash = \(bind: SHA256Hasher.hash(token: token)) AND actor_id = \(bind: actorID)").first() else { throw Abort(.notFound, reason: "Project inventory unavailable") }
        let expiry = try saved.decode(column: "expires_at", as: Date.self)
        guard expiry > Date() else { throw Abort(.gone, reason: "Start a new project inventory and keep unsent work", identifier: "discovery_restart_required") }
        let current = try await scope(actorID: actorID, previous: saved.decode(column: "workspace_ids", as: [UUID].self), on: db)
        guard current.fingerprint == (try saved.decode(column: "access_fingerprint", as: String.self)) else { throw changed() }
        let total = try saved.decode(column: "item_count", as: Int.self)
        guard offset < total || (offset == 0 && total == 0) else { throw Abort(.badRequest, reason: "Invalid inventory page") }
        let snapshotID = try saved.decode(column: "id", as: UUID.self)
        let rows = try await sql.raw("SELECT payload_json FROM project_discovery_items WHERE snapshot_id = \(bind: snapshotID) AND position >= \(bind: offset) ORDER BY position LIMIT 50").all()
        let items = try rows.map { try PlatformMutationService.decode(ProjectDiscoveryPage.Item.self, $0.decode(column: "payload_json", as: String.self)) }
        let next = offset + items.count < total ? offset + items.count : nil
        return try .init(snapshotToken: token, items: items, total: total, nextOffset: next, complete: next == nil,
                         capturedAt: saved.decode(column: "created_at", as: Date.self), expiresAt: expiry)
    }
}
