@testable import App
import XCTVapor
import Foundation

/// B7: the Apple App Site Association file must be served at the well-known path with
/// `application/json`, claim the magic-link `/auth/*` path, and carry the app's
/// TEAMID-qualified appID.
///
/// It must NOT claim `/m/*`. That is the Contractor link: a contractor opens it in a
/// browser with no account and no app, and a manager with Snaglist installed who taps
/// the same link has to reach the same page rather than a screen the app holds no
/// session for. Nor may it name an App Clip, because v2 ships none and Apple caches
/// this file. No database required.
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
            XCTAssertTrue(body.contains("52ZZHYHM62.com.snaglist.app"))
        })
    }

    /// A Contractor link has to open in the browser it was designed for.
    func testAASADoesNotClaimTheContractorLinkOrAnAppClip() async throws {
        try await app.test(.GET, ".well-known/apple-app-site-association", afterResponse: { res async in
            let body = res.body.string
            XCTAssertFalse(body.contains("/m/*"), "claiming /m/* opens a Contractor link in the app instead of a browser")
            XCTAssertFalse(body.contains("appclips"), "v2 ships no App Clip and Apple caches this file")
            XCTAssertFalse(body.contains(".Clip"), "no App Clip target may be named")
        })
    }

    /// The file has to be valid JSON with the shape Apple expects, not merely a body
    /// that happens to contain the right substrings.
    func testAASAIsValidJSONWithApplinksDetails() async throws {
        try await app.test(.GET, ".well-known/apple-app-site-association", afterResponse: { res async in
            guard let data = res.body.string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return XCTFail("AASA is not valid JSON")
            }
            guard let applinks = object["applinks"] as? [String: Any],
                  let details = applinks["details"] as? [[String: Any]], details.count == 1 else {
                return XCTFail("AASA must carry exactly one applinks detail")
            }
            XCTAssertEqual(details[0]["appIDs"] as? [String], ["52ZZHYHM62.com.snaglist.app"])
            let components = details[0]["components"] as? [[String: String]] ?? []
            XCTAssertEqual(components.compactMap { $0["/"] }, ["/auth/*"])
        })
    }
}
