@testable import App
import XCTVapor
import Fluent
import Foundation

// MARK: - Pure unit tests (no database required)

/// B1: validation + hashing + model logic that needs neither an app boot nor a database.
final class MagicLinkUnitTests: XCTestCase {

    func testEmailNormalizationLowercasesAndTrims() {
        XCTAssertEqual(EmailValidator.normalize("  USER@Example.COM "), "user@example.com")
    }

    func testEmailFormatValidation() {
        XCTAssertTrue(EmailValidator.isValidFormat("a@b.co"))
        XCTAssertTrue(EmailValidator.isValidFormat("jack.k+test@kendall-builds.co.uk"))
        XCTAssertFalse(EmailValidator.isValidFormat("no-at-sign"))
        XCTAssertFalse(EmailValidator.isValidFormat("two@@at.com"))
        XCTAssertFalse(EmailValidator.isValidFormat("trailing@dot."))
        XCTAssertFalse(EmailValidator.isValidFormat("has space@dot.com"))
    }

    func testDisposableDomainsRejected() {
        XCTAssertTrue(EmailValidator.isDisposable("throwaway@mailinator.com"))
        XCTAssertTrue(EmailValidator.isDisposable("x@YOPMAIL.com")) // case-insensitive
        XCTAssertFalse(EmailValidator.isDisposable("real@gmail.com"))
        XCTAssertFalse(EmailValidator.isAcceptable("real@mailinator.com"))
        XCTAssertTrue(EmailValidator.isAcceptable("real@kendall-builds.co.uk"))
    }

    func testTokenHashIsDeterministicAndStable() {
        let token = try! SecureTokenGenerator.generate()
        XCTAssertEqual(SHA256Hasher.hash(token: token), SHA256Hasher.hash(token: token))
        // 32 bytes hashed -> 64 hex chars
        XCTAssertEqual(SHA256Hasher.hash(token: token).count, 64)
    }

    func testTokenHashDiffersPerToken() {
        let a = try! SecureTokenGenerator.generate()
        let b = try! SecureTokenGenerator.generate()
        XCTAssertNotEqual(SHA256Hasher.hash(token: a), SHA256Hasher.hash(token: b))
    }

    func testAuthTokenExpiryAndConsumedFlags() {
        let live = MagicLinkAuthToken(tokenHash: "h", email: "a@b.co", expiresAt: Date().addingTimeInterval(60))
        XCTAssertFalse(live.isExpired)
        XCTAssertFalse(live.isConsumed)

        let dead = MagicLinkAuthToken(tokenHash: "h", email: "a@b.co", expiresAt: Date().addingTimeInterval(-60))
        XCTAssertTrue(dead.isExpired)

        live.consumedAt = Date()
        XCTAssertTrue(live.isConsumed)
    }

    func testRateLimitConfigForMagicLinkActions() {
        XCTAssertEqual(RateLimitAction.magicLinkRequest.limit, 3)
        XCTAssertEqual(RateLimitAction.magicLinkRequest.windowSeconds, 3600)
        XCTAssertEqual(RateLimitAction.emailRecognise.limit, 10)
        XCTAssertEqual(RateLimitAction.emailRecognise.windowSeconds, 60)
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B1: magic-link request + verify endpoints exercised against a real Postgres.
/// Skipped automatically when `DATABASE_URL` is not set (e.g. local runs without a DB);
/// runs in CI where an ephemeral Postgres is provisioned (see §5.T5).
final class AuthMagicLinkEndpointTests: XCTestCase {
    var app: Application!
    var dbAvailable: Bool { Environment.get("DATABASE_URL") != nil }

    override func setUp() async throws {
        // Allow the app to boot without external secrets in CI test env.
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        guard dbAvailable else { return }
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
    }

    /// Inserts a ready-to-verify token and returns its raw value.
    private func seedToken(email: String, expiresAt: Date = Date().addingTimeInterval(900)) async throws -> String {
        let raw = "raw-\(UUID().uuidString)"
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw), email: email, expiresAt: expiresAt)
        try await token.save(on: app.db)
        return raw
    }

    func testRequestStoresTokenAndReturns204() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "req-\(UUID().uuidString)@example.com"
        try await app.test(.POST, "api/v1/auth/magic-link/request", beforeRequest: { req in
            try req.content.encode(["email": email, "name": "Jack K"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })
        let count = try await MagicLinkAuthToken.query(on: app.db).filter(\.$email == email).count()
        XCTAssertEqual(count, 1)
    }

    func testRequestRejectsInvalidEmail() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.POST, "api/v1/auth/magic-link/request", beforeRequest: { req in
            try req.content.encode(["email": "not-an-email"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testRequestRejectsDisposableEmail() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.POST, "api/v1/auth/magic-link/request", beforeRequest: { req in
            try req.content.encode(["email": "x@mailinator.com"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testRequestRateLimitedAfterThreePerEmail() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "rl-\(UUID().uuidString)@example.com"
        for _ in 0..<3 {
            try await app.test(.POST, "api/v1/auth/magic-link/request", beforeRequest: { req in
                try req.content.encode(["email": email])
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .noContent)
            })
        }
        try await app.test(.POST, "api/v1/auth/magic-link/request", beforeRequest: { req in
            try req.content.encode(["email": email])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
        })
    }

    func testVerifyHappyPathReturnsTokenAndCreatesUser() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "verify-\(UUID().uuidString)@example.com"
        let raw = try await seedToken(email: email)

        try await app.test(.POST, "api/v1/auth/magic-link/verify", beforeRequest: { req in
            try req.content.encode(["token": raw])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(AuthResponse.self)
            XCTAssertNotNil(body)
            XCTAssertFalse(body?.token.isEmpty ?? true)
            XCTAssertEqual(body?.user.email, email)
            XCTAssertNil(body?.user.appleUserId)
            XCTAssertEqual(body?.user.authProvider, AuthProvider.magicLink.rawValue)
            XCTAssertEqual(body?.isNewUser, true)
        })
    }

    func testVerifyIsSingleUse() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "single-\(UUID().uuidString)@example.com"
        let raw = try await seedToken(email: email)

        try await app.test(.POST, "api/v1/auth/magic-link/verify", beforeRequest: { req in
            try req.content.encode(["token": raw])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        // Second use must be rejected as consumed.
        try await app.test(.POST, "api/v1/auth/magic-link/verify", beforeRequest: { req in
            try req.content.encode(["token": raw])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .gone)
        })
    }

    func testVerifyExpiredTokenReturnsGone() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let email = "exp-\(UUID().uuidString)@example.com"
        let raw = try await seedToken(email: email, expiresAt: Date().addingTimeInterval(-60))

        try await app.test(.POST, "api/v1/auth/magic-link/verify", beforeRequest: { req in
            try req.content.encode(["token": raw])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .gone)
        })
    }

    func testVerifyUnknownTokenReturnsGone() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.POST, "api/v1/auth/magic-link/verify", beforeRequest: { req in
            try req.content.encode(["token": "no-such-token"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .gone)
        })
    }
}
