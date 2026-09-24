@testable import App
import XCTVapor

/// The page a sign-in link shows when it opens in a browser instead of the app.
/// It cannot sign anyone in, so it must not pretend to: no `snaglist://` button (the
/// app accepts sign-in links only as https links), no copy of the token, and the two
/// things that do work. No database.
final class SignInLinkFallbackPageTests: XCTestCase {
    func testThePageOffersNoCustomSchemeButtonAndNamesWhatWorks() {
        for isIOS in [true, false] {
            let html = MagicLinkLandingRenderer.render(isIOS: isIOS)
            XCTAssertFalse(html.contains("snaglist://"), "isIOS=\(isIOS)")
            XCTAssertFalse(html.contains("<a "), "nothing to tap: the page cannot sign in")
            XCTAssertFalse(html.contains("<script"))
            XCTAssertFalse(html.contains("<form"))
            XCTAssertTrue(html.contains("can’t sign you in"))
            XCTAssertTrue(html.contains("On the iPhone where Snaglist is installed, open the email in Mail and tap the sign-in link there."))
            XCTAssertTrue(html.contains("request a new sign-in link"))
            XCTAssertTrue(html.contains(MagicLinkLandingRenderer.expiryNote))
            XCTAssertFalse(html.lowercased().contains("soon"))
        }
        XCTAssertTrue(MagicLinkLandingRenderer.render(isIOS: true).contains("<h1>Open this link in the Snaglist app</h1>"))
        XCTAssertTrue(MagicLinkLandingRenderer.render(isIOS: false).contains("<h1>Open this link on your iPhone</h1>"))
    }
}

/// `GET /auth/:token` end to end. The token is in the URL and must appear nowhere in
/// the response, on an iPhone or a computer; the page is not cached and sends no referrer.
final class SignInLinkFallbackRouteTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testTheLandingNeverEchoesTheTokenAndIsNotCached() async throws {
        let raw = "SyntheticSignInToken" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let agents = [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        ]
        for agent in agents {
            try await app.test(.GET, "auth/\(raw)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .userAgent, value: agent)
            }, afterResponse: { response async in
                XCTAssertEqual(response.status, .ok)
                let body = response.body.string
                XCTAssertFalse(body.contains(raw))
                XCTAssertFalse(body.contains(String(raw.suffix(16))), "not even part of it")
                XCTAssertFalse(body.contains("snaglist://"))
                XCTAssertTrue(body.contains(agent.contains("iPhone") ? "Open this link in the Snaglist app" : "Open this link on your iPhone"))
                XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
                XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
                XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertTrue(response.headers.first(name: "Content-Security-Policy")?.contains("default-src 'none'") == true)
                XCTAssertEqual(response.headers.first(name: .contentType), "text/html; charset=utf-8")
            })
        }
    }
}
