import Vapor
import Fluent
import FluentSQL

struct ProjectGrantCommand: Content {
    let mutation: MutationMetadata
    let userId: UUID
    let role: String?
    let expectedRevision: Int64
    enum CodingKeys: String, CodingKey { case mutation, userId, role, expectedRevision }
    init(mutation: MutationMetadata, userId: UUID, role: String?, expectedRevision: Int64) {
        self.mutation = mutation; self.userId = userId; self.role = role; self.expectedRevision = expectedRevision
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.role) else { throw DecodingError.keyNotFound(CodingKeys.role, .init(codingPath: decoder.codingPath, debugDescription: "Send an explicit role or null to remove project access")) }
        mutation = try container.decode(MutationMetadata.self, forKey: .mutation)
        userId = try container.decode(UUID.self, forKey: .userId)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        expectedRevision = try container.decode(Int64.self, forKey: .expectedRevision)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutation, forKey: .mutation)
        try container.encode(userId, forKey: .userId)
        try container.encode(role, forKey: .role) // Explicit null is the removal command.
        try container.encode(expectedRevision, forKey: .expectedRevision)
    }
}
struct ProjectGrantResponse: Content {
    let projectId: UUID
    let userId: UUID
    let role: String?
    let state: String
    let revision: Int64
}
struct ProjectGrantConflict: Error {
    struct Body: Content {
        let error = true
        let identifier = "project_grant_conflict"
        let reason = "This person's project access changed. Refresh and review it before trying again."
        let current: ProjectGrantResponse
    }
    let body: Body
}

enum ProjectGrantService {
    static func current(projectID: UUID, targetID: UUID, on db: Database) async throws -> ProjectGrantResponse {
        let row = try await VerifiedIdentityService.sql(db).raw("SELECT role, state, revision FROM project_access WHERE project_id = \(bind: projectID) AND user_id = \(bind: targetID)").first()
        let state = try row?.decode(column: "state", as: String.self) ?? "absent"
        return try ProjectGrantResponse(projectId: projectID, userId: targetID,
            role: state == "active" ? row?.decode(column: "role", as: String.self) : nil,
            state: state, revision: row?.decode(column: "revision", as: Int64.self) ?? 0)
    }
    /// Caller holds the workspace transaction lock. Removal retains a versioned
    /// tombstone so a stale 'add' command cannot recreate access after removal.
    static func set(_ command: ProjectGrantCommand, project: Project, actorID: UUID,
                    actions: Set<ProjectAccessPolicy.Action>, on db: Database) async throws -> ProjectGrantResponse {
        guard command.expectedRevision >= 0 else { throw Abort(.badRequest, reason: "A valid access revision is required") }
        let projectID = try project.requireID(), workspaceID = project.workspaceId!
        let current = try await current(projectID: projectID, targetID: command.userId, on: db)
        guard actions.contains(.addProjectMember), actions.contains(.manageProjectGrants) || (command.role == "member" && (current.role == nil || current.role == "member")) else {
            throw Abort(.forbidden, reason: "Only a company owner or admin can change or remove privileged project access")
        }
        guard current.revision == command.expectedRevision else { throw ProjectGrantConflict(body: .init(current: current)) }
        if let role = command.role {
            guard ["manager", "member"].contains(role) else { throw Abort(.badRequest, reason: "Choose Manager or Member") }
            guard try await VerifiedIdentityService.sql(db).raw("SELECT user_id FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: command.userId) AND state = 'active'").first() != nil else {
                throw Abort(.badRequest, reason: "Add this person to the company first")
            }
            try await VerifiedIdentityService.sql(db).raw("""
                INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: projectID), \(bind: workspaceID), \(bind: command.userId), \(bind: role))
                ON CONFLICT (project_id, user_id) DO UPDATE SET role = EXCLUDED.role, state = 'active', revision = project_access.revision + 1, updated_at = NOW()
                """).run()
        } else {
            guard current.state == "active" else { throw Abort(.conflict, reason: "This project access is already absent") }
            // Company owners/admins retain access through their workspace role;
            // never imply that deleting a project grant would remove that power.
            let member = try await VerifiedIdentityService.sql(db).raw("SELECT role FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: command.userId) AND state = 'active'").first()
            if let member, try member.decode(column: "role", as: String.self) != "member" {
                throw Abort(.conflict, reason: "This person has company-wide access. Change their company role first", identifier: "workspace_access_overrides_grant")
            }
            try await VerifiedIdentityService.sql(db).raw("UPDATE project_access SET state = 'removed', revision = revision + 1, updated_at = NOW() WHERE project_id = \(bind: projectID) AND user_id = \(bind: command.userId)").run()
        }
        let result = try await self.current(projectID: projectID, targetID: command.userId, on: db)
        try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID,
            action: command.role == nil ? "project_access_removed" : "project_access_granted", targetID: command.userId,
            detail: projectID.uuidString + ":" + result.state + ":" + String(result.revision) + ":" + (result.role ?? "none"), on: db)
        return result
    }
}
