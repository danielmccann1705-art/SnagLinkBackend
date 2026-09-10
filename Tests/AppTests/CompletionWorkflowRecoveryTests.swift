@testable import App
import XCTVapor
import Fluent
import JWT

final class CompletionWorkflowRecoveryTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testBothManagerApprovalRoutesUpdateCanonicalAndSharedStatus() async throws {
        for useSnagRoute in [false, true] {
            let user = User(appleUserId: nil, email: "workflow-\(UUID())@example.com", name: "Manager", authProvider: .magicLink)
            try await user.save(on: app.db)
            let project = Project(name: "Synthetic project", reference: "TEST", ownerId: user.id!)
            try await project.save(on: app.db)
            let snag = Snag(reference: "SN-001", title: "Synthetic snag", projectId: project.id!, ownerId: user.id!)
            try await snag.save(on: app.db)
            let link = MagicLink(token: "workflow-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600), snagIds: [snag.id!], projectId: project.id!, createdById: user.id!)
            try await link.save(on: app.db)
            let original = "{\"snags\":[{\"id\":\"\(snag.id!)\",\"title\":\"Synthetic snag\",\"status\":\"open\"}]}"
            try await SyncedReport(magicLinkToken: link.token, reportJSON: original).save(on: app.db)
            let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: user.id!.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: user.id!))
            var completionId: UUID!
            try await app.test(.POST, "api/v1/magic-links/\(link.token)/snags/\(snag.id!)/complete", beforeRequest: { req in
                try req.content.encode(["contractorName": "Synthetic contractor"])
            }, afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                completionId = (try? response.content.decode(CompletionActionResponse.self))?.completionId
                XCTAssertNotNil(completionId)
            })
            let submitted = try await Snag.find(snag.id!, on: app.db)
            XCTAssertEqual(submitted?.status, "submitted")
            let route = useSnagRoute ? "api/v1/approvals/\(snag.id!)/approve" : "api/v1/completions/\(completionId!)/approve"
            try await app.test(.POST, route, beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: jwt)
                try req.content.encode(["reviewerName": "Manager"])
            }, afterResponse: { response async in XCTAssertEqual(response.status, .ok) })
            let approved = try await Snag.find(snag.id!, on: app.db)
            XCTAssertEqual(approved?.status, "approved")
            XCTAssertNotNil(approved?.closedAt)
            let completion = try await Completion.find(completionId, on: app.db)
            XCTAssertEqual(completion?.status, .approved)
            // Simulate an old device uploading its pre-completion snapshot.
            try await app.test(.POST, "api/v1/magic-links/\(link.token)/report", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: jwt)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: original)
            }, afterResponse: { response async in XCTAssertEqual(response.status, .ok) })
            try await app.test(.GET, "api/v1/magic-links/\(link.token)/snags", afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try response.content.decode(SnagListResponse.self).snags.first?.status, "approved")
            })
        }
    }
}
