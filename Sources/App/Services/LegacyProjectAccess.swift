import Vapor
import Fluent
import FluentSQL

/// Compatibility boundary during canonical rollout. V1 owner/snapshot DTOs cannot
/// represent company grants or revision-aware writes. They remain available for
/// personal work; company work uses V2. Never expose a removed creator's company
/// records merely because an old owner_id/created_by_id still matches.
enum LegacyProjectAccess {
    enum Resource: String { case projects, snags, magicLinks = "magic_links", deletions = "snag_deletions" }
    static func personalRecords(_ resource: Resource) -> DatabaseQuery.Filter {
        let field = resource == .projects ? "projects.id" : resource.rawValue + ".project_id"
        // Table/column names are a closed server enum, never client input.
        return .sql(unsafeRaw: "NOT EXISTS (SELECT 1 FROM projects lp JOIN teams lw ON lw.id = lp.workspace_id WHERE lp.id = " + field + " AND (lw.kind = 'company' OR lw.lifecycle_state <> 'active' OR lp.archived_at IS NOT NULL OR lp.platform_managed))")
    }

    static func requireAvailable(projectID: UUID, ownerID: UUID, on db: Database) async throws {
        guard let project = try await Project.find(projectID, on: db) else { return } // Owned legacy snapshots remain supported.
        guard project.ownerId == ownerID, project.archivedAt == nil else { throw Abort(.notFound, reason: "Project unavailable") }
        guard !project.platformManaged else { throw Abort(.conflict, reason: "This project needs the current Snaglist app or manager workspace", identifier: "current_client_required") }
        if let workspaceID = project.workspaceId {
            guard let workspace = try await Team.find(workspaceID, on: db), workspace.lifecycleState == "active" else { throw Abort(.notFound, reason: "Project unavailable") }
            guard workspace.kind == "personal", workspace.ownerUserId == ownerID else {
                throw Abort(.conflict, reason: "This company project needs the current Snaglist app or manager workspace", identifier: "current_client_required")
            }
        }
    }
}
