@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Foundation

// MARK: - Pure unit tests (no database)

final class PreviewTokenUnitTests: XCTestCase {

    func testPreviewRequestRejectsEmptySnags() {
        let req = PreviewMagicLinkRequest(projectId: UUID(), snagIds: [], contractorName: nil, contractorId: nil)
        XCTAssertThrowsError(try req.validate())
    }

    func testPreviewRequestAcceptsSnags() {
        let req = PreviewMagicLinkRequest(projectId: UUID(), snagIds: [UUID()], contractorName: "Kendall", contractorId: nil)
        XCTAssertNoThrow(try req.validate())
    }

    func testPreviewExpiryDerivation() {
        let live = MagicLink(token: "t", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                             snagIds: [UUID()], projectId: UUID(), createdById: UUID(),
                             previewMode: true, previewExpiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(live.isPreviewExpired)

        let dead = MagicLink(token: "t", accessLevel: .update, expiresAt: Date().addingTimeInterval(-3600),
                             snagIds: [UUID()], projectId: UUID(), createdById: UUID(),
                             previewMode: true, previewExpiresAt: Date().addingTimeInterval(-3600))
        XCTAssertTrue(dead.isPreviewExpired)
    }

    func testRegularLinkDefaultsToNonPreview() {
        let ml = MagicLink(token: "t", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                           snagIds: [UUID()], projectId: UUID(), createdById: UUID())
        XCTAssertFalse(ml.previewMode)
        XCTAssertNil(ml.previewExpiresAt)
        XCTAssertFalse(ml.isPreviewExpired)
    }

    func testPreviewOverlayInjectionAnchorsOnBody() {
        let html = "<html><head></head><body style=\"x\"><h1>Report</h1></body></html>"
        let out = WebReportController.injectPreviewOverlay(into: html)
        XCTAssertTrue(out.contains("__snaglist_preview_banner"))
        // Banner must be injected before the closing body tag.
        let bannerIdx = out.range(of: "__snaglist_preview_banner")!.lowerBound
        let bodyCloseIdx = out.range(of: "</body>", options: .backwards)!.lowerBound
        XCTAssertLessThan(bannerIdx, bodyCloseIdx)
        // Original content preserved.
        XCTAssertTrue(out.contains("<h1>Report</h1>"))
    }
}

// MARK: - Endpoint / cleanup integration tests (require DATABASE_URL)

/// B2: preview-token creation, submission rejection, and cleanup. Skipped without `DATABASE_URL`;
/// runs in CI (§5.T5).
final class PreviewTokenEndpointTests: XCTestCase {
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

    /// Creates a persisted user and returns a signed JWT for it.
    private func makeUser() async throws -> (id: UUID, token: String) {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return (user.id!, try app.jwt.signers.sign(payload))
    }

    func testCreatePreviewRequiresAuth() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.POST, "api/v1/magic-links/preview", beforeRequest: { req in
            try req.content.encode(PreviewMagicLinkRequest(projectId: UUID(), snagIds: [UUID()], contractorName: nil, contractorId: nil))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testCreatePreviewReturnsTokenAndPersistsPreviewLink() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (_, token) = try await makeUser()
        let projectId = UUID()
        let snagId = UUID()

        struct Body: Content { let projectId: UUID; let snagIds: [UUID]; let contractorName: String? }
        var capturedToken: String?

        try await app.test(.POST, "api/v1/magic-links/preview", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(Body(projectId: projectId, snagIds: [snagId], contractorName: "Kendall Builds"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(PreviewMagicLinkResponse.self)
            XCTAssertNotNil(body)
            XCTAssertFalse(body?.previewToken.isEmpty ?? true)
            XCTAssertTrue(body?.previewURL.contains("/preview/") ?? false)
            capturedToken = body?.previewToken
        })

        let stored = try await MagicLink.query(on: app.db)
            .filter(\.$token == (capturedToken ?? "")).first()
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.previewMode, true)
        XCTAssertNotNil(stored?.previewExpiresAt)
        // ~1h TTL.
        if let exp = stored?.previewExpiresAt {
            let secs = exp.timeIntervalSinceNow
            XCTAssertGreaterThan(secs, 3000)
            XCTAssertLessThanOrEqual(secs, 3600)
        }
    }

    func testSubmitToPreviewLinkIsForbidden() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (ownerID, _) = try await makeUser()
        let snagId = UUID()
        let token = "preview-\(UUID().uuidString)"
        let ml = MagicLink(token: token, accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                           snagIds: [snagId], projectId: UUID(), createdById: ownerID,
                           previewMode: true, previewExpiresAt: Date().addingTimeInterval(3600))
        try await ml.save(on: app.db)

        try await app.test(.POST, "api/v1/magic-links/\(token)/snags/\(snagId.uuidString)/complete", beforeRequest: { req in
            try req.content.encode(["contractorName": "Test"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testCleanupRemovesExpiredPreviewLinksAndStagingData() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")

        let (ownerID, _) = try await makeUser()
        // Stage data while the link is live, then age the fixture.
        let deadToken = "expired-\(UUID().uuidString)"
        let dead = MagicLink(token: deadToken, accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                             snagIds: [UUID()], projectId: UUID(), createdById: ownerID,
                             previewMode: true, previewExpiresAt: Date().addingTimeInterval(-3600))
        try await dead.save(on: app.db)
        try await SyncedReport(magicLinkToken: deadToken, reportJSON: "{}").save(on: app.db)

        try await (app.db as! SQLDatabase).raw("UPDATE magic_links SET expires_at=NOW()-INTERVAL '1 hour' WHERE token=\(bind: deadToken)").run()

        // Live preview link must survive.
        let liveToken = "live-\(UUID().uuidString)"
        let live = MagicLink(token: liveToken, accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                             snagIds: [UUID()], projectId: UUID(), createdById: ownerID,
                             previewMode: true, previewExpiresAt: Date().addingTimeInterval(3600))
        try await live.save(on: app.db)

        try await CleanupService.runCleanup(app: app)

        let deadLink = try await MagicLink.query(on: app.db).filter(\.$token == deadToken).first()
        let deadReport = try await SyncedReport.query(on: app.db).filter(\.$magicLinkToken == deadToken).first()
        let liveLink = try await MagicLink.query(on: app.db).filter(\.$token == liveToken).first()

        XCTAssertNil(deadLink, "expired preview link should be purged")
        XCTAssertNil(deadReport, "expired preview staging data should be purged")
        XCTAssertNotNil(liveLink, "unexpired preview link must survive")
    }
}
