@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Crypto

final class AppleWebAuthEndpointTests: XCTestCase {
    var app: Application!
    private var fixture: AppleWebFixture!
    let platform = PlatformConfiguration(origin: "https://staging-app.usesnaglist.com", environment: "staging")
    let clientID = "com.snaglist.app.staging.web"
    let path = "api/v2/auth/apple/"
    let ip = "synthetic-" + UUID().uuidString

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = platform
        app.storage[AppleCredentialKeyStorage.self] = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
        app.storage[AppleWebConfigurationKey.self] = .init(clientID: clientID,
            redirectURI: platform.origin + AppleWebConfiguration.callbackPath,
            exchange: .init(teamID: "SYNTHETIC1", keyID: "SYNTHETIC2", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, clientID: clientID))
        fixture = AppleWebFixture()
        let provider = fixture!
        app.clients.use { AppleWebFixtureClient(eventLoop: $0.eventLoopGroup.next(), fixture: provider) }
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    func request(_ endpoint: String, method: HTTPMethod = .POST, body: [String: String] = [:], cookie: String? = nil,
                 origin: String? = nil, form: Bool = false) async throws -> XCTHTTPResponse {
        var output: XCTHTTPResponse!
        try await app.test(method, path + endpoint, beforeRequest: { request in
            request.headers.replaceOrAdd(name: "X-Forwarded-For", value: self.ip)
            if let origin { request.headers.replaceOrAdd(name: "Origin", value: origin) }
            if let cookie { request.headers.replaceOrAdd(name: "Cookie", value: cookie) }
            if method == .POST { try request.content.encode(body, as: form ? .urlEncodedForm : .json) }
        }, afterResponse: { response async in output = response })
        return output
    }
    struct Started { let state: String; let nonce: String; let cookie: String }
    func start() async throws -> Started {
        let response = try await request("challenge", origin: platform.origin)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let challenge = try response.content.decode(AppleWebChallengeResponse.self)
        let url = try XCTUnwrap(URLComponents(string: challenge.authorizationURL))
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "appleid.apple.com"); XCTAssertEqual(url.path, "/auth/authorize")
        let fields = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["client_id"], clientID)
        XCTAssertEqual(fields["redirect_uri"], platform.origin + AppleWebConfiguration.callbackPath)
        XCTAssertEqual(fields["response_type"], "code"); XCTAssertEqual(fields["response_mode"], "form_post")
        let state = try XCTUnwrap(fields["state"]), nonce = try XCTUnwrap(fields["nonce"])
        let raw = try XCTUnwrap(response.headers["set-cookie"].first)
        XCTAssertTrue(raw.contains("SameSite=None")); XCTAssertTrue(raw.contains("HttpOnly")); XCTAssertTrue(raw.contains("Secure"))
        XCTAssertFalse(raw.contains("Domain=")); XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
        return .init(state: state, nonce: nonce, cookie: raw.components(separatedBy: ";")[0])
    }
    func callback(_ started: Started, code: String = "synthetic-code", cookie: String? = nil,
                  origin: String? = "https://appleid.apple.com") async throws -> XCTHTTPResponse {
        try await request("callback", body: ["state": started.state, "code": code], cookie: cookie ?? started.cookie, origin: origin, form: true)
    }
    func token(_ started: Started, subject: String = "synthetic-apple", nonce: String? = nil,
               audience: String? = nil, email: String? = nil, verified: Bool = true, expired: Bool = false) throws -> String {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: GoogleIdentityProofTests.syntheticPrivate)), kid: "synthetic-rsa")
        return try signers.sign(AppleWebFixtureClaims(iss: .init(value: "https://appleid.apple.com"), sub: .init(value: subject),
            aud: .init(value: [audience ?? clientID]), exp: .init(value: Date().addingTimeInterval(expired ? -60 : 300)),
            iat: .init(value: Date()), nonce: nonce ?? started.nonce, email: email, email_verified: verified), kid: "synthetic-rsa")
    }
    func assertPrivateFailure(_ response: XCTHTTPResponse, status: HTTPResponseStatus) {
        XCTAssertEqual(response.status, status, response.body.string)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
        XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
        XCTAssertFalse(response.headers["set-cookie"].contains { $0.hasPrefix(BrowserSessionService.cookieName + "=") })
        XCTAssertNil(response.headers.first(name: .location))
    }

    func testDisabledWithoutExplicitProviderConfiguration() async throws {
        app.storage[AppleWebConfigurationKey.self] = nil
        let status = try await request("configuration", method: .GET)
        XCTAssertEqual(status.status, .ok)
        XCTAssertFalse(try status.content.decode(AppleWebClientResponse.self).enabled)
        assertPrivateFailure(try await request("challenge", origin: platform.origin), status: .serviceUnavailable)
    }
    func testBrowserCallbackFailureReturnsToFixedSignInWithoutProviderData() async throws {
        let started = try await start()
        fixture.configure(token: try token(started, nonce: String(repeating: "z", count: 43)))
        try await app.test(.POST, path + "callback", beforeRequest: { request in
            request.headers.replaceOrAdd(name: "Origin", value: "https://appleid.apple.com")
            request.headers.replaceOrAdd(name: "Accept", value: "text/html,application/xhtml+xml")
            request.headers.replaceOrAdd(name: "Cookie", value: started.cookie)
            try request.content.encode(["state": started.state, "code": "synthetic-browser-code", "return_to": "https://untrusted.test"], as: .urlEncodedForm)
        }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, .seeOther)
            XCTAssertEqual(response.headers.first(name: .location), "/?signin=apple_failed")
            XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
            XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
            XCTAssertFalse(response.body.string.contains(started.state))
            XCTAssertFalse(response.headers["set-cookie"].contains { $0.hasPrefix(BrowserSessionService.cookieName + "=") })
            XCTAssertTrue(response.headers["set-cookie"].contains { $0.contains("Max-Age=0") })
        })
    }
    func testSuccessfulCallbackSharesNativeSubjectKeepsBothCredentialsAndLaxSession() async throws {
        let subject = "same-native-web-" + UUID().uuidString
        let native = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveApple(subject: subject, email: nil, name: "Synthetic native manager", on: db)
        }
        try await AppleCredentialService.store(refreshToken: "synthetic-native-refresh", userID: native.requireID(), clientID: "com.snaglist.app.staging", app: app, on: app.db)
        let started = try await start(), identity = try token(started, subject: subject)
        fixture.configure(token: identity)
        let response = try await callback(started)
        XCTAssertEqual(response.status, .seeOther, response.body.string); XCTAssertEqual(response.headers.first(name: .location), "/")
        let sessionCookie = try XCTUnwrap(response.headers["set-cookie"].first { $0.hasPrefix(BrowserSessionService.cookieName + "=") })
        XCTAssertTrue(sessionCookie.contains("SameSite=Lax")); XCTAssertTrue(sessionCookie.contains("Secure")); XCTAssertTrue(sessionCookie.contains("HttpOnly"))
        let credential = try await AppleCredentialService.load(userID: native.requireID(), clientID: clientID, app: app, on: app.db)
        XCTAssertEqual(credential?.refreshToken, "synthetic-web-refresh")
        let nativeCredential = try await AppleCredentialService.load(userID: native.requireID(), clientID: "com.snaglist.app.staging", app: app, on: app.db)
        XCTAssertEqual(nativeCredential?.refreshToken, "synthetic-native-refresh")
        let rawSession = sessionCookie.components(separatedBy: ";")[0]
        try await app.test(.GET, "api/v2/auth/session", beforeRequest: { $0.headers.add(name: "Cookie", value: rawSession) }, afterResponse: { result async throws in
            XCTAssertEqual(result.status, .ok)
            XCTAssertEqual(try result.content.decode(BrowserSessionResponse.self).user.id, try native.requireID())
        })
        XCTAssertFalse(response.body.string.contains(identity)); XCTAssertFalse(response.body.string.contains("synthetic-web-refresh"))
        XCTAssertEqual(fixture.exchangeCount, 1)
        assertPrivateFailure(try await callback(started), status: .gone)
        XCTAssertEqual(fixture.exchangeCount, 1)
    }
    func testUnknownExpiredAndWrongStateNeverExchangeCode() async throws {
        let started = try await start()
        let unknown = Started(state: String(repeating: "x", count: 43), nonce: started.nonce,
                              cookie: AppleWebAuthController.bindingCookie(for: String(repeating: "x", count: 43)) + "=" + String(repeating: "y", count: 43))
        assertPrivateFailure(try await callback(unknown), status: .gone)
        let different = try await start()
        assertPrivateFailure(try await callback(started, cookie: different.cookie), status: .conflict)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE apple_web_challenges SET created_at=NOW()-INTERVAL '20 minutes',expires_at=NOW()-INTERVAL '10 minutes' WHERE state_hash=\(bind: SHA256Hasher.hash(token: started.state))").run()
        assertPrivateFailure(try await callback(started), status: .gone)
        XCTAssertEqual(fixture.exchangeCount, 0)
    }
    func testWrongNonceAudienceExpiredTokenAndMalformedTokenDoNotCreateSessions() async throws {
        for variation in ["nonce", "audience", "expired", "malformed"] {
            let started = try await start()
            let identity = try variation == "malformed" ? "malformed.token.payload" : token(started,
                subject: "rejected-" + UUID().uuidString, nonce: variation == "nonce" ? String(repeating: "z", count: 43) : nil,
                audience: variation == "audience" ? "com.snaglist.app.staging" : nil, expired: variation == "expired")
            fixture.configure(token: identity)
            assertPrivateFailure(try await callback(started), status: .unauthorized)
            assertPrivateFailure(try await callback(started), status: .gone)
        }
    }
    func testOriginAndMalformedFormFailBeforeProviderExchange() async throws {
        assertPrivateFailure(try await request("challenge", origin: "https://evil.example.test"), status: .forbidden)
        let started = try await start()
        assertPrivateFailure(try await callback(started, origin: nil), status: .forbidden)
        assertPrivateFailure(try await callback(started, origin: platform.origin), status: .forbidden)
        assertPrivateFailure(try await request("callback", body: ["state": started.state], cookie: started.cookie, origin: "https://appleid.apple.com"), status: .forbidden)
        assertPrivateFailure(try await request("callback", body: ["code": "synthetic-code"], cookie: started.cookie, origin: "https://appleid.apple.com", form: true), status: .badRequest)
        XCTAssertEqual(fixture.exchangeCount, 0)
    }
    func testExchangeFailureConsumesChallengeAndDoesNotLeakCode() async throws {
        let started = try await start()
        fixture.configure(token: "unused", failing: true)
        let response = try await callback(started, code: "never-print-provider-secret-code")
        assertPrivateFailure(response, status: .serviceUnavailable)
        XCTAssertFalse(response.body.string.contains("never-print-provider-secret-code"))
        fixture.configure(token: try token(started))
        assertPrivateFailure(try await callback(started), status: .gone)
        XCTAssertEqual(fixture.exchangeCount, 1)
    }
    func testEqualVerifiedEmailDoesNotLinkExistingAccount() async throws {
        let address = "collision-" + UUID().uuidString.lowercased() + "@example.test"
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(address, name: "Existing synthetic manager", on: db) }
        let started = try await start(), subject = "unlinked-" + UUID().uuidString
        fixture.configure(token: try token(started, subject: subject, email: address))
        let result = try await callback(started)
        assertPrivateFailure(result, status: .conflict)
        XCTAssertTrue(result.body.string.contains("identity_proof_required"))
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM user_identities WHERE provider='apple' AND subject=\(bind: subject)").first()
        XCTAssertNil(row)
        let stored = try await AppleCredentialService.load(userID: user.requireID(), clientID: clientID, app: app, on: app.db)
        XCTAssertNil(stored)
    }
    func testOnlyProviderVerifiedAddressBecomesInvitationAuthority() async throws {
        for verified in [true, false] {
            let subject = "email-proof-" + UUID().uuidString
            let email = "email-proof-" + UUID().uuidString.lowercased() + "@example.test"
            let started = try await start()
            fixture.configure(token: try token(started, subject: subject, email: email, verified: verified))
            let response = try await callback(started)
            XCTAssertEqual(response.status, .seeOther)
            let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT user_id FROM user_identities WHERE provider='apple' AND subject=\(bind: subject)").first()
            let userID = try XCTUnwrap(try row?.decode(column: "user_id", as: UUID.self))
            let addresses = try await VerifiedIdentityService.verifiedEmails(for: userID, on: app.db)
            XCTAssertEqual(addresses.contains(email), verified)
        }
    }
    func testExistingAppleSubjectCannotStealAnotherAccountsVerifiedEmail() async throws {
        let email = "owned-email-" + UUID().uuidString.lowercased() + "@example.test"
        let subject = "existing-subject-" + UUID().uuidString
        let (emailOwner, appleUser) = try await app.db.transaction { db in
            let first = try await VerifiedIdentityService.resolveEmail(email, name: "Email owner", on: db)
            let second = try await VerifiedIdentityService.resolveApple(subject: subject, email: nil, name: "Apple owner", on: db)
            return (try first.requireID(), try second.requireID())
        }
        let started = try await start()
        fixture.configure(token: try token(started, subject: subject, email: email))
        let response = try await callback(started)
        XCTAssertEqual(response.status, .seeOther)
        let ownerEmails = try await VerifiedIdentityService.verifiedEmails(for: emailOwner, on: app.db)
        let appleEmails = try await VerifiedIdentityService.verifiedEmails(for: appleUser, on: app.db)
        XCTAssertTrue(ownerEmails.contains(email)); XCTAssertFalse(appleEmails.contains(email))
    }
    func testRejectedCallbackKeepsEncryptedRevocationWorkBeforeReturningFailure() async throws {
        let started = try await start()
        fixture.configure(token: try token(started, nonce: String(repeating: "z", count: 43)))
        let response = try await callback(started)
        assertPrivateFailure(response, status: .unauthorized)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT e.challenge_id,e.state,e.client_id,e.credential_ciphertext FROM apple_web_credential_escrow e JOIN apple_web_challenges c ON c.id=e.challenge_id WHERE c.state_hash=\(bind: SHA256Hasher.hash(token: started.state))").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "ready")
        XCTAssertEqual(try row?.decode(column: "client_id", as: String.self), clientID)
        let ciphertext = try XCTUnwrap(try row?.decode(column: "credential_ciphertext", as: String?.self))
        XCTAssertNotEqual(ciphertext, "synthetic-web-refresh")
        XCTAssertFalse(response.body.string.contains("synthetic-web-refresh"))
    }
    func testConcurrentTabsHaveIndependentBindings() async throws {
        let first = try await start(), second = try await start()
        XCTAssertNotEqual(first.cookie.components(separatedBy: "=")[0], second.cookie.components(separatedBy: "=")[0])
        let cookies = first.cookie + "; " + second.cookie
        fixture.configure(token: try token(first, subject: "tabs-" + UUID().uuidString))
        let firstResult = try await callback(first, cookie: cookies)
        XCTAssertEqual(firstResult.status, .seeOther)
        fixture.configure(token: try token(second, subject: "tabs-" + UUID().uuidString))
        let secondResult = try await callback(second, cookie: cookies)
        XCTAssertEqual(secondResult.status, .seeOther)
    }
}

private struct AppleWebFixtureClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim
    let exp: ExpirationClaim; let iat: IssuedAtClaim; let nonce: String; let email: String?; let email_verified: Bool
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}
private final class AppleWebFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "unset"
    private var failing = false
    private var calls = 0
    func configure(token: String, failing: Bool = false) { lock.lock(); defer { lock.unlock() }; self.token = token; self.failing = failing }
    var exchangeCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func exchange() -> (String, Bool) { lock.lock(); defer { lock.unlock() }; calls += 1; return (token, failing) }
}
private struct AppleWebFixtureClient: Client {
    let eventLoop: EventLoop
    let fixture: AppleWebFixture
    func delegating(to eventLoop: EventLoop) -> Client { Self(eventLoop: eventLoop, fixture: fixture) }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        if request.method == .GET, request.url.string == "https://appleid.apple.com/auth/keys" {
            return eventLoop.makeSucceededFuture(.init(status: .ok, headers: ["Content-Type": "application/json"], body: ByteBuffer(string: Self.jwks)))
        }
        guard request.method == .POST, request.url.string == "https://appleid.apple.com/auth/token", request.headers.bearerAuthorization == nil else {
            XCTFail("Unexpected provider request"); return eventLoop.makeFailedFuture(Abort(.internalServerError))
        }
        do {
            let body = try request.content.decode([String: String].self)
            XCTAssertEqual(body["client_id"], "com.snaglist.app.staging.web")
            XCTAssertEqual(body["redirect_uri"], "https://staging-app.usesnaglist.com/api/v2/auth/apple/callback")
            XCTAssertEqual(body["grant_type"], "authorization_code")
            XCTAssertNotNil(body["client_secret"])
            let (token, failing) = fixture.exchange()
            var response = ClientResponse(status: failing ? .serviceUnavailable : .ok)
            try response.content.encode(AppleWebTokenResponse(idToken: token, refreshToken: "synthetic-web-refresh"))
            return eventLoop.makeSucceededFuture(response)
        } catch { return eventLoop.makeFailedFuture(error) }
    }
    static let jwks = "{\"keys\": [{\"kty\": \"RSA\", \"alg\": \"RS256\", \"kid\": \"synthetic-rsa\", \"n\": \"uGYddtsfqUEsknHQigvKpKrqNioJzARPjKWVyxqFMGxVKZaT5xm-9OwxRpBtLQh8O1MKdDHDSCGu43s_eYMVNOgYvfEpCfp8WhT__moII9UrP9AAWJ9uvVvN03NEw-bkyOFChn1fVKeuOO8QPU1LUyWtQOKTx1aGZrFFYvz08sgPeOpRcM0wIs9xfgiodQjGhMVjNsjmQ7P02Nn54-RRGavjXQB-suKGSuAlI9Zsy7Nb1fO9ObufUWS4RiOT3Ozty-sJfYvBNR-HkiB6aSWS7-VWOdogvAf8Z1VcXVT7nXku66FvD-utG5uezKxf2iwx1E4hfKMvuIj9LJ2vwRFfEw\", \"e\": \"AQAB\"}]}"
}
