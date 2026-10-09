@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Crypto

/// Server-authoritative product funnels (`outputs/measurement-2026-10-07/FUNNELS-OCT9.md`):
/// `sign_in_succeeded`, `contractor_link_create_failed`, `report_failed`, and portal
/// attribution of the existing outcome events. Real PostgreSQL, synthetic provider proofs
/// signed with the shared synthetic RSA key, injected provider transport. No provider network.
final class ProductFunnelEventTests: XCTestCase {
    private var app: Application!
    private let platform = PlatformConfiguration(origin: "https://portal-funnels.example.test", environment: "local")
    private let google = GoogleIdentityConfiguration(webClientID: "12345-syntheticweb.apps.googleusercontent.com",
                                                     iosClientID: "12345-syntheticios.apps.googleusercontent.com")
    private var ip = ""
    private var intents: [UUID] = []
    private var accounts: Set<UUID> = []
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private static let flags = ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = platform
        app.storage[GoogleIdentityConfigurationKey.self] = google
        app.storage[AccountDeletionTestActivation.self] = true
        app.clients.use { FunnelProviderFixtureClient(eventLoop: $0.eventLoopGroup.next()) }
        ip = "funnel-" + UUID().uuidString
        intents = []; accounts = []
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
    }

    override func tearDown() async throws {
        if let app {
            let sql = try VerifiedIdentityService.sql(app.db)
            app.storage[ProductFunnelMeasurement.HookKey.self] = nil
            for id in intents {
                if let row = try? await sql.raw("SELECT account_id FROM measurement_signup_intents WHERE id=\(bind:id)").first(),
                   let account = try? row.decode(column: "account_id", as: UUID?.self) { accounts.insert(account) }
            }
            for account in accounts {
                for table in ["measurement_dispatch_jobs", "measurement_product_events", "measurement_erasure_jobs",
                              "measurement_att_assertions", "measurement_permission_current"] {
                    try? await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE account_id=\(bind:account)").run()
                }
            }
            for id in intents {
                try? await sql.raw("DELETE FROM measurement_signup_facts WHERE intent_id=\(bind:id)").run()
                try? await sql.raw("DELETE FROM measurement_signup_intents WHERE id=\(bind:id)").run()
            }
            for account in accounts {
                try? await sql.raw("DELETE FROM measurement_signup_facts WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:account)").run()
            }
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
            try await app.asyncShutdown()
        }
        app = nil
    }

    // MARK: - Wire helpers

    private struct Issued { let id: UUID; let capability: String; let installation: UUID }

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }
    private func address() -> String { "funnel-\(UUID().uuidString.lowercased())@example.test" }

    private func request(_ method: HTTPMethod, _ path: String, object: [String: Any]? = nil, origin: String? = nil,
                         bearer: String? = nil, cookie: String? = nil, csrf: String? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: self.ip)
            if let origin { req.headers.replaceOrAdd(name: "Origin", value: origin) }
            if let bearer { req.headers.bearerAuthorization = .init(token: bearer) }
            if let cookie { req.headers.replaceOrAdd(name: "Cookie", value: cookie) }
            if let csrf { req.headers.replaceOrAdd(name: "X-CSRF-Token", value: csrf) }
            if let object {
                req.headers.contentType = .json
                req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
            }
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func enable(_ keys: String...) async throws {
        for key in keys {
            try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
            try await FeatureFlag(key: key, enabled: true).save(on: app.db)
        }
    }

    private func disable(_ key: String) async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
    }

    private func signer() throws -> JWTSigners {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: GoogleIdentityProofTests.syntheticPrivate)), kid: "synthetic-rsa")
        return signers
    }

    private func appleToken(subject: String, nonce: String? = nil) throws -> String {
        try signer().sign(FunnelAppleClaims(iss: .init(value: "https://appleid.apple.com"), sub: .init(value: subject),
            aud: .init(value: [AppleIdentityConfiguration.releaseAudience]), exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()), nonce: nonce, email: nil, email_verified: nil), kid: "synthetic-rsa")
    }

    private func nativeApple(subject: String, origin: String? = nil) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v1/auth/apple", object: ["identityToken": try appleToken(subject: subject)], origin: origin)
    }

    private func googleToken(_ challenge: GoogleChallengeResponse, subject: String, web: Bool = false) throws -> String {
        try signer().sign(FunnelGoogleClaims(iss: .init(value: "https://accounts.google.com"), sub: .init(value: subject),
            aud: .init(value: [google.webClientID]), exp: .init(value: Date().addingTimeInterval(3600)), iat: .init(value: Date()),
            azp: web ? nil : google.iosClientID, nonce: challenge.nonce, email: nil, email_verified: nil,
            name: "Synthetic Google manager"), kid: "synthetic-rsa")
    }

    private func googleChallenge(_ binding: [String: Any]? = nil) async throws -> GoogleChallengeResponse {
        let response = try await request(.POST, "api/v2/auth/google/ios/challenge", object: binding.map { ["measurementContext": $0] })
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(GoogleChallengeResponse.self)
    }

    private func nativeGoogle(subject: String, binding: [String: Any]? = nil,
                              context: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        let challenge = try await googleChallenge(binding)
        var body: [String: Any] = ["challengeToken": challenge.challengeToken,
                                   "identityToken": try googleToken(challenge, subject: subject),
                                   "verifier": try XCTUnwrap(challenge.verifier)]
        if let context { body["measurementContext"] = context }
        return try await request(.POST, "api/v2/auth/google/ios/verify", object: body)
    }

    private func webGoogle(subject: String) async throws -> XCTHTTPResponse {
        let start = try await request(.POST, "api/v2/auth/google/challenge", origin: platform.origin)
        XCTAssertEqual(start.status, .ok, start.body.string)
        let challenge = try start.content.decode(GoogleChallengeResponse.self)
        let name = GoogleAuthController.bindingCookie(for: challenge.challengeToken)
        let cookie = try XCTUnwrap(start.headers["set-cookie"].first { $0.hasPrefix(name + "=") }?.components(separatedBy: ";").first)
        return try await request(.POST, "api/v2/auth/google/verify", object: [
            "challengeToken": challenge.challengeToken, "identityToken": try googleToken(challenge, subject: subject, web: true)
        ], origin: platform.origin, cookie: cookie)
    }

    /// Stands in for the person tapping the emailed native link: a token row whose raw value
    /// this test knows. Native email verify then issues the app session.
    private func nativeEmail(_ email: String, origin: String? = nil) async throws -> XCTHTTPResponse {
        let raw = "funnel-raw-" + UUID().uuidString
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw), email: EmailValidator.normalize(email),
                                       expiresAt: Date().addingTimeInterval(900))
        try await token.save(on: app.db)
        return try await request(.POST, "api/v1/auth/magic-link/verify", object: ["token": raw], origin: origin)
    }

    /// The portal email path: a browser-bound challenge, then the cookie-session verify.
    private func webEmail(_ email: String) async throws -> XCTHTTPResponse {
        let raw = try await IdentityChallengeService.issue(email: email, purpose: .browserSignIn, targetUserID: nil,
                                                           binding: "funnel-browser", config: platform, on: app.db)
        return try await request(.POST, "api/v2/auth/verify", object: ["token": raw], origin: platform.origin,
                                 cookie: "\(BrowserSessionService.bindingCookieName)=funnel-browser")
    }

    @discardableResult
    private func signedIn(_ response: XCTHTTPResponse, new: Bool? = nil,
                          file: StaticString = #filePath, line: UInt = #line) throws -> AuthResponse {
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line)
        let auth = try response.content.decode(AuthResponse.self)
        accounts.insert(auth.user.id)
        if let new { XCTAssertEqual(auth.isNewUser, new, file: file, line: line) }
        return auth
    }

    private func portalSession(_ response: XCTHTTPResponse, file: StaticString = #filePath,
                               line: UInt = #line) throws -> (user: UUID, cookie: String) {
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line)
        let session = try response.content.decode(BrowserSessionResponse.self)
        accounts.insert(session.user.id)
        let cookie = try XCTUnwrap(response.headers["set-cookie"].first { $0.hasPrefix(BrowserSessionService.cookieName + "=") }?
            .components(separatedBy: ";").first, file: file, line: line)
        return (session.user.id, cookie)
    }

    private func jwt(_ user: User) throws -> String {
        let id = try user.requireID()
        return try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
    }

    private func grant(_ bearer: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date()], bearer: bearer)
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line)
    }

    private func withdraw(_ account: UUID, bearer: String) async throws {
        let revision = try await sql.raw("""
            SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:account) AND purpose='productAnalytics'
            """).first()!.decode(column: "revision", as: UUID.self)
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "expectedRevision": revision.uuidString, "decision": "withdrawn",
            "occurredAt": date()], bearer: bearer)
        XCTAssertEqual(response.status, .ok, response.body.string)
    }

    private func configureDelivery(_ recorder: FunnelHTTPRecorder) {
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox, singularURL: nil, singularAPIKey: nil,
            linkedInAccessToken: nil, linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
    }

    // MARK: - Database probes

    private struct Recorded { let properties: [String: String]; let occurredAt: Date; let installation: UUID? }

    private func events(_ account: UUID, _ name: String = "sign_in_succeeded") async throws -> [Recorded] {
        try await sql.raw("""
            SELECT properties::text AS properties,occurred_at,installation_id FROM measurement_product_events
            WHERE account_id=\(bind:account) AND event_name=\(bind:name) ORDER BY occurred_at
            """).all().map { row in
                let text = try row.decode(column: "properties", as: String.self)
                let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] ?? ["unparsed": text]
                return .init(properties: object, occurredAt: try row.decode(column: "occurred_at", as: Date.self),
                             installation: try row.decode(column: "installation_id", as: UUID?.self))
            }
    }

    private func payloads(_ account: UUID, _ name: String) async throws -> [String] {
        try await sql.raw("""
            SELECT payload::text AS payload FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:account) AND source_kind='productEvent' AND payload->>'event'=\(bind:name)
            """).all().map { try $0.decode(column: "payload", as: String.self) }
    }

    private func jobStates(_ account: UUID, _ name: String) async throws -> [String] {
        try await sql.raw("""
            SELECT j.state FROM measurement_dispatch_jobs j JOIN measurement_product_events e
              ON e.account_id=j.account_id AND e.event_id=j.source_id
            WHERE j.account_id=\(bind:account) AND j.source_kind='productEvent'
              AND (e.event_name=\(bind:name) OR e.event_name IS NULL)
            ORDER BY j.created_at
            """).all().map { try $0.decode(column: "state", as: String.self) }
    }

    private func keys(_ payload: String) throws -> Set<String> {
        Set(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]).keys)
    }

    private func signIn(_ provider: String, _ surface: String) -> [String: String] { ["provider": provider, "surface": surface] }

    // MARK: - Report and project helpers

    private func manager(_ name: String = "Synthetic funnel manager") async throws -> User {
        let user = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("funnel-\(UUID().uuidString.lowercased())@example.test", name: name, on: db)
        }
        accounts.insert(try user.requireID())
        return user
    }
    private func metadata(_ operation: UUID = UUID(), device: UUID = UUID()) -> [String: Any] {
        ["operationId": operation.uuidString, "deviceId": device.uuidString]
    }
    private func project(_ owner: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Funnel Builders", actorID: owner.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
        }
        let response = try await request(.POST, "api/v2/projects", object: [
            "mutation": metadata(), "workspaceId": try workspace.requireID().uuidString,
            "project": ["id": UUID().uuidString, "name": "Funnel Plot 4", "reference": "FP04", "address": "Synthetic site"]
        ], bearer: try jwt(owner))
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, project: PlatformProjectResponse) async throws -> UUID {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", object: [
            "mutation": metadata(), "id": UUID().uuidString, "fields": ["title": "Synthetic sealant check"]
        ], bearer: try jwt(owner))
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self).snag.id
    }
    private func join(_ member: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in
            try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member",
                projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db)
        }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: member.requireID(), on: db) }
    }
    private func reports(_ project: PlatformProjectResponse) -> String { "api/v2/projects/\(project.project.id)/reports" }

    // MARK: - 1. Sign-in: one bounded event per issued session, native and portal

    func testEachNativeAndPortalSessionRecordsOneBoundedSignInOnlyAfterPermission() async throws {
        try await enable("productAnalyticsEnabled")
        // Email: native app session, then a portal session for the same account.
        let email = address()
        let first = try signedIn(try await nativeEmail(email), new: true)
        let beforeGrant = try await events(first.user.id)
        XCTAssertTrue(beforeGrant.isEmpty, "no product permission existed when that session was issued")
        try await grant(first.token)
        try signedIn(try await nativeEmail(email), new: false)
        let emailPortal = try portalSession(try await webEmail(email))
        XCTAssertEqual(emailPortal.user, first.user.id)

        // Apple: native app session.
        let appleSubject = "funnel-apple-\(UUID())"
        let apple = try signedIn(try await nativeApple(subject: appleSubject), new: true)
        try await grant(apple.token)
        try signedIn(try await nativeApple(subject: appleSubject), new: false)

        // Google: native app session, then a portal session for the same subject.
        let googleSubject = "funnel-google-\(UUID())"
        let google = try signedIn(try await nativeGoogle(subject: googleSubject), new: true)
        try await grant(google.token)
        try signedIn(try await nativeGoogle(subject: googleSubject), new: false)
        let googlePortal = try portalSession(try await webGoogle(subject: googleSubject))
        XCTAssertEqual(googlePortal.user, google.user.id)

        for (account, expected, forbidden) in [
            (first.user.id, [signIn("email", "ios"), signIn("email", "web")], [email]),
            (apple.user.id, [signIn("apple", "ios")], [appleSubject]),
            (google.user.id, [signIn("google", "ios"), signIn("google", "web")], [googleSubject])
        ] {
            let recorded = try await events(account)
            XCTAssertEqual(recorded.map(\.properties), expected)
            XCTAssertTrue(recorded.allSatisfy { $0.installation == nil }, "server sessions carry no client installation")
            let queued = try await payloads(account, "sign_in_succeeded")
            XCTAssertEqual(queued.count, expected.count)
            for payload in queued {
                XCTAssertEqual(try keys(payload), ["event", "occurredAt", "provider", "surface"])
                for value in forbidden + [account.uuidString, account.uuidString.lowercased(), "token", "session"] {
                    XCTAssertFalse(payload.contains(value), "payload must not carry \(value)")
                }
            }
        }
    }

    // MARK: - 2. Relationship with account_created

    func testAdoptedNewAccountRecordsAccountCreatedAndExactlyOneLaterSignIn() async throws {
        try await enable("productAnalyticsEnabled")
        let recorder = FunnelHTTPRecorder()
        configureDelivery(recorder)
        let installation = UUID()
        let issue = try await request(.POST, "api/v2/measurement/signup-intents", object: [
            "provider": "google", "installationId": installation.uuidString, "noticeVersion": "signup-measurement-v1",
            "choices": ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false]])
        XCTAssertEqual(issue.status, .created, issue.body.string)
        let issued = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(issue.body.readableBytesView)) as? [String: Any])
        let intent = Issued(id: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(issued["intentId"] as? String))),
                            capability: try XCTUnwrap(issued["capability"] as? String), installation: installation)
        intents.append(intent.id)
        let binding: [String: Any] = ["intentId": intent.id.uuidString, "capability": intent.capability]
        let auth = try signedIn(try await nativeGoogle(subject: "funnel-adopted-\(UUID())", binding: binding, context: binding), new: true)

        let fact = try await sql.raw("SELECT occurred_at FROM measurement_signup_facts WHERE account_id=\(bind:auth.user.id)").all()
        XCTAssertEqual(fact.count, 1, "one account_created fact for the genuinely new account")
        let factAt = try fact[0].decode(column: "occurred_at", as: Date.self)
        let signIns = try await events(auth.user.id)
        XCTAssertEqual(signIns.map(\.properties), [signIn("google", "ios")], "the creating session is also a sign-in")
        XCTAssertGreaterThanOrEqual(signIns[0].occurredAt, factAt, "sign-in never precedes account creation")
        let revisions = try await sql.raw("""
            SELECT DISTINCT consent_revision,subject_id FROM measurement_dispatch_jobs WHERE account_id=\(bind:auth.user.id)
            """).all()
        XCTAssertEqual(revisions.count, 1, "both events rest on the one adopted product grant")

        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = await recorder.calls()
        let bodies = try calls.map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? [String: Any]) }
        XCTAssertEqual(bodies.compactMap { $0["event"] as? String }.sorted(), ["account_created", "sign_in_succeeded"])
        let subjects = Set(bodies.compactMap { ($0["properties"] as? [String: Any])?["distinct_id"] as? String })
        XCTAssertEqual(subjects.count, 1, "one opaque person in PostHog")

        // A genuinely new account without an adopted product choice records neither event.
        let plainSubject = "funnel-plain-\(UUID())"
        let plain = try signedIn(try await nativeGoogle(subject: plainSubject), new: true)
        let plainSignIns = try await events(plain.user.id)
        XCTAssertTrue(plainSignIns.isEmpty)
        let plainFacts = try await sql.raw("SELECT count(*) AS n FROM measurement_signup_facts WHERE account_id=\(bind:plain.user.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(plainFacts, 0)

        // An existing account signing in with a fresh pre-auth intent adopts nothing, so
        // without earlier consent it records no sign-in and no account_created.
        let again = try await request(.POST, "api/v2/measurement/signup-intents", object: [
            "provider": "google", "installationId": UUID().uuidString, "noticeVersion": "signup-measurement-v1",
            "choices": ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false]])
        XCTAssertEqual(again.status, .created, again.body.string)
        let againBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(again.body.readableBytesView)) as? [String: Any])
        let againID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(againBody["intentId"] as? String)))
        intents.append(againID)
        let againBinding: [String: Any] = ["intentId": againID.uuidString, "capability": try XCTUnwrap(againBody["capability"] as? String)]
        let existing = try signedIn(try await nativeGoogle(subject: plainSubject, binding: againBinding, context: againBinding), new: false)
        XCTAssertEqual(existing.user.id, plain.user.id)
        let existingSignIns = try await events(plain.user.id)
        XCTAssertTrue(existingSignIns.isEmpty)
    }

    // MARK: - 3. No backfill

    func testSignInBeforePermissionOrWithTheFlagOffIsNeverBackfilled() async throws {
        try await enable("productAnalyticsEnabled")
        let recorder = FunnelHTTPRecorder()
        configureDelivery(recorder)
        let email = address()
        let account = try signedIn(try await nativeEmail(email), new: true)
        try await grant(account.token)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let afterGrant = try await events(account.user.id)
        XCTAssertTrue(afterGrant.isEmpty, "a later opt-in never reconstructs an earlier session")

        try await disable("productAnalyticsEnabled")
        try signedIn(try await nativeEmail(email), new: false)
        _ = try portalSession(try await webEmail(email))
        try await enable("productAnalyticsEnabled")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let afterFlag = try await events(account.user.id)
        XCTAssertTrue(afterFlag.isEmpty, "enabling the flag later never reconstructs sessions issued while it was off")
        let sent = await recorder.calls()
        XCTAssertTrue(sent.allSatisfy { !$0.body.contains("sign_in_succeeded") })

        try signedIn(try await nativeEmail(email), new: false)
        let eligible = try await events(account.user.id)
        XCTAssertEqual(eligible.map(\.properties), [signIn("email", "ios")])
    }

    // MARK: - 4. Dispatch re-checks permission and flag

    func testDispatchRechecksPermissionAndFlagBeforeDelivery() async throws {
        try await enable("productAnalyticsEnabled")
        let recorder = FunnelHTTPRecorder()
        configureDelivery(recorder)

        let withdrawn = try signedIn(try await nativeEmail(address()), new: true)
        try await grant(withdrawn.token)
        let withdrawnEmail = try await sql.raw("SELECT email FROM users WHERE id=\(bind:withdrawn.user.id)").first()!.decode(column: "email", as: String.self)
        try signedIn(try await nativeEmail(withdrawnEmail), new: false)
        try await withdraw(withdrawn.user.id, bearer: withdrawn.token)

        let switchedOff = try signedIn(try await nativeEmail(address()), new: true)
        try await grant(switchedOff.token)
        let offEmail = try await sql.raw("SELECT email FROM users WHERE id=\(bind:switchedOff.user.id)").first()!.decode(column: "email", as: String.self)
        try signedIn(try await nativeEmail(offEmail), new: false)
        try await disable("productAnalyticsEnabled")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let suppressedSent = await recorder.calls()
        XCTAssertTrue(suppressedSent.isEmpty, "withdrawal and a switched-off flag both suppress before transport")
        let withdrawnStates = try await jobStates(withdrawn.user.id, "sign_in_succeeded")
        XCTAssertEqual(withdrawnStates, ["suppressed"])
        let offStates = try await jobStates(switchedOff.user.id, "sign_in_succeeded")
        XCTAssertEqual(offStates, ["suppressed"])

        try await enable("productAnalyticsEnabled")
        let delivered = try signedIn(try await nativeEmail(address()), new: true)
        try await grant(delivered.token)
        let deliveredEmail = try await sql.raw("SELECT email FROM users WHERE id=\(bind:delivered.user.id)").first()!.decode(column: "email", as: String.self)
        try signedIn(try await nativeEmail(deliveredEmail), new: false)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = await recorder.calls().filter { $0.body.contains("sign_in_succeeded") }
        XCTAssertEqual(calls.count, 1)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(calls.first).body.utf8)) as? [String: Any])
        XCTAssertEqual(body["event"] as? String, "sign_in_succeeded")
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["event", "occurredAt", "provider", "surface", "distinct_id", "source_event_id",
                                              "$process_person_profile", "$geoip_disable"])
        XCTAssertFalse(calls[0].body.contains(deliveredEmail))
        XCTAssertFalse(calls[0].body.contains(delivered.user.id.uuidString.lowercased()))
    }

    // MARK: - 5. Authentication never waits for or fails with optional measurement

    func testAuthenticationSucceedsWhenSignInMeasurementFailsOrItsBarrierIsBusy() async throws {
        try await enable("productAnalyticsEnabled")
        let email = address()
        let account = try signedIn(try await nativeEmail(email), new: true)
        try await grant(account.token)

        // A real SQL error inside the optional savepoint rolls back that savepoint only.
        app.storage[ProductFunnelMeasurement.HookKey.self] = { stage, sql in
            if stage == .signIn { try await sql.raw("SELECT 1/0").run() }
        }
        let native = try signedIn(try await nativeEmail(email), new: false)
        let portal = try portalSession(try await webEmail(email))
        let appleSubject = "funnel-apple-failing-\(UUID())"
        let apple = try signedIn(try await nativeApple(subject: appleSubject), new: true)
        app.storage[ProductFunnelMeasurement.HookKey.self] = nil
        let afterFailure = try await events(account.user.id)
        XCTAssertTrue(afterFailure.isEmpty)
        // The sessions issued while measurement failed are ordinary working sessions.
        let nativeUse = try await request(.GET, "api/v2/auth/session", bearer: native.token)
        XCTAssertEqual(nativeUse.status, .ok, nativeUse.body.string)
        let portalUse = try await request(.GET, "api/v2/auth/session", cookie: portal.cookie)
        XCTAssertEqual(portalUse.status, .ok, portalUse.body.string)
        let appleCommitted = try await sql.raw("SELECT count(*) AS n FROM users WHERE id=\(bind:apple.user.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(appleCommitted, 1, "the account-creating transaction committed")

        // A busy purpose barrier (held by another connection) is tried, never awaited, both
        // when the candidate is captured and when it is recorded after the session exists.
        var loops = app.eventLoopGroup.makeIterator()
        let loopA = loops.next()!, loopB = loops.next() ?? loopA
        let dbA = app.databases.database(.psql, logger: app.logger, on: loopA)!
        let dbB = app.databases.database(.psql, logger: app.logger, on: loopB)!
        let user = try await XCTUnwrapAsync(try await User.find(account.user.id, on: app.db))
        let application = app!
        let ready = try await dbA.transaction { db in
            await ProductFunnelMeasurement.signInCandidate(account: user, sessionID: UUID(), provider: .email,
                                                           surface: .ios, app: application, on: db)
        }
        XCTAssertNotNil(ready)
        let gate = FunnelLockGate()
        let key = "measurement-permission:\(account.user.id.uuidString):productAnalytics"
        let holder = Task {
            try await dbB.transaction { tx in
                try await VerifiedIdentityService.lock(key, on: tx)
                await gate.hold()
            }
        }
        await gate.waitUntilHeld()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await gate.release()
        }
        let clock = ContinuousClock(), started = clock.now
        let busy = try await dbA.transaction { db in
            await ProductFunnelMeasurement.signInCandidate(account: user, sessionID: UUID(), provider: .email,
                                                           surface: .ios, app: application, on: db)
        }
        await ProductFunnelMeasurement.record(ready, app: application, on: dbA)
        let elapsed = started.duration(to: clock.now)
        await gate.release()
        watchdog.cancel(); _ = await watchdog.result
        try await holder.value
        XCTAssertNil(busy)
        XCTAssertLessThan(elapsed, .milliseconds(1_000), "optional sign-in measurement must not wait for the privacy barrier")
        let afterBusy = try await events(account.user.id)
        XCTAssertTrue(afterBusy.isEmpty)
    }

    // MARK: - 6. Restored sessions and bearer reuse

    func testRestoredSessionsBearerReuseAndBrowserCallsToNativeRoutesRecordNothing() async throws {
        try await enable("productAnalyticsEnabled")
        let email = address()
        let account = try signedIn(try await nativeEmail(email), new: true)
        try await grant(account.token)
        let native = try signedIn(try await nativeEmail(email), new: false)
        let portal = try portalSession(try await webEmail(email))
        let issued = try await events(account.user.id)
        XCTAssertEqual(issued.count, 2)

        // Restoring a stored app token or a portal cookie issues no session.
        for _ in 0..<2 {
            let bearer = try await request(.GET, "api/v2/auth/session", bearer: native.token)
            XCTAssertEqual(bearer.status, .ok, bearer.body.string)
            let cookie = try await request(.GET, "api/v2/auth/session", cookie: portal.cookie)
            XCTAssertEqual(cookie.status, .ok, cookie.body.string)
            let permissions = try await request(.GET, "api/v2/measurement/permissions", bearer: native.token)
            XCTAssertEqual(permissions.status, .ok, permissions.body.string)
        }
        // A browser-origin request to a native route has no known surface: unmeasured.
        try signedIn(try await nativeEmail(email, origin: platform.origin), new: false)
        let restored = try await events(account.user.id)
        XCTAssertEqual(restored.count, 2, "only the two issued sessions are sign-ins")
    }

    // MARK: - 7. Closed vocabulary

    func testServerFunnelVocabularyIsClosedAndClientUploadsCannotClaimIt() async throws {
        typealias Relay = MeasurementRelayService
        for provider in ProductFunnelMeasurement.SignInProvider.allCases {
            for surface in ProductFunnelMeasurement.SignInSurface.allCases {
                XCTAssertTrue(Relay.permits(.signInSucceeded, properties: ["provider": provider.rawValue, "surface": surface.rawValue]))
            }
        }
        XCTAssertEqual(ProductFunnelMeasurement.SignInProvider.allCases.map(\.rawValue), ["apple", "google", "email"])
        XCTAssertEqual(ProductFunnelMeasurement.SignInSurface.allCases.map(\.rawValue), ["ios", "web"])
        XCTAssertFalse(Relay.permits(.signInSucceeded, properties: ["provider": "apple"]))
        XCTAssertFalse(Relay.permits(.signInSucceeded, properties: ["provider": "apple", "surface": "ios", "new_account": "true"]))
        XCTAssertFalse(Relay.permits(.signInSucceeded, properties: ["provider": "facebook", "surface": "ios"]))
        XCTAssertFalse(Relay.permits(.signInSucceeded, properties: ["provider": "apple", "surface": "android"]))
        XCTAssertEqual(ProductFunnelMeasurement.ContractorLinkFailure.allCases.map(\.rawValue),
                       ["invalid_request", "not_permitted", "not_ready", "conflict", "unavailable", "server_error"])
        XCTAssertEqual(ProductFunnelMeasurement.ReportFailure.allCases.map(\.rawValue),
                       ["invalid_request", "scope_too_large", "conflict", "server_error"])
        for reason in ProductFunnelMeasurement.ContractorLinkFailure.allCases {
            XCTAssertTrue(Relay.permits(.contractorLinkCreateFailed, properties: ["reason": reason.rawValue]))
        }
        for reason in ProductFunnelMeasurement.ReportFailure.allCases {
            XCTAssertTrue(Relay.permits(.reportFailed, properties: ["reason": reason.rawValue]))
        }
        for event in [Relay.ServerOutcome.contractorLinkCreateFailed, .reportFailed] {
            XCTAssertFalse(Relay.permits(event, properties: [:]))
            XCTAssertFalse(Relay.permits(event, properties: ["reason": "Contractor link unavailable"]))
            XCTAssertFalse(Relay.permits(event, properties: ["reason": "conflict", "projectId": UUID().uuidString]))
            XCTAssertFalse(Relay.permits(event, properties: ["reason": "conflict", "recipient": "person@example.test"]))
        }
        XCTAssertFalse(Relay.permits(.contractorLinkCreateFailed, properties: ["reason": "scope_too_large"]))
        XCTAssertFalse(Relay.permits(.reportFailed, properties: ["reason": "not_ready"]))
        for event in [Relay.ServerOutcome.completionSubmitted, .completionAccepted, .completionRejected, .reportIssued] {
            XCTAssertTrue(Relay.permits(event, properties: [:]))
            XCTAssertFalse(Relay.permits(event, properties: ["reason": "conflict"]))
        }

        // Classification is by status only; free-text reasons never travel.
        let link = ProductFunnelMeasurement.contractorLinkReason
        XCTAssertEqual(link(Abort(.badRequest, reason: "Use a PIN of 4 to 8 digits")), .invalidRequest)
        XCTAssertEqual(link(Abort(.payloadTooLarge)), .invalidRequest)
        XCTAssertEqual(link(Abort(.unauthorized)), .notPermitted)
        XCTAssertEqual(link(Abort(.forbidden)), .notPermitted)
        XCTAssertEqual(link(Abort(.notFound)), .notPermitted)
        XCTAssertEqual(link(Abort(.unprocessableEntity, identifier: "link_media_not_ready")), .notReady)
        XCTAssertEqual(link(Abort(.conflict)), .conflict)
        XCTAssertEqual(link(Abort(.gone)), .conflict)
        XCTAssertEqual(link(Abort(.serviceUnavailable)), .unavailable)
        XCTAssertEqual(link(Abort(.internalServerError)), .serverError)
        XCTAssertEqual(link(NSError(domain: "synthetic", code: 1)), .serverError)
        let report = ProductFunnelMeasurement.reportReason
        XCTAssertEqual(report(Abort(.unprocessableEntity, identifier: "report_scope_too_large")), .scopeTooLarge)
        XCTAssertEqual(report(Abort(.unprocessableEntity)), .invalidRequest)
        XCTAssertEqual(report(Abort(.badRequest, identifier: "report_title_invalid")), .invalidRequest)
        XCTAssertEqual(report(Abort(.conflict)), .conflict)
        XCTAssertEqual(report(Abort(.gone, identifier: "project_archived")), .conflict)
        XCTAssertEqual(report(Abort(.forbidden)), .conflict)
        XCTAssertEqual(report(Abort(.internalServerError)), .serverError)
        XCTAssertEqual(report(NSError(domain: "synthetic", code: 2)), .serverError)

        // Even with permission, a candidate with an unlisted property is never created.
        try await enable("productAnalyticsEnabled")
        let account = try signedIn(try await nativeEmail(address()), new: true)
        try await grant(account.token)
        let refused = try await app.db.transaction { db in
            await MeasurementRelayService.outcomeCandidate(accountID: account.user.id, operationID: UUID(), installationID: nil,
                event: .reportFailed, properties: ["reason": "invalid_request", "title": "Synthetic report"],
                occurredAt: Date().addingTimeInterval(1), on: db)
        }
        XCTAssertNil(refused)

        // Client uploads cannot claim any server-authoritative funnel name.
        let revision = try await sql.raw("""
            SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:account.user.id) AND purpose='productAnalytics'
            """).first()!.decode(column: "revision", as: UUID.self)
        for (name, properties) in [("sign_in_succeeded", ["provider": "apple", "surface": "ios"]),
                                   ("contractor_link_create_failed", ["reason": "conflict"]),
                                   ("report_failed", ["reason": "conflict"]), ("account_created", [:]),
                                   ("sign_in_started", [:]), ("sign_in_failed", [:]), ("sign_in_cancelled", [:])] {
            let upload = try await request(.POST, "api/v2/measurement/events", object: [
                "eventId": UUID().uuidString, "occurredAt": date(Date().addingTimeInterval(1)),
                "consentRevision": revision.uuidString, "installationId": UUID().uuidString,
                "event": ["schemaVersion": 1, "name": name, "properties": properties]], bearer: account.token)
            XCTAssertEqual(upload.status, .badRequest, "\(name): \(upload.body.string)")
        }
    }

    // MARK: - 8. report_failed

    func testReportFailedCountsOnlyGenuineAuthorisedAttemptsOnceWithAFixedReason() async throws {
        try await enable("productAnalyticsEnabled")
        let owner = try await manager(), ownerID = try owner.requireID()
        let envelope = try await project(owner, company: true)
        _ = try await snag(owner, project: envelope)
        let member = try await manager("Synthetic funnel member"), memberID = try member.requireID()
        try await join(member, owner: owner, project: envelope, role: "member")
        try await grant(try jwt(owner))
        try await grant(try jwt(member))

        let started = Date().addingTimeInterval(-1)
        let operation = UUID()
        let longTitle = String(repeating: "Synthetic-title ", count: 10)
        let failing: [String: Any] = ["mutation": metadata(operation), "title": longTitle, "scope": [:] as [String: Any]]
        let refused = try await request(.POST, reports(envelope), object: failing, bearer: try jwt(owner))
        XCTAssertEqual(refused.status, .badRequest, refused.body.string)
        XCTAssertTrue(refused.body.string.contains("120 characters"), "the business response is unchanged")
        let retried = try await request(.POST, reports(envelope), object: failing, bearer: try jwt(owner))
        XCTAssertEqual(retried.status, .badRequest)
        let failed = try await events(ownerID, "report_failed")
        XCTAssertEqual(failed.map(\.properties), [["reason": "invalid_request"]], "one failure per operation")
        XCTAssertNil(failed.first?.installation)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(failed.first).occurredAt, started)
        XCTAssertLessThanOrEqual(try XCTUnwrap(failed.first).occurredAt, Date())
        let stored = try await sql.raw("SELECT count(*) AS n FROM issued_reports WHERE project_id=\(bind:envelope.project.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(stored, 0, "the failed issue stored nothing")

        // Refused before the attempt (no review right): not a report failure.
        let forbidden = try await request(.POST, reports(envelope), object: ["mutation": metadata(), "scope": [:] as [String: Any]],
                                          bearer: try jwt(member))
        XCTAssertEqual(forbidden.status, .forbidden, forbidden.body.string)
        let memberFailures = try await events(memberID, "report_failed")
        XCTAssertTrue(memberFailures.isEmpty)

        // A successful issue and its replay are not failures.
        let good: [String: Any] = ["mutation": metadata(), "scope": [:] as [String: Any]]
        let issued = try await request(.POST, reports(envelope), object: good, bearer: try jwt(owner))
        XCTAssertEqual(issued.status, .ok, issued.body.string)
        let replay = try await request(.POST, reports(envelope), object: good, bearer: try jwt(owner))
        XCTAssertEqual(replay.status, .ok, replay.body.string)
        let finalFailures = try await events(ownerID, "report_failed")
        XCTAssertEqual(finalFailures.count, 1)
        let issuedEvents = try await events(ownerID, "report_issued")
        XCTAssertEqual(issuedEvents.count, 1)

        let queued = try await payloads(ownerID, "report_failed")
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(try keys(queued[0]), ["event", "occurredAt", "reason"])
        for value in [envelope.project.id.uuidString, envelope.project.id.uuidString.lowercased(), operation.uuidString,
                      operation.uuidString.lowercased(), "Synthetic-title", "120 characters"] {
            XCTAssertFalse(queued[0].contains(value))
        }

        // Without product permission, a genuine failure records nothing.
        let unconsented = try await manager("Synthetic unconsented manager")
        let ownProject = try await project(unconsented)
        let silent = try await request(.POST, reports(ownProject), object: ["mutation": metadata(), "title": longTitle,
                                       "scope": [:] as [String: Any]], bearer: try jwt(unconsented))
        XCTAssertEqual(silent.status, .badRequest)
        let unconsentedFailures = try await events(try unconsented.requireID(), "report_failed")
        XCTAssertTrue(unconsentedFailures.isEmpty)
    }

    // MARK: - 9. contractor_link_create_failed

    func testContractorLinkCreateFailedRecordsFixedReasonsWithoutLinkData() async throws {
        try await enable("productAnalyticsEnabled")
        let owner = try await manager(), ownerID = try owner.requireID()
        let envelope = try await project(owner)
        let snagID = try await snag(owner, project: envelope)
        try await grant(try jwt(owner))
        let prepare = "api/v2/projects/\(envelope.project.id)/links/prepare"
        func body(_ operation: UUID = UUID(), mode: String = "read_only", pin: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["mutation": metadata(operation), "id": UUID().uuidString, "mode": mode,
                                        "snagIds": [snagID.uuidString], "assetIds": [] as [String], "durationDays": 30]
            if let pin { value["pin"] = pin }
            return value
        }

        // 1. The request itself is refused (an invalid PIN): invalid_request, PIN never recorded.
        let invalid = try await request(.POST, prepare, object: body(pin: "12ab"), bearer: try jwt(owner))
        XCTAssertEqual(invalid.status, .badRequest, invalid.body.string)
        // 2. Sharing is not configured: unavailable.
        app.storage[LinkGrantTokenKey.self] = nil
        let unconfigured = try await request(.POST, prepare, object: body(), bearer: try jwt(owner))
        XCTAssertEqual(unconfigured.status, .serviceUnavailable, unconfigured.body.string)
        // 3. Activating a link the actor cannot see: not_permitted, once per operation.
        app.storage[LinkGrantTokenKey.self] = Data(repeating: 0x5A, count: 32)
        let activation: [String: Any] = ["mutation": metadata(), "expectedRevision": 1]
        let missing = "api/v2/projects/\(envelope.project.id)/links/\(UUID())/activate"
        let unknown = try await request(.POST, missing, object: activation, bearer: try jwt(owner))
        XCTAssertEqual(unknown.status, .notFound, unknown.body.string)
        let retried = try await request(.POST, missing, object: activation, bearer: try jwt(owner))
        XCTAssertEqual(retried.status, .notFound)
        let recorded = try await events(ownerID, "contractor_link_create_failed")
        XCTAssertEqual(recorded.map { $0.properties["reason"] ?? "" }.sorted(), ["invalid_request", "not_permitted", "unavailable"])
        XCTAssertTrue(recorded.allSatisfy { $0.installation == nil && Set($0.properties.keys) == ["reason"] })

        // 4. Another consenting account preparing a link on a project it cannot share.
        let stranger = try await manager("Synthetic stranger"), strangerID = try stranger.requireID()
        try await grant(try jwt(stranger))
        let foreign = try await request(.POST, prepare, object: body(), bearer: try jwt(stranger))
        XCTAssertTrue([.notFound, .forbidden].contains(foreign.status), foreign.body.string)
        let strangerFailures = try await events(strangerID, "contractor_link_create_failed")
        XCTAssertEqual(strangerFailures.map(\.properties), [["reason": "not_permitted"]])
        let ownerAfter = try await events(ownerID, "contractor_link_create_failed")
        XCTAssertEqual(ownerAfter.count, 3, "a failure belongs to the acting account only")

        let queued = try await payloads(ownerID, "contractor_link_create_failed") + payloads(strangerID, "contractor_link_create_failed")
        XCTAssertEqual(queued.count, 4)
        for payload in queued {
            XCTAssertEqual(try keys(payload), ["event", "occurredAt", "reason"])
            for value in [envelope.project.id.uuidString.lowercased(), envelope.project.id.uuidString, snagID.uuidString,
                          snagID.uuidString.lowercased(), "12ab", "/m/", "c2_"] {
                XCTAssertFalse(payload.contains(value))
            }
        }

        // Without product permission, a failed create records nothing.
        let unconsented = try await manager("Synthetic unconsented sharer")
        let own = try await project(unconsented)
        let silent = try await request(.POST, "api/v2/projects/\(own.project.id)/links/prepare",
                                       object: body(mode: "everything"), bearer: try jwt(unconsented))
        XCTAssertEqual(silent.status, .badRequest)
        let unconsentedFailures = try await events(try unconsented.requireID(), "contractor_link_create_failed")
        XCTAssertTrue(unconsentedFailures.isEmpty)
    }

    // MARK: - 10. Portal-originated outcomes use the acting account's own permission

    func testPortalOriginatedOutcomeUsesOnlyTheActingAccountsOwnPermission() async throws {
        try await enable("productAnalyticsEnabled")
        let owner = try await manager(), ownerID = try owner.requireID()
        let envelope = try await project(owner, company: true)
        _ = try await snag(owner, project: envelope)
        let reviewer = try await manager("Synthetic portal reviewer"), reviewerID = try reviewer.requireID()
        try await join(reviewer, owner: owner, project: envelope, role: "manager")
        try await grant(try jwt(owner))
        let session = try await BrowserSessionService.create(for: reviewer, config: platform, on: app.db)
        let cookie = BrowserSessionService.cookieName + "=" + session.token

        // The reviewer has not consented: the consenting owner's permission is never borrowed.
        let first = try await request(.POST, reports(envelope), object: ["mutation": metadata(), "scope": [:] as [String: Any]],
                                      origin: platform.origin, cookie: cookie, csrf: session.principal.csrfToken)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let reviewerBefore = try await events(reviewerID, "report_issued")
        let ownerBefore = try await events(ownerID, "report_issued")
        XCTAssertTrue(reviewerBefore.isEmpty); XCTAssertTrue(ownerBefore.isEmpty)

        // After the reviewer's own grant, the portal action is theirs alone.
        try await grant(try jwt(reviewer))
        let portalDevice = UUID()
        let second = try await request(.POST, reports(envelope), object: ["mutation": metadata(device: portalDevice),
                                       "scope": [:] as [String: Any]],
                                       origin: platform.origin, cookie: cookie, csrf: session.principal.csrfToken)
        XCTAssertEqual(second.status, .ok, second.body.string)
        let reviewerAfter = try await events(reviewerID, "report_issued")
        XCTAssertEqual(reviewerAfter.count, 1)
        XCTAssertEqual(reviewerAfter.first?.installation, portalDevice, "ledger-only; never sent to the provider")
        let ownerAfter = try await events(ownerID, "report_issued")
        XCTAssertTrue(ownerAfter.isEmpty)
        let queued = try await payloads(reviewerID, "report_issued")
        XCTAssertEqual(queued.count, 1)
        XCTAssertFalse(queued[0].contains(portalDevice.uuidString.lowercased()))
        XCTAssertFalse(queued[0].contains(portalDevice.uuidString))
    }
}

// MARK: - Fixtures

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private struct FunnelAppleClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim
    let exp: ExpirationClaim; let iat: IssuedAtClaim; let nonce: String?; let email: String?; let email_verified: Bool?
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

private struct FunnelGoogleClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim; let exp: ExpirationClaim; let iat: IssuedAtClaim
    let azp: String?; let nonce: String?; let email: String?; let email_verified: Bool?; let name: String?
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

/// Serves only the two providers' public signing keys. Anything else is refused.
private struct FunnelProviderFixtureClient: Client {
    let eventLoop: EventLoop
    func delegating(to eventLoop: EventLoop) -> Client { Self(eventLoop: eventLoop) }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        guard request.method == .GET, ["https://www.googleapis.com/oauth2/v3/certs", "https://appleid.apple.com/auth/keys"].contains(request.url.string) else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .serviceUnavailable))
        }
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok,
            headers: ["Content-Type": "application/json", "Cache-Control": "max-age=3600"], body: ByteBuffer(string: Self.jwks)))
    }
    static let jwks = "{\"keys\": [{\"kty\": \"RSA\", \"alg\": \"RS256\", \"kid\": \"synthetic-rsa\", \"n\": \"uGYddtsfqUEsknHQigvKpKrqNioJzARPjKWVyxqFMGxVKZaT5xm-9OwxRpBtLQh8O1MKdDHDSCGu43s_eYMVNOgYvfEpCfp8WhT__moII9UrP9AAWJ9uvVvN03NEw-bkyOFChn1fVKeuOO8QPU1LUyWtQOKTx1aGZrFFYvz08sgPeOpRcM0wIs9xfgiodQjGhMVjNsjmQ7P02Nn54-RRGavjXQB-suKGSuAlI9Zsy7Nb1fO9ObufUWS4RiOT3Ozty-sJfYvBNR-HkiB6aSWS7-VWOdogvAf8Z1VcXVT7nXku66FvD-utG5uezKxf2iwx1E4hfKMvuIj9LJ2vwRFfEw\", \"e\": \"AQAB\"}]}"
}

private actor FunnelHTTPRecorder {
    struct Call: Sendable { let uri: String; let body: String }
    private var values: [Call] = []
    func record(_ uri: URI, _ body: Data) -> MeasurementDispatchService.Reply {
        values.append(.init(uri: uri.string, body: String(decoding: body, as: UTF8.self)))
        return .init(status: 200, retryAfter: nil)
    }
    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, _, body in await self.record(uri, body) }
    }
    func calls() -> [Call] { values }
}

/// Holds a purpose barrier on a second connection until released.
private actor FunnelLockGate {
    private var held = false
    private var released = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        heldWaiters.forEach { $0.resume() }; heldWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}
