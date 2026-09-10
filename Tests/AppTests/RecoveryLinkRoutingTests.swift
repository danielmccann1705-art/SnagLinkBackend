@testable import App
import XCTVapor
import Fluent

final class RecoveryLinkRoutingTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
    }

    private func report(pin: String? = nil) async throws -> MagicLink {
        let user = User(appleUserId: nil, email: "recovery-\(UUID())@example.com",
                        name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        let token = "recovery-\(UUID().uuidString.lowercased())"
        let snagId = UUID()
        let hashed = try pin.map { try PINVerificationService.hashPIN($0) }
        let link = MagicLink(token: token, accessLevel: .update,
                             pinHash: hashed?.hash, pinSalt: hashed?.salt,
                             expiresAt: Date().addingTimeInterval(3600),
                             snagIds: [snagId], projectId: UUID(), createdById: user.id!,
                             slug: "short-\(UUID().uuidString.lowercased())")
        try await link.save(on: app.db)
        let json = """
        {"projectName":"Synthetic recovery project","contractorName":"Test contractor",
         "snags":[{"id":"\(snagId)","title":"Synthetic private snag","status":"open"}]}
        """
        try await SyncedReport(magicLinkToken: token, reportJSON: json).save(on: app.db)
        return link
    }

    func testFullTokenAndShortSlugRenderTheSameReport() async throws {
        let link = try await report()
        for path in [link.token, link.slug!] {
            try await app.test(.GET, "m/\(path)", afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(response.body.string.contains("Synthetic private snag"))
                XCTAssertTrue(response.body.string.contains("Synthetic recovery project"))
            })
        }
    }

    func testAppClipCompatibilityRoutesResolveShortSlugToReport() async throws {
        let link = try await report()
        for token in [link.token, link.slug!] {
            try await app.test(.GET, "api/v1/magic-links/token/\(token)/validate", afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(try response.content.decode(MagicLinkValidationResponse.self).valid)
            })
            try await app.test(.GET, "api/v1/magic-links/\(token)/snags", afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try response.content.decode(SnagListResponse.self).snags.first?.title, "Synthetic private snag")
            })
        }
    }

    func testLegacyEmailRedirectsWithoutDisclosingPINProtectedReport() async throws {
        let link = try await report(pin: "1234")
        try await app.test(.GET, "link/\(link.token)", afterResponse: { response async in
            XCTAssertEqual(response.status, .temporaryRedirect)
            XCTAssertEqual(response.headers.first(name: .location), "/m/\(link.token)")
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
            XCTAssertFalse(response.body.string.contains("Synthetic private snag"))
        })
        try await app.test(.GET, "m/\(link.token)", afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.body.string.contains("csrf_token"))
            XCTAssertFalse(response.body.string.contains("Synthetic private snag"))
        })
    }

    func testExpiredAndRevokedLinksDoNotExposeReport() async throws {
        let expired = try await report()
        expired.expiresAt = Date().addingTimeInterval(-60)
        try await expired.save(on: app.db)
        let revoked = try await report()
        revoked.revokedAt = Date()
        try await revoked.save(on: app.db)
        for link in [expired, revoked] {
            try await app.test(.GET, "m/\(link.token)", afterResponse: { response async in
                XCTAssertFalse(response.body.string.contains("Synthetic private snag"))
                XCTAssertFalse(response.body.string.contains("Synthetic recovery project"))
            })
        }
    }

    func testSignInLandingDoesNotConsumeTokenDuringEmailScannerVisit() async throws {
        let raw = "synthetic-sign-in-\(UUID())"
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw),
                                      email: "synthetic@example.com",
                                      expiresAt: Date().addingTimeInterval(900))
        try await token.save(on: app.db)
        try await app.test(.GET, "auth/\(raw)", afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
        })
        let stored = try await MagicLinkAuthToken.find(token.id!, on: app.db)
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.consumedAt)
    }
    func testPINProtectsAPIAndCookieIsScopedToOneLink() async throws {
        let link = try await report(pin: "4826")
        let other = try await report(pin: "4826")
        for path in ["snags", "pdf"] {
            try await app.test(.GET, "api/v1/magic-links/\(link.token)/\(path)", afterResponse: { response async in
                XCTAssertEqual(response.status, .forbidden)
            })
        }
        try await app.test(.POST, "api/v1/magic-links/\(link.token)/snags/\(link.snagIds[0])/complete", beforeRequest: { req in
            try req.content.encode(["contractorName": "Synthetic contractor"])
        }, afterResponse: { response async in XCTAssertEqual(response.status, .forbidden) })
        try await app.test(.POST, "api/v1/uploads/photo?token=\(link.token)", afterResponse: { response async in
            XCTAssertEqual(response.status, .forbidden)
        })
        var cookie = ""
        try await app.test(.POST, "api/v1/magic-links/token/\(link.token)/verify-pin", beforeRequest: { req in
            try req.content.encode(["pin": "4826"])
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(try response.content.decode(PINVerificationResponse.self).verified)
            cookie = response.headers.first(name: .setCookie)?.components(separatedBy: ";").first ?? ""
            XCTAssertTrue(response.headers.first(name: .setCookie)?.contains("Path=/") == true)
        })
        XCTAssertFalse(cookie.isEmpty)
        for (candidate, expected) in [(link, HTTPStatus.ok), (other, .forbidden)] {
            try await app.test(.GET, "api/v1/magic-links/\(candidate.token)/snags", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .cookie, value: cookie)
            }, afterResponse: { response async in XCTAssertEqual(response.status, expected) })
        }
        link.revokedAt = Date()
        try await link.save(on: app.db)
        try await app.test(.GET, "api/v1/magic-links/\(link.token)/snags", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .cookie, value: cookie)
        }, afterResponse: { response async in XCTAssertNotEqual(response.status, .ok) })
    }

    func testPINSessionRejectsExpiredAndTamperedCookies() async throws {
        let link = try await report(pin: "4826")
        var response = Response()
        PINSessionService.attach(to: &response, link: link, now: Date().addingTimeInterval(-7300))
        let expired = response.cookies[PINSessionService.cookieName]!.string
        for value in [expired, "0:forged", "NaN:forged"] {
            try await app.test(.GET, "api/v1/magic-links/\(link.token)/snags", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .cookie, value: "snaglist_pin=\(value)")
            }, afterResponse: { response async in XCTAssertEqual(response.status, .forbidden) })
        }
    }

}
