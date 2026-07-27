@testable import App
import XCTVapor
import Fluent
import JWT
import Foundation

/// B8: the generic /events handler must persist arbitrary event names (including the new PLOT
/// funnel events) with their properties, anonymously or linked to a user. Skipped without
/// `DATABASE_URL`; runs in CI (§5.T5).
final class AnalyticsEventsTests: XCTestCase {
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

    private func makeToken() async throws -> (UUID, String) {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return (user.id!, try app.jwt.signers.sign(payload))
    }

    func testNewPlotEventNamesPersistAnonymously() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let name = "onboarding_step_viewed_\(UUID().uuidString.prefix(6))"
        let batch = AnalyticsController.EventBatch(events: [
            AnalyticsController.EventDTO(name: name, properties: ["step": "1"], deviceId: "dev-1", appVersion: "2.0.0", timestamp: nil),
            AnalyticsController.EventDTO(name: "paywall_shown", properties: ["entry": "onboarding"], deviceId: "dev-1", appVersion: "2.0.0", timestamp: nil),
        ])

        try await app.test(.POST, "api/v1/events", beforeRequest: { req in
            try req.content.encode(batch)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(AnalyticsController.EventResponse.self)
            XCTAssertEqual(body?.received, 2)
        })

        let stored = try await AnalyticsEvent.query(on: app.db).filter(\.$eventName == name).first()
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.userId, "anonymous event should have no user")
        XCTAssertEqual(stored?.deviceId, "dev-1")
        XCTAssertEqual(stored?.properties?.contains("step"), true)
    }

    func testAuthedEventLinksUser() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (userId, token) = try await makeToken()
        let name = "auth_magic_link_verified_\(UUID().uuidString.prefix(6))"
        let batch = AnalyticsController.EventBatch(events: [
            AnalyticsController.EventDTO(name: name, properties: ["isNewUser": "true"], deviceId: nil, appVersion: "2.0.0", timestamp: nil),
        ])

        try await app.test(.POST, "api/v1/events", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(batch)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        let stored = try await AnalyticsEvent.query(on: app.db).filter(\.$eventName == name).first()
        XCTAssertEqual(stored?.userId, userId, "authed event should link to the user")
    }
}
