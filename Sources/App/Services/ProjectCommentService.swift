import Vapor
import Fluent
import FluentSQL

/// Internal discussion only. Contractor notes and immutable completion/review
/// records keep their existing, separately authorised paths.
struct ProjectCommentService {
    static func find(_ id: UUID, snagID: UUID, projectID: UUID, on db: Database) async throws -> ProjectCommentResponse {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM project_comments WHERE id = \(bind: id) AND snag_id = \(bind: snagID) AND project_id = \(bind: projectID)").first() else {
            throw Abort(.notFound, reason: "Comment unavailable")
        }
        return try .init(row)
    }

    static func create(_ command: ProjectCommentCreateCommand, project: Project, snag: Snag, actorID: UUID, on db: Database) async throws -> ProjectCommentResponse {
        try PlatformMutationService.requireManaged(project)
        guard snag.archivedAt == nil else { throw Abort(.gone, reason: "Restore this snag before adding a comment") }
        let body = command.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.unicodeScalars.count <= 10000 else { throw Abort(.badRequest, reason: "Enter a comment of up to 10,000 characters") }
        let sql = try VerifiedIdentityService.sql(db), projectID = try project.requireID(), snagID = try snag.requireID()
        try await VerifiedIdentityService.lock("entity:comment:" + command.id.uuidString, on: db)
        guard try await sql.raw("SELECT id FROM project_comments WHERE id = \(bind: command.id)").first() == nil else {
            throw Abort(.conflict, reason: "This comment ID already exists. Keep the original operation when retrying", identifier: "comment_exists")
        }
        if let parentID = command.parentCommentId {
            let parent = try await find(parentID, snagID: snagID, projectID: projectID, on: db)
            guard parent.parentCommentId == nil, parent.redactedAt == nil else {
                throw Abort(.badRequest, reason: "Reply to an existing top-level comment that has not been removed")
            }
        }
        let user = try await VerifiedIdentityService.activeUser(actorID, on: db)
        let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorName = name.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? "Team member"
        try await sql.raw("""
            INSERT INTO project_comments (id, workspace_id, project_id, snag_id, parent_comment_id, author_user_id, author_name, body, created_at)
            VALUES (\(bind: command.id), \(bind: project.workspaceId!), \(bind: projectID), \(bind: snagID), \(bind: command.parentCommentId), \(bind: actorID), \(bind: authorName), \(bind: body), \(bind: Date()))
            """).run()
        let response = try await find(command.id, snagID: snagID, projectID: projectID, on: db)
        try await PlatformMutationService.change(workspaceID: project.workspaceId!, projectID: projectID, type: "comment", entityID: command.id,
            revision: response.revision, kind: "created", fields: ["body", "parentCommentId"], payload: response, actorID: actorID, on: db)
        return response
    }

    static func redact(_ command: ProjectCommentRedactCommand, comment: ProjectCommentResponse, project: Project,
                       actions: Set<ProjectAccessPolicy.Action>, actorID: UUID, on db: Database) async throws -> ProjectCommentResponse {
        try PlatformMutationService.requireManaged(project)
        guard comment.authorUserId == actorID || actions.contains(.archive) else {
            throw Abort(.forbidden, reason: "Only the author or a project manager can remove this comment")
        }
        guard command.expectedRevision > 0 else { throw Abort(.badRequest, reason: "A positive comment revision is required") }
        guard command.expectedRevision == comment.revision else {
            throw Abort(.conflict, reason: "This comment changed. Refresh before removing it", identifier: "comment_revision_conflict")
        }
        guard comment.redactedAt == nil else { throw Abort(.conflict, reason: "This comment is already removed") }
        let reason = command.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.unicodeScalars.count <= 500 else { throw Abort(.badRequest, reason: "Give a reason of up to 500 characters") }
        try await VerifiedIdentityService.sql(db).raw("UPDATE project_comments SET redacted_at = \(bind: Date()), redacted_by_user_id = \(bind: actorID), redaction_reason = \(bind: reason), revision = revision + 1 WHERE id = \(bind: comment.id)").run()
        let response = try await find(comment.id, snagID: comment.snagId, projectID: comment.projectId, on: db)
        try await PlatformMutationService.change(workspaceID: project.workspaceId!, projectID: comment.projectId, type: "comment", entityID: comment.id,
            revision: response.revision, kind: "redacted", fields: ["body", "redactedAt"], payload: response, actorID: actorID, on: db)
        try await WorkspaceAccessService.activity(workspaceID: project.workspaceId!, actorID: actorID, action: "comment_redacted", targetID: comment.id, detail: reason, on: db)
        return response
    }

    /// Old immutable payloads must not deliver a removed comment again. A redaction
    /// invalidates older graph downloads/cursors explicitly, preserving unsent edits.
    /// New snapshots include the tombstone and a high-watermark beyond this event.
    static func requireCurrentContent(projectID: UUID, since sequence: Int64, on db: Database) async throws {
        if try await VerifiedIdentityService.sql(db).raw("SELECT entity_id FROM platform_changes WHERE project_id = \(bind: projectID) AND entity_type = 'comment' AND kind = 'redacted' AND sequence > \(bind: sequence) LIMIT 1").first() != nil {
            throw Abort(.conflict, reason: "A comment was removed. Download this project again and keep unsent edits", identifier: "rebootstrap_required")
        }
    }
}
