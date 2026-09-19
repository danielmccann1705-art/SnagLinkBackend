@testable import App
import XCTVapor
import Fluent
import JWT

/// Uses only newly created fixtures in the explicitly configured disposable database.
final class ContentReportEndpointTests: XCTestCase {
    private var app: Application!
    private var userIDs: [UUID] = []
    private var projectIDs: [UUID] = []
    private var linkIDs: [UUID] = []
    private var completionIDs: [UUID] = []
    private var previousModeratorIDs: String?

    override func setUp() async throws {
        previousModeratorIDs = Environment.get("MODERATOR_USER_IDS")
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil, "Requires isolated PostgreSQL DATABASE_URL")
        unsetenv("MODERATOR_USER_IDS")
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        defer {
            if let previousModeratorIDs { setenv("MODERATOR_USER_IDS", previousModeratorIDs, 1) }
            else { unsetenv("MODERATOR_USER_IDS") }
            app = nil
            userIDs = []; projectIDs = []; linkIDs = []; completionIDs = []
        }
        guard let app else { return }
        do {
            if !completionIDs.isEmpty {
                try await ContentReport.query(on: app.db).filter(\.$completionId ~~ completionIDs).delete()
                try await CompletionPhoto.query(on: app.db).filter(\.$completion.$id ~~ completionIDs).delete()
                try await Completion.query(on: app.db).filter(\.$id ~~ completionIDs).delete()
            }
            if !linkIDs.isEmpty { try await MagicLink.query(on: app.db).filter(\.$id ~~ linkIDs).delete() }
            if !projectIDs.isEmpty { try await Project.query(on: app.db).filter(\.$id ~~ projectIDs).delete() }
            if !userIDs.isEmpty {
                let keys = userIDs.map { "content_report:\($0)" }
                try await RateLimitEntry.query(on: app.db).filter(\.$key ~~ keys).delete()
                try await User.query(on: app.db).filter(\.$id ~~ userIDs).delete()
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func account() async throws -> (id: UUID, jwt: String) {
        let user = User(appleUserId: nil, email: "report-\(UUID().uuidString.lowercased())@example.test",
                        name: "Report test", authProvider: .magicLink)
        try await user.save(on: app.db)
        let id = try user.requireID()
        userIDs.append(id)
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(600)), userId: id))
        return (id, token)
    }

    private func completion(ownerID: UUID) async throws -> Completion {
        let project = Project(name: "Reporting test", reference: "R", ownerId: ownerID)
        try await project.save(on: app.db)
        let projectID = try project.requireID()
        projectIDs.append(projectID)
        let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
                             expiresAt: Date().addingTimeInterval(600), snagIds: [UUID()],
                             projectId: projectID, createdById: ownerID)
        try await link.save(on: app.db)
        let linkID = try link.requireID()
        linkIDs.append(linkID)
        let completion = Completion(snagId: link.snagIds[0], magicLinkId: linkID,
                                    contractorName: "Test contractor", notes: "Test completion evidence")
        try await completion.save(on: app.db)
        completionIDs.append(try completion.requireID())
        return completion
    }

    private func report(_ id: UUID, completionID: UUID, jwt: String?,
                        reason: String = "Other", details: String = "Please review",
                        status: HTTPResponseStatus) async throws {
        try await app.test(.POST, "api/v1/completions/\(completionID)/report", beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            try req.content.encode(ContentReportController.ReportRequest(id: id, reason: reason, details: details))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, status)
            if status == .ok {
                let receipt = try? res.content.decode(ContentReportController.Receipt.self)
                XCTAssertEqual(receipt?.id, id)
                XCTAssertEqual(receipt?.success, true)
            }
        })
    }

    func testOnlyCompletionOwnerCanReportAndCannotReuseAnotherOwnersReceipt() async throws {
        let owner = try await account(), other = try await account()
        let ownCompletion = try await completion(ownerID: owner.id)
        let otherCompletion = try await completion(ownerID: other.id)
        let ownID = try ownCompletion.requireID(), otherID = try otherCompletion.requireID(), reportID = UUID()

        try await report(reportID, completionID: ownID, jwt: nil, status: .unauthorized)
        try await report(reportID, completionID: ownID, jwt: other.jwt, status: .notFound)
        try await report(reportID, completionID: ownID, jwt: owner.jwt, status: .ok)
        try await report(reportID, completionID: otherID, jwt: other.jwt, status: .conflict)

        let retained = try await ContentReport.find(reportID, on: app.db)
        XCTAssertEqual(retained?.reporterId, owner.id)
        XCTAssertEqual(retained?.completionId, ownID)
    }

    func testExactRetryIsIdempotentAndChangedBodyOrCompletionConflicts() async throws {
        let owner = try await account()
        let first = try await completion(ownerID: owner.id), second = try await completion(ownerID: owner.id)
        let firstID = try first.requireID(), secondID = try second.requireID(), id = UUID()
        try await report(id, completionID: firstID, jwt: owner.jwt, details: "  Please review\n", status: .ok)
        try await report(id, completionID: firstID, jwt: owner.jwt, status: .ok)
        let firstCount = try await ContentReport.query(on: app.db).filter(\.$completionId == firstID).count()
        XCTAssertEqual(firstCount, 1)
        try await report(id, completionID: firstID, jwt: owner.jwt, reason: "Harassment or Abuse", status: .conflict)
        try await report(id, completionID: firstID, jwt: owner.jwt, details: "Changed details", status: .conflict)
        try await report(id, completionID: secondID, jwt: owner.jwt, status: .conflict)
        // A separate deliberate submission uses a new reference and is accepted.
        try await report(UUID(), completionID: firstID, jwt: owner.jwt, details: "Additional concern", status: .ok)
        let count = try await ContentReport.query(on: app.db).filter(\.$completionId == firstID).count()
        XCTAssertEqual(count, 2)
        let original = try await ContentReport.find(id, on: app.db)
        XCTAssertEqual(original?.reason, "Other")
        XCTAssertEqual(original?.details, "Please review")
    }

    func testInvalidReportBodyDoesNotCreateRecord() async throws {
        let owner = try await account(), completion = try await completion(ownerID: owner.id)
        let id = try completion.requireID()
        try await report(UUID(), completionID: id, jwt: owner.jwt, reason: "Unsupported", status: .badRequest)
        try await report(UUID(), completionID: id, jwt: owner.jwt,
                         details: String(repeating: "x", count: 4001), status: .badRequest)
        let count = try await ContentReport.query(on: app.db).filter(\.$completionId == id).count()
        XCTAssertEqual(count, 0)
    }

    func testOnlyModeratorCanReadEvidenceAndBlockReportedLink() async throws {
        let owner = try await account(), moderator = try await account()
        let target = try await completion(ownerID: owner.id), unrelated = try await completion(ownerID: owner.id)
        let targetID = try target.requireID(), unrelatedID = try unrelated.requireID(), reportID = UUID()
        let targetPhotoURL = "https://example.test/reported.jpg"
        try await HistoricalCompletionPhotoFixture.insert(completionID:targetID,url:targetPhotoURL,on:app.db)
        try await HistoricalCompletionPhotoFixture.insert(completionID:unrelatedID,url:"https://example.test/unrelated.jpg",on:app.db)
        try await report(reportID, completionID: targetID, jwt: owner.jwt, status: .ok)
        let path = "api/v1/moderation/reports/\(reportID)"

        for endpoint in ["api/v1/moderation/reports", path] {
            try await app.test(.GET, endpoint, beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.jwt)
            }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
        }
        try await app.test(.POST, "\(path)/resolve", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: owner.jwt)
            try req.content.encode(ContentReportController.Resolution(blockLink: true))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })

        setenv("MODERATOR_USER_IDS", moderator.id.uuidString, 1)
        try await app.test(.GET, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: moderator.jwt)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let evidence = try? res.content.decode(ContentReportController.Evidence.self)
            XCTAssertEqual(evidence?.report.id, reportID)
            XCTAssertEqual(evidence?.contractorName, "Test contractor")
            XCTAssertEqual(evidence?.notes, "Test completion evidence")
            XCTAssertEqual(evidence?.photos.map(\.url), [targetPhotoURL])
        })
        try await app.test(.POST, "\(path)/resolve", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: moderator.jwt)
            try req.content.encode(ContentReportController.Resolution(blockLink: true))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })
        let blocked = try await MagicLink.find(target.magicLinkId, on: app.db)
        let retained = try await MagicLink.find(unrelated.magicLinkId, on: app.db)
        let resolved = try await ContentReport.find(reportID, on: app.db)
        XCTAssertNotNil(blocked?.revokedAt)
        XCTAssertNil(retained?.revokedAt)
        XCTAssertEqual(resolved?.status, "link_blocked")
        XCTAssertNotNil(resolved?.resolvedAt)
        try await app.test(.GET, "api/v1/moderation/reports", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: moderator.jwt)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let reports = try? res.content.decode([ContentReport].self)
            XCTAssertNotNil(reports)
            XCTAssertFalse(reports?.contains(where: { $0.id == reportID }) ?? true)
        })
    }
}
