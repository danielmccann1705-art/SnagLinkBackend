@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Real PostgreSQL, synthetic identities. No email provider is called. Challenges
/// are inserted through the same service used by the request endpoint.
final class BrowserIdentityTests: XCTestCase {
    var app: Application!
    let config = PlatformConfiguration(origin: "https://portal.example.test", environment: "local")

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = config
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func challenge(email: String? = nil, binding: String = "test-browser") async throws -> String {
        try await IdentityChallengeService.issue(email: email ?? "manager-\(UUID())@example.test", purpose: .browserSignIn, targetUserID: nil, binding: binding, config: config, on: app.db)
    }
    private func request(_ method: HTTPMethod, _ path: String, body: [String: String] = [:], cookie: String? = nil,
                         csrf: String? = nil, origin: String? = "https://portal.example.test", bearer: String? = nil) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let origin { req.headers.add(name: "Origin", value: origin) }
            if let cookie { req.headers.add(name: "Cookie", value: cookie) }
            if let csrf { req.headers.add(name: "X-CSRF-Token", value: csrf) }
            if let bearer { req.headers.bearerAuthorization = .init(token: bearer) }
            if method != .GET { try req.content.encode(body) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func verify(_ token: String, binding: String = "test-browser", origin: String? = "https://portal.example.test") async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/auth/verify", body: ["token": token], cookie: "\(BrowserSessionService.bindingCookieName)=\(binding)", origin: origin)
    }
    private func signedIn() async throws -> (String, BrowserSessionResponse) {
        let response = try await verify(challenge())
        XCTAssertEqual(response.status, .ok, response.body.string)
        let cookies = response.headers["set-cookie"]
        let cookie = try XCTUnwrap(cookies.first { $0.hasPrefix(BrowserSessionService.cookieName + "=") }?.components(separatedBy: ";").first)
        return try (cookie, response.content.decode(BrowserSessionResponse.self))
    }

    func testVerificationCreatesHostOnlySecureSessionAndNoJWTInBody() async throws {
        let response = try await verify(challenge())
        XCTAssertEqual(response.status, .ok, response.body.string)
        let cookie = try XCTUnwrap(response.headers["set-cookie"].first { $0.hasPrefix(BrowserSessionService.cookieName + "=") })
        XCTAssertTrue(cookie.contains("Secure")); XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("Path=/")); XCTAssertTrue(cookie.contains("SameSite=Lax"))
        XCTAssertFalse(cookie.contains("Domain=")); XCTAssertFalse(response.body.string.contains("\"token\":"))
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let raw = String(cookie.split(separator: ";")[0].split(separator: "=", maxSplits: 1)[1])
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM browser_sessions WHERE token_hash = \(bind: raw)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 0, "Raw session credential must not be persisted")
    }

    func testMissingMailProviderCannotReportThatSignInOrVerificationWasSent() async throws {
        XCTAssertNil(Environment.get("RESEND_API_KEY"), "This suite must not use a live mail provider")
        let email = "undelivered-\(UUID())@example.test"
        let requested = try await request(.POST, "api/v2/auth/email", body: ["email": email])
        XCTAssertEqual(requested.status, .serviceUnavailable)
        XCTAssertTrue(requested.headers["set-cookie"].isEmpty)
        XCTAssertFalse(requested.body.string.contains(email))
        let (cookie, session) = try await signedIn()
        let linked = try await request(.POST, "api/v2/account/email/request", body: ["email": email], cookie: cookie, csrf: session.csrfToken)
        XCTAssertEqual(linked.status, .serviceUnavailable)
        let emails = try await VerifiedIdentityService.verifiedEmails(for: session.user.id, on: app.db)
        XCTAssertFalse(emails.contains(email))
    }

    func testLandingGETDoesNotConsumeAndWrongBrowserDoesNotConsume() async throws {
        let raw = try await challenge()
        let get = try await request(.GET, "api/v2/auth/verify?token=" + raw)
        XCTAssertEqual(get.status, .notFound)
        let wrong = try await verify(raw, binding: "another-browser")
        XCTAssertEqual(wrong.status, .conflict)
        let valid = try await verify(raw)
        XCTAssertEqual(valid.status, .ok, valid.body.string)
        let replay = try await verify(raw)
        XCTAssertEqual(replay.status, .gone)
    }

    func testConcurrentVerificationCreatesExactlyOneSession() async throws {
        let raw = try await challenge()
        let codes = try await withThrowingTaskGroup(of: UInt.self) { group in
            for _ in 0..<6 { group.addTask { try await self.verify(raw).status.code } }
            var codes: [UInt] = []
            for try await code in group { codes.append(code) }
            return codes
        }
        XCTAssertEqual(codes.filter { $0 == 200 }.count, 1)
        XCTAssertEqual(codes.filter { $0 == 410 }.count, 5)
    }

    func testExpiryAndEnvironmentMismatchDenyVerification() async throws {
        let raw = try await challenge()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE identity_challenges SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE token_hash = \(bind: SHA256Hasher.hash(token: raw))").run()
        let expired = try await verify(raw)
        XCTAssertEqual(expired.status, .gone)
        let other = try await challenge()
        app.storage[PlatformConfigurationKey.self] = .init(origin: config.origin, environment: "staging")
        let mismatch = try await verify(other)
        XCTAssertEqual(mismatch.status, .gone)
    }

    func testLoginRequiresExactOriginAndNeverConsumesOnFailure() async throws {
        let raw = try await challenge()
        for origin in [nil, "null", "https://portal.example.test.evil.test", "https://other.example.test"] {
            let response = try await verify(raw, origin: origin)
            XCTAssertEqual(response.status, .forbidden)
        }
        let response = try await verify(raw)
        XCTAssertEqual(response.status, .ok)
    }

    func testCookieMutationRequiresCSRFAndOriginThenLogoutRevokes() async throws {
        let (cookie, session) = try await signedIn()
        let get = try await request(.GET, "api/v2/auth/session", cookie: cookie, origin: nil)
        XCTAssertEqual(get.status, .ok)
        for csrf in [nil, "wrong"] {
            let result = try await request(.POST, "api/v2/auth/logout", cookie: cookie, csrf: csrf)
            XCTAssertEqual(result.status, .forbidden)
        }
        let wrongOrigin = try await request(.POST, "api/v2/auth/logout", cookie: cookie, csrf: session.csrfToken, origin: "https://other.example.test")
        XCTAssertEqual(wrongOrigin.status, .forbidden)
        let result = try await request(.POST, "api/v2/auth/logout", cookie: cookie, csrf: session.csrfToken)
        XCTAssertEqual(result.status, .noContent)
        let revoked = try await request(.GET, "api/v2/auth/session", cookie: cookie)
        XCTAssertEqual(revoked.status, .unauthorized)
    }

    func testSessionCannotCrossEnvironmentsAndExpiryIsEnforced() async throws {
        let (cookie, session) = try await signedIn()
        app.storage[PlatformConfigurationKey.self] = .init(origin: config.origin, environment: "staging")
        let wrong = try await request(.GET, "api/v2/auth/session", cookie: cookie)
        XCTAssertEqual(wrong.status, .unauthorized)
        app.storage[PlatformConfigurationKey.self] = config
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE browser_sessions SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE user_id = \(bind: session.user.id)").run()
        let expired = try await request(.GET, "api/v2/auth/session", cookie: cookie)
        XCTAssertEqual(expired.status, .unauthorized)
    }

    func testVerifiedEmailAndAppleResolveSameStableUser() async throws {
        let apple = "synthetic-apple-\(UUID())", email = "work-\(UUID())@example.test"
        let user = try await app.db.transaction { db in
            let user = try await VerifiedIdentityService.resolveApple(subject: apple, email: "relay-\(UUID())@privaterelay.appleid.com", name: "Site manager", on: db)
            try await VerifiedIdentityService.linkEmail(email, to: user.requireID(), on: db)
            return user
        }
        let response = try await verify(challenge(email: email.uppercased()))
        XCTAssertEqual(response.status, .ok, response.body.string)
        XCTAssertEqual(try response.content.decode(BrowserSessionResponse.self).user.id, user.id)
        let native = try await app.db.transaction { db in try await VerifiedIdentityService.resolveApple(subject: apple, email: nil, name: nil, on: db) }
        XCTAssertEqual(native.id, user.id)
    }

    func testLegacyMutableEmailCannotSelectAnExistingAccount() async throws {
        let email = "legacy-\(UUID())@example.test"
        let user = User(appleUserId: "apple-\(UUID())", email: email, name: "Existing")
        try await user.save(on: app.db)
        let raw = try await challenge(email: email)
        let response = try await verify(raw)
        XCTAssertEqual(response.status, .conflict)
        let unconsumed = try await VerifiedIdentityService.sql(app.db).raw("SELECT consumed_at FROM identity_challenges WHERE token_hash = \(bind: SHA256Hasher.hash(token: raw))").first()!.decode(column: "consumed_at", as: Date?.self)
        XCTAssertNil(unconsumed)
    }

    func testEmailLinkRequiresSameAuthenticatedAccountAndCannotTransferIdentity() async throws {
        let (cookie, session) = try await signedIn()
        let (otherCookie, other) = try await signedIn()
        let email = "added-\(UUID())@example.test"
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM browser_sessions WHERE user_id = \(bind: session.user.id)").first()!
        let binding = "session:" + (try row.decode(column: "id", as: UUID.self)).uuidString
        let raw = try await IdentityChallengeService.issue(email: email, purpose: .verifyEmail, targetUserID: session.user.id, binding: binding, config: config, on: app.db)
        let wrong = try await request(.POST, "api/v2/account/email/verify", body: ["token": raw], cookie: otherCookie, csrf: other.csrfToken)
        XCTAssertEqual(wrong.status, .conflict)
        let correct = try await request(.POST, "api/v2/account/email/verify", body: ["token": raw], cookie: cookie, csrf: session.csrfToken)
        XCTAssertEqual(correct.status, .ok, correct.body.string)
        XCTAssertTrue(try correct.content.decode([String].self).contains(EmailValidator.normalize(email)))
        do {
            try await app.db.transaction { db in try await VerifiedIdentityService.linkEmail(email, to: other.user.id, on: db) }
            XCTFail("An identity owned by another account must not transfer")
        } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }

    func testLogoutEverywhereRevokesNativeAndBrowserCredentials() async throws {
        let (cookie, session) = try await signedIn()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: session.user.id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: session.user.id))
        let before = try await request(.GET, "api/v1/users/me", bearer: jwt)
        XCTAssertEqual(before.status, .ok)
        let logout = try await request(.POST, "api/v2/auth/logout-all", cookie: cookie, csrf: session.csrfToken)
        XCTAssertEqual(logout.status, .noContent)
        let native = try await request(.GET, "api/v1/users/me", bearer: jwt)
        let browser = try await request(.GET, "api/v2/auth/session", cookie: cookie)
        XCTAssertEqual(native.status, .unauthorized); XCTAssertEqual(browser.status, .unauthorized)
    }
}
