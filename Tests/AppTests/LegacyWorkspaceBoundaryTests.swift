@testable import App
import XCTVapor
import Fluent
import JWT

final class LegacyWorkspaceBoundaryTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        let user = User(appleUserId: "test-\(UUID())", email: nil, name: "Synthetic")
        try await user.save(on: app.db); return user
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User, data: Data? = nil) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            if let data { req.headers.contentType = .json; req.body = ByteBuffer(data: data) }
        }, afterResponse: { response async in result = response })
        return result
    }

    func testLegacyListsAndDetailsDoNotExposeCompanyRecordsByCreatorID() async throws {
        let owner = try await user()
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Private company", actorID: owner.requireID(), on: db) }
        let project = Project(name: "Company-only site", reference: "COMPANY-SECRET", ownerId: try owner.requireID())
        project.workspaceId = try company.requireID(); try await project.save(on: app.db)
        let snag = Snag(reference: "COMPANY-SNAG", title: "Company-only defect", status: "submitted", projectId: try project.requireID(), ownerId: try owner.requireID())
        try await snag.save(on: app.db)
        let link = MagicLink(token: "test-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600), snagIds: [try snag.requireID()], projectId: try project.requireID(), createdById: try owner.requireID())
        try await link.save(on: app.db)
        for path in ["api/v1/projects", "api/v1/snags", "api/v1/approvals/pending", "api/v1/completions/pending"] {
            let response = try await request(.GET, path, user: owner)
            XCTAssertEqual(response.status, .ok, response.body.string)
            XCTAssertFalse(response.body.string.contains("COMPANY-"))
        }
        for path in ["api/v1/projects/\(try project.requireID())", "api/v1/snags/\(try snag.requireID())"] {
            let response = try await request(.GET, path, user: owner)
            XCTAssertEqual(response.status, .notFound)
        }
        let delete = try await request(.POST, "api/v1/snags/\(try snag.requireID())/deletion", user: owner,
                                       data: JSONSerialization.data(withJSONObject: ["projectId": try project.requireID().uuidString]))
        XCTAssertEqual(delete.status, .conflict)
        let stillPresent = try await Snag.find(snag.requireID(), on: app.db)
        XCTAssertNotNil(stillPresent)
    }

    func testBatchCreateChecksEveryProjectAndRollsBackWholeBatch() async throws {
        let owner = try await user(), other = try await user()
        let mine = Project(name: "Personal", reference: "P", ownerId: try owner.requireID())
        let theirs = Project(name: "Private", reference: "X", ownerId: try other.requireID())
        try await mine.save(on: app.db); try await theirs.save(on: app.db)
        let ids = [UUID(), UUID()]
        let rows = [["id": ids[0].uuidString, "reference": "S1", "title": "Allowed", "projectId": try mine.requireID().uuidString],
                    ["id": ids[1].uuidString, "reference": "S2", "title": "Forbidden", "projectId": try theirs.requireID().uuidString]]
        let response = try await request(.POST, "api/v1/snags/batch", user: owner, data: JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(response.status, .notFound)
        let count = try await Snag.query(on: app.db).filter(\.$id ~~ ids).count()
        XCTAssertEqual(count, 0)
    }

    func testLegacyUploadHonoursNativeSessionRevocation() async throws {
        let owner = try await user()
        try await app.db.transaction { db in try await BrowserSessionService.revokeAll(for: owner.requireID(), on: db) }
        let response = try await request(.POST, "api/v1/uploads/photo", user: owner)
        XCTAssertEqual(response.status, .unauthorized)
        XCTAssertEqual(response.headers.first(name: "Cache-Control"), "no-store")
    }
}
