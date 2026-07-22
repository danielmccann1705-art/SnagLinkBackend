@testable import App
import XCTVapor
import Fluent
import JWT
import Foundation

// MARK: - Pure unit tests (no database)

final class SnagStatusUnitTests: XCTestCase {

    func testTenStateSet() {
        XCTAssertEqual(Set(SnagStatus.allCases.map { $0.rawValue }),
                       ["draft", "open", "sent", "opened", "cold", "submitted",
                        "awaitingApproval", "approved", "sentBack", "overdue"])
    }

    func testLegacyMapping() {
        XCTAssertEqual(SnagStatus.normalize("inProgress"), "sent")
        XCTAssertEqual(SnagStatus.normalize("readyForInspection"), "submitted")
        XCTAssertEqual(SnagStatus.normalize("closed"), "approved")
        XCTAssertEqual(SnagStatus.normalize("rejected"), "sentBack")
    }

    func testNewValuesPassThrough() {
        for s in ["draft", "open", "sent", "opened", "submitted", "awaitingApproval", "approved", "sentBack"] {
            XCTAssertEqual(SnagStatus.normalize(s), s)
        }
    }

    func testUnknownValuesPassThroughUnchanged() {
        // The web/completion flow's own vocabulary must survive untouched.
        XCTAssertEqual(SnagStatus.normalize("in_progress"), "in_progress")
        XCTAssertEqual(SnagStatus.normalize("resolved"), "resolved")
    }

    func testOverdueDerivation() {
        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3600)
        XCTAssertTrue(SnagStatus.isOverdue(dueDate: past, status: "sent"))
        XCTAssertFalse(SnagStatus.isOverdue(dueDate: past, status: "approved")) // approved is never overdue
        XCTAssertFalse(SnagStatus.isOverdue(dueDate: future, status: "sent"))
        XCTAssertFalse(SnagStatus.isOverdue(dueDate: nil, status: "sent"))
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B3: snag writes accept legacy + new status strings; the adapter maps legacy→new. Skipped
/// without `DATABASE_URL`; runs in CI (§5.T5).
final class SnagStatusBackcompatEndpointTests: XCTestCase {
    var app: Application!
    var dbAvailable: Bool { Environment.get("DATABASE_URL") != nil }

    override func setUp() async throws {
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        guard dbAvailable else { return }
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
    }

    private func makeUserWithProject() async throws -> (token: String, projectId: UUID) {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let project = Project(name: "P", reference: "P-\(UUID().uuidString.prefix(6))", ownerId: user.id!)
        try await project.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return (try app.jwt.signers.sign(payload), project.id!)
    }

    struct CreateBody: Content { let reference: String; let title: String; let projectId: UUID; let status: String }

    func testCreateMapsLegacyStatus() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (token, projectId) = try await makeUserWithProject()
        var createdId: UUID?

        try await app.test(.POST, "api/v1/snags", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateBody(reference: "S1", title: "Tile", projectId: projectId, status: "inProgress"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagResponse.self)
            XCTAssertEqual(body?.status, "sent") // inProgress → sent
            createdId = body?.id
        })

        let reloaded = try await Snag.find(createdId, on: app.db)
        XCTAssertEqual(reloaded?.status, "sent")
    }

    func testCreateAcceptsNewStatus() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (token, projectId) = try await makeUserWithProject()
        try await app.test(.POST, "api/v1/snags", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateBody(reference: "S2", title: "Paint", projectId: projectId, status: "submitted"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagResponse.self)
            XCTAssertEqual(body?.status, "submitted")
        })
    }

    func testUpdateMapsLegacyClosedToApproved() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (token, projectId) = try await makeUserWithProject()
        var snagId: UUID?
        try await app.test(.POST, "api/v1/snags", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateBody(reference: "S3", title: "Door", projectId: projectId, status: "open"))
        }, afterResponse: { res async in
            snagId = (try? res.content.decode(SnagResponse.self))?.id
        })

        try await app.test(.PATCH, "api/v1/snags/\(snagId!.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(["status": "closed"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagResponse.self)
            XCTAssertEqual(body?.status, "approved") // closed → approved
        })
    }
}
