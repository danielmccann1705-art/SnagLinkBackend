import Vapor
import Fluent
import FluentSQL

/// V2 transitions run under the project policy's workspace transaction lock.
/// Revision, evidence, attempt, decision, activity, change and outbox commit together.
/// Existing v1 adapters fail closed for platform-managed projects; no legacy route
/// may invoke this service by guessing the original owner's identity.
enum CanonicalWorkflowService {
    static func attempt(_ id: UUID, snagID: UUID, projectID: UUID, on db: Database) async throws -> CompletionAttemptResponse {
        let sql = try VerifiedIdentityService.sql(db)
        guard let row = try await sql.raw("SELECT * FROM completion_attempts WHERE id = \(bind: id) AND snag_id = \(bind: snagID) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "Completion unavailable") }
        let evidence = try await sql.raw("SELECT asset_id FROM completion_evidence WHERE attempt_id = \(bind: id) ORDER BY position").all().map { try $0.decode(column: "asset_id", as: UUID.self) }
        return try .init(row, evidence: evidence)
    }
    /// One evidence query for a bounded page/bootstrap, not one query per attempt.
    static func attempts(_ rows: [SQLRow], on db: Database) async throws -> [CompletionAttemptResponse] {
        guard !rows.isEmpty else { return [] }
        let ids = try rows.map { try $0.decode(column: "id", as: UUID.self) }
        let evidence = try await VerifiedIdentityService.sql(db).raw("SELECT attempt_id, asset_id FROM completion_evidence WHERE attempt_id = ANY(\(bind: ids)::UUID[]) ORDER BY attempt_id, position").all()
        var grouped: [UUID: [UUID]] = [:]
        for row in evidence { grouped[try row.decode(column: "attempt_id", as: UUID.self), default: []].append(try row.decode(column: "asset_id", as: UUID.self)) }
        return try rows.map { try CompletionAttemptResponse($0, evidence: grouped[$0.decode(column: "id", as: UUID.self)] ?? []) }
    }
    static func pending(snagID: UUID, projectID: UUID, on db: Database) async throws -> CompletionAttemptResponse? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT id FROM completion_attempts WHERE snag_id = \(bind: snagID) AND project_id = \(bind: projectID) AND state = 'pending'").first() else { return nil }
        return try await attempt(row.decode(column: "id", as: UUID.self), snagID: snagID, projectID: projectID, on: db)
    }
    static func validate(_ command: WorkflowCommand, action: WorkflowAction) throws {
        guard command.expectedRevision > 0, command.expectedWorkflowRevision > 0,
              (command.notes?.count ?? 0) <= 10000, (command.reason?.count ?? 0) <= 2000, (command.waiverReason?.count ?? 0) <= 2000 else { throw Abort(.badRequest, reason: "Check the base revisions and note length") }
        let submission = action == .submit || action == .internalFix
        let review = action == .accept || action == .sendBack
        guard (submission || review) == (command.attemptId != nil),
              review == (command.expectedAttemptRevision != nil),
              submission == (command.evidenceIds != nil),
              submission || (command.notes == nil && command.waiverReason == nil) else { throw Abort(.badRequest, reason: "Use the fields for this workflow action only") }
        if action == .start || action == .submit { guard command.reason == nil else { throw Abort(.badRequest, reason: "Use a completion note for this action") } }
        if let ids = command.evidenceIds { guard ids.count <= 20, Set(ids).count == ids.count else { throw Abort(.badRequest, reason: "Choose up to 20 distinct after photos") } }
        if [.sendBack, .reopen, .internalFix].contains(action) { _ = try reason(command.reason) }
        if command.waiverReason != nil { _ = try reason(command.waiverReason) }
    }
    static func reason(_ raw: String?) throws -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.count <= 2000 else { throw Abort(.badRequest, reason: "Give a clear reason, up to 2,000 characters") }
        return value
    }
    static func execute(_ command: WorkflowCommand, action: WorkflowAction, snag: Snag, project: Project, actorID: UUID?, grantID: UUID? = nil, actions: Set<ProjectAccessPolicy.Action>, on db: Database) async throws -> WorkflowResponse {
        try validate(command, action: action)
        guard (actorID == nil) != (grantID == nil),
              grantID == nil || ([WorkflowAction.start, .submit].contains(action) && command.waiverReason == nil) else { throw Abort(.forbidden, reason: "A Contractor link can submit evidence, but cannot accept or close a snag") }
        guard actions.contains([.accept, .sendBack, .reopen, .internalFix].contains(action) ? .review : .submitCompletion) else { throw Abort(.forbidden, reason: "Your project role does not allow this workflow action") }
        try PlatformMutationService.requireManaged(project); try PrivateMediaService.available(snag)
        let projectID = try project.requireID(), snagID = try snag.requireID(), workspaceID = project.workspaceId!
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: workspaceID, on: db)
        guard command.expectedWorkflowRevision == snag.workflowRevision else {
            throw WorkflowConflict(body: try await .init(current: PlatformSnagResponse(snag), attempt: pending(snagID: snagID, projectID: projectID, on: db)))
        }
        guard snag.publishedAt != nil else { throw Abort(.conflict, reason: "Log this draft before starting completion or review", identifier: "snag_not_published") }
        guard ["open", "in_progress", "awaiting_review", "changes_requested", "closed"].contains(snag.status) else { throw Abort(.conflict, reason: "Reconcile this historical status before changing its workflow", identifier: "workflow_reconciliation_required") }
        var affected: UUID?, decisions: [ReviewDecisionResponse] = []
        // Lane A WP2 (Fable §3.2): a submission collects its change rows and writes them in one pass after the snag is
        // saved, in the order the per-row path wrote them — media in evidence order, then any decision, then the snag,
        // then the completionAttempt — under the same exclusive workspace lock and in the same transaction. Every other
        // action writes its rows one at a time exactly as before.
        let batch: PlatformMutationService.Batch? = (action == .submit || action == .internalFix) ? .init() : nil
        var created: SQLRow?
        // An imported legacy state has no canonical attempt or decision behind it. The only
        // permitted transition is an explicit reviewer reopen, which records the reconciliation
        // and returns the snag to ordinary canonical `open`. Accept/send-back/start/submit are refused.
        if snag.workflowQualification != nil {
            guard action == .reopen, actorID != nil, actions.contains(.review) else {
                throw Abort(.conflict, reason: "This snag carries an unverified legacy status. A reviewer must reopen it before any other workflow action", identifier: "workflow_reconciliation_required")
            }
            decisions.append(try await decision("reopen", attemptID: nil, command: command, reason: reason(command.reason), snag: snag, project: project, actorID: actorID!, on: db))
            snag.status = "open"; snag.closedAt = nil; snag.workflowQualification = nil
            snag.revision += 1; snag.workflowRevision += 1
            try await snag.save(on: db)
            let updated = try await PlatformSnagService.changed(snag, project: project, actorID: actorID, grantID: nil, kind: "workflow_reconciled", fields: ["status", "workflowRevision", "workflow"], on: db)
            try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID, action: "workflow_reconciled", targetID: snagID, detail: command.reason, on: db)
            return .init(snag: updated, attempt: nil, decisions: decisions)
        }
        switch action {
        case .start:
            guard ["open", "changes_requested"].contains(snag.status) else { throw Abort(.conflict, reason: "This snag is already in progress, awaiting review or closed") }
            snag.status = "in_progress"
        case .submit, .internalFix:
            try PrivateMediaService.submittable(snag)
            let id = command.attemptId!
            created = try await createAttempt(id, command: command, internalFix: action == .internalFix, snag: snag, project: project, actorID: actorID, grantID: grantID, actions: actions, batch: batch!, on: db)
            affected = id
            if command.waiverReason != nil {
                decisions.append(try await decision("waiver", attemptID: id, command: command, reason: reason(command.waiverReason), snag: snag, project: project, actorID: actorID!, batch: batch, on: db))
            }
            if action == .internalFix {
                decisions.append(try await decision("internal_fix", attemptID: id, command: command, reason: reason(command.reason), snag: snag, project: project, actorID: actorID!, batch: batch, on: db))
                snag.status = "closed"; snag.closedAt = Date()
            } else { snag.status = "awaiting_review"; snag.closedAt = nil }
        case .accept, .sendBack:
            let current = try await attempt(command.attemptId!, snagID: snagID, projectID: projectID, on: db)
            guard snag.status == "awaiting_review", current.state == "pending", current.revision == command.expectedAttemptRevision else {
                throw WorkflowConflict(body: .init(current: PlatformSnagResponse(snag), attempt: current))
            }
            affected = current.id
            try await VerifiedIdentityService.sql(db).raw("UPDATE completion_attempts SET state = \(bind: action == .accept ? "accepted" : "sent_back"), revision = revision + 1 WHERE id = \(bind: current.id)").run()
            decisions.append(try await decision(action == .accept ? "accept" : "send_back", attemptID: current.id, command: command, reason: action == .sendBack ? reason(command.reason) : command.reason, snag: snag, project: project, actorID: actorID!, on: db))
            snag.status = action == .accept ? "closed" : "changes_requested"
            snag.closedAt = action == .accept ? Date() : nil
        case .reopen:
            guard snag.status == "closed" else { throw Abort(.conflict, reason: "Only a closed snag can be reopened") }
            decisions.append(try await decision("reopen", attemptID: nil, command: command, reason: reason(command.reason), snag: snag, project: project, actorID: actorID!, on: db))
            snag.status = "open"; snag.closedAt = nil
        }
        snag.revision += 1; snag.workflowRevision += 1
        try await snag.save(on: db)
        let updated: PlatformSnagResponse
        if let batch {
            // What `PlatformSnagService.changed` writes, built from the saved snag and written with the batch.
            updated = PlatformSnagResponse(snag)
            batch.append(try .init(projectID: projectID, type: "snag", entityID: snagID, revision: snag.revision, kind: "workflow_\(action.rawValue)", fields: ["status", "workflowRevision", "closedAt"], payload: updated, actorID: actorID, grantID: grantID))
        } else {
            updated = try await PlatformSnagService.changed(snag, project: project, actorID: actorID, grantID: grantID, kind: "workflow_\(action.rawValue)", fields: ["status", "workflowRevision", "closedAt"], on: db)
        }
        let completion: CompletionAttemptResponse?
        // A new attempt is built from the row its INSERT returned (nothing in this transaction changes it afterwards)
        // and the evidence list in position order — what `attempt` would read back (Fable §3.2 rule 5).
        if let created { completion = try CompletionAttemptResponse(created, evidence: command.evidenceIds!) }
        else if let affected { completion = try await attempt(affected, snagID: snagID, projectID: projectID, on: db) }
        else { completion = nil }
        if let completion {
            if let batch {
                batch.append(try .init(projectID: projectID, type: "completionAttempt", entityID: completion.id, revision: completion.revision, kind: action.rawValue, fields: ["state", "evidenceIds"], payload: completion, actorID: actorID, grantID: grantID))
            } else {
                try await PlatformMutationService.change(workspaceID: workspaceID, projectID: projectID, type: "completionAttempt", entityID: completion.id, revision: completion.revision, kind: action.rawValue, fields: ["state", "evidenceIds"], payload: completion, actorID: actorID, grantID: grantID, on: db)
            }
        }
        if let batch { try await PlatformMutationService.changes(batch.items, workspaceID: workspaceID, on: db) }
        try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID, grantID: grantID, action: "workflow_\(action.rawValue)", targetID: snagID, detail: command.reason, on: db)
        let payload: [String: String] = ["snagId": snagID.uuidString, "projectId": projectID.uuidString, "event": action.rawValue]
        // Delivery is a separate leased worker. A queued event is never shown as
        // a sent email; the worker must resolve current authorised recipients.
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO workflow_outbox (id, workspace_id, project_id, snag_id, actor_id, actor_grant_id, event_kind, payload_json, dedupe_key, available_at, created_at)
            VALUES (\(bind: UUID()), \(bind: workspaceID), \(bind: projectID), \(bind: snagID), \(bind: actorID), \(bind: grantID), \(bind: action.rawValue), \(bind: PlatformMutationService.encode(payload)), \(bind: "\(grantID == nil ? "user" : "grant"):\((actorID ?? grantID)!):\(command.mutation.operationId)"), \(bind: Date()), \(bind: Date()))
            """).run()
        return .init(snag: updated, attempt: completion, decisions: decisions)
    }
    /// Lane A WP2 (Fable §3.2): the same checks in the same order with the same refusals, in fewer statements — one read
    /// of every evidence row, one multi-row INSERT of the evidence, one UPDATE of the media rows returning their new
    /// state; the attempt row is returned by its INSERT. The media change rows go into `batch`, in evidence order.
    /// Every media row attached by one submission gets the same `attached_at` (before WP2 each got its own `Date()`,
    /// microseconds apart).
    private static func createAttempt(_ id: UUID, command: WorkflowCommand, internalFix: Bool, snag: Snag, project: Project, actorID: UUID?, grantID: UUID? = nil, actions: Set<ProjectAccessPolicy.Action>, batch: PlatformMutationService.Batch, on db: Database) async throws -> SQLRow {
        let sql = try VerifiedIdentityService.sql(db), projectID = try project.requireID(), snagID = try snag.requireID()
        let evidenceIDs = command.evidenceIds!
        if evidenceIDs.isEmpty {
            guard actions.contains(.review), command.waiverReason != nil else { throw Abort(.unprocessableEntity, reason: "Add at least one processed after photo. Only a reviewer can record a reasoned evidence waiver", identifier: "completion_evidence_required") }
        } else if command.waiverReason != nil { throw Abort(.badRequest, reason: "An evidence waiver is only needed when no after photo can be provided") }
        try await VerifiedIdentityService.lock("entity:attempt:\(id)", on: db)
        guard try await sql.raw("SELECT id FROM completion_attempts WHERE id = \(bind: id)").first() == nil else { throw Abort(.conflict, reason: "This completion intention already exists. Retry the original operation", identifier: "entity_exists") }
        // Validate the whole evidence graph before any attachment becomes shared. One read of every row (the same
        // predicate `PrivateMediaService.row` applies to each), then the checks per photo in the order of
        // `evidenceIds`, so the first failing photo yields exactly the refusal it yielded when each row was read alone.
        if !evidenceIDs.isEmpty {
            var rows: [UUID: SQLRow] = [:]
            for row in try await sql.raw("SELECT * FROM media_assets WHERE id = ANY(\(bind: evidenceIDs)::UUID[]) AND snag_id = \(bind: snagID) AND project_id = \(bind: projectID)").all() {
                rows[try row.decode(column: "id", as: UUID.self)] = row
            }
            for assetID in evidenceIDs {
                guard let row = rows[assetID] else { throw Abort(.notFound, reason: "Photo unavailable") }
                try PrivateMediaService.requireUploader(row, actorID: actorID, grantID: grantID)
                guard try row.decode(column: "state", as: String.self) == "ready",
                      try row.decode(column: "purpose", as: String.self) == "completion",
                      try row.decode(column: "intent_id", as: UUID?.self) == id,
                      try row.decode(column: "attached_at", as: Date?.self) == nil else {
                    throw Abort(.unprocessableEntity, reason: "Use processed after photos uploaded for this completion intention", identifier: "invalid_completion_evidence")
                }
            }
        }
        let number = try await sql.raw("SELECT COALESCE(MAX(attempt_number), 0) + 1 AS n FROM completion_attempts WHERE snag_id = \(bind: snagID)").first()!.decode(column: "n", as: Int64.self)
        guard let attempt = try await sql.raw("""
            INSERT INTO completion_attempts (id, workspace_id, project_id, snag_id, attempt_number, actor_id, actor_grant_id, actor_kind, notes, state, submitted_at)
            VALUES (\(bind: id), \(bind: project.workspaceId!), \(bind: projectID), \(bind: snagID), \(bind: number), \(bind: actorID), \(bind: grantID), \(bind: grantID != nil ? "contractor_link" : internalFix ? "internal_fix" : "internal"), \(bind: command.notes), \(bind: internalFix ? "accepted" : "pending"), \(bind: Date()))
            RETURNING *
            """).first() else { throw Abort(.internalServerError) }
        guard !evidenceIDs.isEmpty else { return attempt }
        let evidence = evidenceIDs.enumerated().map { (position, assetID) -> SQLQueryString in
            "(\(bind: id), \(bind: assetID), \(bind: snagID), \(bind: projectID), \(bind: position))"
        }
        try await sql.raw(SQLQueryString("INSERT INTO completion_evidence (attempt_id, asset_id, snag_id, project_id, position) VALUES ") + evidence.joined(separator: ", ")).run()
        var attached: [UUID: SQLRow] = [:]
        for row in try await sql.raw("UPDATE media_assets SET attached_at = \(bind: Date()), revision = revision + 1 WHERE id = ANY(\(bind: evidenceIDs)::UUID[]) RETURNING *").all() {
            attached[try row.decode(column: "id", as: UUID.self)] = row
        }
        for assetID in evidenceIDs {
            guard let row = attached[assetID] else { throw Abort(.notFound, reason: "Photo unavailable") }
            let media = try MediaAssetResponse(row)
            batch.append(try .init(projectID: projectID, type: "media", entityID: assetID, revision: media.revision, kind: "completion_evidence", fields: ["attachedAt"], payload: media, actorID: actorID, grantID: grantID))
        }
        return attempt
    }
    private static func decision(_ kind: String, attemptID: UUID?, command: WorkflowCommand, reason: String?, snag: Snag, project: Project, actorID: UUID, batch: PlatformMutationService.Batch? = nil, on db: Database) async throws -> ReviewDecisionResponse {
        let id = UUID(), sql = try VerifiedIdentityService.sql(db)
        guard let row = try await sql.raw("""
            INSERT INTO review_decisions (id, workspace_id, project_id, snag_id, attempt_id, actor_id, kind, reason, expected_snag_revision, expected_workflow_revision, created_at)
            VALUES (\(bind: id), \(bind: project.workspaceId!), \(bind: project.requireID()), \(bind: snag.requireID()), \(bind: attemptID), \(bind: actorID), \(bind: kind), \(bind: reason), \(bind: command.expectedRevision), \(bind: command.expectedWorkflowRevision), \(bind: Date())) RETURNING *
            """).first() else { throw Abort(.internalServerError) }
        let result = try ReviewDecisionResponse(row)
        if let batch {
            batch.append(try .init(projectID: project.requireID(), type: "reviewDecision", entityID: id, revision: 1, kind: kind, fields: ["kind", "reason", "actorId"], payload: result, actorID: actorID))
        } else {
            try await PlatformMutationService.change(workspaceID: project.workspaceId!, projectID: project.requireID(), type: "reviewDecision", entityID: id, revision: 1, kind: kind, fields: ["kind", "reason", "actorId"], payload: result, actorID: actorID, on: db)
        }
        return result
    }
}
