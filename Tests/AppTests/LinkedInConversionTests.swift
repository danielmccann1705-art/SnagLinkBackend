@testable import App
import XCTest
import Vapor

/// Failure cases first: no permission, ATT refusal/staleness, an older account's permission,
/// pre-consent history, sandbox money in production, forged/restore/transfer facts, duplicate
/// delivery keys, leaked identifiers, malformed money, and ambiguous network responses.
/// These tests never connect to LinkedIn or RevenueCat.
final class LinkedInConversionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_369_000)
    let account = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let email = "SYNTHETIC@example.test"

    func permission(_ accountID: UUID? = nil, att: Bool = true) -> LinkedInConversion.Permission {
        .init(accountID: accountID ?? account, revision: UUID(), allowed: true, attAuthorised: att,
              grantedAt: now.addingTimeInterval(-600), checkedAt: now, expiresAt: now.addingTimeInterval(3600))
    }
    func settings(enabled: Bool = true) -> LinkedInConversion.Configuration {
        .init(enabled: enabled, environment: .production, signupRule: "101", subscriptionRule: "102",
              accessToken: "synthetic-test-credential", fetchedAt: now)
    }
    func signup() -> LinkedInConversion.Fact {
        .accountCreated(accountID: account, occurredAt: now, environment: .production)
    }

    func testPermissionRefusalExpiryATTAndAccountBoundary() throws {
        let valid = permission()
        XCTAssertNotNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: valid, configuration: settings(), now: now))
        var refused = valid; refused.allowed = false
        var stale = valid; stale.checkedAt = now.addingTimeInterval(-86_400)
        var expired = valid; expired.expiresAt = now
        var future = valid; future.checkedAt = now.addingTimeInterval(1)
        var lateConsent = valid; lateConsent.grantedAt = now.addingTimeInterval(1)
        for p in [refused, stale, expired, future, lateConsent, permission(UUID()), permission(att: false)] {
            XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: settings(), now: now))
        }
        XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: valid, configuration: settings(enabled: false), now: now))
        var staleConfig = settings(); staleConfig.fetchedAt = now.addingTimeInterval(-86_400)
        XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: valid, configuration: staleConfig, now: now))
    }

    func testPayloadContainsOnlyPermittedFieldsAndHasStableOpaqueIdentity() throws {
        let p = permission()
        let first = try XCTUnwrap(LinkedInConversion.prepare(signup(), verifiedEmail: "  SYNTHETIC@example.test \n", permission: p, configuration: settings(), now: now))
        let repeated = try XCTUnwrap(LinkedInConversion.prepare(signup(), verifiedEmail: email.lowercased(), permission: p, configuration: settings(), now: now))
        XCTAssertEqual(first.payload.eventId, repeated.payload.eventId)
        let data = try JSONEncoder().encode(first.payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["conversion", "conversionHappenedAt", "eventId", "user"])
        XCTAssertEqual(first.payload.conversion, "urn:lla:llaPartnerConversion:101")
        XCTAssertEqual(first.payload.conversionHappenedAt, 1_791_369_000_000)
        XCTAssertEqual(first.payload.user.userIds.first?.idType, "SHA256_EMAIL")
        XCTAssertEqual(first.payload.user.userIds.first?.idValue, SHA256Hasher.hash(token: email.lowercased()))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [email, email.lowercased(), account.uuidString, "accessToken", "userInfo", "externalIds", "ip_address"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertNil(first.payload.conversionValue)
    }

    func testMalformedOrRelayEmailNeverBecomesAMatchingIdentifier() {
        for address in ["", "name", "one@two@three.test", "a b@example.test", "a@privaterelay.appleid.com", "\"\n@example.test"] {
            XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: address, permission: permission(), configuration: settings(), now: now))
        }
    }

    func webhook(type: String = "INITIAL_PURCHASE", environment: String = "PRODUCTION", price: Any = 14.99,
                 appUserID: String? = nil, family: Bool = false, period: String = "NORMAL", transaction: String = "synthetic-transaction-1") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": [
            "id": "synthetic-source-event", "app_id": "synthetic-rc-app", "app_user_id": appUserID ?? account.uuidString,
            "type": type, "environment": environment, "store": "APP_STORE", "period_type": period,
            "is_family_share": family, "product_id": "com.snaglist.pro.monthly", "entitlement_ids": ["Snaglist Pro"],
            "event_timestamp_ms": 1_791_369_000_000,
            "purchased_at_ms": 1_791_369_000_000, "price_in_purchased_currency": price, "currency": "GBP",
            "transaction_id": transaction, "subscriber_attributes": ["email": "must-not-be-forwarded@example.test"]
        ]])
    }
    func revenue(_ body: Data, auth: String = "Bearer synthetic-webhook-secret") -> LinkedInConversion.Fact? {
        LinkedInConversion.subscriptionFact(body: body, authorization: auth,
            expectedAuthorization: "Bearer synthetic-webhook-secret", expectedRevenueCatAppID: "synthetic-rc-app")
    }

    func testMoneyComesOnlyFromAuthenticatedRevenueCatPaidFacts() throws {
        let initial = try XCTUnwrap(revenue(webhook()))
        let prepared = try XCTUnwrap(LinkedInConversion.prepare(initial, verifiedEmail: email, permission: permission(), configuration: settings(), now: now))
        XCTAssertEqual(prepared.payload.conversionValue?.amount, "14.99")
        XCTAssertEqual(prepared.payload.conversionValue?.currencyCode, "GBP")
        XCTAssertEqual(prepared.payload.conversion, "urn:lla:llaPartnerConversion:102")
        XCTAssertNil(revenue(try webhook(), auth: "Bearer wrong"))
        XCTAssertNil(LinkedInConversion.subscriptionFact(body: try webhook(), authorization: "", expectedAuthorization: "", expectedRevenueCatAppID: "synthetic-rc-app"))
        for type in ["TEST", "TRANSFER", "SUBSCRIBER_ALIAS", "CANCELLATION", "EXPIRATION", "TEMPORARY_ENTITLEMENT_GRANT", "RESTORE", "PURCHASE_REDEEMED"] {
            XCTAssertNil(revenue(try webhook(type: type)), type)
        }
        for price: Any in [0, -10, "14.99", true] { XCTAssertNil(revenue(try webhook(price: price))) }
        XCTAssertNil(revenue(try webhook(family: true)))
        XCTAssertNil(revenue(try webhook(period: "TRIAL")))
        XCTAssertNil(revenue(try webhook(appUserID: "$RCAnonymousID:synthetic")))
        XCTAssertNil(revenue(Data(repeating: 120, count: 65_537)))
    }

    func testTransactionDeduplicationAndEnvironmentIsolation() throws {
        let initial = try XCTUnwrap(revenue(webhook()))
        let replay = try XCTUnwrap(revenue(webhook(type: "RENEWAL")))
        let renewal = try XCTUnwrap(revenue(webhook(type: "RENEWAL", transaction: "synthetic-transaction-2")))
        let p = permission()
        func id(_ fact: LinkedInConversion.Fact) throws -> String {
            try XCTUnwrap(LinkedInConversion.prepare(fact, verifiedEmail: email, permission: p, configuration: settings(), now: now)).payload.eventId
        }
        XCTAssertEqual(try id(initial), try id(replay), "same charge must have the same key despite webhook redelivery/type")
        XCTAssertNotEqual(try id(initial), try id(renewal), "a different paid transaction is a separate payment")
        let sandbox = try XCTUnwrap(revenue(webhook(environment: "SANDBOX")))
        XCTAssertNil(LinkedInConversion.prepare(sandbox, verifiedEmail: email, permission: p, configuration: settings(), now: now))
    }

    func testRevenueSourceAppProductAndIdentifiersCannotBeSubstituted() throws {
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: webhook()) as? [String: Any])
        let original = try XCTUnwrap(source["event"] as? [String: Any])
        let mutations: [(String, Any)] = [
            ("app_id", "another-app"), ("store", "PLAY_STORE"), ("environment", "production"),
            ("product_id", "unrecognised.product"), ("entitlement_ids", ["different entitlement"]),
            ("app_user_id", "not-a-uuid"), ("transaction_id", ""), ("is_family_share", 0),
            ("currency", "NOT_CURRENCY"), ("event_timestamp_ms", true), ("event_timestamp_ms", -1),
            ("purchased_at_ms", true), ("purchased_at_ms", -1),
            ("purchased_at_ms", 1.1), ("price_in_purchased_currency", 1_000_000)
        ]
        for (key, value) in mutations {
            var event = original; event[key] = value
            XCTAssertNil(revenue(try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": event])), key)
        }
        // A receipt observed under another account is still the same charge, never fresh revenue.
        let otherAccount = UUID()
        let otherFact = try XCTUnwrap(revenue(webhook(appUserID: otherAccount.uuidString)))
        let first = try XCTUnwrap(LinkedInConversion.prepare(try XCTUnwrap(revenue(webhook())), verifiedEmail: email,
            permission: permission(), configuration: settings(), now: now))
        let second = try XCTUnwrap(LinkedInConversion.prepare(otherFact, verifiedEmail: email,
            permission: permission(otherAccount), configuration: settings(), now: now))
        XCTAssertEqual(first.payload.eventId, second.payload.eventId)
    }

    func testQueueCannotChangeRulesOutliveConsentOrBypassAChangedSwitch() async throws {
        let p = permission(), config = settings()
        let prepared = try XCTUnwrap(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: config, now: now))
        let recorder = LinkedInTransportRecorder()
        var changedRule = config; changedRule.signupRule = "103"
        for c in [settings(enabled: false), changedRule] {
            let result = await LinkedInConversion.send(prepared, configuration: c, now: now, permission: { p }, transport: recorder.transport)
            XCTAssertEqual(result, .suppressed)
        }
        let deletedAccount = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { nil }, transport: recorder.transport)
        XCTAssertEqual(deletedAccount, .suppressed)
        let expired = await LinkedInConversion.send(prepared, configuration: config, now: now.addingTimeInterval(3601), permission: { p }, transport: recorder.transport)
        XCTAssertEqual(expired, .suppressed)
        let calls = await recorder.count()
        XCTAssertEqual(calls, 0)
    }

    func testNoBackfillAndInvalidRulesFailClosed() {
        let p = permission()
        let history = LinkedInConversion.Fact.accountCreated(accountID: account, occurredAt: now.addingTimeInterval(-601), environment: .production)
        XCTAssertNil(LinkedInConversion.prepare(history, verifiedEmail: email, permission: p, configuration: settings(), now: now))
        var bad = settings(); bad.signupRule = "102?email=secret"
        XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: bad, now: now))
        var missing = settings(); missing.accessToken = ""
        XCTAssertNil(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: missing, now: now))
    }

    func testDispatchChecksWithdrawalAgainAndSendsTheOfficialProtocol() async throws {
        let p = permission()
        let prepared = try XCTUnwrap(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: settings(), now: now))
        let recorder = LinkedInTransportRecorder()
        let config = settings()
        let accepted = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { p }, transport: recorder.transport)
        XCTAssertEqual(accepted, .received)
        let recorded = await recorder.last()
        let call = try XCTUnwrap(recorded)
        XCTAssertEqual(call.uri, "https://api.linkedin.com/rest/conversionEvents")
        XCTAssertEqual(call.headers.first(name: "LinkedIn-Version"), "202609")
        XCTAssertEqual(call.headers.first(name: "X-Restli-Protocol-Version"), "2.0.0")
        XCTAssertEqual(call.headers.bearerAuthorization?.token, "synthetic-test-credential")
        let withdrawn: LinkedInConversion.Permission = { var copy = p; copy.allowed = false; return copy }()
        let refused = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { withdrawn }, transport: recorder.transport)
        XCTAssertEqual(refused, .suppressed)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
        let regranted: LinkedInConversion.Permission = { var copy = p; copy.revision = UUID(); return copy }()
        let oldQueue = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { regranted }, transport: recorder.transport)
        XCTAssertEqual(oldQueue, .suppressed, "regrant must not resurrect an old consent's queue")
    }

    func testNoFalseDeliveryClaimOrBlindRetryOnAmbiguousResponses() async throws {
        let p = permission(), config = settings()
        let prepared = try XCTUnwrap(LinkedInConversion.prepare(signup(), verifiedEmail: email, permission: p, configuration: config, now: now))
        let cases: [(Int, LinkedInConversion.Delivery)] = [(201, .received), (200, .uncertain), (202, .uncertain),
            (301, .rejected), (400, .rejected), (401, .configurationRequired), (403, .configurationRequired),
            (422, .rejected), (429, .rateLimited(retryAfterSeconds: 120)), (500, .uncertain)]
        for (code, expected) in cases {
            let result = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { p }, transport: { _, _, _ in
                .init(status: code, retryAfter: "120")
            })
            XCTAssertEqual(result, expected, "HTTP \(code)")
        }
        struct Timeout: Error {}
        let timedOut = await LinkedInConversion.send(prepared, configuration: config, now: now, permission: { p }, transport: { _, _, _ in throw Timeout() })
        XCTAssertEqual(timedOut, .uncertain)
    }
}

actor LinkedInTransportRecorder {
    struct Call: Sendable { let uri: String; let headers: HTTPHeaders; let body: Data }
    private var calls: [Call] = []
    func last() -> Call? { calls.last }
    func count() -> Int { calls.count }
    func record(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) -> LinkedInConversion.Reply {
        calls.append(.init(uri: uri.string, headers: headers, body: body))
        return .init(status: 201, retryAfter: nil)
    }
    nonisolated var transport: LinkedInConversion.Transport { { uri, headers, body in await self.record(uri, headers, body) } }
}
