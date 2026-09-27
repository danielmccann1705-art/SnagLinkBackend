@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// F06 (audit 27 Sep): overdue means the contractor still owes work. Work awaiting the
/// manager's decision, closed work and unreconciled legacy states are never trade
/// overdue; the manager's outstanding review is reported as its own ageing.
final class RegisterOverdueSemanticsTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("overdue-\(UUID())@example.test", name: "Synthetic manager", on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User, body: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            if method != .GET { req.headers.contentType = .json; req.body = .init(data: bytes) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func metadata() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func project(_ owner: User) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let body: [String: Any] = ["mutation": metadata(), "workspaceId": try workspace.requireID().uuidString,
                                   "project": ["id": UUID().uuidString, "name": "Willow Mews · Plot 7", "reference": "WM07", "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, project: PlatformProjectResponse, title: String, dueOn: String?) async throws -> UUID {
        var fields: [String: Any] = ["title": title]
        if let dueOn { fields["dueOn"] = dueOn }
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
                                         body: ["mutation": metadata(), "id": UUID().uuidString, "fields": fields])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self).snag.id
    }
    /// Workflow state fixture only (the same pattern the register tests use); the
    /// workflow commands themselves are covered by CanonicalWorkflow tests.
    private func setState(_ id: UUID, _ status: String, legacy: Bool = false) async throws {
        let qualification: String? = legacy ? "legacy_unverified" : nil
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE snags SET status = \(bind: status), workflow_qualification = \(bind: qualification) WHERE id = \(bind: id)
            """).run()
    }
    private func pendingAttempt(_ snagID: UUID, project: PlatformProjectResponse, actor: User, submittedAt: Date) async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO completion_attempts (id, workspace_id, project_id, snag_id, attempt_number, actor_id, actor_kind, notes, state, revision, submitted_at)
            VALUES (\(bind: UUID()), \(bind: project.workspaceId), \(bind: project.project.id), \(bind: snagID), 1, \(bind: actor.requireID()), 'internal', NULL, 'pending', 1, \(bind: submittedAt))
            """).run()
    }

    func testOverdueCountsAndFilterIncludeOnlyContractorOwedCanonicalWork() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let open = try await snag(owner, project: envelope, title: "Open past due", dueOn: "2026-09-01")
        let started = try await snag(owner, project: envelope, title: "In progress past due", dueOn: "2026-09-02")
        let sentBack = try await snag(owner, project: envelope, title: "Changes requested past due", dueOn: "2026-09-03")
        let waiting = try await snag(owner, project: envelope, title: "Awaiting review past due", dueOn: "2026-09-04")
        let closed = try await snag(owner, project: envelope, title: "Closed past due", dueOn: "2026-09-05")
        let legacy = try await snag(owner, project: envelope, title: "Legacy unverified past due", dueOn: "2026-09-06")
        let future = try await snag(owner, project: envelope, title: "Open not yet due", dueOn: "2026-10-01")
        _ = try await snag(owner, project: envelope, title: "Open without date", dueOn: nil)
        try await setState(started, "in_progress")
        try await setState(sentBack, "changes_requested")
        try await setState(waiting, "awaiting_review")
        try await setState(closed, "closed")
        try await setState(legacy, "in_progress", legacy: true)
        let submitted = ISO8601DateFormatter().date(from: "2026-09-07T08:00:00Z")!
        try await pendingAttempt(waiting, project: envelope, actor: owner, submittedAt: submitted)
        _ = future

        let project = try await Project.find(envelope.project.id, on: app.db)!
        let now = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!
        let all = try await SnagRegisterService.list(.init(), project: project, on: app.db, now: now)
        XCTAssertEqual(all.summary.total, 8)
        XCTAssertEqual(all.summary.overdue, 3, "open, in progress and changes requested only")
        XCTAssertEqual(all.summary.awaitingReview, 1)
        XCTAssertEqual(all.summary.legacyUnverified, 1)
        XCTAssertEqual(all.summary.reviewPastDue, 1, "the manager's review ageing is separate from trade overdue")
        XCTAssertEqual(all.summary.oldestAwaitingReviewSince, submitted)

        let filtered = try await SnagRegisterService.list(.init(due: "overdue"), project: project, on: app.db, now: now)
        XCTAssertEqual(Set(filtered.items.map(\.snag.id)), [open, started, sentBack])
        XCTAssertEqual(filtered.total, filtered.summary.overdue, "the count and the filter share one definition")
        // Combining the overdue filter with a review state yields nothing: that work is not the trade's.
        let reviewOverdue = try await SnagRegisterService.list(.init(status: "awaiting_review", due: "overdue"), project: project, on: app.db, now: now)
        XCTAssertEqual(reviewOverdue.total, 0)

        // The same rule through HTTP, with the optional fields present.
        let path = "api/v2/projects/\(envelope.project.id)/snags?due=overdue"
        let response = try await request(.GET, path, user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let body = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
        let summary = body["summary"] as! [String: Any]
        XCTAssertNotNil(summary["reviewPastDue"]); XCTAssertNotNil(summary["oldestAwaitingReviewSince"])
    }

    func testOverdueBoundaryUsesTheWorkspaceCalendar() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let dueTenth = try await snag(owner, project: envelope, title: "Due on the tenth", dueOn: "2026-09-10")
        let project = try await Project.find(envelope.project.id, on: app.db)!
        // 12:30 UTC on the 10th: still the 10th in London, already the 11th in Auckland.
        let now = ISO8601DateFormatter().date(from: "2026-09-10T12:30:00Z")!
        let london = try await SnagRegisterService.list(.init(due: "overdue"), project: project, on: app.db, now: now)
        XCTAssertEqual(london.total, 0)
        XCTAssertEqual(london.summary.overdue, 0)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE teams SET timezone = 'Pacific/Auckland' WHERE id = \(bind: envelope.workspaceId)").run()
        let auckland = try await SnagRegisterService.list(.init(due: "overdue"), project: project, on: app.db, now: now)
        XCTAssertEqual(auckland.items.map(\.snag.id), [dueTenth])
        XCTAssertEqual(auckland.summary.overdue, 1)
        // Once submitted, the same late item leaves trade overdue and joins review ageing.
        try await setState(dueTenth, "awaiting_review")
        let submitted = try await SnagRegisterService.list(.init(), project: project, on: app.db, now: now)
        XCTAssertEqual(submitted.summary.overdue, 0)
        XCTAssertEqual(submitted.summary.reviewPastDue, 1)
        XCTAssertNil(submitted.summary.oldestAwaitingReviewSince, "no pending attempt fixture was written")
    }
}
