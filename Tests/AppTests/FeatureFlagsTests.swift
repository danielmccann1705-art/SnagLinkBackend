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

    /// The app's privacy-choices capability: off unless an environment sets exactly "true" (or an
    /// override row says so), and one entry only.
    func testMeasurementChoicesCapabilityDefaultsOffAndIsSetPerEnvironment() {
        let entry = FeatureFlagService.registry.first { $0.key == "measurementChoicesEnabled" }
        XCTAssertEqual(entry?.envVar, "FEATURE_MEASUREMENT_CHOICES_ENABLED")
        XCTAssertEqual(entry?.hardDefault, false)
        XCTAssertEqual(FeatureFlagService.registry.filter { $0.key == "measurementChoicesEnabled" }.count, 1)
    }

    /// The envelope is unchanged: `{"flags": {name: bool}}`. An older app ignores the new name, and a
    /// response from an older server, which lacks it, reads as off.
    func testTheEnvelopeStaysBackwardCompatible() throws {
        struct OlderClientEnvelope: Decodable { let flags: [String: Bool] }
        let current = try JSONEncoder().encode(FeatureFlagsResponse(flags: ["useNewDesign": false, "measurementChoicesEnabled": true]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["flags"])
        let decodedByOlderApp = try JSONDecoder().decode(OlderClientEnvelope.self, from: current)
        XCTAssertEqual(decodedByOlderApp.flags["useNewDesign"], false)
        let olderServer = Data(#"{"flags":{"useNewDesign":false,"productAnalyticsEnabled":true}}"#.utf8)
        let fromOlderServer = try JSONDecoder().decode(FeatureFlagsResponse.self, from: olderServer)
        XCTAssertEqual(fromOlderServer.flags["measurementChoicesEnabled"] ?? false, false,
                       "an older server never asks the app to present choices it cannot save")
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

    func testMeasurementChoicesCapabilityIsServedOffByDefaultAndFollowsItsEnvironment() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await FeatureFlag.query(on: app.db).filter(\.$key == "measurementChoicesEnabled").delete()
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let object = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
            XCTAssertEqual(object.map { Set($0.keys) }, ["flags"], "the envelope is unchanged")
            let flags = object?["flags"] as? [String: Bool]
            XCTAssertEqual(flags?["measurementChoicesEnabled"], false, "off unless an environment turns it on")
            for entry in FeatureFlagService.registry { XCTAssertNotNil(flags?[entry.key], entry.key) }
        })
        let staging = try await FeatureFlagService.resolve(on: app.db) { $0 == "FEATURE_MEASUREMENT_CHOICES_ENABLED" ? "true" : nil }
        XCTAssertEqual(staging["measurementChoicesEnabled"], true)
        for value in ["TRUE", "1", "yes", "false"] {
            let other = try await FeatureFlagService.resolve(on: app.db) { $0 == "FEATURE_MEASUREMENT_CHOICES_ENABLED" ? value : nil }
            XCTAssertEqual(other["measurementChoicesEnabled"], false, value)
        }
        try await FeatureFlag(key: "measurementChoicesEnabled", enabled: false).save(on: app.db)
        let overridden = try await FeatureFlagService.resolve(on: app.db) { $0 == "FEATURE_MEASUREMENT_CHOICES_ENABLED" ? "true" : nil }
        XCTAssertEqual(overridden["measurementChoicesEnabled"], false, "an override row wins, so it can be switched off at once")
        try await FeatureFlag.query(on: app.db).filter(\.$key == "measurementChoicesEnabled").delete()
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
