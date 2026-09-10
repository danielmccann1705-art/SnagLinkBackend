@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CanonicalWorkflowTests: XCTestCase {
    var app: Application!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("media-\(UUID())@example.test", name: "Synthetic photo tester", on: db) }
    }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:], bytes: Data? = nil, mime: String = "image/png") async throws -> XCTHTTPResponse {
        let jwt: String?
        if let user {
            let id = try user.requireID()
            jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        } else { jwt = nil }
        let payload = try bytes ?? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if method != .GET {
                req.headers.replaceOrAdd(name: .contentType, value: bytes == nil ? "application/json" : mime)
                req.body = .init(data: payload)
            }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func project(_ user: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: user.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: user.requireID(), on: db)
        }
        let response = try await call(.POST, "api/v2/projects", user, body: ["mutation": meta(), "workspaceId": try workspace.requireID().uuidString, "project": ["id": UUID().uuidString, "name": "Plot 12", "reference": "WC12"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ user: User, _ project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let response = try await call(.POST, "api/v2/projects/\(project.project.id)/snags", user, body: ["mutation": meta(), "id": UUID().uuidString, "fields": ["title": "Seal shower tray", "location": "Plot 12 · Ensuite"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func path(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media" }
    private func command(_ snag: PlatformSnagResponse, bytes: Data = png, purpose: String = "capture", intent: UUID? = nil) -> [String: Any] {
        var value: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": snag.revision, "purpose": purpose, "sha256": PrivateImageProcessor.digest(bytes), "byteCount": bytes.count, "mimeType": "image/png"]
        if let intent { value["intentId"] = intent.uuidString }
        return value
    }
    private func allocate(_ user: User, _ path: String, _ command: [String: Any]) async throws -> MediaAssetResponse {
        let result = try await call(.POST, path, user, body: command)
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(MediaAssetResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }
    private func logged(_ owner: User, _ project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let draft = try await snag(owner, project)
        let result = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(draft.snag.id)/publish", owner, body: ["mutation": meta(), "expectedRevision": draft.revision])
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(PlatformSnagResponse.self)
    }
    private func workflowPath(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/workflow" }
    private func action(_ snag: PlatformSnagResponse, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = ["mutation": meta(), "expectedRevision": snag.revision, "expectedWorkflowRevision": snag.workflowRevision]
        body.merge(extra) { _, new in new }; return body
    }
    private func after(_ actor: User, project: PlatformProjectResponse, snag: PlatformSnagResponse, intent: UUID) async throws -> UUID {
        let path = path(project, snag)
        let media = try await allocate(actor, path, command(snag, purpose: "completion", intent: intent))
        let result = try await call(.PUT, path + "/\(media.id)/content", actor, bytes: Self.png)
        XCTAssertEqual(result.status, .ok, result.body.string); return media.id
    }
    private func submit(_ actor: User, project: PlatformProjectResponse, snag: PlatformSnagResponse) async throws -> WorkflowResponse {
        let intent = UUID(), media = try await after(actor, project: project, snag: snag, intent: intent)
        let result = try await call(.POST, workflowPath(project, snag) + "/submit", actor, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [media.uuidString], "notes": "Repaired and checked on site"]))
        XCTAssertEqual(result.status, .ok, result.body.string); return try result.content.decode(WorkflowResponse.self)
    }
    private func decide(_ actor: User, project: PlatformProjectResponse, submitted: WorkflowResponse, kind: String, reason: String? = nil) async throws -> WorkflowResponse {
        var extra: [String: Any] = ["attemptId": submitted.attempt!.id.uuidString, "expectedAttemptRevision": submitted.attempt!.revision]
        if let reason { extra["reason"] = reason }
        let response = try await call(.POST, workflowPath(project, submitted.snag) + "/" + kind, actor, body: action(submitted.snag, extra: extra))
        XCTAssertEqual(response.status, .ok, response.body.string); return try response.content.decode(WorkflowResponse.self)
    }
    func testSubmissionRequiresProcessedOwnedAfterEvidenceAndDoesNotClose() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project), path = workflowPath(project, snag), intent = UUID()
        let none = try await call(.POST, path + "/submit", owner, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": []]))
        XCTAssertEqual(none.status, .unprocessableEntity)
        let unprocessed = try await allocate(owner, self.path(project, snag), command(snag, purpose: "completion", intent: intent))
        let unready = try await call(.POST, path + "/submit", owner, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [unprocessed.id.uuidString]]))
        XCTAssertEqual(unready.status, .unprocessableEntity)
        let mismatchedIntent = try await after(owner, project: project, snag: snag, intent: UUID())
        let wrong = try await call(.POST, path + "/submit", owner, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [mismatchedIntent.uuidString]]))
        XCTAssertEqual(wrong.status, .unprocessableEntity)
        let submitted = try await submit(owner, project: project, snag: snag)
        XCTAssertEqual(submitted.snag.snag.status, "awaiting_review"); XCTAssertNil(submitted.snag.snag.closedAt)
        XCTAssertEqual(submitted.attempt?.state, "pending"); XCTAssertEqual(submitted.attempt?.number, 1)
        XCTAssertEqual(submitted.attempt?.evidenceIds.count, 1); XCTAssertTrue(submitted.decisions.isEmpty)
        let history = try await call(.GET, path, owner)
        XCTAssertEqual(try history.content.decode(CanonicalWorkflowController.History.self).pending?.id, submitted.attempt?.id)
    }
    func testConcurrentSubmissionRetriesProduceOneAttemptAndOutboxEvent() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project), intent = UUID()
        let asset = try await after(owner, project: project, snag: snag, intent: intent)
        let body = action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [asset.uuidString]])
        var results: [WorkflowResponse] = []
        try await withThrowingTaskGroup(of: WorkflowResponse.self) { group in
            for _ in 0..<4 { group.addTask {
                let result = try await self.call(.POST, self.workflowPath(project, snag) + "/submit", owner, body: body)
                XCTAssertEqual(result.status, .ok, result.body.string)
                return try result.content.decode(WorkflowResponse.self)
            } }
            for try await result in group { results.append(result) }
        }
        XCTAssertEqual(Set(results.compactMap { $0.attempt?.id }), [intent])
        XCTAssertEqual(Set(results.map { $0.snag.revision }), [snag.revision + 1])
        let sql = try VerifiedIdentityService.sql(app.db)
        let attempts = try await sql.raw("SELECT count(*) AS n FROM completion_attempts WHERE snag_id = \(bind: snag.snag.id)").first()!.decode(column: "n", as: Int.self)
        let jobs = try await sql.raw("SELECT count(*) AS n FROM workflow_outbox WHERE snag_id = \(bind: snag.snag.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(jobs, 1)
        let another = try await call(.POST, workflowPath(project, results[0].snag) + "/submit", owner, body: action(results[0].snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": []]))
        XCTAssertEqual(another.status, .conflict)
    }
    func testAnotherProjectManagerCanReviewAndCompetingDecisionsHaveOneOutcome() async throws {
        let owner = try await user(), contributor = try await user(), reviewer = try await user(), project = try await project(owner, company: true)
        try await join(contributor, owner: owner, project: project, role: "member")
        try await join(reviewer, owner: owner, project: project, role: "manager")
        let snag = try await logged(contributor, project), submitted = try await submit(contributor, project: project, snag: snag)
        let extra: [String: Any] = ["attemptId": submitted.attempt!.id.uuidString, "expectedAttemptRevision": 1]
        let denied = try await call(.POST, workflowPath(project, snag) + "/accept", contributor, body: action(submitted.snag, extra: extra))
        XCTAssertEqual(denied.status, .forbidden)
        var results: [HTTPResponseStatus] = []
        try await withThrowingTaskGroup(of: HTTPResponseStatus.self) { group in
            for (actor, kind) in [(reviewer, "accept"), (owner, "send-back")] { group.addTask {
                var extra = extra
                if kind == "send-back" { extra["reason"] = "Seal is still uneven at the corner" }
                return try await self.call(.POST, self.workflowPath(project, snag) + "/" + kind, actor, body: self.action(submitted.snag, extra: extra)).status
            } }
            for try await status in group { results.append(status) }
        }
        XCTAssertEqual(results.filter { $0 == .ok }.count, 1); XCTAssertEqual(results.filter { $0 == .conflict }.count, 1)
        let history = try await call(.GET, workflowPath(project, snag), reviewer)
        let current = try history.content.decode(CanonicalWorkflowController.History.self)
        XCTAssertNil(current.pending); XCTAssertEqual(current.decisions.count, 1)
        XCTAssertTrue(["closed", "changes_requested"].contains(current.snag.snag.status))
        XCTAssertEqual(current.attempts.first?.revision, 2)
    }
    func testSendBackResubmitAcceptAndReopenPreserveEveryAttemptAndDecision() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project)
        let first = try await submit(owner, project: project, snag: snag)
        let rejected = try await decide(owner, project: project, submitted: first, kind: "send-back", reason: "Please include the corner of the tray")
        XCTAssertEqual(rejected.snag.snag.status, "changes_requested")
        let second = try await submit(owner, project: project, snag: rejected.snag)
        XCTAssertEqual(second.attempt?.number, 2); XCTAssertNotEqual(first.attempt?.id, second.attempt?.id)
        let accepted = try await decide(owner, project: project, submitted: second, kind: "accept")
        XCTAssertEqual(accepted.snag.snag.status, "closed"); XCTAssertNotNil(accepted.snag.snag.closedAt)
        let closedSubmission = try await call(.POST, workflowPath(project, snag) + "/submit", owner, body: action(accepted.snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": [], "waiverReason": "Try to overwrite acceptance"]))
        XCTAssertEqual(closedSubmission.status, .conflict)
        let blankReopen = try await call(.POST, workflowPath(project, snag) + "/reopen", owner, body: action(accepted.snag, extra: ["reason": "   "]))
        XCTAssertEqual(blankReopen.status, .badRequest)
        let reopenedResult = try await call(.POST, workflowPath(project, snag) + "/reopen", owner, body: action(accepted.snag, extra: ["reason": "Seal failed during the final water test"]))
        XCTAssertEqual(reopenedResult.status, .ok)
        let reopened = try reopenedResult.content.decode(WorkflowResponse.self)
        XCTAssertEqual(reopened.snag.snag.status, "open"); XCTAssertNil(reopened.snag.snag.closedAt)
        let history = try await call(.GET, workflowPath(project, snag), owner)
        let retained = try history.content.decode(CanonicalWorkflowController.History.self)
        XCTAssertEqual(retained.attempts.map(\.state), ["accepted", "sent_back"])
        XCTAssertEqual(retained.attempts.flatMap(\.evidenceIds).count, 2)
        XCTAssertEqual(retained.decisions.map(\.kind), ["reopen", "accept", "send_back"])
        let oldPhoto = first.attempt!.evidenceIds[0]
        let image = try await call(.GET, self.path(project, snag) + "/\(oldPhoto)/content", owner)
        XCTAssertEqual(image.status, .ok)
    }
    func testWaiverAndInternalFixRequireReviewerAndRecordHonestAttribution() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let snag = try await logged(member, project)
        let attemptedWaiver = action(snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": [], "waiverReason": "No safe access for a photo"])
        let denied = try await call(.POST, workflowPath(project, snag) + "/submit", member, body: attemptedWaiver)
        XCTAssertEqual(denied.status, .unprocessableEntity)
        let internalFix = action(snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": [], "waiverReason": "Hidden repair inspected before enclosure", "reason": "Manager completed and inspected the repair"])
        let memberFix = try await call(.POST, workflowPath(project, snag) + "/internal-fix", member, body: internalFix)
        XCTAssertEqual(memberFix.status, .forbidden)
        let fixed = try await call(.POST, workflowPath(project, snag) + "/internal-fix", owner, body: internalFix)
        XCTAssertEqual(fixed.status, .ok, fixed.body.string)
        let result = try fixed.content.decode(WorkflowResponse.self)
        XCTAssertEqual(result.snag.snag.status, "closed"); XCTAssertEqual(result.attempt?.actorKind, "internal_fix")
        XCTAssertEqual(result.attempt?.actorId, try owner.requireID())
        XCTAssertEqual(result.decisions.map(\.kind), ["waiver", "internal_fix"])
    }
    func testStaleReviewAndLegacyPatchCannotOverwriteAcceptedClosure() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project)
        let submitted = try await submit(owner, project: project, snag: snag)
        let wrongAttempt = try await call(.POST, workflowPath(project, snag) + "/accept", owner, body: action(submitted.snag, extra: ["attemptId": submitted.attempt!.id.uuidString, "expectedAttemptRevision": 99]))
        XCTAssertEqual(wrongAttempt.status, .conflict); XCTAssertTrue(wrongAttempt.body.string.contains("workflow_conflict"))
        let accepted = try await decide(owner, project: project, submitted: submitted, kind: "accept")
        let stale = try await call(.POST, workflowPath(project, snag) + "/send-back", owner, body: action(submitted.snag, extra: ["attemptId": submitted.attempt!.id.uuidString, "expectedAttemptRevision": 1, "reason": "Stale screen"]))
        XCTAssertEqual(stale.status, .conflict)
        let native = try await call(.PATCH, "api/v1/snags/\(snag.snag.id)", owner, body: ["status": "open"])
        XCTAssertEqual(native.status, .notFound)
        let generic = try await call(.PATCH, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)", owner, body: ["mutation": meta(), "expectedRevision": accepted.snag.revision, "fields": ["status": "open"]])
        XCTAssertEqual(generic.status, .badRequest)
        let record = try await Snag.find(snag.snag.id, on: app.db)
        XCTAssertEqual(record?.status, "closed"); XCTAssertEqual(record?.revision, accepted.snag.revision)
    }
    func testSnapshotRetainsOriginalHistoryAndDeltaDoesNotSplitAcceptanceAtPageBoundary() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project)
        let submitted = try await submit(owner, project: project, snag: snag)
        let snapshot = try await app.db.transaction { db in try await RegisterSyncService.create(projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertTrue(snapshot.coverage.contains("completionAttempts")); XCTAssertTrue(snapshot.coverage.contains("reviewDecisions"))
        let savedAttempt = try XCTUnwrap(snapshot.items.first { $0.type == "completionAttempt" })
        XCTAssertEqual(try PlatformMutationService.decode(CompletionAttemptResponse.self, PlatformMutationService.encode(savedAttempt.data)).state, "pending")
        var current = submitted.snag
        for n in 0..<99 {
            let patch = try await call(.PATCH, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)", owner, body: ["mutation": meta(), "expectedRevision": current.revision, "fields": ["description": "Inspection note \(n)"]])
            XCTAssertEqual(patch.status, .ok, patch.body.string)
            current = try patch.content.decode(PlatformSnagResponse.self)
        }
        _ = try await decide(owner, project: project, submitted: .init(snag: current, attempt: submitted.attempt, decisions: []), kind: "accept")
        let delta = try await app.db.transaction { db in try await RegisterSyncService.changes(cursor: snapshot.changesCursor!, projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertEqual(delta.changes.count, 102); XCTAssertFalse(delta.hasMore)
        let closure = Array(delta.changes.suffix(3))
        XCTAssertEqual(Set(closure.map(\.type)), ["snag", "completionAttempt", "reviewDecision"])
        XCTAssertEqual(Set(closure.map(\.transactionGroup)).count, 1)
        XCTAssertEqual(Set(delta.changes.prefix(99).map(\.transactionGroup)).count, 99)
        let replayPage = try await app.db.transaction { db in try await RegisterSyncService.page(token: snapshot.snapshotToken, offset: 0, projectID: project.project.id, actorID: owner.requireID(), on: db) }
        let stillPending = try XCTUnwrap(replayPage.items.first { $0.type == "completionAttempt" })
        XCTAssertEqual(try PlatformMutationService.decode(CompletionAttemptResponse.self, PlatformMutationService.encode(stillPending.data)).state, "pending")
        let fresh = try await app.db.transaction { db in try await RegisterSyncService.create(projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertEqual(fresh.items.filter { $0.type == "reviewDecision" }.count, 1)
        let nowAccepted = try XCTUnwrap(fresh.items.first { $0.type == "completionAttempt" })
        XCTAssertEqual(try PlatformMutationService.decode(CompletionAttemptResponse.self, PlatformMutationService.encode(nowAccepted.data)).state, "accepted")
        XCTAssertEqual(fresh.items.filter { $0.type == "media" }.count, 1)
        let empty = try await app.db.transaction { db in try await RegisterSyncService.changes(cursor: delta.cursor, projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertTrue(empty.changes.isEmpty)
    }
    func testRollbackRetainsNeitherAttemptDecisionChangesNorNotificationJob() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project), intent = UUID()
        let asset = try await after(owner, project: project, snag: snag, intent: intent)
        let body = action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [asset.uuidString]])
        let command = try PlatformMutationService.decode(WorkflowCommand.self, String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        enum ForcedRollback: Error { case afterWorkflow }
        do {
            try await app.db.transaction { db in
                let (record, actions) = try await ProjectAccessService.require(.submitCompletion, projectID: project.project.id, actorID: owner.requireID(), on: db)
                let current = try await PlatformSnagService.find(snag.snag.id, projectID: project.project.id, on: db)
                _ = try await CanonicalWorkflowService.execute(command, action: .submit, snag: current, project: record, actorID: owner.requireID(), actions: actions, on: db)
                throw ForcedRollback.afterWorkflow
            }
            XCTFail("Expected rollback")
        } catch ForcedRollback.afterWorkflow { }
        let sql = try VerifiedIdentityService.sql(app.db)
        for table in ["completion_attempts", "review_decisions", "workflow_outbox"] {
            let rows = try await sql.select().column("id").from(SQLIdentifier(table)).where("snag_id", .equal, snag.snag.id).all()
            XCTAssertTrue(rows.isEmpty, table)
        }
        let current = try await Snag.find(snag.snag.id, on: app.db)
        XCTAssertEqual(current?.status, "open"); XCTAssertEqual(current?.revision, snag.revision)
        let row = try await PrivateMediaService.row(asset, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        XCTAssertNil(try row.decode(column: "attached_at", as: Date?.self))
    }
}
