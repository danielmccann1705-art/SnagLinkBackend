@testable import App
import XCTVapor
import Fluent
import Foundation

// MARK: - Pure unit tests (no database)

final class EmailRecognitionShapeTests: XCTestCase {
    /// Privacy invariant: the canonical "not recognised" payload carries no extra fields.
    func testNotRecognisedShapeIsEmpty() {
        let r = EmailRecognitionResponse.notRecognised
        XCTAssertFalse(r.recognised)
        XCTAssertNil(r.displayName)
        XCTAssertNil(r.projectCount)
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B1: `GET /api/v1/auth/recognise`. Skipped without `DATABASE_URL`; runs in CI (§5.T5).
final class AuthRecogniseEndpointTests: XCTestCase {
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

    func testRecognisedEmailReturnsDisplayNameAndProjectCount() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "known-\(UUID().uuidString)@example.com"
        let user = User(appleUserId: nil, email: email, name: "Kendall Builds", authProvider: .magicLink)
        try await user.save(on: app.db)
        let project = Project(name: "Riverside Phase 2", reference: "RIV-2", ownerId: user.id!)
        try await project.save(on: app.db)

        try await app.test(.GET, "api/v1/auth/recognise?email=\(email)", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(EmailRecognitionResponse.self)
            XCTAssertEqual(body?.recognised, true)
            XCTAssertEqual(body?.displayName, "Kendall Builds")
            XCTAssertEqual(body?.projectCount, 1)
        })
    }

    func testUnknownEmailReturnsNotRecognisedShape() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "ghost-\(UUID().uuidString)@example.com"
        try await app.test(.GET, "api/v1/auth/recognise?email=\(email)", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(EmailRecognitionResponse.self)
            XCTAssertEqual(body?.recognised, false)
            XCTAssertNil(body?.displayName)
            XCTAssertNil(body?.projectCount)
        })
    }

    /// No information leakage: a malformed email yields the identical "not recognised" shape,
    /// not a 400 — so the endpoint can't distinguish "invalid" from "unknown".
    func testInvalidEmailReturnsNotRecognisedShapeNot400() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.GET, "api/v1/auth/recognise?email=not-an-email", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(EmailRecognitionResponse.self)
            XCTAssertEqual(body?.recognised, false)
            XCTAssertNil(body?.displayName)
            XCTAssertNil(body?.projectCount)
        })
    }

    func testRecogniseRateLimitedAfterTenPerIP() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        // 10 allowed within the per-IP window, 11th rejected.
        for _ in 0..<10 {
            try await app.test(.GET, "api/v1/auth/recognise?email=rl-\(UUID().uuidString)@example.com", afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })
        }
        try await app.test(.GET, "api/v1/auth/recognise?email=rl-final@example.com", afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
        })
    }
}
