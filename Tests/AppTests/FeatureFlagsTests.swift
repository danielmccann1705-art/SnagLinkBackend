@testable import App
import XCTVapor
import Fluent
import JWT
import Foundation

// MARK: - Pure unit tests (no database)

final class FeatureFlagUnitTests: XCTestCase {
    func testRegistryContainsUseNewDesignDefaultOff() {
        let entry = FeatureFlagService.registry.first { $0.key == "useNewDesign" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.hardDefault, false)
        XCTAssertEqual(entry?.envVar, "FEATURE_USE_NEW_DESIGN")
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B6: feature-flags endpoint. Skipped without `DATABASE_URL`; runs in CI (§5.T5).
final class FeatureFlagsEndpointTests: XCTestCase {
    var app: Application!
    var dbAvailable: Bool { Environment.get("DATABASE_URL") != nil }

    override func setUp() async throws {
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        guard dbAvailable else { return }
        app = try await Application.make(.testing)
        try await configure(app)
        // This fixture owns this key in disposable test databases; clean it so
        // repeated suites cannot inherit a previous test run's override.
        try await FeatureFlag.query(on: app.db).filter(\.$key == "useNewDesign").delete()
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
    }

    private func makeToken() async throws -> String {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return try app.jwt.signers.sign(payload)
    }

    func testUnauthenticatedGetsFlags() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(FeatureFlagsResponse.self)
            XCTAssertNotNil(body?.flags["useNewDesign"]) // key present
        })
    }

    func testAuthenticatedGetsFlags() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let token = try await makeToken()
        try await app.test(.GET, "api/v1/config/feature-flags", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(FeatureFlagsResponse.self)
            XCTAssertNotNil(body?.flags["useNewDesign"])
        })
    }

    func testDbOverrideWins() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        // No existing override + FEATURE_USE_NEW_DESIGN unset in test env → default false.
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            let body = try? res.content.decode(FeatureFlagsResponse.self)
            XCTAssertEqual(body?.flags["useNewDesign"], false)
        })

        // Insert an override row → true.
        try await FeatureFlag(key: "useNewDesign", enabled: true).save(on: app.db)
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            let body = try? res.content.decode(FeatureFlagsResponse.self)
            XCTAssertEqual(body?.flags["useNewDesign"], true)
        })
    }
}
