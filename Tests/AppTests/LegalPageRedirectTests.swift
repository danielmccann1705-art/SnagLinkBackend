@testable import App
import XCTVapor
import Foundation

/// There is one privacy policy and one set of terms, and they are published on the
/// customer website. This host used to render a second copy that nothing linked to
/// and that drifted away from the page Apple is given. These tests hold the rule
/// that it redirects rather than restates.
final class LegalPageRedirectTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testPrivacyRedirectsPermanentlyToThePublishedPolicy() async throws {
        try await app.test(.GET, "privacy", afterResponse: { res async in
            XCTAssertEqual(res.status, .movedPermanently)
            XCTAssertEqual(res.headers.first(name: .location), "https://usesnaglist.com/privacy")
        })
    }

    func testTermsRedirectsPermanentlyToThePublishedTerms() async throws {
        try await app.test(.GET, "terms", afterResponse: { res async in
            XCTAssertEqual(res.status, .movedPermanently)
            XCTAssertEqual(res.headers.first(name: .location), "https://usesnaglist.com/terms")
        })
    }

    /// Neither route may answer with a policy of its own again. A body that carries
    /// policy text is the drift this change exists to remove.
    func testNeitherRouteServesAPolicyOfItsOwn() async throws {
        for path in ["privacy", "terms"] {
            try await app.test(.GET, path, afterResponse: { res async in
                let body = res.body.string
                XCTAssertFalse(body.localizedCaseInsensitiveContains("Privacy Policy"), "\(path) must not restate the policy")
                XCTAssertFalse(body.localizedCaseInsensitiveContains("Hetzner"))
                XCTAssertFalse(body.localizedCaseInsensitiveContains("snaglist.dev"), "no hop through a second redirector")
            })
        }
    }

    /// The destinations are the ones the app compiles in and the ones App Store
    /// Connect is given. If these move, all three move together.
    func testTheDestinationsAreTheCanonicalPublishedPages() {
        XCTAssertEqual(LegalPageRedirect.privacyURL, "https://usesnaglist.com/privacy")
        XCTAssertEqual(LegalPageRedirect.termsURL, "https://usesnaglist.com/terms")
    }
}
