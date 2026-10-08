@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Report contract v1 (`LANE-D-BACKEND.md` §0): preview stores nothing, issue stores an
/// immutable record once per operation, history and download respect project access,
/// names resolve on read, and the record goes with its project at account deletion.
final class IssuedReportTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws {
        if let app {
            if let sql = try? VerifiedIdentityService.sql(app.db) {
                try? await sql.raw("""
                    DELETE FROM measurement_dispatch_jobs j USING users u
                    WHERE j.account_id=u.id AND u.email LIKE 'report-%@example.test'
                    """).run()
                try? await sql.raw("""
                    DELETE FROM measurement_product_events e USING users u
                    WHERE e.account_id=u.id AND u.email LIKE 'report-%@example.test'
                    """).run()
            }
            try await app.asyncShutdown()
        }
    }

    private func user(_ name: String = "Synthetic manager") async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("report-\(UUID())@example.test", name: name, on: db) }
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
    private func metadata(_ operation: UUID = UUID()) -> [String: Any] { ["operationId": operation.uuidString, "deviceId": UUID().uuidString] }
    private func project(_ owner: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Willow Construction", actorID: owner.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
        }
        let body: [String: Any] = ["mutation": metadata(), "workspaceId": try workspace.requireID().uuidString,
                                   "project": ["id": UUID().uuidString, "name": "Willow Mews <Plot 9>", "reference": "WM09", "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, project: PlatformProjectResponse, fields: [String: Any]) async throws -> UUID {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
                                         body: ["mutation": metadata(), "id": UUID().uuidString, "fields": fields])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self).snag.id
    }
    private func join(_ member: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: member.requireID(), on: db) }
    }
    private func path(_ project: PlatformProjectResponse) -> String { "api/v2/projects/\(project.project.id)/reports" }
    private func grantProductAnalytics(_ user: User) async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
        try await FeatureFlag(key: "productAnalyticsEnabled", enabled: true).save(on: app.db)
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", user: user, body: [
            "requestId": UUID().uuidString, "decision": "granted",
            "occurredAt": ISO8601DateFormatter().string(from: Date())
        ])
        XCTAssertEqual(response.status, .ok, response.body.string)
    }

    func testIssueStoresOneImmutableRecordPerOperationAndHistoryDownloadAgree() async throws {
        let owner = try await user("Dana <Site> Manager"), envelope = try await project(owner)
        let late = try await snag(owner, project: envelope, fields: ["title": "Reseal <bath> & tray", "location": "Plot 9 · Bathroom", "dueOn": "2020-01-01"])
        let waiting = try await snag(owner, project: envelope, fields: ["title": "Door closer", "dueOn": "2020-01-02"])
        _ = try await snag(owner, project: envelope, fields: ["title": "Paint reveal"])
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE snags SET status = 'awaiting_review' WHERE id = \(bind: waiting)").run()

        // Preview: built, not stored.
        let preview = try await request(.POST, path(envelope) + "/preview", user: owner, body: ["title": "Handover", "scope": ["q": " "]])
        XCTAssertEqual(preview.status, .ok, preview.body.string)
        let previewed = try preview.content.decode(IssuedReportDetail.self)
        XCTAssertNil(previewed.report)
        XCTAssertEqual(previewed.snapshot.items.count, 3)
        XCTAssertEqual(previewed.snapshot.summary, ReportSummary(total: 3, open: 2, overdue: 1, awaitingReview: 1, closed: 0, legacyUnverified: 0))
        XCTAssertEqual(previewed.snapshot.scope, ReportScope(), "blank filters normalise away")
        var stored = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM issued_reports WHERE project_id = \(bind: envelope.project.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(stored, 0)

        // Issue twice with one operation id: one record.
        let operation = UUID()
        let body: [String: Any] = ["mutation": metadata(operation), "title": "  Plot 9 handover\n", "scope": ["due": "overdue"]]
        let first = try await request(.POST, path(envelope), user: owner, body: body)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let issued = try first.content.decode(IssuedReportResponse.self)
        let again = try await request(.POST, path(envelope), user: owner, body: body).content.decode(IssuedReportResponse.self)
        XCTAssertEqual(again, issued)
        XCTAssertEqual(issued.reference, "RPT-001"); XCTAssertEqual(issued.title, "Plot 9 handover")
        XCTAssertEqual(issued.snagCount, 1); XCTAssertEqual(issued.summary.overdue, 1)
        XCTAssertEqual(issued.issuedBy.name, "Dana <Site> Manager"); XCTAssertFalse(issued.issuedBy.former)
        let reused = try await request(.POST, path(envelope), user: owner, body: ["mutation": metadata(operation), "scope": [:] as [String: Any]])
        XCTAssertEqual(reused.status, .conflict)
        stored = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM issued_reports WHERE project_id = \(bind: envelope.project.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(stored, 1)

        // A second report numbers on; history is newest first.
        let second = try await request(.POST, path(envelope), user: owner, body: ["mutation": metadata(), "scope": [:] as [String: Any]]).content.decode(IssuedReportResponse.self)
        XCTAssertEqual(second.reference, "RPT-002"); XCTAssertEqual(second.title, IssuedReportService.defaultTitle)
        let history = try await request(.GET, path(envelope), user: owner).content.decode(IssuedReportPage.self)
        XCTAssertEqual(history.items.map(\.reference), ["RPT-002", "RPT-001"]); XCTAssertFalse(history.hasMore)

        // The stored snapshot is what was issued, and it does not change when the register does.
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE snags SET title = 'Renamed later' WHERE id = \(bind: late)").run()
        let detail = try await request(.GET, path(envelope) + "/\(issued.id)", user: owner).content.decode(IssuedReportDetail.self)
        XCTAssertEqual(detail.report, issued)
        XCTAssertEqual(detail.snapshot.items.map(\.snagId), [late])
        XCTAssertEqual(detail.snapshot.items.first?.title, "Reseal <bath> & tray")
        XCTAssertEqual(detail.snapshot.items.first?.overdue, true)
        let reencoded = try IssuedReportService.encode(detail.snapshot)
        XCTAssertEqual(PrivateImageProcessor.digest(Data(reencoded.utf8)), issued.snapshotSha256)
        let snapshotText = try await VerifiedIdentityService.sql(app.db).raw("SELECT snapshot_json FROM issued_reports WHERE id = \(bind: issued.id)").first()!.decode(column: "snapshot_json", as: String.self)
        XCTAssertFalse(snapshotText.contains("Dana"), "no person's name is stored in the record")

        // Download: escaped, self-contained, fingerprinted.
        let download = try await request(.GET, path(envelope) + "/\(issued.id)/download", user: owner)
        XCTAssertEqual(download.status, .ok)
        XCTAssertEqual(download.headers.first(name: "X-Snaglist-Report-Sha256"), issued.snapshotSha256)
        XCTAssertEqual(download.headers.first(name: "Content-Security-Policy"), IssuedReportRenderer.contentSecurityPolicy)
        XCTAssertEqual(download.headers.first(name: .contentDisposition), "attachment; filename=\"WM09-RPT-001.html\"")
        let html = download.body.string
        XCTAssertTrue(html.contains("Reseal &lt;bath&gt; &amp; tray")); XCTAssertFalse(html.contains("<bath>"))
        XCTAssertTrue(html.contains("Dana &lt;Site&gt; Manager"))
        XCTAssertFalse(html.contains("<script")); XCTAssertFalse(html.contains("src="))
        XCTAssertTrue(html.contains(issued.snapshotSha256))

        // Immutable in the database as well as through the API.
        do {
            try await VerifiedIdentityService.sql(app.db).raw("UPDATE issued_reports SET title = 'Edited' WHERE id = \(bind: issued.id)").run()
            XCTFail("An issued report must refuse updates")
        } catch {}
    }

    func testPermissionsFollowTheProjectPolicy() async throws {
        let owner = try await user(), envelope = try await project(owner, company: true)
        _ = try await snag(owner, project: envelope, fields: ["title": "Skirting gap"])
        // Invitations grant project Manager or Member; a Member (read, edit, submit) stands for
        // every role without `review`, including Viewer, which the policy gives `read` only.
        let member = try await user("Synthetic member"), manager = try await user("Synthetic project manager")
        try await join(member, owner: owner, project: envelope, role: "member")
        try await join(manager, owner: owner, project: envelope, role: "manager")
        let issued = try await request(.POST, path(envelope), user: manager, body: ["mutation": metadata(), "scope": [:] as [String: Any]])
        XCTAssertEqual(issued.status, .ok, issued.body.string)
        let report = try issued.content.decode(IssuedReportResponse.self)
        for reader in [member] {
            do { let status = try await request(.POST, path(envelope), user: reader, body: ["mutation": metadata(), "scope": [:] as [String: Any]]).status; XCTAssertEqual(status, .forbidden) }
            do { let status = try await request(.POST, path(envelope) + "/preview", user: reader, body: ["scope": [:] as [String: Any]]).status; XCTAssertEqual(status, .ok) }
            do { let status = try await request(.GET, path(envelope), user: reader).status; XCTAssertEqual(status, .ok) }
            do { let status = try await request(.GET, path(envelope) + "/\(report.id)/download", user: reader).status; XCTAssertEqual(status, .ok) }
        }
        let stranger = try await user()
        do { let status = try await request(.GET, path(envelope), user: stranger).status; XCTAssertEqual(status, .notFound) }
        do { let status = try await request(.GET, path(envelope) + "/\(report.id)", user: stranger).status; XCTAssertEqual(status, .notFound) }
        do { let status = try await request(.GET, path(envelope) + "/\(report.id)/download", user: stranger).status; XCTAssertEqual(status, .notFound) }
        // A report id from another project is not found under this one.
        let other = try await project(owner)
        do { let status = try await request(.GET, "api/v2/projects/\(other.project.id)/reports/\(report.id)", user: owner).status; XCTAssertEqual(status, .notFound) }
        do { let status = try await request(.POST, path(envelope) + "/preview", user: owner, body: ["scope": ["status": "bogus"]]).status; XCTAssertEqual(status, .badRequest) }

        // A deleted member is named "Former member" when the record is read later.
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET lifecycle_state='deleted',name=NULL,email=NULL,apple_user_id=NULL,auth_version=auth_version+1 WHERE id=\(bind: manager.requireID())").run()
        let read = try await request(.GET, path(envelope) + "/\(report.id)", user: owner).content.decode(IssuedReportDetail.self)
        XCTAssertEqual(read.report?.issuedBy.name, "Former member"); XCTAssertEqual(read.report?.issuedBy.former, true)
    }

    func testReportIssuedRecordsOnlyNewDurableIssueWithOriginalReceiptTime() async throws {
        let owner = try await user(), ownerID = try owner.requireID(), envelope = try await project(owner)
        _ = try await snag(owner, project: envelope, fields: ["title": "Synthetic sealant check"])
        try await grantProductAnalytics(owner)

        let preview = try await request(.POST, path(envelope) + "/preview", user: owner,
                                        body: ["scope": [:] as [String: Any]])
        XCTAssertEqual(preview.status, .ok, preview.body.string)
        let sql = try VerifiedIdentityService.sql(app.db)
        var count = try await sql.raw("SELECT count(*) AS n FROM measurement_product_events WHERE account_id=\(bind:ownerID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 0)

        let operation = UUID(), device = UUID()
        let body: [String: Any] = [
            "mutation": ["operationId": operation.uuidString, "deviceId": device.uuidString],
            "scope": [:] as [String: Any]
        ]
        let first = try await request(.POST, path(envelope), user: owner, body: body)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let replay = try await request(.POST, path(envelope), user: owner, body: body)
        XCTAssertEqual(replay.status, .ok, replay.body.string)

        let storedEvent = try await sql.raw("""
            SELECT event_name,properties::text AS properties,occurred_at,installation_id
            FROM measurement_product_events WHERE account_id=\(bind:ownerID)
            """).first()
        let row = try XCTUnwrap(storedEvent)
        XCTAssertEqual(try row.decode(column: "event_name", as: String.self), "report_issued")
        XCTAssertEqual(try row.decode(column: "properties", as: String.self), "{}")
        XCTAssertEqual(try row.decode(column: "installation_id", as: UUID.self), device)
        let receiptAt = try await sql.raw("""
            SELECT created_at FROM mutation_receipts
            WHERE actor_id=\(bind:ownerID) AND operation_id=\(bind:operation)
            """).first()!.decode(column: "created_at", as: Date.self)
        XCTAssertEqual(try row.decode(column: "occurred_at", as: Date.self), receiptAt)
        count = try await sql.raw("SELECT count(*) AS n FROM measurement_product_events WHERE account_id=\(bind:ownerID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
        let payload = try await sql.raw("""
            SELECT payload::text AS payload FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:ownerID) AND source_kind='productEvent'
            """).first()!.decode(column: "payload", as: String.self)
        XCTAssertFalse(payload.contains(envelope.project.id.uuidString))
        XCTAssertFalse(payload.contains(operation.uuidString))
        XCTAssertFalse(payload.contains(try first.content.decode(IssuedReportResponse.self).id.uuidString))
    }

    func testAccountDeletionRemovesPersonalReportsWithTheProject() async throws {
        let owner = try await user(), envelope = try await project(owner)
        _ = try await snag(owner, project: envelope, fields: ["title": "Sealant bead"])
        do { let status = try await request(.POST, path(envelope), user: owner, body: ["mutation": metadata(), "scope": [:] as [String: Any]]).status; XCTAssertEqual(status, .ok) }
        let reference = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        _ = try await AccountDeletionService.request(userID: owner.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference), app: app)
        let remaining = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM issued_reports WHERE project_id = \(bind: envelope.project.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(remaining, 0)
    }
}
