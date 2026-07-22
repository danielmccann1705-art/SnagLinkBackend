@testable import App
import XCTVapor
import Fluent
import JWT
import Foundation

// MARK: - Pure unit tests (no database)

final class ApprovalUnitTests: XCTestCase {

    func testSendBackReasonCases() {
        XCTAssertEqual(Set(SendBackReason.allCases.map { $0.rawValue }),
                       ["workIncomplete", "poorFinish", "wrongLocation", "needMorePhotos", "cannotVerify", "other"])
    }

    func testPendingStatuses() {
        XCTAssertEqual(ApprovalController.pendingStatuses, ["submitted", "awaitingApproval"])
    }

    func testSendBackRequestValidation() {
        XCTAssertNoThrow(try SendBackRequest(reason: .other, note: nil).validate())
        XCTAssertNoThrow(try SendBackRequest(reason: .poorFinish, note: "Redo the grout").validate())
        XCTAssertThrowsError(try SendBackRequest(reason: .other, note: String(repeating: "x", count: 1001)).validate())
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B5: approvals queue + approve/send-back. Skipped without `DATABASE_URL`; runs in CI (§5.T5).
final class ApprovalsControllerEndpointTests: XCTestCase {
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

    /// Creates a user + a project they own, returning (userId, jwt, projectId).
    private func makeUserWithProject() async throws -> (userId: UUID, token: String, projectId: UUID) {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let project = Project(name: "Riverside", reference: "RIV-\(UUID().uuidString.prefix(6))", ownerId: user.id!)
        try await project.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return (user.id!, try app.jwt.signers.sign(payload), project.id!)
    }

    @discardableResult
    private func seedSnag(status: String, ownerId: UUID, projectId: UUID) async throws -> Snag {
        let snag = Snag(reference: "S-\(UUID().uuidString.prefix(6))", title: "Cracked tile",
                        status: status, projectId: projectId, ownerId: ownerId)
        try await snag.save(on: app.db)
        return snag
    }

    func testPendingRequiresAuth() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.GET, "api/v1/approvals/pending", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testPendingReturnsOnlySubmittedAndAwaiting() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (userId, token, projectId) = try await makeUserWithProject()
        let submitted = try await seedSnag(status: "submitted", ownerId: userId, projectId: projectId)
        let awaiting = try await seedSnag(status: "awaitingApproval", ownerId: userId, projectId: projectId)
        _ = try await seedSnag(status: "open", ownerId: userId, projectId: projectId)

        try await app.test(.GET, "api/v1/approvals/pending", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(PendingApprovalsResponse.self)
            XCTAssertEqual(body?.totalCount, 2)
            let ids = Set(body?.approvals.map { $0.snagId } ?? [])
            XCTAssertTrue(ids.contains(submitted.id!))
            XCTAssertTrue(ids.contains(awaiting.id!))
        })
    }

    func testApproveSetsStatusApproved() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (userId, token, projectId) = try await makeUserWithProject()
        let snag = try await seedSnag(status: "submitted", ownerId: userId, projectId: projectId)

        try await app.test(.POST, "api/v1/approvals/\(snag.id!.uuidString)/approve", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagResponse.self)
            XCTAssertEqual(body?.status, "approved")
        })

        let reloaded = try await Snag.find(snag.id!, on: app.db)
        XCTAssertEqual(reloaded?.status, "approved")
        XCTAssertNotNil(reloaded?.closedAt)
    }

    func testApproveOtherUsersSnagIsNotFound() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (_, token, _) = try await makeUserWithProject()
        // Snag owned by a DIFFERENT user/project.
        let (otherId, _, otherProject) = try await makeUserWithProject()
        let snag = try await seedSnag(status: "submitted", ownerId: otherId, projectId: otherProject)

        try await app.test(.POST, "api/v1/approvals/\(snag.id!.uuidString)/approve", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testSendBackWithEachReasonSetsStatusAndRecords() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (userId, token, projectId) = try await makeUserWithProject()

        for reason in SendBackReason.allCases {
            let snag = try await seedSnag(status: "submitted", ownerId: userId, projectId: projectId)
            try await app.test(.POST, "api/v1/approvals/\(snag.id!.uuidString)/send-back", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SendBackRequest(reason: reason, note: "note for \(reason.rawValue)"))
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok, "send-back should succeed for \(reason.rawValue)")
                let body = try? res.content.decode(SnagResponse.self)
                XCTAssertEqual(body?.status, "sentBack")
            })

            let reloaded = try await Snag.find(snag.id!, on: app.db)
            XCTAssertEqual(reloaded?.status, "sentBack")
            let record = try await SnagSendBack.query(on: app.db).filter(\.$snagId == snag.id!).first()
            XCTAssertEqual(record?.reason, reason.rawValue)
        }
    }
}
