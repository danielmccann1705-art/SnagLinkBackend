@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Dan's direction of 9 October 2026, section 3, on the server: a cross-company choice recorded
/// while Apple's tracking permission was denied, restricted, not determined or stale stays
/// ineffective. A later authorised ATT assertion or heartbeat never makes it effective and never
/// replays anything; only a new choice recorded with fresh authorised ATT (a new revision) does.
/// An uninterrupted authorised choice keeps its heartbeat continuity (PURCHASE-DISPATCH-OCT8.md).
/// The permissions read reports the actual state in the additive `activation` field.
/// Real PostgreSQL, synthetic identities, injected provider transport. No provider network.
final class CrossCompanyATTActivationTests: XCTestCase {
    private var app: Application!
    private var user: User!
    private var jwt: String!
    private var userID: UUID { try! user.requireID() }
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let recorder = ATTActivationHTTPRecorder()

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: .sandbox)
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: nil, postHogEnvironment: nil, singularURL: nil, singularAPIKey: nil,
            linkedInAccessToken: "linkedin_synthetic", linkedInSignupRule: "101",
            linkedInSubscriptionRule: "31231714", linkedInEnvironment: .sandbox)
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        user = User(appleUserId: nil, email: "att-activation-\(UUID().uuidString.lowercased())@example.test",
                    name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: userID,
            authVersion: user.authVersion, authenticatedAt: Date()))
        for key in ["crossCompanyAdsEnabled", "linkedInConversionsEnabled"] {
            try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
            try await FeatureFlag(key: key, enabled: true).save(on: app.db)
        }
        try await sql.raw("""
            INSERT INTO user_identities(id,user_id,provider,subject,verified_at)
            VALUES (\(bind:UUID()),\(bind:userID),'email','att-activation@example.test',NOW()-INTERVAL '1 minute')
            """).run()
    }

    override func tearDown() async throws {
        if let app {
            try? await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE charge_id IN (SELECT id FROM measurement_revenuecat_events WHERE account_id=\(bind:userID))").run()
            try? await sql.raw("DELETE FROM measurement_purchase_intents WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_purchase_acquisitions WHERE account_id=\(bind: userID)").run()
            for table in ["measurement_dispatch_jobs", "measurement_revenuecat_adjustments", "measurement_revenuecat_lifecycle_events",
                          "measurement_revenuecat_events", "measurement_product_events", "measurement_device_bindings",
                          "measurement_erasure_jobs", "measurement_att_assertions", "measurement_permission_current",
                          "measurement_consent_events", "measurement_subjects"] {
                try? await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE account_id=\(bind: userID)").run()
            }
            try? await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:userID)").run()
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ ["crossCompanyAdsEnabled", "linkedInConversionsEnabled"]).delete()
            try? await User.query(on: app.db).filter(\.$id == userID).delete()
            try await app.asyncShutdown()
        }
        app = nil; user = nil; jwt = nil
    }

    // MARK: - Helpers (dates are whole-second ISO-8601, exactly what the iOS client sends)

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }

    private func request(_ method: HTTPMethod, _ path: String, object: [String: Any]? = nil,
                         installation: UUID? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.jwt)
            if let installation { req.headers.replaceOrAdd(name: "X-Measurement-Installation-ID", value: installation.uuidString) }
            if let object {
                req.headers.contentType = .json
                req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
            }
        }, afterResponse: { answer = $0 })
        return answer
    }

    /// A cross-company choice made on `installation` with the ATT status read at that moment.
    private func choose(_ installation: UUID, att: String, expected: UUID? = nil,
                        assertedAt: Date = Date(), file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["requestId": UUID().uuidString, "decision": "granted", "occurredAt": date(),
                                   "installationId": installation.uuidString, "attStatus": att,
                                   "attAssertedAt": date(assertedAt)]
        if let expected { body["expectedRevision"] = expected.uuidString }
        return try await request(.PUT, "api/v2/measurement/permissions/crossCompanyAds", object: body)
    }

    private func observe(_ installation: UUID, _ revision: UUID, _ status: String, at: Date) async throws -> XCTHTTPResponse {
        try await request(.PUT, "api/v2/measurement/devices/att", object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "attStatus": status, "observedAt": date(at)])
    }

    private func cross(_ response: XCTHTTPResponse, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        let values = try XCTUnwrap(body["permissions"] as? [[String: Any]])
        return try XCTUnwrap(values.first { $0["purpose"] as? String == "crossCompanyAds" })
    }

    private func revisionOf(_ response: XCTHTTPResponse) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: try XCTUnwrap(try cross(response)["revision"] as? String)))
    }

    private func assertInactive(_ state: [String: Any], att: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state["decision"] as? String, "granted", file: file, line: line)
        XCTAssertEqual(state["effective"] as? Bool, false, file: file, line: line)
        XCTAssertNil(state["subjectId"], file: file, line: line)
        XCTAssertEqual(state["activation"] as? String, "chosen_inactive_att", file: file, line: line)
        XCTAssertEqual(state["attStatus"] as? String, att, "the read reports the actual ATT status", file: file, line: line)
    }

    private func assertActive(_ state: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state["effective"] as? Bool, true, file: file, line: line)
        XCTAssertNotNil(state["subjectId"], file: file, line: line)
        XCTAssertEqual(state["activation"] as? String, "active", file: file, line: line)
    }

    private func prepare(_ installation: UUID, _ revision: UUID) async throws -> (XCTHTTPResponse, UUID?, String?) {
        let response = try await request(.POST, "api/v2/measurement/purchase-intents", object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "productId": "com.snaglist.pro.monthly"])
        guard response.status == .created else { return (response, nil, nil) }
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        return (response, UUID(uuidString: try XCTUnwrap(body["intentId"] as? String)), body["capability"] as? String)
    }

    private func witness(_ intent: UUID, _ capability: String, transaction: String, purchaseDate: Date) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/purchase-intents/\(intent.uuidString)/witness", object: [
            "capability": capability, "transactionId": transaction, "productId": "com.snaglist.pro.monthly",
            "purchaseDate": date(purchaseDate), "source": "purchaseCallback"])
    }

    private func bind(_ installation: UUID, _ revision: UUID) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/devices", object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "singularDeviceId": "synthetic-sdid-\(UUID().uuidString.prefix(8).lowercased())"])
    }

    private func webhook(transaction: String, type: String = "INITIAL_PURCHASE", at: Date,
                         chain: String) async throws -> XCTHTTPResponse {
        let event: [String: Any] = [
            "id": UUID().uuidString, "app_id": "synthetic-rc-app", "app_user_id": userID.uuidString,
            "type": type, "environment": "SANDBOX", "store": "APP_STORE", "period_type": "NORMAL",
            "is_family_share": false, "product_id": "com.snaglist.pro.monthly", "entitlement_ids": ["Snaglist Pro"],
            "event_timestamp_ms": Int64(at.timeIntervalSince1970 * 1000),
            "purchased_at_ms": Int64(at.timeIntervalSince1970 * 1000),
            "expiration_at_ms": Int64(at.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000),
            "price_in_purchased_currency": 14.99, "currency": "GBP", "transaction_id": transaction,
            "original_transaction_id": chain]
        let body = try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": event])
        var answer: XCTHTTPResponse!
        try await app.test(.POST, "api/v2/measurement/webhooks/revenuecat", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .authorization, value: "Bearer synthetic-webhook-secret")
            req.headers.contentType = .json
            req.body = .init(data: body)
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func count(_ query: SQLQueryString) async throws -> Int {
        try await sql.raw(query).first()!.decode(column: "n", as: Int.self)
    }

    private func linkedInJobs(_ state: String? = nil) async throws -> Int {
        if let state {
            return try await count("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND destination='linkedin' AND state=\(bind:state)")
        }
        return try await count("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND destination='linkedin'")
    }

    private func crossSubjects() async throws -> Int {
        try await count("SELECT count(*) AS n FROM measurement_subjects WHERE account_id=\(bind:userID) AND purpose='crossCompanyAds' AND state='active'")
    }

    private func continuity(_ installation: UUID) async throws -> UUID? {
        try await sql.raw("""
            SELECT continuity_id FROM measurement_att_assertions WHERE account_id=\(bind:userID) AND installation_id=\(bind:installation)
            """).first()?.decode(column: "continuity_id", as: UUID?.self)
    }

    // MARK: - Denied at the choice, authorised later: never activates, nothing replayed

    func testDeniedChoiceStaysInactiveAfterLaterAuthorisedATTAndNothingIsReplayed() async throws {
        let installation = UUID()
        let granted = try await choose(installation, att: "denied")
        assertInactive(try cross(granted), att: "denied")
        let revision = try revisionOf(granted)

        // While inactive: no purchase evidence, no device binding, no provider work for a purchase.
        let refusedIntent = try await prepare(installation, revision)
        XCTAssertEqual(refusedIntent.0.status, .forbidden)
        let refusedBinding = try await bind(installation, revision)
        XCTAssertEqual(refusedBinding.status, .forbidden)
        let whileInactive = Date()
        let purchased = try await webhook(transaction: "att-inactive-initial", at: whileInactive, chain: "att-inactive-chain")
        XCTAssertEqual(purchased.status, .ok)

        // ATT is allowed later. The observation is recorded (the read shows the actual status), but
        // the choice made while it was denied stays inactive: no subject, no continuity.
        let later = try await observe(installation, revision, "authorized", at: Date().addingTimeInterval(1))
        assertInactive(try cross(later), att: "authorized")
        let heartbeat = try await observe(installation, revision, "authorized", at: Date().addingTimeInterval(2))
        assertInactive(try cross(heartbeat), att: "authorized")
        let read = try await request(.GET, "api/v2/measurement/permissions", installation: installation)
        assertInactive(try cross(read), att: "authorized")
        let subjects = try await crossSubjects()
        XCTAssertEqual(subjects, 0)
        let storedContinuity = try await continuity(installation)
        XCTAssertNil(storedContinuity)

        // Still no dispatch eligibility after the later authorisation.
        let stillRefused = try await prepare(installation, revision)
        XCTAssertEqual(stillRefused.0.status, .forbidden)
        let stillUnbound = try await bind(installation, revision)
        XCTAssertEqual(stillUnbound.status, .forbidden)
        let renewal = try await webhook(transaction: "att-inactive-renewal", type: "RENEWAL", at: Date(),
                                        chain: "att-inactive-chain")
        XCTAssertEqual(renewal.status, .ok)

        // Nothing withheld while inactive is replayed.
        let jobs = try await linkedInJobs()
        XCTAssertEqual(jobs, 0)
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 0)
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty)
        let bindings = try await count("SELECT count(*) AS n FROM measurement_device_bindings WHERE account_id=\(bind:userID)")
        XCTAssertEqual(bindings, 0)
    }

    // MARK: - Restricted, not determined and stale

    func testRestrictedNotDeterminedAndStaleChoicesNeverActivateLater() async throws {
        let installation = UUID()
        var expected: UUID?
        var clock = Date()
        for status in ["restricted", "notDetermined"] {
            let granted = try await choose(installation, att: status, expected: expected, assertedAt: clock)
            assertInactive(try cross(granted), att: status)
            let revision = try revisionOf(granted)
            clock = clock.addingTimeInterval(1)
            let later = try await observe(installation, revision, "authorized", at: clock)
            assertInactive(try cross(later), att: "authorized")
            let intent = try await prepare(installation, revision)
            XCTAssertEqual(intent.0.status, .forbidden, status)
            expected = revision
            clock = clock.addingTimeInterval(1)
        }
        let subjects = try await crossSubjects()
        XCTAssertEqual(subjects, 0)

        // Stale: an ATT assertion older than 15 minutes cannot record a choice at all, and a stale
        // authorised observation cannot reach the standing (inactive) one either.
        let before = try await count("SELECT count(*) AS n FROM measurement_consent_events WHERE account_id=\(bind:userID)")
        let stale = try await choose(installation, att: "authorized", expected: expected,
                                     assertedAt: Date().addingTimeInterval(-901))
        XCTAssertEqual(stale.status, .badRequest)
        let after = try await count("SELECT count(*) AS n FROM measurement_consent_events WHERE account_id=\(bind:userID)")
        XCTAssertEqual(after, before, "a stale assertion records nothing that could activate later")
        let staleObservation = try await observe(installation, try XCTUnwrap(expected), "authorized",
                                                 at: Date().addingTimeInterval(-901))
        XCTAssertEqual(staleObservation.status, .badRequest)
        let read = try await request(.GET, "api/v2/measurement/permissions", installation: installation)
        assertInactive(try cross(read), att: "authorized")
    }

    // MARK: - A fresh explicit choice after ATT is authorised activates (a new revision)

    func testFreshChoiceRecordedWithAuthorisedATTActivatesAsANewRevision() async throws {
        let installation = UUID()
        let denied = try await choose(installation, att: "denied")
        let deniedRevision = try revisionOf(denied)
        let later = try await observe(installation, deniedRevision, "authorized", at: Date().addingTimeInterval(1))
        assertInactive(try cross(later), att: "authorized")

        let fresh = try await choose(installation, att: "authorized", expected: deniedRevision,
                                     assertedAt: Date().addingTimeInterval(2))
        let state = try cross(fresh)
        assertActive(state)
        let freshRevision = try revisionOf(fresh)
        XCTAssertNotEqual(freshRevision, deniedRevision)
        let storedContinuity = try await continuity(installation)
        XCTAssertNotNil(storedContinuity)
        let intent = try await prepare(installation, freshRevision)
        XCTAssertEqual(intent.0.status, .created, intent.0.body.string)
        let bound = try await bind(installation, freshRevision)
        XCTAssertEqual(bound.status, .noContent, bound.body.string)
        let oldRevision = try await prepare(installation, deniedRevision)
        XCTAssertEqual(oldRevision.0.status, .forbidden, "the inactive revision never becomes usable")
    }

    // MARK: - Continuity of a choice that was effective from the start

    func testEffectiveChoiceKeepsHeartbeatContinuityAndARefusalLatchesThisInstallation() async throws {
        let installation = UUID()
        let granted = try await choose(installation, att: "authorized", assertedAt: Date().addingTimeInterval(-10))
        assertActive(try cross(granted))
        let revision = try revisionOf(granted)
        let started = try await continuity(installation)
        let original = try XCTUnwrap(started)

        // Uninterrupted authorised heartbeats keep the same continuity.
        var clock = Date()
        for _ in 0..<2 {
            let heartbeat = try await observe(installation, revision, "authorized", at: clock)
            assertActive(try cross(heartbeat))
            let kept = try await continuity(installation)
            XCTAssertEqual(kept, original)
            clock = clock.addingTimeInterval(1)
        }

        // A lapsed 24 h observation of this uninterrupted choice may be refreshed: a new continuity
        // (queued work under the old one stays unhealable), and the choice is active again.
        try await sql.raw("""
            UPDATE measurement_att_assertions SET received_at=NOW()-INTERVAL '2 days',expires_at=NOW()-INTERVAL '1 day'
            WHERE account_id=\(bind:userID) AND installation_id=\(bind:installation)
            """).run()
        let lapsed = try await request(.GET, "api/v2/measurement/permissions", installation: installation)
        let lapsedState = try cross(lapsed)
        XCTAssertEqual(lapsedState["effective"] as? Bool, false)
        XCTAssertEqual(lapsedState["activation"] as? String, "chosen_awaiting_att")
        let refreshed = try await observe(installation, revision, "authorized", at: clock)
        assertActive(try cross(refreshed))
        let renewed = try await continuity(installation)
        XCTAssertNotNil(renewed)
        XCTAssertNotEqual(renewed, original)
        let bound = try await bind(installation, revision)
        XCTAssertEqual(bound.status, .noContent, bound.body.string)

        // A refusal on this installation keeps the revision inactive here for good.
        clock = clock.addingTimeInterval(1)
        let denied = try await observe(installation, revision, "denied", at: clock)
        assertInactive(try cross(denied), att: "denied")
        // Whole-second client clocks: a different status in the same second is a conflict, never an upgrade.
        let sameSecond = try await observe(installation, revision, "authorized", at: clock)
        XCTAssertEqual(sameSecond.status, .conflict)
        clock = clock.addingTimeInterval(1)
        let allowedAgain = try await observe(installation, revision, "authorized", at: clock)
        assertInactive(try cross(allowedAgain), att: "authorized")
        let latched = try await continuity(installation)
        XCTAssertNil(latched)
        let refusedIntent = try await prepare(installation, revision)
        XCTAssertEqual(refusedIntent.0.status, .forbidden)
        let refusedBinding = try await bind(installation, revision)
        XCTAssertEqual(refusedBinding.status, .forbidden, "the still-active subject carries no authority on a latched installation")

        // Another installation sees the same choice for the first time. The choice itself was made
        // with authorised ATT, so that installation's own first authorised observation may activate
        // it there; a first refusal there latches it there instead.
        let other = UUID(), unanswered = UUID()
        let otherFirst = try await observe(other, revision, "authorized", at: clock)
        assertActive(try cross(otherFirst))
        let unansweredFirst = try await observe(unanswered, revision, "notDetermined", at: clock)
        assertInactive(try cross(unansweredFirst), att: "notDetermined")
        let unansweredLater = try await observe(unanswered, revision, "authorized", at: clock.addingTimeInterval(1))
        assertInactive(try cross(unansweredLater), att: "authorized")
        let stillLatched = try await request(.GET, "api/v2/measurement/permissions", installation: installation)
        assertInactive(try cross(stillLatched), att: "authorized")
    }

    // MARK: - LinkedIn purchase dispatch stays ineligible for an inactive revision

    func testQueuedLinkedInPurchaseAndLaterRenewalAreIneligibleOnceTheRevisionIsInactive() async throws {
        let installation = UUID()
        let granted = try await choose(installation, att: "authorized", assertedAt: Date().addingTimeInterval(-10))
        let revision = try revisionOf(granted)
        let intent = try await prepare(installation, revision)
        let purchaseDate = Date()
        let witnessed = try await witness(try XCTUnwrap(intent.1), try XCTUnwrap(intent.2),
                                          transaction: "att-latch-initial", purchaseDate: purchaseDate)
        XCTAssertEqual(witnessed.status, .accepted)
        let purchase = try await webhook(transaction: "att-latch-initial", at: purchaseDate, chain: "att-latch-chain")
        XCTAssertEqual(purchase.status, .ok)
        let queued = try await linkedInJobs("pending")
        XCTAssertEqual(queued, 1)

        let denied = try await observe(installation, revision, "denied", at: Date().addingTimeInterval(1))
        XCTAssertEqual(denied.status, .ok)
        let allowed = try await observe(installation, revision, "authorized", at: Date().addingTimeInterval(2))
        assertInactive(try cross(allowed), att: "authorized")
        let renewal = try await webhook(transaction: "att-latch-renewal", type: "RENEWAL", at: Date(), chain: "att-latch-chain")
        XCTAssertEqual(renewal.status, .ok)
        let total = try await linkedInJobs()
        XCTAssertEqual(total, 1, "no renewal job for an inactive revision")

        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 0)
        XCTAssertEqual(counts.suppressed, 1)
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty)
        let scrubbed = try await count("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND destination='linkedin' AND state='suppressed' AND payload IS NULL")
        XCTAssertEqual(scrubbed, 1)
    }
}

private actor ATTActivationHTTPRecorder {
    struct Call: Sendable { let uri: String; let body: String }
    private var values: [Call] = []
    func record(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) -> MeasurementDispatchService.Reply {
        values.append(.init(uri: uri.string, body: String(decoding: body, as: UTF8.self)))
        return .init(status: 201, retryAfter: nil)
    }
    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, headers, body in await self.record(uri, headers, body) }
    }
    func calls() -> [Call] { values }
}
