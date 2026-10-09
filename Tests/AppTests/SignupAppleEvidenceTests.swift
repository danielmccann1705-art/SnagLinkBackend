@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// The optional pre-auth Apple Ads evidence slot (SIGNUP-ATTRIBUTION-CONTRACT.md, required
/// test 5, backend part). Real PostgreSQL; the AdServices exchange and provider keys are
/// injected fixtures. No network.
final class SignupAppleEvidenceTests: XCTestCase {
    private var app: Application!
    private let platform = PlatformConfiguration(origin: "https://portal-apple-slot.example.test", environment: "local")
    private var ip = ""
    private var intents: [UUID] = []
    private var accounts: Set<UUID> = []
    private var exchange: AppleSlotExchangeFixture!
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private static let flags = ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]
    private static let attributed = #"{"attribution":true,"orgId":40669820,"campaignId":542370539,"adGroupId":1,"keywordId":2,"adId":3,"claimType":"Click","conversionType":"Download","countryOrRegion":"GB"}"#
    private static let token = String(repeating: "QUJD", count: 40)

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = platform
        app.clients.use { AppleSlotKeysClient(eventLoop: $0.eventLoopGroup.next()) }
        exchange = AppleSlotExchangeFixture()
        app.storage[AppleAttributionExchangeService.TransportKey.self] = exchange.transport
        app.storage[AppleAttributionExchangeService.SleepKey.self] = { _ in }
        ip = "apple-slot-" + UUID().uuidString
        intents = []; accounts = []
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
        try await FeatureFlag(key: "adMeasurementEnabled", enabled: true).save(on: app.db)
    }

    override func tearDown() async throws {
        if let app {
            let sql = try VerifiedIdentityService.sql(app.db)
            for id in intents {
                if let row = try? await sql.raw("SELECT account_id FROM measurement_signup_intents WHERE id=\(bind:id)").first(),
                   let account = try? row.decode(column: "account_id", as: UUID?.self) { accounts.insert(account) }
                try? await sql.raw("DELETE FROM ad_attribution_records WHERE rc_app_user_id=\(bind:SignupAppleEvidenceService.marker(id))").run()
            }
            for account in accounts {
                try? await sql.raw("DELETE FROM ad_attribution_records WHERE canonical_account_id=\(bind:account) OR rc_app_user_id=\(bind:account.uuidString)").run()
                for table in ["measurement_dispatch_jobs", "measurement_erasure_jobs", "measurement_att_assertions", "measurement_permission_current"] {
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
                try? await sql.raw("DELETE FROM account_deletion_jobs WHERE user_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM users WHERE id=\(bind:account)").run()
            }
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
            try await app.asyncShutdown()
        }
        app = nil; exchange = nil
    }

    // MARK: - Helpers

    private struct Issued { let id: UUID; let capability: String; let nonce: String; let installation: UUID }

    private func request(_ method: HTTPMethod, _ path: String, object: [String: Any]? = nil, origin: String? = nil,
                         bearer: String? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: self.ip)
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

    private func issue(apple: Bool = true, product: Bool = false) async throws -> Issued {
        let installation = UUID()
        let response = try await request(.POST, "api/v2/measurement/signup-intents", object: [
            "provider": "apple", "installationId": installation.uuidString, "noticeVersion": "signup-measurement-v1",
            "choices": ["productAnalytics": product, "appleAds": apple, "crossCompanyAds": false]])
        XCTAssertEqual(response.status, .created, response.body.string)
        let value = try json(response)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value["intentId"] as? String)))
        intents.append(id)
        return .init(id: id, capability: try XCTUnwrap(value["capability"] as? String),
                     nonce: try XCTUnwrap(value["appleNonce"] as? String), installation: installation)
    }

    private func evidence(_ intent: Issued, capability: String? = nil, extra: [String: Any] = [:],
                          origin: String? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["capability": capability ?? intent.capability, "token": Self.token, "appVersion": "2.0.1"]
        body.merge(extra) { $1 }
        return try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/apple-evidence", object: body, origin: origin)
    }

    private func reference(_ response: XCTHTTPResponse, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        XCTAssertEqual(response.status, .created, response.body.string, file: file, line: line)
        return try XCTUnwrap(try json(response)["reference"] as? String, file: file, line: line)
    }

    private func appleToken(subject: String, nonce: String?) throws -> String {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: GoogleIdentityProofTests.syntheticPrivate)), kid: "synthetic-rsa")
        return try signers.sign(AppleSlotClaims(iss: .init(value: "https://appleid.apple.com"), sub: .init(value: subject),
            aud: .init(value: [AppleIdentityConfiguration.releaseAudience]), exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()), nonce: nonce), kid: "synthetic-rsa")
    }

    private func signIn(_ intent: Issued?, subject: String = "apple-slot-\(UUID())",
                        file: StaticString = #filePath, line: UInt = #line) async throws -> AuthResponse {
        var body: [String: Any] = ["identityToken": try appleToken(subject: subject, nonce: intent?.nonce)]
        if let intent { body["measurementContext"] = ["intentId": intent.id.uuidString, "capability": intent.capability] }
        let response = try await request(.POST, "api/v1/auth/apple", object: body)
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line)
        let auth = try response.content.decode(AuthResponse.self)
        accounts.insert(auth.user.id)
        return auth
    }

    private func record(_ reference: String) async throws -> SQLRow? {
        try await sql.raw("""
            SELECT exchange_state,rc_app_user_id,token,canonical_account_id,canonical_consent_revision,canonical_installation_id,
                   evidence_class,evidence_config_hash,campaign_id
            FROM ad_attribution_records WHERE reference=\(bind:reference)
            """).first()
    }

    private func appleRevision(_ intent: Issued) async throws -> UUID {
        let value = try await sql.raw("SELECT apple_revision FROM measurement_signup_intents WHERE id=\(bind:intent.id)").first()?
            .decode(column: "apple_revision", as: UUID?.self)
        return try XCTUnwrap(value ?? nil)
    }

    private func collect(_ auth: AuthResponse, installation: UUID, revision: UUID) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/apple", object: [
            "token": Self.token, "installationId": installation.uuidString,
            "consentRevision": revision.uuidString, "appVersion": "2.0.1"], bearer: auth.token)
    }

    // MARK: - Arrival order

    func testEvidenceBeforeAuthIsLinkedAtAdoptionAndReusedByTheSignedInCollector() async throws {
        await exchange.answer(.ok, Self.attributed)
        let intent = try await issue()
        let slot = try reference(try await evidence(intent))
        let before = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertEqual(try before.decode(column: "exchange_state", as: String.self), "done")
        XCTAssertNil(try before.decode(column: "token", as: String?.self), "the token is never stored")
        XCTAssertNil(try before.decode(column: "canonical_account_id", as: UUID?.self))
        XCTAssertEqual(try before.decode(column: "rc_app_user_id", as: String.self), SignupAppleEvidenceService.marker(intent.id))
        XCTAssertEqual(try before.decode(column: "evidence_class", as: String?.self), "unknown", "no verified ownership allowlist")

        let auth = try await signIn(intent)
        XCTAssertTrue(auth.isNewUser)
        let revision = try await appleRevision(intent)
        let linked = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertEqual(try linked.decode(column: "canonical_account_id", as: UUID?.self), auth.user.id)
        XCTAssertEqual(try linked.decode(column: "canonical_consent_revision", as: UUID?.self), revision)
        XCTAssertEqual(try linked.decode(column: "canonical_installation_id", as: UUID?.self), intent.installation)
        XCTAssertEqual(try linked.decode(column: "rc_app_user_id", as: String.self), auth.user.id.uuidString)

        // The signed-in collector finds the same canonical row: no second exchange.
        let collected = try await collect(auth, installation: intent.installation, revision: revision)
        XCTAssertEqual(try reference(collected), slot)
        let again = try reference(try await evidence(intent))
        XCTAssertEqual(again, slot)
        let calls = await exchange.calls()
        XCTAssertEqual(calls, 1)
    }

    func testAuthBeforeExchangeCompletesFillsOnlyTheFrozenSlot() async throws {
        await exchange.answer(.ok, Self.attributed)
        await exchange.suspendNext()
        let intent = try await issue()
        let application = app!, address = ip
        let submit = Task { () -> (UInt, String) in
            var result: (UInt, String) = (0, "")
            try await application.test(.POST, "api/v2/measurement/signup-intents/\(intent.id)/apple-evidence", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-Forwarded-For", value: address)
                try req.content.encode(["capability": intent.capability, "token": Self.token, "appVersion": "2.0.1"])
            }, afterResponse: { response async in result = (response.status.code, response.body.string) })
            return result
        }
        await exchange.waitUntilEntered()
        let auth = try await signIn(intent)
        XCTAssertTrue(auth.isNewUser, "authentication never waits for the exchange")
        let pointer = try await sql.raw("SELECT apple_slot_reference FROM measurement_signup_intents WHERE id=\(bind:intent.id)").first()?
            .decode(column: "apple_slot_reference", as: String?.self)
        let slot = try XCTUnwrap(pointer ?? nil)
        let processing = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertEqual(try processing.decode(column: "exchange_state", as: String.self), "processing")
        XCTAssertEqual(try processing.decode(column: "canonical_account_id", as: UUID?.self), auth.user.id)
        await exchange.resume()
        let (status, body) = try await submit.value
        XCTAssertEqual(status, 201, body)
        let filled = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertEqual(try filled.decode(column: "exchange_state", as: String.self), "done")
        XCTAssertEqual(try filled.decode(column: "campaign_id", as: Int64?.self), 542_370_539)
        let adoptedRevision = try await appleRevision(intent)
        XCTAssertEqual(try filled.decode(column: "canonical_consent_revision", as: UUID?.self), adoptedRevision)
    }

    func testCancellationDuringExchangeDiscardsTheResult() async throws {
        await exchange.answer(.ok, Self.attributed)
        await exchange.suspendNext()
        let intent = try await issue()
        let application = app!, address = ip
        let submit = Task { () -> UInt in
            var status: UInt = 0
            try await application.test(.POST, "api/v2/measurement/signup-intents/\(intent.id)/apple-evidence", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-Forwarded-For", value: address)
                try req.content.encode(["capability": intent.capability, "token": Self.token, "appVersion": "2.0.1"])
            }, afterResponse: { response async in status = response.status.code })
            return status
        }
        await exchange.waitUntilEntered()
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(cancel.status, .ok)
        await exchange.resume()
        let status = try await submit.value
        XCTAssertEqual(status, 409)
        let rows = try await sql.raw("SELECT id FROM ad_attribution_records WHERE rc_app_user_id=\(bind:SignupAppleEvidenceService.marker(intent.id))").all()
        XCTAssertTrue(rows.isEmpty)
        let auth = try await signIn(intent)
        let joined = try await sql.raw("SELECT id FROM ad_attribution_records WHERE canonical_account_id=\(bind:auth.user.id)").all()
        XCTAssertTrue(joined.isEmpty)
    }

    // MARK: - No slot, no join; never another account or installation

    func testNoSlotBeforeCreationMeansNoCampaignJoinAndExistingAccountsNeverJoin() async throws {
        await exchange.answer(.ok, Self.attributed)
        let unslotted = try await issue()
        let auth = try await signIn(unslotted)
        let none = try await sql.raw("SELECT id FROM ad_attribution_records WHERE canonical_account_id=\(bind:auth.user.id)").all()
        XCTAssertTrue(none.isEmpty)
        let late = try await evidence(unslotted)
        XCTAssertEqual(late.status, .conflict)
        XCTAssertTrue(late.body.string.contains("measurement_signup_slot_closed"))

        let subject = "apple-slot-existing-\(UUID())"
        let existing = try await signIn(nil, subject: subject)
        let intent = try await issue()
        let slot = try reference(try await evidence(intent))
        let again = try await signIn(intent, subject: subject)
        XCTAssertFalse(again.isNewUser); XCTAssertEqual(again.user.id, existing.user.id)
        let unlinked = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertNil(try unlinked.decode(column: "canonical_account_id", as: UUID?.self))
        _ = try await SignupIntentService.cleanup(on: app.db)
        let gone = try await record(slot)
        XCTAssertNil(gone)
        let calls = await exchange.calls()
        XCTAssertEqual(calls, 1)
    }

    func testWrongInstallationOrRevisionNeverReusesTheSlot() async throws {
        await exchange.answer(.ok, Self.attributed)
        let intent = try await issue()
        let slot = try reference(try await evidence(intent))
        let auth = try await signIn(intent)
        let revision = try await appleRevision(intent)
        let otherInstall = try await collect(auth, installation: UUID(), revision: revision)
        let otherReference = try reference(otherInstall)
        XCTAssertNotEqual(otherReference, slot)
        let wrongRevision = try await collect(auth, installation: intent.installation, revision: UUID())
        XCTAssertEqual(wrongRevision.status, .conflict)
        let kept = try await XCTUnwrapAsync(try await record(slot))
        XCTAssertEqual(try kept.decode(column: "canonical_installation_id", as: UUID?.self), intent.installation)
        let calls = await exchange.calls()
        XCTAssertEqual(calls, 2, "only the other installation's own collection exchanged")
    }

    // MARK: - Classification and ownership provenance

    func testClassificationsStayExplicitAndPaidNeedsTheCurrentOwnershipAllowlist() async throws {
        func classify(_ body: String) async throws -> SQLRow {
            await exchange.answer(.ok, body)
            let intent = try await issue()
            return try await XCTUnwrapAsync(try await record(try reference(try await evidence(intent))))
        }
        let organic = try await classify(#"{"attribution":false}"#)
        XCTAssertEqual(try organic.decode(column: "evidence_class", as: String?.self), "organic")
        let test = try await classify(#"{"attribution":true,"orgId":1234567890,"campaignId":1234567890,"adGroupId":1234567890,"keywordId":123222,"adId":542317136}"#)
        XCTAssertEqual(try test.decode(column: "evidence_class", as: String?.self), "test")
        let absent = try await classify(Self.attributed)
        XCTAssertEqual(try absent.decode(column: "evidence_class", as: String?.self), "unknown")
        XCTAssertNil(try absent.decode(column: "evidence_config_hash", as: String?.self))

        let owned = ApplePurchaseOriginService.CampaignConfiguration(organizationID: 40_669_820, campaignIDs: [542_370_539])
        app.storage[ApplePurchaseOriginService.CampaignConfigurationKey.self] = owned
        let verified = try await classify(Self.attributed)
        XCTAssertEqual(try verified.decode(column: "evidence_class", as: String?.self), "verified")
        XCTAssertEqual(try verified.decode(column: "evidence_config_hash", as: String?.self), owned.provenanceHash)

        // A changed allowlist classifies new evidence by the new list and never re-blesses old rows.
        let changed = ApplePurchaseOriginService.CampaignConfiguration(organizationID: 40_669_820, campaignIDs: [1])
        app.storage[ApplePurchaseOriginService.CampaignConfigurationKey.self] = changed
        let unowned = try await classify(Self.attributed)
        XCTAssertEqual(try unowned.decode(column: "evidence_class", as: String?.self), "unknown")
        XCTAssertNotEqual(owned.provenanceHash, changed.provenanceHash)
    }

    // MARK: - Withdrawal, regrant and deletion

    func testCancellationRegrantAndDeletionNeverResurrectTheSlot() async throws {
        await exchange.answer(.ok, Self.attributed)
        let intent = try await issue()
        let slot = try reference(try await evidence(intent))
        let auth = try await signIn(intent)
        let cancel = try await request(.POST, "api/v2/measurement/signup-intents/\(intent.id)/cancel", object: ["capability": intent.capability])
        XCTAssertEqual(cancel.status, .ok, cancel.body.string)
        let cancelled = try await record(slot)
        XCTAssertNil(cancelled)
        let current = try await XCTUnwrapAsync(try await sql.raw("SELECT revision,decision FROM measurement_permission_current WHERE account_id=\(bind:auth.user.id) AND purpose='appleAds'").first())
        XCTAssertEqual(try current.decode(column: "decision", as: String.self), "withdrawn")
        let regrant = try await request(.PUT, "api/v2/measurement/permissions/appleAds", object: [
            "requestId": UUID().uuidString, "expectedRevision": try current.decode(column: "revision", as: UUID.self).uuidString,
            "decision": "granted", "occurredAt": ISO8601DateFormatter().string(from: Date())], bearer: auth.token)
        XCTAssertEqual(regrant.status, .ok, regrant.body.string)
        let resurrected = try await sql.raw("SELECT id FROM ad_attribution_records WHERE canonical_account_id=\(bind:auth.user.id)").all()
        XCTAssertTrue(resurrected.isEmpty)

        let second = try await issue()
        let secondSlot = try reference(try await evidence(second))
        let deleted = try await signIn(second)
        let job = UUID()
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:job),\(bind:deleted.user.id),\(bind:SHA256Hasher.hash(token: "apple-slot-deletion-\(job)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        try await app.db.transaction { tx in
            _ = try await VerifiedIdentityService.sql(tx).raw("SELECT id FROM users WHERE id=\(bind:deleted.user.id) FOR UPDATE").first()
            try await MeasurementPrivacyService.eraseAccount(deleted.user.id, accountDeletionJobID: job, now: Date(), on: tx)
        }
        let erased = try await record(secondSlot)
        XCTAssertNil(erased)
    }

    // MARK: - Route guards

    func testSlotGuardsAndOneExchangePerSlot() async throws {
        await exchange.answer(.ok, Self.attributed)
        let intent = try await issue()
        let browser = try await evidence(intent, origin: platform.origin)
        XCTAssertEqual(browser.status, .forbidden)
        let wrong = try await evidence(intent, capability: String(repeating: "C", count: 43))
        XCTAssertEqual(wrong.status, .notFound)
        XCTAssertFalse(wrong.body.string.contains(Self.token))
        let extra = try await evidence(intent, extra: ["installationId": UUID().uuidString])
        XCTAssertEqual(extra.status, .badRequest)
        let noApple = try await issue(apple: false, product: true)
        let refused = try await evidence(noApple)
        XCTAssertEqual(refused.status, .conflict)

        try await FeatureFlag.query(on: app.db).filter(\.$key == "adMeasurementEnabled").delete()
        let off = try await evidence(intent)
        XCTAssertEqual(off.status, .serviceUnavailable)
        XCTAssertTrue(off.body.string.contains("measurement_off"))
        try await FeatureFlag(key: "adMeasurementEnabled", enabled: true).save(on: app.db)

        // Apple has nothing yet: the reservation is released and a later attempt may try again.
        await exchange.answer(.notFound, "")
        let notYet = try await evidence(intent)
        XCTAssertEqual(notYet.status, .serviceUnavailable)
        let released = try await sql.raw("SELECT apple_slot_reference FROM measurement_signup_intents WHERE id=\(bind:intent.id)").first()?
            .decode(column: "apple_slot_reference", as: String?.self)
        XCTAssertNil(released ?? nil)
        await exchange.answer(.ok, Self.attributed)
        let slot = try reference(try await evidence(intent))
        let before = await exchange.calls()
        let repeated = try reference(try await evidence(intent))
        XCTAssertEqual(repeated, slot)
        let after = await exchange.calls()
        XCTAssertEqual(after, before, "a settled slot is never exchanged twice")
    }
}

// MARK: - Fixtures

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private struct AppleSlotClaims: JWTPayload {
    let iss: IssuerClaim; let sub: SubjectClaim; let aud: AudienceClaim
    let exp: ExpirationClaim; let iat: IssuedAtClaim; let nonce: String?
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

private struct AppleSlotKeysClient: Client {
    let eventLoop: EventLoop
    func delegating(to eventLoop: EventLoop) -> Client { Self(eventLoop: eventLoop) }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        guard request.method == .GET, request.url.string == "https://appleid.apple.com/auth/keys" else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .serviceUnavailable))
        }
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok, headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: "{\"keys\": [{\"kty\": \"RSA\", \"alg\": \"RS256\", \"kid\": \"synthetic-rsa\", \"n\": \"uGYddtsfqUEsknHQigvKpKrqNioJzARPjKWVyxqFMGxVKZaT5xm-9OwxRpBtLQh8O1MKdDHDSCGu43s_eYMVNOgYvfEpCfp8WhT__moII9UrP9AAWJ9uvVvN03NEw-bkyOFChn1fVKeuOO8QPU1LUyWtQOKTx1aGZrFFYvz08sgPeOpRcM0wIs9xfgiodQjGhMVjNsjmQ7P02Nn54-RRGavjXQB-suKGSuAlI9Zsy7Nb1fO9ObufUWS4RiOT3Ozty-sJfYvBNR-HkiB6aSWS7-VWOdogvAf8Z1VcXVT7nXku66FvD-utG5uezKxf2iwx1E4hfKMvuIj9LJ2vwRFfEw\", \"e\": \"AQAB\"}]}")))
    }
}

/// Synthetic AdServices endpoint. It can hold one call open until the test releases it.
private actor AppleSlotExchangeFixture {
    private var status: HTTPStatus = .ok
    private var body = ""
    private var count = 0
    private var suspend = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    func answer(_ status: HTTPStatus, _ body: String) { self.status = status; self.body = body }
    func suspendNext() { suspend = true; entered = false }
    func calls() -> Int { count }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func resume() { gate?.resume(); gate = nil }

    func reply() async -> AppleAttributionExchangeService.Reply {
        count += 1
        if suspend {
            suspend = false
            entered = true
            enteredWaiters.forEach { $0.resume() }; enteredWaiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        return .init(status: status, body: ByteBuffer(string: body))
    }

    nonisolated var transport: AppleAttributionExchangeService.Transport {
        { _, _, _ in await self.reply() }
    }
}
