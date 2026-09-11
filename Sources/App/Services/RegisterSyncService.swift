import Vapor
import Fluent
import FluentSQL

struct RegisterSnapshotPage: Content {
    struct Item: Content { let type: String; let id: UUID; let data: PlatformJSON }
    let snapshotToken: String
    let coverage: [String]
    let items: [Item]
    let total: Int
    let nextOffset: Int?
    let changesCursor: String?
    let expiresAt: Date
}
struct ProjectChangePage: Content {
    struct Change: Content {
        let type: String; let id: UUID; let revision: Int64; let kind: String
        let changedFields: [String]; let data: PlatformJSON; let transactionGroup: UUID
    }
    let changes: [Change]
    let cursor: String
    let hasMore: Bool
    /// Bootstrap coverage carried by this cursor, not the current server's wider
    /// capability. Empty means an older cursor with unknown coverage.
    var coverage: [String]? = nil
}

/// Stable register download, with its workspace directory. It is not the complete
/// native graph bootstrap: drawing/annotation and project organisation graphs follow.
struct RegisterSyncService {
    static let coverage = ["project", "snags", "contractors", "trades", "attachedMedia", "completionAttempts", "reviewDecisions", "comments", "assignmentHistory", "projectMetadataV2"]
    static func fingerprint(_ project: Project, actorID: UUID, on db: Database) async throws -> String {
        let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT t.owner_user_id, t.kind, COALESCE(m.revision, 0) AS membership_revision,
                COALESCE(m.role, '') AS membership_role, COALESCE(g.role, '') AS project_role, COALESCE(g.revision, 0) AS grant_revision, COALESCE(g.state, '') AS grant_state
            FROM teams t LEFT JOIN workspace_memberships m ON m.workspace_id = t.id AND m.user_id = \(bind: actorID)
            LEFT JOIN project_access g ON g.project_id = \(bind: project.requireID()) AND g.user_id = \(bind: actorID)
            WHERE t.id = \(bind: project.workspaceId!)
            """).first()!
        let parts = try [project.workspaceId!.uuidString, row.decode(column: "owner_user_id", as: UUID.self).uuidString,
                         row.decode(column: "kind", as: String.self), String(row.decode(column: "membership_revision", as: Int64.self)),
                         row.decode(column: "membership_role", as: String.self), row.decode(column: "project_role", as: String.self),
                         String(row.decode(column: "grant_revision", as: Int64.self)), row.decode(column: "grant_state", as: String.self)]
        return SHA256Hasher.hash(token: parts.joined(separator: ":"))
    }
    static func create(projectID: UUID, actorID: UUID, on db: Database) async throws -> RegisterSnapshotPage {
        let (project, actions) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
        try PlatformMutationService.requireManaged(project)
        let workspaceID = project.workspaceId!, sql = try VerifiedIdentityService.sql(db), now = Date()
        let count = try await Snag.query(on: db).filter(\.$projectId == projectID).count()
        let contractorCount = try await Contractor.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).count()
        let tradeCount = try await Trade.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).count()
        let mediaCount = try await sql.raw("SELECT count(*) AS n FROM media_assets WHERE project_id = \(bind: projectID) AND attached_at IS NOT NULL AND state = 'ready'").first()!.decode(column: "n", as: Int.self)
        let attemptCount = try await sql.raw("SELECT count(*) AS n FROM completion_attempts WHERE project_id = \(bind: projectID)").first()!.decode(column: "n", as: Int.self)
        let decisionCount = try await sql.raw("SELECT count(*) AS n FROM review_decisions WHERE project_id = \(bind: projectID)").first()!.decode(column: "n", as: Int.self)
        let commentCount = try await sql.raw("SELECT count(*) AS n FROM project_comments WHERE project_id = \(bind: projectID)").first()!.decode(column: "n", as: Int.self)
        let assignmentCount = try await sql.raw("SELECT count(*) AS n FROM assignment_history WHERE project_id = \(bind: projectID)").first()!.decode(column: "n", as: Int.self)
        let total = count + contractorCount + tradeCount + mediaCount + attemptCount + decisionCount + commentCount + assignmentCount + 1
        guard total <= 10000 else { throw Abort(.payloadTooLarge, reason: "This project needs a background snapshot. No partial download was created", identifier: "snapshot_job_required") }
        // Expired private snapshots can be removed without deleting customer work.
        try await sql.raw("DELETE FROM register_snapshots WHERE actor_id = \(bind: actorID) AND expires_at < \(bind: now)").run()
        let active = try await sql.raw("SELECT count(*) AS n FROM register_snapshots WHERE actor_id = \(bind: actorID) AND project_id = \(bind: projectID)").first()!.decode(column: "n", as: Int.self)
        guard active < 5 else { throw Abort(.tooManyRequests, reason: "Several project downloads are already open. Reuse the existing download or retry after it expires", identifier: "snapshot_limit") }
        let token = try SecureTokenGenerator.generate(byteCount: 32), id = UUID(), expiry = now.addingTimeInterval(1800)
        let access = try await fingerprint(project, actorID: actorID, on: db)
        let sequence = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: workspaceID)").first()!.decode(column: "change_sequence", as: Int64.self)
        try await sql.raw("INSERT INTO register_snapshots (id, token_hash, actor_id, workspace_id, project_id, access_fingerprint, high_watermark, item_count, created_at, expires_at) VALUES (\(bind: id), \(bind: SHA256Hasher.hash(token: token)), \(bind: actorID), \(bind: workspaceID), \(bind: projectID), \(bind: access), \(bind: sequence), \(bind: total), \(bind: now), \(bind: expiry))").run()
        try await sql.raw("UPDATE register_snapshots SET coverage = \(bind: coverage) WHERE id = \(bind: id)").run()
        try await item(snapshotID: id, position: 0, type: "project", id: projectID, value: PlatformProjectResponse(project, actions: actions), on: db)
        // Workspace writes are blocked only for this bounded transaction. HTTP page
        // requests read immutable rows, without holding a transaction open between requests.
        let snags = try await Snag.query(on: db).filter(\.$projectId == projectID).sort(\.$displayNumber).sort(\.$id).all()
        for (position, snag) in snags.enumerated() {
            try await item(snapshotID: id, position: position + 1, type: "snag", id: snag.requireID(), value: PlatformSnagResponse(snag), on: db)
        }
        var position = count + 1
        let contractors = try await Contractor.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).sort(\.$id).all()
        for contractor in contractors {
            try await item(snapshotID: id, position: position, type: "contractor", id: contractor.requireID(), value: WorkspaceDirectoryService.response(contractor), on: db)
            position += 1
        }
        let trades = try await Trade.query(on: db).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).sort(\.$id).all()
        for trade in trades {
            try await item(snapshotID: id, position: position, type: "trade", id: trade.requireID(), value: WorkspaceDirectoryService.response(trade), on: db)
            position += 1
        }
        let media = try await sql.raw("SELECT * FROM media_assets WHERE project_id = \(bind: projectID) AND attached_at IS NOT NULL AND state = 'ready' ORDER BY snag_id, created_at, id").all()
        for row in media {
            let asset = try MediaAssetResponse(row)
            try await item(snapshotID: id, position: position, type: "media", id: asset.id, value: asset, on: db)
            position += 1
        }
        let attemptRows = try await sql.raw("SELECT * FROM completion_attempts WHERE project_id = \(bind: projectID) ORDER BY snag_id, attempt_number").all()
        for attempt in try await CanonicalWorkflowService.attempts(attemptRows, on: db) {
            try await item(snapshotID: id, position: position, type: "completionAttempt", id: attempt.id, value: attempt, on: db)
            position += 1
        }
        let decisions = try await sql.raw("SELECT * FROM review_decisions WHERE project_id = \(bind: projectID) ORDER BY snag_id, expected_workflow_revision, CASE kind WHEN 'waiver' THEN 0 ELSE 1 END, id").all()
        for row in decisions {
            let decision = try ReviewDecisionResponse(row)
            try await item(snapshotID: id, position: position, type: "reviewDecision", id: decision.id, value: decision, on: db)
            position += 1
        }
        let comments = try await sql.raw("SELECT * FROM project_comments WHERE project_id = \(bind: projectID) ORDER BY created_at, id").all()
        for row in comments {
            let comment = try ProjectCommentResponse(row)
            try await item(snapshotID: id, position: position, type: "comment", id: comment.id, value: comment, on: db)
            position += 1
        }
        let assignments = try await sql.raw("SELECT * FROM assignment_history WHERE project_id = \(bind: projectID) ORDER BY snag_id, snag_revision, id").all()
        for row in assignments {
            let assignment = try AssignmentHistoryResponse(row)
            try await item(snapshotID: id, position: position, type: "assignmentHistory", id: assignment.id, value: assignment, on: db)
            position += 1
        }
        return try await page(token: token, offset: 0, projectID: projectID, actorID: actorID, on: db)
    }
    private static func item<T: Encodable>(snapshotID: UUID, position: Int, type: String, id: UUID, value: T, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO register_snapshot_items (snapshot_id, position, entity_type, entity_id, payload_json) VALUES (\(bind: snapshotID), \(bind: position), \(bind: type), \(bind: id), \(bind: PlatformMutationService.encode(value)))").run()
    }
    static func page(token: String, offset: Int, projectID: UUID, actorID: UUID, on db: Database) async throws -> RegisterSnapshotPage {
        guard token.count <= 100, offset >= 0, offset % 100 == 0 else { throw Abort(.badRequest, reason: "Invalid snapshot page") }
        let sql = try VerifiedIdentityService.sql(db)
        guard let snapshot = try await sql.raw("SELECT * FROM register_snapshots WHERE token_hash = \(bind: SHA256Hasher.hash(token: token)) AND actor_id = \(bind: actorID) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "Download unavailable") }
        let (project, _) = try await authorised(projectID: projectID, actorID: actorID, on: db)
        let workspaceID = try snapshot.decode(column: "workspace_id", as: UUID.self), expiry = try snapshot.decode(column: "expires_at", as: Date.self)
        guard expiry > Date() else { throw Abort(.gone, reason: "This download expired. Start a new download and keep any unsent edits", identifier: "rebootstrap_required") }
        let access = try await fingerprint(project, actorID: actorID, on: db)
        guard project.workspaceId == workspaceID, access == (try snapshot.decode(column: "access_fingerprint", as: String.self)) else { throw Abort(.conflict, reason: "Your project access changed. Refresh the project; keep unsent edits", identifier: "rebootstrap_required") }
        try await ProjectCommentService.requireCurrentContent(projectID: projectID, since: snapshot.decode(column: "high_watermark", as: Int64.self), on: db)
        let total = try snapshot.decode(column: "item_count", as: Int.self)
        guard offset < total else { throw Abort(.badRequest, reason: "Invalid snapshot page") }
        let id = try snapshot.decode(column: "id", as: UUID.self)
        let rows = try await sql.raw("SELECT entity_type, entity_id, payload_json FROM register_snapshot_items WHERE snapshot_id = \(bind: id) AND position >= \(bind: offset) ORDER BY position LIMIT 100").all()
        let items = try rows.map { row in
            try RegisterSnapshotPage.Item(type: row.decode(column: "entity_type", as: String.self), id: row.decode(column: "entity_id", as: UUID.self), data: PlatformMutationService.decode(PlatformJSON.self, row.decode(column: "payload_json", as: String.self)))
        }
        let next = offset + items.count < total ? offset + items.count : nil
        let cursor = next == nil ? try await issueCursor(project: project, actorID: actorID, sequence: snapshot.decode(column: "high_watermark", as: Int64.self), fingerprint: access, coverage: snapshot.decode(column: "coverage", as: [String].self), on: db) : nil
        return try .init(snapshotToken: token, coverage: snapshot.decode(column: "coverage", as: [String].self), items: items, total: total, nextOffset: next, changesCursor: cursor, expiresAt: expiry)
    }
    static func changes(cursor: String, projectID: UUID, actorID: UUID, on db: Database) async throws -> ProjectChangePage {
        guard cursor.count <= 100 else { throw Abort(.badRequest) }
        let sql = try VerifiedIdentityService.sql(db)
        guard let saved = try await sql.raw("SELECT * FROM project_change_cursors WHERE token_hash = \(bind: SHA256Hasher.hash(token: cursor)) AND actor_id = \(bind: actorID) AND project_id = \(bind: projectID)").first() else { throw Abort(.gone, reason: "Start a new project download and retain any unsent edits", identifier: "rebootstrap_required") }
        let (project, actions) = try await authorised(projectID: projectID, actorID: actorID, on: db)
        guard try saved.decode(column: "expires_at", as: Date.self) > Date() else { throw Abort(.gone, reason: "The sync cursor expired. Download the project again and keep unsent edits", identifier: "rebootstrap_required") }
        let workspaceID = try saved.decode(column: "workspace_id", as: UUID.self), access = try await fingerprint(project, actorID: actorID, on: db)
        guard project.workspaceId == workspaceID, access == (try saved.decode(column: "access_fingerprint", as: String.self)) else { throw Abort(.conflict, reason: "Your project access changed. Download the project again", identifier: "rebootstrap_required") }
        let sequence = try saved.decode(column: "sequence", as: Int64.self)
        let cursorCoverage = try saved.decode(column: "coverage", as: [String].self)
        try await ProjectCommentService.requireCurrentContent(projectID: projectID, since: sequence, on: db)
        let rows = try await sql.raw("SELECT * FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND (project_id = \(bind: projectID) OR (project_id IS NULL AND entity_type IN ('contractor', 'trade'))) AND sequence > \(bind: sequence) ORDER BY sequence LIMIT 101").all()
        // A page targets 100 rows, then includes the remainder of its final
        // transaction. A client applies each complete group in one local commit.
        // Do not advance a cursor through half a review/evidence transition.
        var selected = Array(rows.prefix(100))
        if let last = selected.last {
            let lastSequence = try last.decode(column: "sequence", as: Int64.self)
            let groupID = try last.decode(column: "transaction_group", as: UUID.self)
            let tail = try await sql.raw("SELECT * FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND transaction_group = \(bind: groupID) AND (project_id = \(bind: projectID) OR (project_id IS NULL AND entity_type IN ('contractor', 'trade'))) AND sequence > \(bind: lastSequence) ORDER BY sequence LIMIT 1001").all()
            guard tail.count <= 1000 else { throw Abort(.payloadTooLarge, reason: "This historical change batch requires a new project download. Keep unsent edits", identifier: "rebootstrap_required") }
            selected.append(contentsOf: tail)
        }
        let changes = try selected.map { row in
            let type = try row.decode(column: "entity_type", as: String.self)
            var payload = try PlatformMutationService.decode(PlatformJSON.self, row.decode(column: "payload_json", as: String.self))
            // Shared project events were written by a different actor. Never
            // project their permissions into this reader's response.
            if type == "project", case .object(var object) = payload {
                object["capabilities"] = .array(actions.map(\.rawValue).sorted().map(PlatformJSON.string))
                payload = .object(object)
            }
            return try ProjectChangePage.Change(type: type, id: row.decode(column: "entity_id", as: UUID.self), revision: row.decode(column: "revision", as: Int64.self), kind: row.decode(column: "kind", as: String.self), changedFields: row.decode(column: "changed_fields", as: [String].self), data: payload, transactionGroup: row.decode(column: "transaction_group", as: UUID.self))
        }
        let last = try selected.last.map { try $0.decode(column: "sequence", as: Int64.self) }
        let next: String, hasMore: Bool
        if let last {
            next = try await issueCursor(project: project, actorID: actorID, sequence: last, fingerprint: access, coverage: cursorCoverage, on: db)
            hasMore = try await sql.raw("SELECT sequence FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND (project_id = \(bind: projectID) OR (project_id IS NULL AND entity_type IN ('contractor', 'trade'))) AND sequence > \(bind: last) LIMIT 1").first() != nil
        } else { next = cursor; hasMore = false }
        return .init(changes: changes, cursor: next, hasMore: hasMore, coverage: cursorCoverage)
    }

    private static func authorised(projectID: UUID, actorID: UUID, on db: Database) async throws -> (Project, Set<ProjectAccessPolicy.Action>) {
        do {
            let result = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(result.0)
            return result
        } catch let error as Abort where error.status == .notFound || error.status == .forbidden {
            // Only reached after a cursor/snapshot has proved this actor previously
            // held this scope. Return no project data with a revocation indication.
            throw Abort(.forbidden, reason: "You no longer have access to this project. Keep unsent work private for recovery", identifier: "project_access_revoked")
        }
    }
    private static func issueCursor(project: Project, actorID: UUID, sequence: Int64, fingerprint: String, coverage: [String], on db: Database) async throws -> String {
        let token = try SecureTokenGenerator.generate(byteCount: 32)
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO project_change_cursors (token_hash, actor_id, workspace_id, project_id, sequence, expires_at, access_fingerprint, coverage) VALUES (\(bind: SHA256Hasher.hash(token: token)), \(bind: actorID), \(bind: project.workspaceId!), \(bind: project.requireID()), \(bind: sequence), \(bind: Date().addingTimeInterval(7 * 86400)), \(bind: fingerprint), \(bind: coverage))").run()
        return token
    }
}
