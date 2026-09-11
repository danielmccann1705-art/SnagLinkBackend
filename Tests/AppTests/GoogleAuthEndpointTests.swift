@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class GoogleAuthEndpointTests: XCTestCase {
    var app: Application!
    let platform = PlatformConfiguration(origin: "https://portal-\(UUID().uuidString.lowercased()).example.test", environment: "local")
    let provider = GoogleIdentityConfiguration(webClientID: "12345-syntheticweb.apps.googleusercontent.com", iosClientID: "12345-syntheticios.apps.googleusercontent.com")

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = platform
        app.storage[GoogleIdentityConfigurationKey.self] = provider
        useProvider(failing: false)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    func useProvider(failing: Bool) {
        app.clients.use { GoogleJWKSFixtureClient(eventLoop: $0.eventLoopGroup.next(), failing: failing) }
    }
    func request(_ method: HTTPMethod, _ path: String, body: [String: String] = [:], cookie: String? = nil,
                 csrf: String? = nil, origin: String? = "valid", bearer: String? = nil) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let origin { req.headers.add(name: "Origin", value: origin == "valid" ? self.platform.origin : origin) }
            if let cookie { req.headers.add(name: "Cookie", value: cookie) }
            if let csrf { req.headers.add(name: "X-CSRF-Token", value: csrf) }
            if let bearer { req.headers.bearerAuthorization = .init(token: bearer) }
            if method != .GET { try req.content.encode(body) }
        }, afterResponse: { response async in result = response })
        return result
    }
    func cookie(_ response: XCTHTTPResponse, name: String) throws -> String {
        try XCTUnwrap(response.headers["set-cookie"].first { $0.hasPrefix(name + "=") }?.components(separatedBy: ";").first)
    }
    func challenge(ios: Bool = false) async throws -> (GoogleChallengeResponse, String?) {
        let response = try await request(.POST, "api/v2/auth/google/" + (ios ? "ios/challenge" : "challenge"), origin: ios ? nil : "valid")
        XCTAssertEqual(response.status, .ok, response.body.string)
        let issued = try response.content.decode(GoogleChallengeResponse.self)
        return try (issued, ios ? nil : cookie(response, name: GoogleAuthController.bindingCookie(for: issued.challengeToken)))
    }
    func token(_ challenge: GoogleChallengeResponse, subject: String, ios: Bool = false, nonce: String? = nil) throws -> String {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: GoogleIdentityProofTests.syntheticPrivate)), kid: "synthetic-rsa")
        let claims = GoogleIdentityClaims(iss: .init(value: "https://accounts.google.com"), sub: .init(value: subject),
            aud: .init(value: [provider.webClientID]), exp: .init(value: Date().addingTimeInterval(3600)), iat: .init(value: Date()),
            azp: ios ? provider.iosClientID : nil, nonce: nonce ?? challenge.nonce,
            email: "synthetic-\(UUID().uuidString.lowercased())@example.test", name: "Synthetic Google manager")
        return try signers.sign(claims, kid: "synthetic-rsa")
    }
    func verifyBody(_ challenge: GoogleChallengeResponse, identity: String) -> [String: String] {
        var body = ["challengeToken": challenge.challengeToken, "identityToken": identity]
        if let verifier = challenge.verifier { body["verifier"] = verifier }
        return body
    }
    func signedInApple() async throws -> (User, String, String, UUID) {
        let user = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveApple(subject: "synthetic-apple-\(UUID())", email: nil, name: "Existing manager", on: db)
        }
        let session = try await BrowserSessionService.create(for: user, config: platform, on: app.db)
        return (user, BrowserSessionService.cookieName + "=" + session.token, session.principal.csrfToken, session.principal.sessionID)
    }

    func testTwoOpenGoogleSignInTabsKeepIndependentBindings() async throws {
        let (first, firstCookie) = try await challenge()
        let (second, secondCookie) = try await challenge()
        XCTAssertNotEqual(GoogleAuthController.bindingCookie(for: first.challengeToken), GoogleAuthController.bindingCookie(for: second.challengeToken))
        let cookies = try XCTUnwrap(firstCookie) + "; " + XCTUnwrap(secondCookie)
        let subject = "two-tabs-\(UUID())"
        let signedFirst = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(first, identity: token(first, subject: subject)), cookie: cookies)
        let signedSecond = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(second, identity: token(second, subject: subject)), cookie: cookies)
        XCTAssertEqual(signedFirst.status, .ok); XCTAssertEqual(signedSecond.status, .ok)
        XCTAssertEqual(try signedFirst.content.decode(BrowserSessionResponse.self).user.id, try signedSecond.content.decode(BrowserSessionResponse.self).user.id)
    }

    func testConfigurationIsDisabledWithoutExplicitEnvironmentClients() async throws {
        app.storage[GoogleIdentityConfigurationKey.self] = nil
        let response = try await request(.GET, "api/v2/auth/google/configuration", origin: nil)
        XCTAssertEqual(response.status, .ok)
        XCTAssertFalse(try response.content.decode(GoogleClientResponse.self).enabled)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let start = try await request(.POST, "api/v2/auth/google/challenge")
        XCTAssertEqual(start.status, .serviceUnavailable)
    }

    func testWebProofCreatesSecureCookieSessionWithoutReturningGoogleToken() async throws {
        let (issued, binding) = try await challenge()
        XCTAssertNil(issued.verifier)
        XCTAssertEqual(issued.clientID, provider.webClientID)
        let identity = try token(issued, subject: "google-web-\(UUID())")
        let response = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(issued, identity: identity), cookie: #"g_state={"i_l":0,"i_ll":123}; "# + (binding ?? ""))
        XCTAssertEqual(response.status, .ok, response.body.string)
        let payload = try response.content.decode(BrowserSessionResponse.self)
        XCTAssertTrue(payload.verifiedEmails.isEmpty)
        XCTAssertFalse(response.body.string.contains(identity)); XCTAssertFalse(response.body.string.contains("\"token\":"))
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let rawCookie = try XCTUnwrap(response.headers["set-cookie"].first { $0.hasPrefix(BrowserSessionService.cookieName + "=") })
        XCTAssertTrue(rawCookie.contains("Secure")); XCTAssertTrue(rawCookie.contains("HttpOnly")); XCTAssertFalse(rawCookie.contains("Domain="))
        let session = try await request(.GET, "api/v2/auth/session", cookie: cookie(response, name: BrowserSessionService.cookieName), origin: nil)
        XCTAssertEqual(try session.content.decode(BrowserSessionResponse.self).user.id, payload.user.id)
    }

    func testIOSAndWebResolveSameStableUserWithDistinctBindings() async throws {
        let subject = "google-shared-\(UUID())"
        let (web, binding) = try await challenge()
        let signedWeb = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(web, identity: token(web, subject: subject)), cookie: binding)
        let webUser = try signedWeb.content.decode(BrowserSessionResponse.self).user.id
        let (native, _) = try await challenge(ios: true)
        XCTAssertNotNil(native.verifier); XCTAssertEqual(native.clientID, provider.iosClientID)
        let signedNative = try await request(.POST, "api/v2/auth/google/ios/verify", body: verifyBody(native, identity: token(native, subject: subject, ios: true)), origin: nil)
        XCTAssertEqual(signedNative.status, .ok, signedNative.body.string)
        let payload = try signedNative.content.decode(AuthResponse.self)
        XCTAssertEqual(payload.user.id, webUser)
        let session = try await request(.GET, "api/v2/auth/session", origin: nil, bearer: payload.token)
        XCTAssertEqual(session.status, .ok)
        XCTAssertTrue(signedNative.headers["set-cookie"].isEmpty)
    }

    func testOriginBindingNonceAndReplayRejectionsDoNotIssueSession() async throws {
        let forbidden = try await request(.POST, "api/v2/auth/google/challenge", origin: "https://evil.example.test")
        XCTAssertEqual(forbidden.status, .forbidden)
        let (issued, binding) = try await challenge(), subject = "google-context-\(UUID())"
        let identity = try token(issued, subject: subject)
        let body = verifyBody(issued, identity: identity)
        let missing = try await request(.POST, "api/v2/auth/google/verify", body: body)
        XCTAssertEqual(missing.status, .conflict)
        let wrongOrigin = try await request(.POST, "api/v2/auth/google/verify", body: body, cookie: binding, origin: nil)
        XCTAssertEqual(wrongOrigin.status, .forbidden)
        let wrongNonce = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(issued, identity: token(issued, subject: subject, nonce: String(repeating: "x", count: 43))), cookie: binding)
        XCTAssertEqual(wrongNonce.status, .unauthorized); XCTAssertTrue(wrongNonce.headers["set-cookie"].isEmpty)
        let valid = try await request(.POST, "api/v2/auth/google/verify", body: body, cookie: binding)
        XCTAssertEqual(valid.status, .ok)
        let replay = try await request(.POST, "api/v2/auth/google/verify", body: body, cookie: binding)
        XCTAssertEqual(replay.status, .gone)
    }

    func testBrowserCannotUseNativeResponsePathAndWrongNativeVerifierFails() async throws {
        let browserStart = try await request(.POST, "api/v2/auth/google/ios/challenge")
        XCTAssertEqual(browserStart.status, .forbidden)
        let (issued, _) = try await challenge(ios: true)
        var body = try verifyBody(issued, identity: token(issued, subject: "google-native-\(UUID())", ios: true))
        let browserVerify = try await request(.POST, "api/v2/auth/google/ios/verify", body: body)
        XCTAssertEqual(browserVerify.status, .forbidden)
        body["verifier"] = String(repeating: "wrong", count: 10)
        let wrong = try await request(.POST, "api/v2/auth/google/ios/verify", body: body, origin: nil)
        XCTAssertEqual(wrong.status, .conflict)
    }

    func testAccountLinkRequiresCSRFAndProofOfSameRecentAccount() async throws {
        let (user, cookie, csrf, _) = try await signedInApple()
        let (_, otherCookie, otherCSRF, _) = try await signedInApple()
        let noCSRF = try await request(.POST, "api/v2/account/google/challenge", cookie: cookie)
        XCTAssertEqual(noCSRF.status, .forbidden)
        let start = try await request(.POST, "api/v2/account/google/challenge", cookie: cookie, csrf: csrf)
        XCTAssertEqual(start.status, .ok, start.body.string)
        let issued = try start.content.decode(GoogleChallengeResponse.self), subject = "google-linked-\(UUID())"
        let body = try verifyBody(issued, identity: token(issued, subject: subject))
        let wrong = try await request(.POST, "api/v2/account/google/verify", body: body, cookie: otherCookie, csrf: otherCSRF)
        XCTAssertEqual(wrong.status, .conflict)
        let result = try await request(.POST, "api/v2/account/google/verify", body: body, cookie: cookie, csrf: csrf)
        XCTAssertEqual(result.status, .ok, result.body.string)
        XCTAssertTrue(try result.content.decode(GoogleConnectionResponse.self).connected)
        let (fresh, binding) = try await challenge()
        let signed = try await request(.POST, "api/v2/auth/google/verify", body: verifyBody(fresh, identity: token(fresh, subject: subject)), cookie: binding)
        XCTAssertEqual(try signed.content.decode(BrowserSessionResponse.self).user.id, user.id)
    }

    func testOldSessionRequiresReauthenticationBeforeLinking() async throws {
        let (_, cookie, csrf, sessionID) = try await signedInApple()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE browser_sessions SET authenticated_at = \(bind: Date().addingTimeInterval(-900)) WHERE id = \(bind: sessionID)").run()
        let result = try await request(.POST, "api/v2/account/google/challenge", cookie: cookie, csrf: csrf)
        XCTAssertEqual(result.status, .forbidden)
        XCTAssertTrue(result.body.string.contains("reauthentication_required"))
    }

    func testProviderOutageDoesNotConsumeChallengeOrLeakCredentials() async throws {
        useProvider(failing: true)
        let (issued, binding) = try await challenge(), subject = "google-outage-\(UUID())"
        let identity = try token(issued, subject: subject), body = verifyBody(issued, identity: identity)
        let failed = try await request(.POST, "api/v2/auth/google/verify", body: body, cookie: binding)
        XCTAssertEqual(failed.status, .serviceUnavailable)
        XCTAssertFalse(failed.body.string.contains(identity)); XCTAssertFalse(failed.body.string.contains(subject))
        useProvider(failing: false)
        let retry = try await request(.POST, "api/v2/auth/google/verify", body: body, cookie: binding)
        XCTAssertEqual(retry.status, .ok, retry.body.string)
    }
}

private struct GoogleJWKSFixtureClient: Client {
    let eventLoop: EventLoop
    let failing: Bool
    func delegating(to eventLoop: EventLoop) -> Client { Self(eventLoop: eventLoop, failing: failing) }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        guard request.method == .GET, request.url.string == "https://www.googleapis.com/oauth2/v3/certs", request.headers.bearerAuthorization == nil else {
            XCTFail("Unexpected network request in Google identity test")
            return eventLoop.makeFailedFuture(Abort(.internalServerError))
        }
        return eventLoop.makeSucceededFuture(ClientResponse(status: failing ? .serviceUnavailable : .ok,
            headers: ["Content-Type": "application/json", "Cache-Control": "max-age=3600"], body: ByteBuffer(string: failing ? "{}" : Self.jwks)))
    }
    static let jwks = "{\"keys\": [{\"kty\": \"RSA\", \"alg\": \"RS256\", \"kid\": \"synthetic-rsa\", \"n\": \"uGYddtsfqUEsknHQigvKpKrqNioJzARPjKWVyxqFMGxVKZaT5xm-9OwxRpBtLQh8O1MKdDHDSCGu43s_eYMVNOgYvfEpCfp8WhT__moII9UrP9AAWJ9uvVvN03NEw-bkyOFChn1fVKeuOO8QPU1LUyWtQOKTx1aGZrFFYvz08sgPeOpRcM0wIs9xfgiodQjGhMVjNsjmQ7P02Nn54-RRGavjXQB-suKGSuAlI9Zsy7Nb1fO9ObufUWS4RiOT3Ozty-sJfYvBNR-HkiB6aSWS7-VWOdogvAf8Z1VcXVT7nXku66FvD-utG5uezKxf2iwx1E4hfKMvuIj9LJ2vwRFfEw\", \"e\": \"AQAB\"}]}"
}
