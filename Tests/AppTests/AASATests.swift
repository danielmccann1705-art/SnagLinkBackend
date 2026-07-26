@testable import App
import XCTVapor
import Foundation

/// B7: the Apple App Site Association file must be served at the well-known path with
/// `application/json`, include the magic-link `/auth/*` path (and keep `/m/*`), and carry the
/// app's TEAMID-qualified appID. No database required.
final class AASATests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testAASAServedWithAuthPath() async throws {
        try await app.test(.GET, ".well-known/apple-app-site-association", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let contentType = res.headers.first(name: .contentType) ?? ""
            XCTAssertTrue(contentType.contains("application/json"), "AASA must be application/json, got \(contentType)")
            let body = res.body.string
            XCTAssertTrue(body.contains("/auth/*"), "AASA must include the /auth/* universal-link path")
            XCTAssertTrue(body.contains("/m/*"), "AASA must keep the /m/* contractor path")
            XCTAssertTrue(body.contains("52ZZHYHM62.com.snaglist.app"))
        })
    }
}
