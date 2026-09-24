@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// The identifiers per-device sign-out keys on, and the cleanup record's size.
/// No database.
final class AppSessionRevocationRulesTests: XCTestCase {
    typealias Service = AppSessionRevocationService

    static func claims(_ token: String) throws -> [String: Any] {
        var segment = String(token.split(separator: ".", omittingEmptySubsequences: false)[1])
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while segment.count % 4 != 0 { segment += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: segment))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A token issued before `jti` existed is named by its signed part alone: the same
    /// header and payload name the same session whatever the signature segment says,
    /// and a different payload names a different session.
    func testALegacySessionIsNamedByItsSignedPartOnly() {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"
        let named = Service.legacySessionID(token: token)
        XCTAssertEqual(named, Service.legacySessionID(token: token))
        XCTAssertEqual(named, Service.legacySessionID(token: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJm"))
        XCTAssertNotEqual(named, Service.legacySessionID(token: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ5In0.c2lnbmF0dXJl"))
        // Version 8 with the RFC variant, so never equal to a random (version 4) `jti`.
        let text = Array(named.uuidString)
        XCTAssertEqual(text[14], "8")
        XCTAssertTrue(["8", "9", "A", "B"].contains(text[19]))
    }

    /// New tokens carry the session as `jti`; a token without one decodes with none and
    /// falls back to the derived name.
    func testTheSessionTravelsAsJTIAndIsOptional() throws {
        let signers = JWTSigners()
        signers.use(.hs256(key: "synthetic-test-only-signing-key"))
        let userID = UUID(), session = UUID()
        let current = try signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
                                                      expiration: .init(value: Date().addingTimeInterval(600)),
                                                      userId: userID, authVersion: 0, authenticatedAt: Date(), sessionID: session))
        let decoded = try signers.verify(current, as: UserJWTPayload.self)
        XCTAssertEqual(decoded.sessionID, session)
        XCTAssertEqual(Service.sessionID(for: decoded, token: current), session)
        XCTAssertEqual(try Self.claims(current)["jti"] as? String, session.uuidString)

        let legacy = try signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
                                                     expiration: .init(value: Date().addingTimeInterval(600)), userId: userID))
        let old = try signers.verify(legacy, as: UserJWTPayload.self)
        XCTAssertNil(old.sessionID)
        XCTAssertNil(try Self.claims(legacy)["jti"])
        XCTAssertEqual(Service.sessionID(for: old, token: legacy), Service.legacySessionID(token: legacy))
    }

    /// The scheduler refuses a maintenance response over 4,096 bytes. With the new count
    /// at seven digits beside everything else at its largest, the response still fits.
    func testTheCleanupRecordStillFitsTheSchedulerCap() throws {
        var reasons = Dictionary(uniqueKeysWithValues: DeletionReasonKind.allCases.map { ($0.rawValue, 9_999_999) })
        reasons["unspecified"] = 9_999_999; reasons["other"] = 9_999_999
        var removed = CleanupService.Removed()
        removed.rateLimits = 9_999_999; removed.auditLogs = 9_999_999
        removed.magicLinkAuthTokens = 9_999_999; removed.expiredPreviewLinks = 9_999_999
        removed.accountDeletionJobs = .init(processed: 32, completed: 32, blocked: 32, retrying: 32, deferredByBudget: 32)
        removed.accountDeletionHealth = .init(status: .escalate, open: 9_999_999, blocked: 9_999_999, olderThan7Days: 9_999_999,
                                              olderThan25Days: 9_999_999, oldestOpenAgeDays: 99_999, reasons: reasons,
                                              previousPassGapHours: 99_999)
        removed.appSessionRevocations = 9_999_999
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(MaintenanceCleanupResponse(ran: true, removed: removed, lastSuccessfulRun: Date()))
        XCTAssertLessThan(body.count, 4_096, "\(body.count) bytes")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"appSessionRevocations\":9999999"))
    }
}

/// `POST /api/v1/auth/logout` against PostgreSQL. Synthetic identities; no provider,
/// no email. Tokens come from the real issuer (the email-link verify route) unless a
/// test needs a token that issuer no longer makes.
final class AppSessionLogoutTests: XCTestCase {
    typealias Service = AppSessionRevocationService
    var app: Application!
    let config = PlatformConfiguration(origin: "https://portal.example.test", environment: "local")

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = config
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func email() -> String { "logout-\(UUID().uuidString.lowercased())@example.test" }

    /// Signs in exactly as the app does after tapping a sign-in link.
    private func signIn(_ address: String) async throws -> AuthResponse {
        let raw = "synthetic-sign-in-\(UUID().uuidString)"
        try await MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw), email: address,
                                     expiresAt: Date().addingTimeInterval(900)).save(on: app.db)
        let response = try await send(.POST, "api/v1/auth/magic-link/verify", body: ["token": raw])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(AuthResponse.self)
    }

    private func send(_ method: HTTPMethod, _ path: String, bearer: String? = nil, cookie: String? = nil,
                      body: [String: String]? = nil) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let bearer { req.headers.bearerAuthorization = .init(token: bearer) }
            if let cookie { req.headers.add(name: "Cookie", value: cookie) }
            if let body { try req.content.encode(body) }
        }, afterResponse: { response async in result = response })
        return result
    }

    private func status(_ path: String, bearer: String? = nil, cookie: String? = nil) async throws -> HTTPResponseStatus {
        try await send(.GET, path, bearer: bearer, cookie: cookie).status
    }

    private func logout(_ bearer: String?) async throws -> XCTHTTPResponse {
        try await send(.POST, "api/v1/auth/logout", bearer: bearer)
    }

    private func rows(user: UUID) async throws -> [UUID] {
        try await VerifiedIdentityService.sql(app.db)
            .raw("SELECT session_id FROM app_session_revocations WHERE user_id = \(bind: user) ORDER BY session_id").all()
            .map { try $0.decode(column: "session_id", as: UUID.self) }
    }

    private func sign(_ userID: UUID, authVersion: Int, expiresIn seconds: TimeInterval, session: UUID? = nil) throws -> String {
        try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
                                                expiration: .init(value: Date().addingTimeInterval(seconds)),
                                                userId: userID, authVersion: authVersion, sessionID: session))
    }

    func testEachSignInIsItsOwnSession() async throws {
        let address = email()
        let first = try await signIn(address), second = try await signIn(address)
        XCTAssertEqual(first.user.id, second.user.id)
        let a = try app.jwt.signers.verify(first.token, as: UserJWTPayload.self)
        let b = try app.jwt.signers.verify(second.token, as: UserJWTPayload.self)
        XCTAssertNotNil(a.sessionID)
        XCTAssertNotNil(b.sessionID)
        XCTAssertNotEqual(a.sessionID, b.sessionID)
    }

    /// Two phones and the portal. Signing out on one phone ends that phone's session and
    /// nothing else: not the other phone, not the portal, and not `auth_version`.
    func testLogoutEndsThatSessionAndNoOther() async throws {
        let address = email()
        let phoneA = try await signIn(address), phoneB = try await signIn(address)
        let userID = phoneA.user.id
        let before = try await VerifiedIdentityService.activeUser(userID, on: app.db)
        let portal = try await BrowserSessionService.create(for: before, config: config, on: app.db)
        let cookie = "\(BrowserSessionService.cookieName)=\(portal.token)"
        for token in [phoneA.token, phoneB.token] {
            let live = try await status("api/v1/users/me", bearer: token)
            XCTAssertEqual(live, .ok)
        }

        let out = try await logout(phoneA.token)
        XCTAssertEqual(out.status, .noContent, out.body.string)
        XCTAssertEqual(out.body.readableBytes, 0)
        XCTAssertEqual(out.headers.first(name: .cacheControl), "no-store")

        let v1 = try await status("api/v1/users/me", bearer: phoneA.token)
        let v2 = try await status("api/v2/auth/session", bearer: phoneA.token)
        let upload = try await send(.POST, "api/v1/uploads/photo", bearer: phoneA.token)
        XCTAssertEqual(v1, .unauthorized)
        XCTAssertEqual(v2, .unauthorized, "the v2 bearer path refuses it too")
        XCTAssertEqual(upload.status, .unauthorized, "and so do routes that authenticate for themselves")
        let otherPhone = try await status("api/v1/users/me", bearer: phoneB.token)
        let portalSession = try await status("api/v2/auth/session", cookie: cookie)
        XCTAssertEqual(otherPhone, .ok)
        XCTAssertEqual(portalSession, .ok)
        let after = try await VerifiedIdentityService.activeUser(userID, on: app.db)
        XCTAssertEqual(after.authVersion, before.authVersion, "one session, not everywhere")

        // One row: this session, kept until the token would have expired anyway.
        let payload = try app.jwt.signers.verify(phoneA.token, as: UserJWTPayload.self)
        let sessionID = try XCTUnwrap(payload.sessionID)
        let row = try await VerifiedIdentityService.sql(app.db)
            .raw("SELECT user_id, expires_at FROM app_session_revocations WHERE session_id = \(bind: sessionID)").first()
        XCTAssertEqual(try row?.decode(column: "user_id", as: UUID.self), userID)
        let expires = try XCTUnwrap(try row?.decode(column: "expires_at", as: Date.self))
        XCTAssertEqual(expires.timeIntervalSince1970, payload.expiration.value.timeIntervalSince1970, accuracy: 1)
        let all = try await rows(user: userID)
        XCTAssertEqual(all.count, 1)
    }

    /// From the app's side a repeat is harmless: the session is already gone, so the
    /// second call is 401 and writes nothing.
    func testARepeatIsRefusedAndChangesNothing() async throws {
        let session = try await signIn(email())
        let first = try await logout(session.token)
        let second = try await logout(session.token)
        XCTAssertEqual(first.status, .noContent)
        XCTAssertEqual(second.status, .unauthorized)
        let remaining = try await rows(user: session.user.id)
        XCTAssertEqual(remaining.count, 1)
    }

    /// Missing, malformed, foreign-signed, expired and orphaned tokens are all 401, and
    /// none of them writes a row.
    func testAnInvalidOrExpiredTokenIsRefusedWithoutWriting() async throws {
        let session = try await signIn(email())
        let user = try await VerifiedIdentityService.activeUser(session.user.id, on: app.db)
        let foreign = JWTSigners()
        foreign.use(.hs256(key: "a-different-synthetic-signing-key"))
        let forged = try foreign.sign(UserJWTPayload(subject: .init(value: session.user.id.uuidString),
                                                     expiration: .init(value: Date().addingTimeInterval(600)),
                                                     userId: session.user.id, authVersion: user.authVersion, sessionID: UUID()))
        let expired = try sign(session.user.id, authVersion: user.authVersion, expiresIn: -60, session: UUID())
        let orphanID = UUID()
        let orphan = try sign(orphanID, authVersion: 0, expiresIn: 600, session: UUID())
        let cases: [(String, String?)] = [("no header", nil), ("malformed", "not-a-token"), ("foreign key", forged),
                                          ("expired", expired), ("no such account", orphan)]
        for (label, bearer) in cases {
            let response = try await logout(bearer)
            XCTAssertEqual(response.status, .unauthorized, label)
        }
        let written = try await rows(user: session.user.id)
        XCTAssertEqual(written, [])
        let live = try await status("api/v1/users/me", bearer: session.token)
        XCTAssertEqual(live, .ok)
    }

    /// A token issued before this change (no `jti`) keeps working, and signing out with
    /// it ends it alone, keyed by its own signed part. Re-spelling its signature segment
    /// does not get it back in.
    func testATokenFromBeforeThisChangeKeepsWorkingAndSignsOutAlone() async throws {
        let current = try await signIn(email())
        let user = try await VerifiedIdentityService.activeUser(current.user.id, on: app.db)
        let legacy = try sign(current.user.id, authVersion: user.authVersion, expiresIn: 3_600)
        let otherLegacy = try sign(current.user.id, authVersion: user.authVersion, expiresIn: 7_200)
        XCTAssertNil(try app.jwt.signers.verify(legacy, as: UserJWTPayload.self).sessionID)
        for token in [legacy, otherLegacy] {
            let live = try await status("api/v1/users/me", bearer: token)
            XCTAssertEqual(live, .ok, "a deploy signs nobody out")
        }

        let out = try await logout(legacy)
        XCTAssertEqual(out.status, .noContent, out.body.string)
        let written = try await rows(user: current.user.id)
        XCTAssertEqual(written, [Service.legacySessionID(token: legacy)])

        // The last character of a 32-byte signature carries two unused bits. Whether or
        // not the verifier accepts that spelling, it names the same session.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var characters = Array(legacy)
        let last = try XCTUnwrap(alphabet.firstIndex(of: characters[characters.count - 1]))
        characters[characters.count - 1] = alphabet[last ^ 1]
        let respelled = String(characters)
        XCTAssertNotEqual(respelled, legacy)
        XCTAssertEqual(Service.legacySessionID(token: respelled), Service.legacySessionID(token: legacy))

        let signedOut = try await status("api/v1/users/me", bearer: legacy)
        let respelledStatus = try await status("api/v1/users/me", bearer: respelled)
        let stillLive = try await status("api/v1/users/me", bearer: otherLegacy)
        let newToken = try await status("api/v1/users/me", bearer: current.token)
        XCTAssertEqual(signedOut, .unauthorized)
        XCTAssertEqual(respelledStatus, .unauthorized)
        XCTAssertEqual(stillLive, .ok)
        XCTAssertEqual(newToken, .ok)
        let repeated = try await logout(legacy)
        XCTAssertEqual(repeated.status, .unauthorized)
    }

    /// Account deletion still ends every session at once (`auth_version`), including
    /// ones never signed out, and takes the account's sign-out rows with it.
    func testAccountDeletionStillEndsEverySession() async throws {
        app.storage[AccountDeletionTestActivation.self] = true
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
        let address = email()
        let phoneA = try await signIn(address), phoneB = try await signIn(address)
        let userID = phoneA.user.id
        let versionBefore = try await VerifiedIdentityService.activeUser(userID, on: app.db).authVersion
        let out = try await logout(phoneB.token)
        XCTAssertEqual(out.status, .noContent)
        let beforeDeletion = try await rows(user: userID)
        XCTAssertEqual(beforeDeletion.count, 1)

        let reference = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let deletion = try await send(.DELETE, "api/v1/users/me", bearer: phoneA.token,
                                      body: ["confirmation": "DELETE", "receiptReference": reference])
        XCTAssertEqual(deletion.status, .accepted, deletion.body.string)

        for token in [phoneA.token, phoneB.token] {
            let refused = try await status("api/v1/users/me", bearer: token)
            XCTAssertEqual(refused, .unauthorized)
        }
        let afterDeletion = try await logout(phoneA.token)
        XCTAssertEqual(afterDeletion.status, .unauthorized)
        let row = try await VerifiedIdentityService.sql(app.db)
            .raw("SELECT auth_version, lifecycle_state FROM users WHERE id = \(bind: userID)").first()
        XCTAssertGreaterThan(try XCTUnwrap(try row?.decode(column: "auth_version", as: Int.self)), versionBefore)
        XCTAssertEqual(try row?.decode(column: "lifecycle_state", as: String.self), "deleted")
        let remaining = try await rows(user: userID)
        XCTAssertEqual(remaining, [])
    }

    /// The hourly pass removes a sign-out row once its token has been expired for longer
    /// than the margin, and keeps the rest.
    func testTheCleanupPassRemovesRowsOnlyAfterTheirTokensExpire() async throws {
        app.storage[CleanupLockKeyStorage.self] = Int64.random(in: 1_000_000...9_000_000)
        let session = try await signIn(email())
        let long = UUID(), recent = UUID(), live = UUID()
        let now = Date()
        for (id, expires) in [(long, now.addingTimeInterval(-2 * 24 * 3_600)),
                              (recent, now.addingTimeInterval(-3_600)),
                              (live, now.addingTimeInterval(24 * 3_600))] {
            try await VerifiedIdentityService.sql(app.db).raw("""
                INSERT INTO app_session_revocations (session_id, user_id, expires_at) VALUES (\(bind: id), \(bind: session.user.id), \(bind: expires))
                """).run()
        }
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(removed?.appSessionRevocations), 1)
        let remaining = try await rows(user: session.user.id)
        XCTAssertEqual(Set(remaining), [recent, live])
    }
}
