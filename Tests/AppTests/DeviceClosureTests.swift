@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// F02 amendments §2.2 / §4.3 (Fable, 27 Sep): a snag closed on a device before it reached
/// the workspace is recorded exactly like a 1.x import's unverified closure — never
/// accepted, never in the review queue, never overdue, reopenable — through an optional
/// field on the existing create and a reconcile route for copies made without it.
/// Real PostgreSQL, synthetic data only.
final class DeviceClosureTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private let closedOnDevice = "2026-09-12T10:00:00Z"
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("closure-\(UUID())@example.test", name: "Synthetic manager", on: db) }
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
                                   "project": ["id": UUID().uuidString, "name": "Willow Mews · Plot 9", "reference": "WM09", "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func json(_ response: XCTHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
    }
    private func create(_ owner: User, _ envelope: PlatformProjectResponse, closure: [String: Any]?, dueOn: String? = nil,
                        mutation: [String: Any]? = nil, id: UUID = UUID()) async throws -> XCTHTTPResponse {
        var fields: [String: Any] = ["title": "Skirting gap by the stairs"]
        if let dueOn { fields["dueOn"] = dueOn }
        var body: [String: Any] = ["mutation": mutation ?? metadata(), "id": id.uuidString, "fields": fields]
        if let closure { body["deviceClosure"] = closure }
        return try await request(.POST, "api/v2/projects/\(envelope.project.id)/snags", user: owner, body: body)
    }
    private func row(_ id: UUID) async throws -> SQLRow {
        try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT status, closed_at, source_status, source_closed_at, workflow_qualification, revision, workflow_revision FROM snags WHERE id = \(bind: id)
            """).first()!
    }
    private func activity(_ id: UUID) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM workspace_activity WHERE action = 'snag_device_closure_carried' AND target_id = \(bind: id)")
            .first()!.decode(column: "n", as: Int.self)
    }
    private func carry(_ owner: User, _ envelope: PlatformProjectResponse, _ id: UUID, revision: Int, closedAt: String? = nil,
                       sourceStatus: String = "closed", mutation: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/projects/\(envelope.project.id)/snags/\(id)/workflow/device-closure", user: owner,
                          body: ["mutation": mutation ?? metadata(), "expectedRevision": revision, "closedAt": closedAt ?? closedOnDevice, "sourceStatus": sourceStatus])
    }

    func testCreateWithADeviceClosureIsAnUnverifiedClosureEverywhere() async throws {
        let owner = try await user(), envelope = try await project(owner), id = UUID()
        let created = try await create(owner, envelope, closure: ["closedAt": closedOnDevice, "sourceStatus": "closed"], dueOn: "2026-09-01", id: id)
        XCTAssertEqual(created.status, .ok, created.body.string)
        let body = try json(created)
        let snag = try XCTUnwrap(body["snag"] as? [String: Any]), workflow = try XCTUnwrap(body["workflow"] as? [String: Any])
        XCTAssertEqual(snag["status"] as? String, "closed")
        XCTAssertNil(snag["closedAt"] as? String, "not an accepted closure: closedAt stays empty")
        XCTAssertEqual(workflow["qualification"] as? String, "legacy_unverified")
        XCTAssertEqual(workflow["legacyClosureUnverified"] as? Bool, true)
        XCTAssertEqual(workflow["actionableReview"] as? Bool, false)
        XCTAssertEqual(workflow["sourceStatus"] as? String, "closed")
        XCTAssertEqual(workflow["sourceClosedAt"] as? String, closedOnDevice)

        let stored = try await row(id)
        XCTAssertNil(try stored.decode(column: "closed_at", as: Date?.self))
        XCTAssertEqual(try stored.decode(column: "source_closed_at", as: Date?.self), ISO8601DateFormatter().date(from: closedOnDevice))
        XCTAssertEqual(try stored.decode(column: "workflow_qualification", as: String?.self), "legacy_unverified")
        let carried = try await activity(id)
        XCTAssertEqual(carried, 1)

        // Register: counted as unverified, never overdue although its due date has passed.
        let project = try await Project.find(envelope.project.id, on: app.db)!
        let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
        let register = try await SnagRegisterService.list(.init(), project: project, on: app.db, now: now)
        XCTAssertEqual(register.summary.legacyUnverified, 1)
        XCTAssertEqual(register.summary.overdue, 0)
        XCTAssertEqual(register.summary.awaitingReview, 0)
        XCTAssertEqual(IssuedReportService.statusLabel(status: "closed", legacy: true, acceptance: nil), "Previously closed on this device — unverified")

        // A reviewer's reopen clears it, as for a 1.x import.
        let published = try await request(.POST, "api/v2/projects/\(envelope.project.id)/snags/\(id)/publish", user: owner,
                                           body: ["mutation": metadata(), "expectedRevision": 1])
        XCTAssertEqual(published.status, .ok, published.body.string)
        let reopened = try await request(.POST, "api/v2/projects/\(envelope.project.id)/snags/\(id)/workflow/reopen", user: owner,
                                          body: ["mutation": metadata(), "expectedRevision": 2, "expectedWorkflowRevision": 1, "reason": "Not verified on site"])
        XCTAssertEqual(reopened.status, .ok, reopened.body.string)
        let after = try await row(id)
        XCTAssertEqual(try after.decode(column: "status", as: String.self), "open")
        XCTAssertNil(try after.decode(column: "workflow_qualification", as: String?.self))

        // Once it has a review decision of its own it can never take a device closure again.
        let again = try await carry(owner, envelope, id, revision: 3)
        XCTAssertEqual(again.status, .conflict, again.body.string)
        XCTAssertEqual(try json(again)["identifier"] as? String, "device_closure_not_applicable")
    }

    func testCreateWithoutAClosureIsUnchangedAndHashesAsBefore() async throws {
        let owner = try await user(), envelope = try await project(owner), id = UUID()
        let created = try await create(owner, envelope, closure: nil, id: id)
        XCTAssertEqual(created.status, .ok, created.body.string)
        let body = try json(created)
        XCTAssertEqual((body["snag"] as? [String: Any])?["status"] as? String, "open")
        XCTAssertNil(body["workflow"] as? [String: Any])
        let carried = try await activity(id)
        XCTAssertEqual(carried, 0)
        // An older client's create encodes (and so hashes) exactly as it did before the field existed.
        let command = SnagCreateCommand(mutation: .init(operationId: UUID(), deviceId: UUID()), id: UUID(), fields: ["title": .string("Old client")])
        XCTAssertFalse(try PlatformMutationService.encode(command).contains("deviceClosure"))
    }

    func testAnInvalidDeviceClosureIsRefusedAndCreatesNothing() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        for closure: [String: Any] in [["closedAt": future, "sourceStatus": "closed"],
                                       ["closedAt": "2014-12-31T23:00:00Z", "sourceStatus": "closed"],
                                       ["closedAt": closedOnDevice, "sourceStatus": "approved"]] {
            let id = UUID()
            let refused = try await create(owner, envelope, closure: closure, id: id)
            XCTAssertEqual(refused.status, .badRequest, refused.body.string)
            XCTAssertEqual(try json(refused)["identifier"] as? String, "invalid_device_closure")
            let exists = try await Snag.find(id, on: app.db)
            XCTAssertNil(exists)
        }
    }

    func testTheReconcileRouteCarriesAClosureOnceAndReplaysIdentically() async throws {
        let owner = try await user(), envelope = try await project(owner), id = UUID()
        let made1 = try await create(owner, envelope, closure: nil, dueOn: "2026-09-01", id: id)
        XCTAssertEqual(made1.status, .ok, made1.body.string)
        let mutation = metadata()
        let first = try await carry(owner, envelope, id, revision: 1, mutation: mutation)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let body = try json(first)
        XCTAssertEqual((body["snag"] as? [String: Any])?["status"] as? String, "closed")
        XCTAssertEqual((body["workflow"] as? [String: Any])?["qualification"] as? String, "legacy_unverified")
        XCTAssertEqual(body["revision"] as? Int, 2)
        XCTAssertEqual(body["workflowRevision"] as? Int, 2)
        // The same operation again: the stored result, nothing applied twice.
        let replay = try await carry(owner, envelope, id, revision: 1, mutation: mutation)
        XCTAssertEqual(replay.status, .ok, replay.body.string)
        let replayed = try json(replay)
        XCTAssertEqual(replayed["revision"] as? Int, 2)
        XCTAssertEqual((replayed["snag"] as? [String: Any])?["status"] as? String, "closed")
        let stored = try await row(id)
        XCTAssertEqual(try stored.decode(column: "revision", as: Int64.self), 2)
        let carried = try await activity(id)
        XCTAssertEqual(carried, 1)
        // A new operation on the now-qualified snag is refused.
        let second = try await carry(owner, envelope, id, revision: 2)
        XCTAssertEqual(second.status, .conflict)
        XCTAssertEqual(try json(second)["identifier"] as? String, "device_closure_not_applicable")
        let project = try await Project.find(envelope.project.id, on: app.db)!
        let register = try await SnagRegisterService.list(.init(), project: project, on: app.db,
                                                         now: ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!)
        XCTAssertEqual(register.summary.overdue, 0); XCTAssertEqual(register.summary.legacyUnverified, 1)
    }

    func testTheReconcileRouteRefusesWorkWithItsOwnWorkflow() async throws {
        let owner = try await user(), envelope = try await project(owner)
        // A completion attempt exists.
        let attempted = UUID()
        let made2 = try await create(owner, envelope, closure: nil, id: attempted)
        XCTAssertEqual(made2.status, .ok, made2.body.string)
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO completion_attempts (id, workspace_id, project_id, snag_id, attempt_number, actor_id, actor_kind, notes, state, revision, submitted_at)
            VALUES (\(bind: UUID()), \(bind: envelope.workspaceId), \(bind: envelope.project.id), \(bind: attempted), 1, \(bind: owner.requireID()), 'internal', NULL, 'pending', 1, \(bind: Date()))
            """).run()
        let withAttempt = try await carry(owner, envelope, attempted, revision: 1)
        XCTAssertEqual(withAttempt.status, .conflict, withAttempt.body.string)
        XCTAssertEqual(try json(withAttempt)["identifier"] as? String, "device_closure_not_applicable")
        // Not open.
        let started = UUID()
        let made3 = try await create(owner, envelope, closure: nil, id: started)
        XCTAssertEqual(made3.status, .ok, made3.body.string)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE snags SET status = 'in_progress' WHERE id = \(bind: started)").run()
        let notOpen = try await carry(owner, envelope, started, revision: 1)
        XCTAssertEqual(notOpen.status, .conflict)
        // A stale revision is the ordinary revision conflict, and nothing changes.
        let stale = UUID()
        let made4 = try await create(owner, envelope, closure: nil, id: stale)
        XCTAssertEqual(made4.status, .ok, made4.body.string)
        let wrongRevision = try await carry(owner, envelope, stale, revision: 7)
        XCTAssertEqual(wrongRevision.status, .conflict)
        let unchanged = try await row(stale)
        XCTAssertEqual(try unchanged.decode(column: "status", as: String.self), "open")
        // A bad closure date is a 400, not a conflict.
        let badDate = try await carry(owner, envelope, stale, revision: 1, closedAt: "2014-01-01T00:00:00Z")
        XCTAssertEqual(badDate.status, .badRequest)
        let carriedNone = try await activity(stale)
        XCTAssertEqual(carriedNone, 0)
    }
}
