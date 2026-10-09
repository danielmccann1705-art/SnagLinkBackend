@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Crypto

/// Genuine pre-auth signup attribution (SIGNUP-ATTRIBUTION-CONTRACT.md, required tests
/// 1, 2, 4 and 5 backend parts). Real PostgreSQL, synthetic provider proofs signed with
/// the shared synthetic RSA key, injected provider transport. No provider network.
final class SignupIntentTests: XCTestCase {
    private var app: Application!
    private let platform = PlatformConfiguration(origin: "https://portal-signup.example.test", environment: "local")
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
        app.clients.use { SignupProviderFixtureClient(eventLoop: $0.eventLoopGroup.next()) }
        ip = "signup-" + UUID().uuidString
        intents = []; accounts = []
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
    }

    override func tearDown() async throws {
        if let app {
            let sql = try VerifiedIdentityService.sql(app.db)
            for id in intents {
                if let row = try? await sql.raw("SELECT account_id FROM measurement_signup_intents WHERE id=\(bind:id)").first(),
                   let account = try? row.decode(column: "account_id", as: UUID?.self) { accounts.insert(account) }
            }
            for account in accounts {
                for table in ["measurement_dispatch_jobs", "measurement_erasure_jobs", "measurement_att_assertions",
                              "measurement_permission_current"] {
                    try? await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE account_id=\(bind:account)").run()
                }
            }
            for id in intents {
                try? await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE source_kind='signupFact' AND source_id IN (SELECT id FROM measurement_signup_facts WHERE intent_id=\(bind:id))").run()
                try? await sql.raw("DELETE FROM measurement_signup_facts WHERE intent_id=\(bind:id)").run()
                try? await sql.raw("DELETE FROM measurement_signup_intents WHERE id=\(bind:id)").run()
            }
            for account in accounts {
                try? await sql.raw("DELETE FROM measurement_signup_facts WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM account_deletion_jobs WHERE user_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM users WHERE id=\(bind:account)").run()
            }
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
            try await app.asyncShutdown()
        }
        app = nil
    }

    // MARK: - Wire helpers

    private struct Issued { let id: UUID; let capability: String; let nonce: String?; let installation: UUID }

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }

    private func request(_ method: HTTPMethod, _ path: String, object: [String: Any]? = nil, origin: String? = nil,
                         bearer: String? = nil, from address: String? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: address ?? self.ip)
            if let origin { req.headers.replaceOrAdd(name: "Origin", value: origin) }
            if let bearer { req.headers.bearerAuthorization = .init(token: bearer) }
            if let object {
                req.headers.contentType = .json
                req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
            }
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func json(_ response: XCTHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    private func issue(_ provider: String, product: Bool = true, apple: Bool = false, cross: Bool = false,
                       installation: UUID = UUID(), att: String = "authorized", notice: String = MeasurementNotice.current,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> Issued {
        var body: [String: Any] = ["provider": provider, "installationId": installation.uuidString,
                                   "noticeVersion": notice,
                                   "choices": ["productAnalytics": product, "appleAds": apple, "crossCompanyAds": cross]]
        if cross { body["attStatus"] = att; body["attObservedAt"] = date() }
        let response = try await request(.POST, "api/v2/measurement/signup-intents", object: body)
        XCTAssertEqual(response.status, .created, response.body.string, file: file, line: line)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store", file: file, line: line)
        let value = try json(response)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value["intentId"] as? String)))
        intents.append(id)
        let capability = try XCTUnwrap(value["capability"] as? String)
        XCTAssertEqual(capability.count, 43, file: file, line: line)
        XCTAssertNotNil(value["expiresAt"] as? String, file: file, line: line)
        let nonce = value["appleNonce"] as? String
        XCTAssertEqual(nonce != nil, provider == "apple", file: file, line: line)
        return .init(id: id, capability: capability, nonce: nonce, installation: installation)
    }

    private func context(_ issued: Issued, capability: String? = nil, installation: UUID? = nil,
                         att: String? = nil, observedAt: Date = Date()) -> [String: Any] {
        var value: [String: Any] = ["intentId": issued.id.uuidString, "capability": capability ?? issued.capability]
        if let att {
            value["installationId"] = (installation ?? issued.installation).uuidString
            value["attStatus"] = att
            value["attObservedAt"] = date(observedAt)
        }
        return value
    }

    private func binding(_ issued: Issued) -> [String: Any] {
        ["intentId": issued.id.uuidString, "capability": issued.capability]
    }

    private func signer() throws -> JWTSigners {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: GoogleIdentityProofTests.syntheticPrivate)), kid: "synthetic-rsa")
        return signers
    }

    private func appleToken(subject: String, nonce: String?, email: String? = nil) throws -> String {
        try signer().sign(SignupAppleClaims(iss: .init(value: "https://appleid.apple.com"), sub: .init(value: subject),
            aud: .init(value: [AppleIdentityConfiguration.releaseAudience]), exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()), nonce: nonce, email: email, email_verified: email == nil ? nil : true), kid: "synthetic-rsa")
    }

    private func apple(_ token: String, context: [String: Any]? = nil, origin: String? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["identityToken": token]
        if let context { body["measurementContext"] = context }
        return try await request(.POST, "api/v1/auth/apple", object: body, origin: origin)
    }

    private func googleChallenge(_ binding: [String: Any]? = nil, origin: String? = nil) async throws -> GoogleChallengeResponse {
        let response = try await request(.POST, "api/v2/auth/google/ios/challenge",
                                         object: binding.map { ["measurementContext": $0] }, origin: origin)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(GoogleChallengeResponse.self)
    }

    private func googleToken(_ challenge: GoogleChallengeResponse, subject: String, email: String? = nil) throws -> String {
        try signer().sign(SignupGoogleClaims(iss: .init(value: "https://accounts.google.com"), sub: .init(value: subject),
            aud: .init(value: [google.webClientID]), exp: .init(value: Date().addingTimeInterval(3600)), iat: .init(value: Date()),
            azp: google.iosClientID, nonce: challenge.nonce, email: email, email_verified: email == nil ? nil : true,
            name: "Synthetic Google manager"), kid: "synthetic-rsa")
    }

    private func googleVerify(_ challenge: GoogleChallengeResponse, subject: String, email: String? = nil,
                              context: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["challengeToken": challenge.challengeToken,
                                   "identityToken": try googleToken(challenge, subject: subject, email: email),
                                   "verifier": try XCTUnwrap(challenge.verifier)]
        if let context { body["measurementContext"] = context }
        return try await request(.POST, "api/v2/auth/google/ios/verify", object: body)
    }

    /// Requests a link, then stands in for the person tapping the emailed URL: the newest
    /// token row for that address is given a hash this test knows the raw value of.
    private func emailLink(_ email: String, binding: [String: Any]? = nil, origin: String? = nil) async throws -> String {
        var body: [String: Any] = ["email": email]
        if let binding { body["measurementContext"] = binding }
        let response = try await request(.POST, "api/v1/auth/magic-link/request", object: body, origin: origin)
        XCTAssertEqual(response.status, .noContent, response.body.string)
        XCTAssertTrue(response.body.readableBytes == 0)
        let raw = "raw-" + UUID().uuidString
        try await sql.raw("""
            UPDATE magic_link_auth_tokens SET token_hash=\(bind:SHA256Hasher.hash(token: raw))
            WHERE id=(SELECT id FROM magic_link_auth_tokens WHERE email=\(bind:EmailValidator.normalize(email))
                      ORDER BY created_at DESC LIMIT 1)
            """).run()
        return raw
    }

    private func emailVerify(_ raw: String, context: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["token": raw]
        if let context { body["measurementContext"] = context }
        return try await request(.POST, "api/v1/auth/magic-link/verify", object: body)
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

    // MARK: - Database probes

    private func state(_ intent: UUID) async throws -> (state: String, reason: String?) {
        let row = try await XCTUnwrapAsync(try await sql.raw("SELECT state,consumed_reason FROM measurement_signup_intents WHERE id=\(bind:intent)").first())
        return (try row.decode(column: "state", as: String.self), try row.decode(column: "consumed_reason", as: String?.self))
    }

    private func count(_ query: SQLQueryString) async throws -> Int {
        try await sql.raw(query).first()!.decode(column: "n", as: Int.self)
    }

    private func facts(_ account: UUID) async throws -> Int {
        try await count("SELECT count(*) AS n FROM measurement_signup_facts WHERE account_id=\(bind:account)")
    }

    private func consents(_ account: UUID) async throws -> [String] {
        try await sql.raw("SELECT purpose FROM measurement_consent_events WHERE account_id=\(bind:account) ORDER BY purpose").all()
            .map { try $0.decode(column: "purpose", as: String.self) }
    }

    private func jobs(_ account: UUID) async throws -> [(destination: String, state: String, installation: UUID?)] {
        try await sql.raw("""
            SELECT destination,state,installation_id FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:account) AND source_kind='signupFact' ORDER BY destination
            """).all().map { (try $0.decode(column: "destination", as: String.self), try $0.decode(column: "state", as: String.self),
                              try $0.decode(column: "installation_id", as: UUID?.self)) }
    }

    private func enable(_ keys: String...) async throws {
        for key in keys {
            try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
            try await FeatureFlag(key: key, enabled: true).save(on: app.db)
        }
    }

    private func configureDelivery(_ recorder: SignupHTTPRecorder) {
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox, singularURL: nil, singularAPIKey: nil,
            linkedInAccessToken: "synthetic-linkedin-token", linkedInSignupRule: "31231706",
            linkedInSubscriptionRule: "31231714", linkedInEnvironment: .sandbox)
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
    }

    private func address() -> String { "signup-\(UUID().uuidString.lowercased())@example.test" }

    // MARK: - 1. Resolver branches: exactly one fact per true insert, none otherwise

    func testEachTrueInsertBranchAdoptsOnceAndRecordsOneFact() async throws {
        let appleIntent = try await issue("apple", apple: true)
        let appleAuth = try signedIn(try await apple(try appleToken(subject: "signup-apple-\(UUID())", nonce: appleIntent.nonce),
                                                     context: context(appleIntent)), new: true)
        let googleIntent = try await issue("google")
        let challenge = try await googleChallenge(binding(googleIntent))
        let googleAuth = try signedIn(try await googleVerify(challenge, subject: "signup-google-\(UUID())",
                                                             context: context(googleIntent)), new: true)
        let emailIntent = try await issue("email")
        let raw = try await emailLink(address(), binding: binding(emailIntent))
        let emailAuth = try signedIn(try await emailVerify(raw, context: context(emailIntent)), new: true)

        for (intent, auth, expected) in [(appleIntent, appleAuth, ["appleAds", "productAnalytics"]),
                                         (googleIntent, googleAuth, ["productAnalytics"]),
                                         (emailIntent, emailAuth, ["productAnalytics"])] {
            let settled = try await state(intent.id)
            XCTAssertEqual(settled.state, "consumed_new"); XCTAssertEqual(settled.reason, "new_account")
            let factCount = try await facts(auth.user.id)
            XCTAssertEqual(factCount, 1)
            let purposes = try await consents(auth.user.id)
            XCTAssertEqual(purposes, expected)
            // Receipt time evidences the choice; the grant became effective at adoption.
            let row = try await XCTUnwrapAsync(try await sql.raw("""
                SELECT e.occurred_at,e.received_at,c.updated_at,f.occurred_at AS fact_at,i.received_at AS intent_at
                FROM measurement_consent_events e JOIN measurement_permission_current c ON c.revision=e.id
                JOIN measurement_signup_facts f ON f.account_id=e.account_id
                JOIN measurement_signup_intents i ON i.id=f.intent_id
                WHERE e.account_id=\(bind:auth.user.id) AND e.purpose='productAnalytics'
                """).first())
            let factAt = try row.decode(column: "fact_at", as: Date.self)
            XCTAssertEqual(try row.decode(column: "updated_at", as: Date.self), factAt, "eligibility equality at the creation operation")
            XCTAssertEqual(try row.decode(column: "occurred_at", as: Date.self), try row.decode(column: "intent_at", as: Date.self))
        }
        // No flag was on, so nothing was queued (eligibility frozen off).
        let queued = try await jobs(appleAuth.user.id)
        XCTAssertTrue(queued.isEmpty)
        // The capability is held only as a versioned hash.
        let stored = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE capability_hash=\(bind:appleIntent.capability)")
        XCTAssertEqual(stored, 0)
        let hashed = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE capability_hash=\(bind:SignupIntentService.capabilityHash(appleIntent.capability))")
        XCTAssertEqual(hashed, 1)
    }

    func testExistingLoginLegacyAdoptionAndLinkingNeverCreateAFact() async throws {
        // Existing Apple account.
        let subject = "signup-existing-\(UUID())"
        let first = try signedIn(try await apple(try appleToken(subject: subject, nonce: nil)), new: true)
        let again = try await issue("apple")
        let existing = try signedIn(try await apple(try appleToken(subject: subject, nonce: again.nonce), context: context(again)), new: false)
        XCTAssertEqual(existing.user.id, first.user.id)
        let existingState = try await state(again.id)
        XCTAssertEqual(existingState.state, "consumed_existing"); XCTAssertEqual(existingState.reason, "existing_account")
        let existingFacts = try await facts(first.user.id), existingConsents = try await consents(first.user.id)
        XCTAssertEqual(existingFacts, 0); XCTAssertEqual(existingConsents, [])

        // Legacy Apple account adopted by identity, not inserted.
        let legacy = User(appleUserId: "signup-legacy-\(UUID())", email: nil, name: nil)
        try await legacy.save(on: app.db)
        accounts.insert(try legacy.requireID())
        let legacyIntent = try await issue("apple")
        let adopted = try signedIn(try await apple(try appleToken(subject: legacy.appleUserId!, nonce: legacyIntent.nonce),
                                                   context: context(legacyIntent)), new: false)
        XCTAssertEqual(adopted.user.id, legacy.id)
        let legacyState = try await state(legacyIntent.id)
        XCTAssertEqual(legacyState.state, "consumed_existing")
        let legacyFacts = try await facts(try legacy.requireID())
        XCTAssertEqual(legacyFacts, 0)

        // Account-link challenges never bind an intent; a linked Google identity is an existing login.
        let linkIntent = try await issue("google")
        let start = try await request(.POST, "api/v2/account/google/challenge", object: ["measurementContext": binding(linkIntent)],
                                      bearer: first.token)
        XCTAssertEqual(start.status, .ok, start.body.string)
        let link = try start.content.decode(GoogleChallengeResponse.self)
        let linkedSubject = "signup-linked-\(UUID())"
        let linked = try await request(.POST, "api/v2/account/google/verify", object: [
            "challengeToken": link.challengeToken, "identityToken": try googleToken(link, subject: linkedSubject),
            "measurementContext": context(linkIntent)], bearer: first.token)
        XCTAssertEqual(linked.status, .ok, linked.body.string)
        let linkState = try await state(linkIntent.id)
        XCTAssertEqual(linkState.state, "issued", "an account-link challenge never binds an intent")
        let signInIntent = try await issue("google")
        let challenge = try await googleChallenge(binding(signInIntent))
        let viaLink = try signedIn(try await googleVerify(challenge, subject: linkedSubject, context: context(signInIntent)), new: false)
        XCTAssertEqual(viaLink.user.id, first.user.id)
        let signInState = try await state(signInIntent.id)
        XCTAssertEqual(signInState.state, "consumed_existing")
        let linkedFacts = try await facts(first.user.id)
        XCTAssertEqual(linkedFacts, 0)
    }

    func testConcurrentFirstSignInsCreateExactlyOneFact() async throws {
        let subject = "signup-race-\(UUID())"
        var bodies: [[String: Any]] = []
        var issuedIntents: [Issued] = []
        for _ in 0..<4 {
            let intent = try await issue("apple")
            issuedIntents.append(intent)
            bodies.append(["identityToken": try appleToken(subject: subject, nonce: intent.nonce), "measurementContext": context(intent)])
        }
        let application = app!, address = ip
        let payloads = try bodies.map { try JSONSerialization.data(withJSONObject: $0) }
        let results = try await withThrowingTaskGroup(of: (UInt, Data).self) { group in
            for payload in payloads {
                group.addTask {
                    var result: (UInt, Data) = (0, Data())
                    try await application.test(.POST, "api/v1/auth/apple", beforeRequest: { req in
                        req.headers.replaceOrAdd(name: "X-Forwarded-For", value: address)
                        req.headers.contentType = .json
                        req.body = .init(data: payload)
                    }, afterResponse: { response async in result = (response.status.code, Data(response.body.readableBytesView)) })
                    return result
                }
            }
            var values: [(UInt, Data)] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.map(\.0), [200, 200, 200, 200])
        let auths = try results.map { try JSONDecoder().decode(AuthResponse.self, from: $0.1) }
        auths.forEach { accounts.insert($0.user.id) }
        XCTAssertEqual(Set(auths.map(\.user.id)).count, 1)
        XCTAssertEqual(auths.filter(\.isNewUser).count, 1)
        let factCount = try await facts(auths[0].user.id)
        XCTAssertEqual(factCount, 1)
        var states: [String] = []
        for intent in issuedIntents { states.append(try await state(intent.id).state) }
        XCTAssertEqual(states.filter { $0 == "consumed_new" }.count, 1)
        XCTAssertEqual(states.filter { $0 == "consumed_existing" }.count, 3)
    }

    func testRolledBackCoreTransactionLeavesTheIntentUnusedAndCreatesNothing() async throws {
        let held = address()
        _ = try signedIn(try await emailVerify(try await emailLink(held)), new: true)
        let intent = try await issue("apple")
        let refused = try await apple(try appleToken(subject: "signup-refused-\(UUID())", nonce: intent.nonce, email: held),
                                      context: context(intent))
        XCTAssertEqual(refused.status, .conflict)
        let afterRefusal = try await state(intent.id)
        XCTAssertEqual(afterRefusal.state, "bound", "the rolled-back identity transaction took the optional block with it")
        let orphanConsents = try await count("SELECT count(*) AS n FROM measurement_consent_events WHERE request_id=\(bind:SignupIntentService.derivedID("signup-consent-v1", intent.id, "productAnalytics"))")
        XCTAssertEqual(orphanConsents, 0)
        let created = try signedIn(try await apple(try appleToken(subject: "signup-after-refusal-\(UUID())", nonce: intent.nonce),
                                                   context: context(intent)), new: true)
        let factCount = try await facts(created.user.id)
        XCTAssertEqual(factCount, 1)
    }

    // MARK: - 2. Intent service and auth binding

    func testSubstitutedCapabilityProviderSurfaceEnvironmentOrChallengeIsSuppressed() async throws {
        // Capability: the verified nonce proves the binding, the capability does not match.
        let wrongCapability = try await issue("apple")
        let a = try signedIn(try await apple(try appleToken(subject: "signup-cap-\(UUID())", nonce: wrongCapability.nonce),
                                             context: context(wrongCapability, capability: String(repeating: "A", count: 43))), new: true)
        let aFacts = try await facts(a.user.id), aState = try await state(wrongCapability.id)
        XCTAssertEqual(aFacts, 0); XCTAssertEqual(aState.state, "consumed_existing"); XCTAssertEqual(aState.reason, "context_absent")

        // Provider: a Google intent cannot ride an Apple token.
        let googleIntent = try await issue("google")
        let b = try signedIn(try await apple(try appleToken(subject: "signup-provider-\(UUID())", nonce: googleIntent.capability),
                                             context: context(googleIntent)), new: true)
        let bFacts = try await facts(b.user.id), bState = try await state(googleIntent.id)
        XCTAssertEqual(bFacts, 0); XCTAssertEqual(bState.state, "issued")

        // Encoding: the app sets the nonce verbatim; a hashed nonce in the token never matches.
        let hashed = try await issue("apple")
        let c = try signedIn(try await apple(try appleToken(subject: "signup-hashed-\(UUID())", nonce: SHA256Hasher.hash(token: hashed.nonce!)),
                                             context: context(hashed)), new: true)
        let cFacts = try await facts(c.user.id), cState = try await state(hashed.id)
        XCTAssertEqual(cFacts, 0); XCTAssertEqual(cState.state, "bound")

        // Surface: browser requests never bind or adopt native intents.
        let browser = try await issue("google")
        let webStart = try await request(.POST, "api/v2/auth/google/challenge", object: ["measurementContext": binding(browser)],
                                         origin: platform.origin)
        XCTAssertEqual(webStart.status, .ok)
        let browserState = try await state(browser.id)
        XCTAssertEqual(browserState.state, "issued")
        let browserIntentRoute = try await request(.POST, "api/v2/measurement/signup-intents", object: [
            "provider": "email", "installationId": UUID().uuidString, "noticeVersion": "signup-measurement-v1",
            "choices": ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false]], origin: platform.origin)
        XCTAssertEqual(browserIntentRoute.status, .forbidden)
        let emailBrowser = try await issue("email")
        _ = try await emailLink(address(), binding: binding(emailBrowser), origin: platform.origin)
        let emailBrowserState = try await state(emailBrowser.id)
        XCTAssertEqual(emailBrowserState.state, "issued")
        let nativeOnApple = try await issue("apple")
        let d = try signedIn(try await apple(try appleToken(subject: "signup-web-\(UUID())", nonce: nativeOnApple.nonce),
                                             context: context(nativeOnApple), origin: platform.origin), new: true)
        let dFacts = try await facts(d.user.id)
        XCTAssertEqual(dFacts, 0)

        // Environment: an intent issued for one environment never adopts in another.
        let local = try await issue("apple")
        app.storage[PlatformConfigurationKey.self] = .init(origin: platform.origin, environment: "staging")
        let e = try signedIn(try await apple(try appleToken(subject: "signup-env-\(UUID())", nonce: local.nonce),
                                             context: context(local)), new: true)
        let eFacts = try await facts(e.user.id), eState = try await state(local.id)
        XCTAssertEqual(eFacts, 0); XCTAssertEqual(eState.state, "bound")
        app.storage[PlatformConfigurationKey.self] = platform

        // Challenge: an intent bound to challenge A is not adopted through challenge B.
        let boundToA = try await issue("google")
        _ = try await googleChallenge(binding(boundToA))
        let challengeB = try await googleChallenge()
        let f = try signedIn(try await googleVerify(challengeB, subject: "signup-challenge-\(UUID())", context: context(boundToA)), new: true)
        let fFacts = try await facts(f.user.id), fState = try await state(boundToA.id)
        XCTAssertEqual(fFacts, 0); XCTAssertEqual(fState.state, "bound")
        // Rebinding is refused: a second challenge cannot take the same intent.
        let challengeC = try await googleChallenge(binding(boundToA))
        let rebound = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:boundToA.id) AND binding_id IS NOT NULL")
        XCTAssertEqual(rebound, 1)
        _ = challengeC
    }

    func testExpiredReusedAndCancelledIntentsNeverAdopt() async throws {
        let expired = try await issue("apple")
        try await sql.raw("""
            UPDATE measurement_signup_intents SET received_at=received_at-interval '20 minutes',
                expires_at=now()-interval '1 second' WHERE id=\(bind:expired.id)
            """).run()
        let a = try signedIn(try await apple(try appleToken(subject: "signup-expired-\(UUID())", nonce: expired.nonce),
                                             context: context(expired)), new: true)
        let aFacts = try await facts(a.user.id)
        XCTAssertEqual(aFacts, 0)

        let reused = try await issue("apple")
        let first = try signedIn(try await apple(try appleToken(subject: "signup-reuse-1-\(UUID())", nonce: reused.nonce),
                                                 context: context(reused)), new: true)
        let second = try signedIn(try await apple(try appleToken(subject: "signup-reuse-2-\(UUID())", nonce: reused.nonce),
                                                  context: context(reused)), new: true)
        let firstFacts = try await facts(first.user.id), secondFacts = try await facts(second.user.id)
        XCTAssertEqual(firstFacts, 1); XCTAssertEqual(secondFacts, 0)

        let cancelled = try await issue("google")
        let challenge = try await googleChallenge(binding(cancelled))
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(cancelled.id)/cancel",
                                       object: ["capability": cancelled.capability])
        XCTAssertEqual(cancel.status, .ok)
        XCTAssertEqual(try json(cancel)["state"] as? String, "cancelled")
        let c = try signedIn(try await googleVerify(challenge, subject: "signup-cancelled-\(UUID())", context: context(cancelled)), new: true)
        let cFacts = try await facts(c.user.id), cConsents = try await consents(c.user.id)
        XCTAssertEqual(cFacts, 0); XCTAssertEqual(cConsents, [])
        let cState = try await state(cancelled.id)
        XCTAssertEqual(cState.state, "cancelled")
    }

    func testEmailSameDeviceOtherDeviceAndResend() async throws {
        let same = try await issue("email")
        let sameAuth = try signedIn(try await emailVerify(try await emailLink(address(), binding: binding(same)),
                                                          context: context(same)), new: true)
        let sameFacts = try await facts(sameAuth.user.id)
        XCTAssertEqual(sameFacts, 1)

        // The emailed token alone authenticates elsewhere; the intent ends import-free.
        let other = try await issue("email")
        let otherAuth = try signedIn(try await emailVerify(try await emailLink(address(), binding: binding(other))), new: true)
        let otherFacts = try await facts(otherAuth.user.id), otherConsents = try await consents(otherAuth.user.id)
        XCTAssertEqual(otherFacts, 0); XCTAssertEqual(otherConsents, [])
        let otherState = try await state(other.id)
        XCTAssertEqual(otherState.state, "consumed_existing"); XCTAssertEqual(otherState.reason, "context_absent")

        // A resend is a new token; it cannot reuse a capability attached to the first link.
        let resend = try await issue("email")
        let resendAddress = address()
        _ = try await emailLink(resendAddress, binding: binding(resend))
        let secondRaw = try await emailLink(resendAddress, binding: binding(resend))
        let resent = try signedIn(try await emailVerify(secondRaw, context: context(resend)), new: true)
        let resentFacts = try await facts(resent.user.id)
        XCTAssertEqual(resentFacts, 0)
        let resendState = try await state(resend.id)
        XCTAssertEqual(resendState.state, "bound", "still bound to the first link only")
    }

    func testRateLimitStrictDTOsNoStoreAndRedaction() async throws {
        let base: [String: Any] = ["provider": "email", "installationId": UUID().uuidString, "noticeVersion": "signup-measurement-v1",
                                   "choices": ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false]]
        var unknown = base; unknown["email"] = "person@example.test"
        let unknownField = try await request(.POST, "api/v2/measurement/signup-intents", object: unknown)
        XCTAssertEqual(unknownField.status, .badRequest)
        XCTAssertTrue(unknownField.body.string.contains("measurement_request_invalid"))
        XCTAssertEqual(unknownField.headers.first(name: .cacheControl), "no-store")
        var notice = base; notice["noticeVersion"] = "signup-measurement-v0"
        let staleNotice = try await request(.POST, "api/v2/measurement/signup-intents", object: notice)
        XCTAssertTrue(staleNotice.body.string.contains("measurement_notice_invalid"))
        var none = base; none["choices"] = ["productAnalytics": false, "appleAds": false, "crossCompanyAds": false]
        let empty = try await request(.POST, "api/v2/measurement/signup-intents", object: none)
        XCTAssertTrue(empty.body.string.contains("measurement_choices_empty"))
        var cross = base; cross["choices"] = ["productAnalytics": false, "appleAds": false, "crossCompanyAds": true]
        let missingATT = try await request(.POST, "api/v2/measurement/signup-intents", object: cross)
        XCTAssertTrue(missingATT.body.string.contains("measurement_att_invalid"))
        var stray = base; stray["attStatus"] = "authorized"; stray["attObservedAt"] = date()
        let unexpectedATT = try await request(.POST, "api/v2/measurement/signup-intents", object: stray)
        XCTAssertTrue(unexpectedATT.body.string.contains("measurement_att_unexpected"))
        var extraChoice = base; extraChoice["choices"] = ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false, "singular": true]
        let extra = try await request(.POST, "api/v2/measurement/signup-intents", object: extraChoice)
        XCTAssertEqual(extra.status, .badRequest)

        // Cancellation: capability in the body only, uniform 404, never echoed.
        let intent = try await issue("google")
        let wrong = String(repeating: "B", count: 43)
        let refused = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": wrong])
        XCTAssertEqual(refused.status, .notFound)
        XCTAssertFalse(refused.body.string.contains(wrong)); XCTAssertFalse(refused.body.string.contains(intent.capability))
        let unknownIntent = try await request(.POST, "api/v2/measurement/signup-intents/\(UUID())/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(unknownIntent.status, .notFound)
        // Unknown intent and wrong capability are indistinguishable.
        XCTAssertEqual(try json(unknownIntent) as NSDictionary, try json(refused) as NSDictionary)
        let extraCancel = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel",
                                            object: ["capability": intent.capability, "accountId": UUID().uuidString])
        XCTAssertEqual(extraCancel.status, .badRequest)
        let ok = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.headers.first(name: .cacheControl), "no-store")
        XCTAssertFalse(ok.body.string.contains(intent.capability))
        let again = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(try json(again)["state"] as? String, "cancelled", "idempotent")

        // Fifteen per installation and window (five sign-in screen views of three intents);
        // the next from that installation is refused before anything is written.
        let flood = "signup-flood-" + UUID().uuidString
        // A fresh installation: the vocabulary checks above already used `base`'s bucket.
        var floodBody = base; floodBody["installationId"] = UUID().uuidString
        var created = 0
        for _ in 0..<15 {
            let response = try await request(.POST, "api/v2/measurement/signup-intents", object: floodBody, from: flood)
            if response.status == .created, let id = UUID(uuidString: try json(response)["intentId"] as? String ?? "") {
                intents.append(id); created += 1
            }
        }
        XCTAssertEqual(created, 15)
        let limited = try await request(.POST, "api/v2/measurement/signup-intents", object: floodBody, from: flood)
        XCTAssertEqual(limited.status, .tooManyRequests)
        XCTAssertEqual(limited.headers.first(name: .cacheControl), "no-store")
        XCTAssertNotNil(limited.headers.first(name: "Retry-After"))
        // The same installation from another address is still limited: the bucket is per installation.
        let elsewhere = try await request(.POST, "api/v2/measurement/signup-intents", object: floodBody, from: "signup-other-" + UUID().uuidString)
        XCTAssertEqual(elsewhere.status, .tooManyRequests)
        // Other installations behind the same shared address continue until the address
        // ceiling (60 per window, three times the former 20) is reached: 16 requests above
        // plus 44 here. The address ceiling remains the abuse bound, since installation IDs
        // are chosen by the client.
        var shared = 0
        for _ in 0..<44 {
            var other = floodBody; other["installationId"] = UUID().uuidString
            let response = try await request(.POST, "api/v2/measurement/signup-intents", object: other, from: flood)
            if response.status == .created, let id = UUID(uuidString: try json(response)["intentId"] as? String ?? "") {
                intents.append(id); shared += 1
            }
        }
        XCTAssertEqual(shared, 44)
        var fresh = floodBody; fresh["installationId"] = UUID().uuidString
        let ceiling = try await request(.POST, "api/v2/measurement/signup-intents", object: fresh, from: flood)
        XCTAssertEqual(ceiling.status, .tooManyRequests)
        XCTAssertEqual(ceiling.headers.first(name: .cacheControl), "no-store")
        let floodInstallation = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(floodBody["installationId"] as? String)))
        let rows = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE installation_id=\(bind:floodInstallation)")
        XCTAssertEqual(rows, 15, "refused requests wrote nothing")
    }

    // MARK: - 4. Atomic fact, eligibility freeze, replay and cancellation

    func testLostResponseReplayNeverCreatesASecondFact() async throws {
        try await enable("productAnalyticsEnabled")
        let intent = try await issue("apple")
        let body: [String: Any] = ["identityToken": try appleToken(subject: "signup-replay-\(UUID())", nonce: intent.nonce),
                                   "measurementContext": context(intent)]
        let first = try signedIn(try await request(.POST, "api/v1/auth/apple", object: body), new: true)
        let replay = try signedIn(try await request(.POST, "api/v1/auth/apple", object: body), new: false)
        XCTAssertEqual(first.user.id, replay.user.id)
        let factCount = try await facts(first.user.id), queued = try await jobs(first.user.id)
        XCTAssertEqual(factCount, 1)
        XCTAssertEqual(queued.map(\.destination), ["posthog"])

        let googleIntent = try await issue("google")
        let challenge = try await googleChallenge(binding(googleIntent))
        let subject = "signup-google-replay-\(UUID())"
        let googleBody: [String: Any] = ["challengeToken": challenge.challengeToken,
                                         "identityToken": try googleToken(challenge, subject: subject),
                                         "verifier": try XCTUnwrap(challenge.verifier), "measurementContext": context(googleIntent)]
        let googleFirst = try signedIn(try await request(.POST, "api/v2/auth/google/ios/verify", object: googleBody), new: true)
        let googleReplay = try await request(.POST, "api/v2/auth/google/ios/verify", object: googleBody)
        XCTAssertEqual(googleReplay.status, .gone)
        let googleFacts = try await facts(googleFirst.user.id)
        XCTAssertEqual(googleFacts, 1)

        let emailIntent = try await issue("email")
        let raw = try await emailLink(address(), binding: binding(emailIntent))
        let emailFirst = try signedIn(try await emailVerify(raw, context: context(emailIntent)), new: true)
        let emailReplay = try await emailVerify(raw, context: context(emailIntent))
        XCTAssertEqual(emailReplay.status, .gone)
        let emailFacts = try await facts(emailFirst.user.id)
        XCTAssertEqual(emailFacts, 1)
    }

    func testLaterOptInRegrantOrFlagActivationAddsNothing() async throws {
        let intent = try await issue("google")
        let challenge = try await googleChallenge(binding(intent))
        let auth = try signedIn(try await googleVerify(challenge, subject: "signup-late-\(UUID())", context: context(intent)), new: true)
        let frozen = try await XCTUnwrapAsync(try await sql.raw("SELECT product_eligible FROM measurement_signup_facts WHERE account_id=\(bind:auth.user.id)").first())
        XCTAssertFalse(try frozen.decode(column: "product_eligible", as: Bool.self))

        try await enable("productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled")
        let recorder = SignupHTTPRecorder()
        configureDelivery(recorder)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let current = try await XCTUnwrapAsync(try await sql.raw("SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:auth.user.id) AND purpose='productAnalytics'").first())
        let regrant = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "expectedRevision": try current.decode(column: "revision", as: UUID.self).uuidString,
            "decision": "granted", "occurredAt": date()], bearer: auth.token)
        XCTAssertEqual(regrant.status, .ok, regrant.body.string)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let queued = try await jobs(auth.user.id)
        XCTAssertTrue(queued.isEmpty)
        let calls = await recorder.calls()
        XCTAssertTrue(calls.allSatisfy { !$0.body.contains("account_created") })
    }

    func testDeniedOrForeignInstallationATTSuppressesOnlyCrossCompany() async throws {
        try await enable("productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled")
        let denied = try await issue("apple", apple: true, cross: true)
        let a = try signedIn(try await apple(try appleToken(subject: "signup-denied-\(UUID())", nonce: denied.nonce, email: address()),
                                             context: context(denied, att: "denied")), new: true)
        let aConsents = try await consents(a.user.id), aJobs = try await jobs(a.user.id)
        XCTAssertEqual(aConsents, ["appleAds", "productAnalytics"])
        XCTAssertEqual(aJobs.map(\.destination), ["posthog"])

        let foreign = try await issue("apple", cross: true)
        let b = try signedIn(try await apple(try appleToken(subject: "signup-foreign-\(UUID())", nonce: foreign.nonce, email: address()),
                                             context: context(foreign, installation: UUID(), att: "authorized")), new: true)
        let bConsents = try await consents(b.user.id), bJobs = try await jobs(b.user.id)
        XCTAssertEqual(bConsents, ["productAnalytics"])
        XCTAssertEqual(bJobs.map(\.destination), ["posthog"])

        // Cross-company alone with denied ATT: a new account, nothing adopted, no fact.
        let crossOnly = try await issue("apple", product: false, cross: true)
        let only = try signedIn(try await apple(try appleToken(subject: "signup-cross-only-\(UUID())", nonce: crossOnly.nonce),
                                                context: context(crossOnly, att: "denied")), new: true)
        let onlyConsents = try await consents(only.user.id), onlyFacts = try await facts(only.user.id)
        XCTAssertEqual(onlyConsents, []); XCTAssertEqual(onlyFacts, 0)
        let onlyState = try await state(crossOnly.id)
        XCTAssertEqual(onlyState.state, "consumed_existing"); XCTAssertEqual(onlyState.reason, "nothing_eligible")

        let stale = try await issue("apple", cross: true)
        let c = try signedIn(try await apple(try appleToken(subject: "signup-stale-\(UUID())", nonce: stale.nonce, email: address()),
                                             context: context(stale, att: "authorized", observedAt: Date().addingTimeInterval(-3600))), new: true)
        let cConsents = try await consents(c.user.id)
        XCTAssertEqual(cConsents, ["productAnalytics"])

        // Same installation, fresh authorised ATT and a verified address: the gated LinkedIn row exists.
        let fresh = try await issue("apple", cross: true)
        let d = try signedIn(try await apple(try appleToken(subject: "signup-fresh-\(UUID())", nonce: fresh.nonce, email: address()),
                                             context: context(fresh, att: "authorized")), new: true)
        let dConsents = try await consents(d.user.id), dJobs = try await jobs(d.user.id)
        XCTAssertEqual(dConsents, ["crossCompanyAds", "productAnalytics"])
        XCTAssertEqual(dJobs.map(\.destination), ["linkedin", "posthog"])
        XCTAssertEqual(dJobs.first?.installation, fresh.installation)
        XCTAssertNil(dJobs.last?.installation)

        // No pre-event verified address (relay) means no LinkedIn row, other purposes unaffected.
        let relay = try await issue("apple", cross: true)
        let e = try signedIn(try await apple(try appleToken(subject: "signup-relay-\(UUID())", nonce: relay.nonce,
                                                            email: "r\(UUID().uuidString.prefix(8).lowercased())@privaterelay.appleid.com"),
                                             context: context(relay, att: "authorized")), new: true)
        let eJobs = try await jobs(e.user.id)
        XCTAssertEqual(eJobs.map(\.destination), ["posthog"])
    }

    func testCancellationBeforeAndAfterCommitWithdrawsOnlyThisIntentsRevisions() async throws {
        try await enable("productAnalyticsEnabled")
        // After commit: the exact imported revisions and pending dispatch are withdrawn.
        let intent = try await issue("email", apple: true)
        let auth = try signedIn(try await emailVerify(try await emailLink(address(), binding: binding(intent)),
                                                      context: context(intent)), new: true)
        let queued = try await jobs(auth.user.id)
        XCTAssertEqual(queued.map(\.state), ["pending"])
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(cancel.status, .ok, cancel.body.string)
        XCTAssertEqual(try json(cancel)["state"] as? String, "cancelled")
        let current = try await sql.raw("SELECT purpose,decision,subject_id FROM measurement_permission_current WHERE account_id=\(bind:auth.user.id) ORDER BY purpose").all()
        XCTAssertEqual(try current.map { try $0.decode(column: "decision", as: String.self) }, ["withdrawn", "withdrawn"])
        XCTAssertTrue(try current.allSatisfy { try $0.decode(column: "subject_id", as: UUID?.self) == nil })
        let afterCancel = try await jobs(auth.user.id)
        XCTAssertEqual(afterCancel.map(\.state), ["suppressed"])
        let withdrawn = try await count("SELECT count(*) AS n FROM measurement_signup_facts WHERE account_id=\(bind:auth.user.id) AND withdrawn_at IS NOT NULL")
        XCTAssertEqual(withdrawn, 1)
        let again = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(try json(again)["state"] as? String, "cancelled")
        let withdrawals = try await count("SELECT count(*) AS n FROM measurement_consent_events WHERE account_id=\(bind:auth.user.id) AND decision='withdrawn'")
        XCTAssertEqual(withdrawals, 2, "an idempotent repeat writes nothing more")

        // A later, independently chosen revision is never touched; the signup dispatch still is.
        let later = try await issue("google")
        let challenge = try await googleChallenge(binding(later))
        let other = try signedIn(try await googleVerify(challenge, subject: "signup-later-\(UUID())", context: context(later)), new: true)
        let adopted = try await XCTUnwrapAsync(try await sql.raw("SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:other.user.id) AND purpose='productAnalytics'").first())
        let changed = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "expectedRevision": try adopted.decode(column: "revision", as: UUID.self).uuidString,
            "decision": "granted", "occurredAt": date()], bearer: other.token)
        XCTAssertEqual(changed.status, .ok, changed.body.string)
        let laterCancel = try await request(.POST, "api/v2/measurement/signup-intents/\(later.id)/cancel", object: ["capability": later.capability])
        XCTAssertEqual(laterCancel.status, .ok)
        let kept = try await XCTUnwrapAsync(try await sql.raw("SELECT decision,subject_id FROM measurement_permission_current WHERE account_id=\(bind:other.user.id) AND purpose='productAnalytics'").first())
        XCTAssertEqual(try kept.decode(column: "decision", as: String.self), "granted")
        XCTAssertNotNil(try kept.decode(column: "subject_id", as: UUID?.self))
        let otherJobs = try await jobs(other.user.id)
        XCTAssertEqual(otherJobs.map(\.state), ["suppressed"])
    }

    func testOptionalLockContentionOrSQLFailureCommitsAuthenticationUnmeasured() async throws {
        try await enable("productAnalyticsEnabled")
        // A real SQL error inside the savepoint after consent rows were written.
        app.storage[SignupIntentService.HookKey.self] = { stage, _, sql in
            if stage == .afterConsent { try await sql.raw("SELECT 1/0").run() }
        }
        let failing = try await issue("apple", apple: true)
        let a = try signedIn(try await apple(try appleToken(subject: "signup-sqlfail-\(UUID())", nonce: failing.nonce),
                                             context: context(failing)), new: true)
        let aConsents = try await consents(a.user.id), aFacts = try await facts(a.user.id), aJobs = try await jobs(a.user.id)
        XCTAssertEqual(aConsents, []); XCTAssertEqual(aFacts, 0); XCTAssertTrue(aJobs.isEmpty)
        let aSubjects = try await count("SELECT count(*) AS n FROM measurement_subjects WHERE account_id=\(bind:a.user.id)")
        XCTAssertEqual(aSubjects, 0)
        let aState = try await state(failing.id)
        XCTAssertEqual(aState.state, "bound")
        app.storage[SignupIntentService.HookKey.self] = nil

        // A busy purpose barrier (held by another connection) is tried, never awaited.
        var loops = app.eventLoopGroup.makeIterator()
        let loopA = loops.next()!, loopB = loops.next() ?? loopA
        let dbA = app.databases.database(.psql, logger: app.logger, on: loopA)!
        let dbB = app.databases.database(.psql, logger: app.logger, on: loopB)!
        // Everything that needs a pooled connection happens before the holder takes one.
        let busy = try await issue("email")
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: UUID().uuidString), email: address(),
                                       expiresAt: Date().addingTimeInterval(900))
        let application = app!
        let busyContext = SignupMeasurementContext(intentId: busy.id, capability: busy.capability)
        let bound = try await dbA.transaction { db -> Bool in
            try await token.save(on: db)
            return await SignupIntentService.bind(.init(intentId: busy.id, capability: busy.capability),
                                                  to: .emailToken(id: try token.requireID(), expiresAt: token.expiresAt), app: application, on: db)
        }
        XCTAssertTrue(bound)
        let cancelling = try await issue("email")
        let second = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: UUID().uuidString), email: address(),
                                        expiresAt: Date().addingTimeInterval(900))
        let secondBound = try await dbA.transaction { db -> Bool in
            try await second.save(on: db)
            return await SignupIntentService.bind(.init(intentId: cancelling.id, capability: cancelling.capability),
                                                  to: .emailToken(id: try second.requireID(), expiresAt: second.expiresAt), app: application, on: db)
        }
        XCTAssertTrue(secondBound)
        let barrier = SignupLockHolder()
        app.storage[SignupIntentService.HookKey.self] = { stage, accountID, _ in
            guard stage == .beforePurposeLocks else { return }
            await barrier.provide("measurement-permission:\(accountID.uuidString):productAnalytics")
            await barrier.waitUntilLocked()
        }
        let holder = Task {
            try await dbB.transaction { tx in
                let key = await barrier.waitForKey()
                try await VerifiedIdentityService.lock(key, on: tx)
                await barrier.markLocked()
                await barrier.waitForRelease()
            }
        }
        let started = Date()
        let (resolution, settlement) = try await dbA.transaction { db -> (VerifiedIdentityService.Resolution, SignupIntentService.Settlement) in
            let resolution = try await VerifiedIdentityService.resolveEmailOutcome(token.email, name: nil, on: db)
            let settlement = await SignupIntentService.settle(.emailToken(try token.requireID()), context: busyContext,
                                                              resolution: resolution, app: application, on: db)
            return (resolution, settlement)
        }
        await barrier.release()
        try await holder.value
        accounts.insert(try resolution.user.requireID())
        XCTAssertTrue(resolution.insertedNewAccount)
        XCTAssertEqual(settlement, .suppressed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "authentication never waited for the barrier")
        let busyAccount = try resolution.user.requireID()
        let busyConsents = try await consents(busyAccount)
        XCTAssertEqual(busyConsents, [])
        let committed = try await count("SELECT count(*) AS n FROM users WHERE id=\(bind:busyAccount)")
        XCTAssertEqual(committed, 1)
        app.storage[SignupIntentService.HookKey.self] = nil

        // A cancellation holding the intent row wins; authentication proceeds unmeasured.
        let rowLock = SignupLockHolder()
        let rowHolder = Task {
            try await dbB.transaction { tx in
                _ = try await VerifiedIdentityService.sql(tx).raw("SELECT id FROM measurement_signup_intents WHERE id=\(bind:cancelling.id) FOR UPDATE").first()
                await rowLock.markLocked()
                await rowLock.waitForRelease()
            }
        }
        await rowLock.waitUntilLocked()
        let cancellingContext = SignupMeasurementContext(intentId: cancelling.id, capability: cancelling.capability)
        let (secondResolution, secondSettlement) = try await dbA.transaction { db -> (VerifiedIdentityService.Resolution, SignupIntentService.Settlement) in
            let resolution = try await VerifiedIdentityService.resolveEmailOutcome(second.email, name: nil, on: db)
            let settlement = await SignupIntentService.settle(.emailToken(try second.requireID()), context: cancellingContext,
                                                              resolution: resolution, app: application, on: db)
            return (resolution, settlement)
        }
        await rowLock.release()
        try await rowHolder.value
        accounts.insert(try secondResolution.user.requireID())
        XCTAssertTrue(secondResolution.insertedNewAccount)
        XCTAssertEqual(secondSettlement, .suppressed)
        let secondFacts = try await facts(try secondResolution.user.requireID())
        XCTAssertEqual(secondFacts, 0)
    }

    func testDeletionScrubsIntentAndFactJoins() async throws {
        try await enable("productAnalyticsEnabled")
        let intent = try await issue("apple", apple: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-delete-\(UUID())", nonce: intent.nonce),
                                                context: context(intent)), new: true)
        let job = UUID()
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:job),\(bind:auth.user.id),\(bind:SHA256Hasher.hash(token: "signup-deletion-\(job)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        try await app.db.transaction { tx in
            _ = try await VerifiedIdentityService.sql(tx).raw("SELECT id FROM users WHERE id=\(bind:auth.user.id) FOR UPDATE").first()
            try await MeasurementPrivacyService.eraseAccount(auth.user.id, accountDeletionJobID: job, now: Date(), on: tx)
        }
        let row = try await XCTUnwrapAsync(try await sql.raw("""
            SELECT state,account_id,installation_id,capability_hash,apple_nonce_hash,product_revision,apple_revision,scrubbed_at
            FROM measurement_signup_intents WHERE id=\(bind:intent.id)
            """).first())
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "consumed_new", "tombstone keeps the dedup state")
        for column in ["account_id", "installation_id", "product_revision", "apple_revision"] {
            XCTAssertNil(try row.decode(column: column, as: UUID?.self), column)
        }
        XCTAssertNil(try row.decode(column: "capability_hash", as: String?.self))
        XCTAssertNil(try row.decode(column: "apple_nonce_hash", as: String?.self))
        XCTAssertNotNil(try row.decode(column: "scrubbed_at", as: Date?.self))
        let linked = try await facts(auth.user.id)
        XCTAssertEqual(linked, 0)
        let kept = try await count("SELECT count(*) AS n FROM measurement_signup_facts WHERE intent_id=\(bind:intent.id)")
        XCTAssertEqual(kept, 0, "the per-account deduplication record goes with the account")
        let dispatch = try await count("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:auth.user.id)")
        XCTAssertEqual(dispatch, 0)
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(cancel.status, .notFound, "a scrubbed capability no longer resolves")
        // The intent's tombstone is pruned on the ordinary schedule, 30 days after scrubbing.
        _ = try await SignupIntentService.cleanup(now: Date().addingTimeInterval(29 * 86_400), on: app.db)
        let early = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:intent.id)")
        XCTAssertEqual(early, 1)
        _ = try await SignupIntentService.cleanup(now: Date().addingTimeInterval(31 * 86_400), on: app.db)
        let pruned = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:intent.id)")
        XCTAssertEqual(pruned, 0)
    }

    // MARK: - Final notice and finite tombstones (FINAL-PRIVACY-NOTICE-2.0.1.md)

    /// Every adopted revision records the notice its intent was issued under: the current notice
    /// and the historical draft each keep exactly their own coverage. The Singular alternative and
    /// unknown versions are refused before anything is written.
    func testAdoptionRecordsTheIntentsNoticeOnEveryRevisionAndRefusesOthers() async throws {
        try await enable("productAnalyticsEnabled")
        for notice in [MeasurementNotice.current, MeasurementNotice.signupDraft] {
            let intent = try await issue("apple", apple: true, notice: notice)
            let auth = try signedIn(try await apple(try appleToken(subject: "signup-notice-\(UUID())", nonce: intent.nonce),
                                                    context: context(intent)), new: true)
            let recorded = try await sql.raw("""
                SELECT purpose,notice_version FROM measurement_consent_events WHERE account_id=\(bind:auth.user.id) ORDER BY purpose
                """).all().map { "\(try $0.decode(column: "purpose", as: String.self))=\(try $0.decode(column: "notice_version", as: String?.self) ?? "nil")" }
            XCTAssertEqual(recorded, ["appleAds=\(notice)", "productAnalytics=\(notice)"])
            let read = try await request(.GET, "api/v2/measurement/permissions", bearer: auth.token)
            let product = try XCTUnwrap((try json(read)["permissions"] as? [[String: Any]])?.first { $0["purpose"] as? String == "productAnalytics" })
            XCTAssertEqual(product["noticeVersion"] as? String, notice)
            XCTAssertEqual(product["coversPortal"] as? Bool, notice == MeasurementNotice.current,
                           "only the current notice covers the web portal; the draft stays app-only")
        }
        for notice in [MeasurementNotice.singularAlternative, "measurement-notice-2026-10c"] {
            let refused = try await request(.POST, "api/v2/measurement/signup-intents", object: [
                "provider": "google", "installationId": UUID().uuidString, "noticeVersion": notice,
                "choices": ["productAnalytics": true, "appleAds": false, "crossCompanyAds": false]])
            XCTAssertEqual(refused.status, .badRequest, refused.body.string)
            XCTAssertTrue(refused.body.string.contains("measurement_notice_invalid"))
        }
        let stored = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE notice_version IN ('measurement-notice-2026-10b-singular','measurement-notice-2026-10c')")
        XCTAssertEqual(stored, 0)
    }

    private static let tombstoneFields: Set<String> = [
        "id", "provider", "surface", "environment", "notice_version", "binding_kind", "state", "consumed_reason",
        "received_at", "expires_at", "bound_at", "consumed_at", "cancelled_at", "scrubbed_at", "signup_fact_id"]

    private func present(_ intent: UUID) async throws -> Set<String> {
        let text = try await XCTUnwrapAsync(try await sql.raw("""
            SELECT row_to_json(i)::text AS j FROM measurement_signup_intents i WHERE id=\(bind:intent)
            """).first()).decode(column: "j", as: String.self)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return Set(object.filter { !($0.value is NSNull) }.keys)
    }

    /// Unused, expired, cancelled and settled intents: the full row only while it is live or inside
    /// the 7-day cancellation window, then exactly the documented tombstone fields, then nothing
    /// 30 days after scrubbing. The live account's fact stays as its deduplication record.
    func testTombstonesKeepOnlyTheDocumentedFieldsAndArePrunedThirtyDaysAfterScrubbing() async throws {
        let unused = try await issue("google")
        try await sql.raw("""
            UPDATE measurement_signup_intents SET received_at=received_at-interval '1 hour',
                expires_at=now()-interval '1 minute' WHERE id=\(bind:unused.id)
            """).run()
        let cancelled = try await issue("email")
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(cancelled.id)/cancel",
                                       object: ["capability": cancelled.capability])
        XCTAssertEqual(cancel.status, .ok, cancel.body.string)
        let settled = try await issue("apple", apple: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-tombstone-\(UUID())", nonce: settled.nonce),
                                                context: context(settled)), new: true)
        let subject = "signup-tombstone-existing-\(UUID())"
        _ = try signedIn(try await googleVerify(try await googleChallenge(), subject: subject), new: true)
        let existing = try await issue("google")
        let challenge = try await googleChallenge(binding(existing))
        _ = try signedIn(try await googleVerify(challenge, subject: subject, context: context(existing)), new: false)
        let existingState = try await state(existing.id)
        XCTAssertEqual(existingState.state, "consumed_existing")

        _ = try await SignupIntentService.cleanup(on: app.db)
        let expired = try await state(unused.id)
        XCTAssertEqual(expired.state, "expired")
        let unusedFields = try await present(unused.id)
        XCTAssertTrue(unusedFields.isSubset(of: Self.tombstoneFields), "unused tombstone kept \(unusedFields.subtracting(Self.tombstoneFields))")
        // Inside the 7-day window the settled and cancelled rows keep what late cancellation needs.
        let live = try await present(settled.id)
        XCTAssertTrue(live.isSuperset(of: ["capability_hash", "account_id", "installation_id", "product_revision", "apple_revision"]))
        let cancelledLive = try await present(cancelled.id)
        XCTAssertTrue(cancelledLive.contains("capability_hash"))

        try await sql.raw("""
            UPDATE measurement_signup_intents SET consumed_at=consumed_at-interval '8 days'
            WHERE id IN (\(bind:settled.id),\(bind:existing.id))
            """).run()
        try await sql.raw("""
            UPDATE measurement_signup_intents SET cancelled_at=cancelled_at-interval '8 days' WHERE id=\(bind:cancelled.id)
            """).run()
        _ = try await SignupIntentService.cleanup(on: app.db)
        for intent in [unused.id, cancelled.id, settled.id, existing.id] {
            let fields = try await present(intent)
            XCTAssertTrue(fields.isSubset(of: Self.tombstoneFields), "\(intent) kept \(fields.subtracting(Self.tombstoneFields))")
            XCTAssertTrue(fields.contains("scrubbed_at"))
        }
        let settledState = try await state(settled.id)
        XCTAssertEqual(settledState.state, "consumed_new")
        let factBefore = try await facts(auth.user.id)
        XCTAssertEqual(factBefore, 1, "the per-account fact remains the deduplication record while the account lives")

        _ = try await SignupIntentService.cleanup(now: Date().addingTimeInterval(29 * 86_400), on: app.db)
        let within = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id IN (\(bind:unused.id),\(bind:cancelled.id),\(bind:settled.id),\(bind:existing.id))")
        XCTAssertEqual(within, 4)
        _ = try await SignupIntentService.cleanup(now: Date().addingTimeInterval(31 * 86_400), on: app.db)
        let after = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id IN (\(bind:unused.id),\(bind:cancelled.id),\(bind:settled.id),\(bind:existing.id))")
        XCTAssertEqual(after, 0, "no tombstone is kept indefinitely")
        let factAfter = try await facts(auth.user.id)
        XCTAssertEqual(factAfter, 1, "pruning the intent never removes a live account's fact")
        // The fact no longer needs its intent row, and the pruned intent can never be adopted again.
        let replay = try await apple(try appleToken(subject: "signup-tombstone-replay-\(UUID())", nonce: settled.nonce),
                                     context: context(settled))
        let replayAuth = try signedIn(replay, new: true)
        let replayFacts = try await count("SELECT count(*) AS n FROM measurement_signup_facts WHERE intent_id=\(bind:settled.id)")
        XCTAssertEqual(replayFacts, 1)
        let newFacts = try await facts(replayAuth.user.id)
        XCTAssertEqual(newFacts, 0, "a pruned intent adopts nothing")
    }

    /// The hourly maintenance pass runs the same pruning, and facts an earlier image left behind for
    /// deleted accounts (account join already cleared) are removed.
    func testTheScheduledMaintenancePassPrunesOldTombstonesAndOrphanedFacts() async throws {
        let old = try await issue("google")
        try await sql.raw("""
            UPDATE measurement_signup_intents SET state='expired',capability_hash=NULL,installation_id=NULL,
                product_analytics=NULL,apple_ads=NULL,cross_company_ads=NULL,
                received_at=now()-interval '40 days',expires_at=now()-interval '39 days',scrubbed_at=now()-interval '31 days'
            WHERE id=\(bind:old.id)
            """).run()
        let recent = try await issue("google")
        try await sql.raw("""
            UPDATE measurement_signup_intents SET state='expired',capability_hash=NULL,installation_id=NULL,
                product_analytics=NULL,apple_ads=NULL,cross_company_ads=NULL,
                received_at=now()-interval '10 days',expires_at=now()-interval '9 days',scrubbed_at=now()-interval '9 days'
            WHERE id=\(bind:recent.id)
            """).run()
        let orphan = UUID()
        try await sql.raw("""
            INSERT INTO measurement_signup_facts(id,account_id,intent_id,provider,environment,occurred_at,product_eligible,
                linkedin_eligible,created_at,withdrawn_at,scrubbed_at)
            VALUES (\(bind:orphan),NULL,\(bind:UUID()),'email','local',now()-interval '2 days',true,false,now()-interval '2 days',
                    now()-interval '1 day',now()-interval '1 day')
            """).run()
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(removed?.measurementSignupIntents), 2)
        let oldLeft = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:old.id)")
        XCTAssertEqual(oldLeft, 0)
        let recentLeft = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:recent.id)")
        XCTAssertEqual(recentLeft, 1, "a tombstone younger than 30 days is kept")
        let orphanLeft = try await count("SELECT count(*) AS n FROM measurement_signup_facts WHERE id=\(bind:orphan)")
        XCTAssertEqual(orphanLeft, 0)
    }

    func testRetentionReducesUnclaimedAndSettledIntentsToTombstones() async throws {
        let unclaimed = try await issue("google")
        try await sql.raw("""
            UPDATE measurement_signup_intents SET received_at=received_at-interval '1 hour',
                expires_at=now()-interval '1 minute' WHERE id=\(bind:unclaimed.id)
            """).run()
        let settled = try await issue("apple")
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-retention-\(UUID())", nonce: settled.nonce),
                                                context: context(settled)), new: true)
        try await sql.raw("UPDATE measurement_signup_intents SET consumed_at=now()-interval '8 days' WHERE id=\(bind:settled.id)").run()
        _ = try await SignupIntentService.cleanup(on: app.db)
        let expired = try await state(unclaimed.id)
        XCTAssertEqual(expired.state, "expired")
        let scrubbed = try await count("""
            SELECT count(*) AS n FROM measurement_signup_intents WHERE id IN (\(bind:unclaimed.id),\(bind:settled.id))
              AND capability_hash IS NULL AND installation_id IS NULL AND product_analytics IS NULL AND account_id IS NULL
              AND scrubbed_at IS NOT NULL
            """)
        XCTAssertEqual(scrubbed, 2)
        let kept = try await facts(auth.user.id)
        XCTAssertEqual(kept, 1, "the per-account fact remains the dedup record until deletion")
    }

    // MARK: - Tombstones are pseudonymous (ASTRA-REVIEW-2026-10-09b.md, correction 1)

    /// Starting from nothing but a settled tombstone, exactly these joins reach the account: (1) its
    /// `signup_fact_id` to the fact, (2) the fact's `intent_id` back to it, (3) the consent revisions'
    /// request IDs derived from its `id`, and (4) its exact times. (1) and (2) end when account deletion
    /// deletes the fact; (3) and (4) end when the deleted account's receipts are removed; and nothing is
    /// left to join once the tombstone itself is pruned. It is never claimed to be anonymous.
    func testTombstoneJoinPathsAreTheListedOnesAndEndWithTheirRecords() async throws {
        try await enable("productAnalyticsEnabled")
        let intent = try await issue("apple", apple: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-joins-\(UUID())", nonce: intent.nonce),
                                                context: context(intent)), new: true)
        let account = auth.user.id
        let start = Date()
        _ = try await SignupIntentService.cleanup(now: start.addingTimeInterval(8 * 86_400), on: app.db)
        let fields = try await present(intent.id)
        XCTAssertTrue(fields.isSubset(of: Self.tombstoneFields), "\(fields.subtracting(Self.tombstoneFields))")
        XCTAssertFalse(fields.contains("account_id"))

        let derived = MeasurementPurpose.allCases.flatMap { purpose in
            ["signup-consent-v1", "signup-cancel-v1"].map { SignupIntentService.derivedID($0, intent.id, purpose.rawValue) }
        }
        func reach(_ query: SQLQueryString) async throws -> Set<UUID> {
            let rows = try await sql.raw(query).all().map { try $0.decode(column: "account_id", as: UUID.self) }
            return Set(rows)
        }
        func paths() async throws -> [String: Set<UUID>] {
            let byFactID = try await reach("""
                SELECT f.account_id FROM measurement_signup_intents i JOIN measurement_signup_facts f ON f.id=i.signup_fact_id
                WHERE i.id=\(bind:intent.id) AND f.account_id IS NOT NULL
                """)
            let byIntentID = try await reach("""
                SELECT f.account_id FROM measurement_signup_intents i JOIN measurement_signup_facts f ON f.intent_id=i.id
                WHERE i.id=\(bind:intent.id) AND f.account_id IS NOT NULL
                """)
            let byDerivedRequest = try await reach("""
                SELECT DISTINCT c.account_id FROM measurement_signup_intents i JOIN measurement_consent_events c
                  ON c.request_id IN (\(binds: derived))
                WHERE i.id=\(bind:intent.id)
                """)
            let byExactTimes = try await reach("""
                SELECT DISTINCT c.account_id FROM measurement_signup_intents i JOIN measurement_consent_events c
                  ON c.occurred_at=i.received_at AND c.received_at=i.consumed_at
                WHERE i.id=\(bind:intent.id)
                """)
            return ["fact_by_signup_fact_id": byFactID, "fact_by_intent_id": byIntentID,
                    "consent_by_derived_request_id": byDerivedRequest, "consent_by_exact_times": byExactTimes]
        }
        let live = try await paths()
        XCTAssertEqual(live, ["fact_by_signup_fact_id": [account], "fact_by_intent_id": [account],
                              "consent_by_derived_request_id": [account], "consent_by_exact_times": [account]],
                       "while the account exists, every listed path reaches it")

        let job = UUID()
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:job),\(bind:account),\(bind:SHA256Hasher.hash(token: "signup-joins-\(job)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        try await app.db.transaction { tx in
            let txSQL = try VerifiedIdentityService.sql(tx)
            _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:account) FOR UPDATE").first()
            try await MeasurementPrivacyService.eraseAccount(account, accountDeletionJobID: job, now: Date(), on: tx)
            try await txSQL.raw("UPDATE users SET lifecycle_state='deleted',auth_version=auth_version+1 WHERE id=\(bind:account)").run()
        }
        let deleted = try await paths()
        XCTAssertEqual(deleted, ["fact_by_signup_fact_id": [], "fact_by_intent_id": [],
                                 "consent_by_derived_request_id": [account], "consent_by_exact_times": [account]],
                       "deletion ends the fact paths; the consent receipts still reach the deleted account's row")

        // Nothing was delivered, so provider erasure completed with the deletion: 30 days later the
        // receipts go, before the tombstone's own pruning.
        _ = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(31 * 86_400), limit: 5_000, on: app.db)
        let afterReceipts = try await paths()
        XCTAssertEqual(afterReceipts, ["fact_by_signup_fact_id": [], "fact_by_intent_id": [],
                                       "consent_by_derived_request_id": [], "consent_by_exact_times": []])
        let tombstone = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:intent.id)")
        XCTAssertEqual(tombstone, 1, "the tombstone itself is pruned 30 days after it was scrubbed")
        _ = try await SignupIntentService.cleanup(now: start.addingTimeInterval(39 * 86_400), on: app.db)
        let pruned = try await count("SELECT count(*) AS n FROM measurement_signup_intents WHERE id=\(bind:intent.id)")
        XCTAssertEqual(pruned, 0, "a settled row lasts about 37 days from settlement plus scheduling")
    }

    // MARK: - Destinations

    func testOutboxSchemaHasADedicatedSignupSourceAndHoldsSingular() async throws {
        let intent = try await issue("google")
        let challenge = try await googleChallenge(binding(intent))
        try await enable("productAnalyticsEnabled")
        let auth = try signedIn(try await googleVerify(challenge, subject: "signup-schema-\(UUID())", context: context(intent)), new: true)
        let row = try await XCTUnwrapAsync(try await sql.raw("""
            SELECT j.subject_id,j.consent_revision,f.id AS fact_id FROM measurement_dispatch_jobs j
            JOIN measurement_signup_facts f ON f.id=j.source_id WHERE j.account_id=\(bind:auth.user.id) AND j.source_kind='signupFact'
            """).first())
        let subject = try row.decode(column: "subject_id", as: UUID.self), revision = try row.decode(column: "consent_revision", as: UUID.self)
        let fact = try row.decode(column: "fact_id", as: UUID.self)
        for (destination, installation) in [("singular", UUID() as UUID?), ("linkedin", nil)] {
            do {
                try await sql.raw("""
                    INSERT INTO measurement_dispatch_jobs
                        (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,installation_id,state,available_at,payload,created_at)
                    VALUES (\(bind:UUID()),\(bind:destination),'signupFact',\(bind:fact),\(bind:auth.user.id),\(bind:subject),\(bind:revision),
                            \(bind:installation),'pending',now(),'{}'::jsonb,now())
                    """).run()
                XCTFail("\(destination) signup job must be refused by the schema")
            } catch {}
        }
        do {
            try await sql.raw("""
                INSERT INTO measurement_signup_facts(id,account_id,intent_id,provider,environment,occurred_at,product_eligible,linkedin_eligible,created_at)
                VALUES (\(bind:UUID()),\(bind:auth.user.id),\(bind:intent.id),'google','local',now(),false,false,now())
                """).run()
            XCTFail("a second canonical signup fact for one account must be refused")
        } catch {}
    }

    func testProductSignupUsesTheEUPostHogRelayOnceWithBoundedProperties() async throws {
        try await enable("productAnalyticsEnabled")
        let recorder = SignupHTTPRecorder()
        configureDelivery(recorder)
        let intent = try await issue("google")
        let challenge = try await googleChallenge(binding(intent))
        let email = address()
        let auth = try signedIn(try await googleVerify(challenge, subject: "signup-posthog-\(UUID())", email: email,
                                                       context: context(intent)), new: true)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = await recorder.calls().filter { $0.body.contains("account_created") }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.uri, "https://eu.i.posthog.com/capture/")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "account_created")
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["event", "occurredAt", "distinct_id", "source_event_id", "$process_person_profile", "$geoip_disable"])
        for forbidden in [email, auth.user.id.uuidString.lowercased(), auth.user.id.uuidString, intent.installation.uuidString.lowercased(), intent.capability] {
            XCTAssertFalse(call.body.contains(forbidden))
        }
        let queued = try await jobs(auth.user.id)
        XCTAssertEqual(queued.map(\.state), ["delivered"])
    }

    func testLinkedInSignupIsGatedAndRecheckedBeforeDispatch() async throws {
        try await enable("crossCompanyAdsEnabled", "linkedInConversionsEnabled")
        let recorder = SignupHTTPRecorder()
        configureDelivery(recorder)
        let email = address()
        let intent = try await issue("apple", product: false, cross: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-linkedin-\(UUID())", nonce: intent.nonce, email: email),
                                                context: context(intent, att: "authorized")), new: true)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = await recorder.calls().filter { $0.uri == "https://api.linkedin.com/rest/conversionEvents" }
        XCTAssertEqual(calls.count, 1)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(calls.first).body.utf8)) as? [String: Any])
        XCTAssertEqual(body["conversion"] as? String, "urn:lla:llaPartnerConversion:31231706")
        XCTAssertNil(body["conversionValue"])
        let ids = try XCTUnwrap((body["user"] as? [String: Any])?["userIds"] as? [[String: Any]])
        XCTAssertEqual(ids.first?["idType"] as? String, "SHA256_EMAIL")
        XCTAssertEqual(ids.first?["idValue"] as? String, SHA256Hasher.hash(token: email))
        XCTAssertFalse(calls.first!.body.contains(email))

        // Withdrawal before dispatch suppresses and scrubs; a regrant cannot resurrect it.
        let held = try await issue("apple", product: false, cross: true)
        let other = try signedIn(try await apple(try appleToken(subject: "signup-linkedin-held-\(UUID())", nonce: held.nonce, email: address()),
                                                 context: context(held, att: "authorized")), new: true)
        let revision = try await XCTUnwrapAsync(try await sql.raw("SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:other.user.id) AND purpose='crossCompanyAds'").first())
        let withdraw = try await request(.PUT, "api/v2/measurement/permissions/crossCompanyAds", object: [
            "requestId": UUID().uuidString, "expectedRevision": try revision.decode(column: "revision", as: UUID.self).uuidString,
            "decision": "withdrawn", "occurredAt": date()], bearer: other.token)
        XCTAssertEqual(withdraw.status, .ok, withdraw.body.string)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let after = await recorder.calls().filter { $0.uri == "https://api.linkedin.com/rest/conversionEvents" }
        XCTAssertEqual(after.count, 1)
        let otherJobs = try await jobs(other.user.id)
        XCTAssertEqual(otherJobs.map(\.state), ["suppressed"])
        let payloads = try await count("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:other.user.id) AND payload IS NOT NULL")
        XCTAssertEqual(payloads, 0)

        // Flags off at dispatch time suppress even an eligible queued signup.
        let late = try await issue("apple", product: false, cross: true)
        let third = try signedIn(try await apple(try appleToken(subject: "signup-linkedin-off-\(UUID())", nonce: late.nonce, email: address()),
                                                 context: context(late, att: "authorized")), new: true)
        try await FeatureFlag.query(on: app.db).filter(\.$key == "linkedInConversionsEnabled").delete()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let thirdJobs = try await jobs(third.user.id)
        XCTAssertEqual(thirdJobs.map(\.state), ["suppressed"])
    }

    // MARK: - ATT: no later activation after sign-up (Dan, 9 October 2026, section 3)

    func testRefusedCrossCompanyChoiceAdoptsNothingForItAndLaterAuthorisedATTCannotAddIt() async throws {
        try await enable("productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled")
        let recorder = SignupHTTPRecorder()
        configureDelivery(recorder)
        let refused = try await issue("apple", cross: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-att-later-\(UUID())", nonce: refused.nonce, email: address()),
                                                context: context(refused, att: "denied")), new: true)
        let adopted = try await consents(auth.user.id)
        XCTAssertEqual(adopted, ["productAnalytics"], "adoption is unchanged: nothing is written for the refused choice")
        let product = try await XCTUnwrapAsync(try await sql.raw("SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:auth.user.id) AND purpose='productAnalytics'").first())
        // ATT allowed after sign-up: there is no cross-company revision for it to reach.
        for revision in [UUID(), try product.decode(column: "revision", as: UUID.self)] {
            let later = try await request(.PUT, "api/v2/measurement/devices/att", object: [
                "installationId": refused.installation.uuidString, "consentRevision": revision.uuidString,
                "attStatus": "authorized", "observedAt": date()], bearer: auth.token)
            XCTAssertEqual(later.status, .conflict, later.body.string)
        }
        let read = try await request(.GET, "api/v2/measurement/permissions", bearer: auth.token)
        XCTAssertEqual(read.status, .ok)
        let permissions = try XCTUnwrap(try json(read)["permissions"] as? [[String: Any]])
        let cross = try XCTUnwrap(permissions.first { $0["purpose"] as? String == "crossCompanyAds" })
        XCTAssertEqual(cross["decision"] as? String, "undecided")
        XCTAssertEqual(cross["effective"] as? Bool, false)
        XCTAssertEqual(cross["activation"] as? String, "not_chosen")
        let queued = try await jobs(auth.user.id)
        XCTAssertEqual(queued.map(\.destination), ["posthog"])
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let linkedIn = await recorder.calls().filter { $0.uri == "https://api.linkedin.com/rest/conversionEvents" }
        XCTAssertTrue(linkedIn.isEmpty)
        let subjects = try await count("SELECT count(*) AS n FROM measurement_subjects WHERE account_id=\(bind:auth.user.id) AND purpose='crossCompanyAds'")
        XCTAssertEqual(subjects, 0)
    }

    func testQueuedLinkedInSignupIsIneligibleOnceItsRevisionIsInactiveOnTheInstallation() async throws {
        try await enable("crossCompanyAdsEnabled", "linkedInConversionsEnabled")
        let recorder = SignupHTTPRecorder()
        configureDelivery(recorder)
        let intent = try await issue("apple", product: false, cross: true)
        let auth = try signedIn(try await apple(try appleToken(subject: "signup-att-latch-\(UUID())", nonce: intent.nonce, email: address()),
                                                context: context(intent, att: "authorized")), new: true)
        let queued = try await jobs(auth.user.id)
        XCTAssertEqual(queued.map(\.destination), ["linkedin"])
        XCTAssertEqual(queued.map(\.state), ["pending"])
        let row = try await XCTUnwrapAsync(try await sql.raw("SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:auth.user.id) AND purpose='crossCompanyAds'").first())
        let revision = try row.decode(column: "revision", as: UUID.self)
        func observe(_ status: String, at: Date) async throws -> XCTHTTPResponse {
            try await request(.PUT, "api/v2/measurement/devices/att", object: [
                "installationId": intent.installation.uuidString, "consentRevision": revision.uuidString,
                "attStatus": status, "observedAt": date(at)], bearer: auth.token)
        }
        let denied = try await observe("denied", at: Date().addingTimeInterval(1))
        XCTAssertEqual(denied.status, .ok, denied.body.string)
        let allowed = try await observe("authorized", at: Date().addingTimeInterval(2))
        XCTAssertEqual(allowed.status, .ok, allowed.body.string)
        let permissions = try XCTUnwrap(try json(allowed)["permissions"] as? [[String: Any]])
        let cross = try XCTUnwrap(permissions.first { $0["purpose"] as? String == "crossCompanyAds" })
        XCTAssertEqual(cross["effective"] as? Bool, false)
        XCTAssertEqual(cross["activation"] as? String, "chosen_inactive_att")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let linkedIn = await recorder.calls().filter { $0.uri == "https://api.linkedin.com/rest/conversionEvents" }
        XCTAssertTrue(linkedIn.isEmpty)
        let after = try await jobs(auth.user.id)
        XCTAssertEqual(after.map(\.state), ["suppressed"])
    }
}

// MARK: - Fixtures

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private struct SignupAppleClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim
    let exp: ExpirationClaim; let iat: IssuedAtClaim; let nonce: String?; let email: String?; let email_verified: Bool?
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

private struct SignupGoogleClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim; let exp: ExpirationClaim; let iat: IssuedAtClaim
    let azp: String?; let nonce: String?; let email: String?; let email_verified: Bool?; let name: String?
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

/// Serves only the two providers' public signing keys. Anything else is refused.
private struct SignupProviderFixtureClient: Client {
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

private actor SignupHTTPRecorder {
    struct Call: Sendable { let uri: String; let body: String }
    private var values: [Call] = []
    func record(_ uri: URI, _ body: Data) -> MeasurementDispatchService.Reply {
        values.append(.init(uri: uri.string, body: String(decoding: body, as: UTF8.self)))
        return .init(status: uri.string.contains("linkedin") ? 201 : 200, retryAfter: nil)
    }
    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, _, body in await self.record(uri, body) }
    }
    func calls() -> [Call] { values }
}

/// Coordinates a second database connection that holds a lock while the identity
/// transaction runs on the first.
private actor SignupLockHolder {
    private var key: String?
    private var keyWaiters: [CheckedContinuation<String, Never>] = []
    private var locked = false
    private var lockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func provide(_ value: String) { key = value; keyWaiters.forEach { $0.resume(returning: value) }; keyWaiters.removeAll() }
    func waitForKey() async -> String {
        if let key { return key }
        return await withCheckedContinuation { keyWaiters.append($0) }
    }
    func markLocked() { locked = true; lockedWaiters.forEach { $0.resume() }; lockedWaiters.removeAll() }
    func waitUntilLocked() async {
        if locked { return }
        await withCheckedContinuation { lockedWaiters.append($0) }
    }
    func release() { released = true; releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll() }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// Tombstones are restricted: only the signup services and the rollback reconciliation (which looks only
/// for rows still carrying an account) read the intent table, so a new reader is a reviewed change.
final class SignupTombstoneRestrictionTests: XCTestCase {
    func testOnlyTheNamedSourcesReadSignupIntents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/App")
        var readers: Set<String> = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) where path.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            if text.contains("measurement_signup_intents") { readers.insert(path) }
        }
        XCTAssertEqual(readers, [
            "Measurement/SignupIntentService.swift", "Measurement/SignupAppleEvidenceService.swift",
            "Measurement/MeasurementReconciliation.swift",
            "Migrations/CreateMeasurementSignupIntents.swift", "Migrations/AddSignupAppleEvidenceSlot.swift",
            "Migrations/AddMeasurementNoticeVersions.swift"])
    }
}
