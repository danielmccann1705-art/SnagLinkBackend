@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Conversion classification of verified RevenueCat purchases (PURCHASE-ORIGIN-OCT9.md).
///
/// The money ledger stays verified and deduplicated. Product events say which of three
/// origins a new-money candidate has: `confirmed_origin` (an exact product-purpose purchase
/// callback witness joined the verified charge), `recovered_history` (evidence that the
/// transaction was restored, transferred or aliased) or `unknown_origin`. Purchase age is a
/// freshness label only. Written before the 72-hour rule was replaced, so every case here
/// first ran against that rule (outputs/measurement-2026-10-07/purchase-origin-oct9-01-*.log).
final class PurchaseOriginClassificationTests: XCTestCase {
    private var app: Application!
    private var user: User!
    private var jwt: String!
    private var others: [UUID] = []
    private var recorder: OriginHTTPRecorder!
    private var userID: UUID { try! user.requireID() }
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let day: TimeInterval = 86_400

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: .sandbox)
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        recorder = OriginHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        (user, jwt) = try await makeUser("origin")
    }

    override func tearDown() async throws {
        if let app {
            for account in [userID] + others {
                try? await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE charge_id IN (SELECT id FROM measurement_revenuecat_events WHERE account_id=\(bind:account))").run()
                try? await sql.raw("DELETE FROM measurement_purchase_intents WHERE account_id=\(bind:account)").run()
                try? await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_purchase_acquisitions WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_revenuecat_adjustments WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_revenuecat_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_product_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_device_bindings WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_att_assertions WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_permission_current WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:account)").run()
                try? await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:account)").run()
                try? await User.query(on: app.db).filter(\.$id == account).delete()
            }
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]).delete()
            try await app.asyncShutdown()
        }
        app = nil; user = nil; jwt = nil; others = []; recorder = nil
    }

    // MARK: - Helpers

    private func makeUser(_ label: String) async throws -> (User, String) {
        let created = User(appleUserId: nil, email: "\(label)-\(UUID().uuidString.lowercased())@example.test",
                           name: "Synthetic manager", authProvider: .magicLink)
        try await created.save(on: app.db)
        let id = try created.requireID()
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: id,
            authVersion: created.authVersion, authenticatedAt: Date()))
        return (created, token)
    }

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }

    private func request(_ method: HTTPMethod, _ path: String, token: String? = nil,
                         object: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if let object {
                req.headers.contentType = .json
                req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
            }
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func enable(_ key: String) async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
        try await FeatureFlag(key: key, enabled: true).save(on: app.db)
    }

    private func object(_ response: XCTHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    private func revision(_ purpose: String, in response: XCTHTTPResponse) throws -> UUID {
        let values = try XCTUnwrap(try object(response)["permissions"] as? [[String: Any]])
        let entry = try XCTUnwrap(values.first { $0["purpose"] as? String == purpose })
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(entry["revision"] as? String)))
    }

    /// Product permission granted long before every purchase below, so only the
    /// classification decides; consent timing has its own tests.
    @discardableResult
    private func grantProduct(token: String? = nil, account: UUID? = nil) async throws -> UUID {
        try await enable("productAnalyticsEnabled")
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics",
                                         token: token ?? jwt, object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date()
        ])
        XCTAssertEqual(response.status, .ok, response.body.string)
        try await sql.raw("""
            UPDATE measurement_permission_current SET updated_at=updated_at - INTERVAL '90 days'
            WHERE account_id=\(bind:account ?? userID) AND purpose='productAnalytics'
            """).run()
        return try revision("productAnalytics", in: response)
    }

    private func prepareProduct(_ revision: UUID, installation: UUID = UUID(),
                                token: String? = nil) async throws -> (XCTHTTPResponse, UUID?, String?) {
        let response = try await request(.POST, "api/v2/measurement/product/purchase-intents", token: token ?? jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "productId": "com.snaglist.pro.monthly"
        ])
        guard response.status == .created else { return (response, nil, nil) }
        let body = try object(response)
        return (response, UUID(uuidString: try XCTUnwrap(body["intentId"] as? String)), body["capability"] as? String)
    }

    private func witnessProduct(_ intent: UUID, _ capability: String, transaction: String, purchaseDate: Date,
                                source: String = "purchaseCallback", path: String = "product/purchase-intents") async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/\(path)/\(intent.uuidString)/witness", token: jwt, object: [
            "capability": capability, "transactionId": transaction, "productId": "com.snaglist.pro.monthly",
            "purchaseDate": date(purchaseDate), "source": source
        ])
    }

    /// Simulates a callback witnessed `interval` ago by moving the stored intent back.
    private func backdateIntent(_ intent: UUID, by interval: TimeInterval) async throws {
        try await sql.raw("""
            UPDATE measurement_purchase_intents SET issued_at=issued_at - make_interval(secs => \(bind:interval)),
                expires_at=expires_at - make_interval(secs => \(bind:interval)),
                purchase_observed_at=purchase_observed_at - make_interval(secs => \(bind:interval)),
                witnessed_at=witnessed_at - make_interval(secs => \(bind:interval)),
                pending_expires_at=pending_expires_at - make_interval(secs => \(bind:interval))
            WHERE id=\(bind:intent)
            """).run()
    }

    private func revenueCatBody(transaction: String, type: String = "INITIAL_PURCHASE",
                                eventID: String = UUID().uuidString, eventTimestamp: Date = Date(),
                                purchasedAt: Date? = nil, price: Any = 14.99,
                                cancellationReason: String? = nil, appUserID: UUID? = nil) throws -> Data {
        let purchasedAt = purchasedAt ?? eventTimestamp
        var event: [String: Any] = [
            "id": eventID, "app_id": "synthetic-rc-app", "app_user_id": (appUserID ?? userID).uuidString,
            "type": type, "environment": "SANDBOX", "store": "APP_STORE", "period_type": "NORMAL",
            "is_family_share": false, "product_id": "com.snaglist.pro.monthly", "entitlement_ids": ["Snaglist Pro"],
            "event_timestamp_ms": Int64(eventTimestamp.timeIntervalSince1970 * 1000),
            "purchased_at_ms": Int64(purchasedAt.timeIntervalSince1970 * 1000),
            "expiration_at_ms": Int64(purchasedAt.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000),
            "price_in_purchased_currency": price, "currency": "GBP", "transaction_id": transaction,
            "original_transaction_id": transaction,
            "subscriber_attributes": ["email": "must-never-be-stored@example.test"]
        ]
        if let cancellationReason { event["cancel_reason"] = cancellationReason }
        return try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": event])
    }

    /// TRANSFER carries no subscription lifecycle fields (RevenueCat event-types-and-fields, Transfer fields).
    private func transferBody(to account: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": [
            "id": UUID().uuidString, "app_id": "synthetic-rc-app", "type": "TRANSFER",
            "event_timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000), "store": "APP_STORE",
            "environment": "SANDBOX", "transferred_from": [UUID().uuidString], "transferred_to": [account.uuidString]
        ] as [String: Any]])
    }

    private func webhook(_ body: Data) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(.POST, "api/v2/measurement/webhooks/revenuecat", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .authorization, value: "Bearer synthetic-webhook-secret")
            req.headers.contentType = .json
            req.body = .init(data: body)
        }, afterResponse: { answer = $0 })
        return answer
    }

    /// A consented client `restore_verified` upload (the product-purpose restore signal).
    private func uploadRestoreVerified(_ revision: UUID) async throws {
        let response = try await request(.POST, "api/v2/measurement/events", token: jwt, object: [
            "eventId": UUID().uuidString, "occurredAt": date(), "consentRevision": revision.uuidString,
            "installationId": UUID().uuidString,
            "event": ["schemaVersion": 1, "name": "restore_verified", "properties": ["context": "settings"]]
        ])
        XCTAssertEqual(response.status, .accepted, response.body.string)
    }

    /// The settle window has passed: every witness that could confirm these charges exists by now.
    private func elapseSettleWindow(_ account: UUID? = nil) async throws {
        try await sql.raw("""
            UPDATE measurement_dispatch_jobs SET available_at=NOW() - INTERVAL '1 second'
            WHERE account_id=\(bind:account ?? userID) AND state='pending'
            """).run()
    }

    private func count(_ sqlText: String, _ account: UUID? = nil) async throws -> Int {
        try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: sqlText) AND account_id=\(bind:account ?? userID)")
            .first()!.decode(column: "n", as: Int.self)
    }

    /// Subscription events PostHog received, as (event, properties).
    private func subscriptionCalls() async throws -> [(String, [String: Any])] {
        try await recorder.calls().compactMap { call in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
            let event = try XCTUnwrap(body["event"] as? String)
            guard event.hasPrefix("subscription_") else { return nil }
            return (event, try XCTUnwrap(body["properties"] as? [String: Any]))
        }
    }

    // MARK: - Required cases

    /// A transaction RevenueCat first learns about during a restore can be recent. Being inside
    /// 72 hours does not make it a user purchase on this account.
    func testRecentRestoreDiscoveredTransactionIsNeverConfirmedOrigin() async throws {
        try await grantProduct()
        let now = Date()
        let response = try await webhook(revenueCatBody(transaction: "restore-recent", eventTimestamp: now,
                                                        purchasedAt: now.addingTimeInterval(-2 * day)))
        XCTAssertEqual(response.status, .ok, response.body.string)
        let charges = try await count("measurement_revenuecat_events WHERE TRUE")
        XCTAssertEqual(charges, 1, "the verified money ledger keeps the charge")
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "subscription_payment")
        XCTAssertEqual(calls.first?.1["lifecycleKind"] as? String, "initial_purchase")
        XCTAssertNotEqual(calls.first?.1["purchaseOrigin"] as? String, "confirmed_origin")
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "unknown_origin",
                       "no product-purpose witness: unknown, never presented as confirmed")
        XCTAssertEqual(calls.first?.1["reportLag"] as? String, "within_72h", "freshness label only")
    }

    /// The same recent restore with the consented client restore signal is recovered history.
    func testRecentRestoreWithConsentedRestoreSignalIsRecoveredHistory() async throws {
        let revision = try await grantProduct()
        let now = Date()
        _ = try await webhook(revenueCatBody(transaction: "restore-signalled", eventTimestamp: now,
                                             purchasedAt: now.addingTimeInterval(-2 * day)))
        _ = try await webhook(revenueCatBody(transaction: "restore-signalled-trial", eventTimestamp: now,
                                             purchasedAt: now.addingTimeInterval(-40 * day), price: 0))
        try await uploadRestoreVerified(revision)
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(Set(calls.map(\.0)), ["subscription_payment", "subscription_zero_value"])
        for (event, properties) in calls {
            XCTAssertEqual(properties["purchaseOrigin"] as? String, "recovered_history", event)
        }
        let charges = try await count("measurement_revenuecat_events WHERE TRUE")
        XCTAssertEqual(charges, 1)
    }

    /// A genuine purchase whose RevenueCat event is generated more than 72 hours after
    /// `purchased_at`, with the exact product-purpose callback witness, is confirmed.
    func testGenuinePurchaseReportedLateWithProductWitnessIsConfirmedOrigin() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        XCTAssertEqual(prepared.0.status, .created, prepared.0.body.string)
        XCTAssertEqual(prepared.0.headers.first(name: .cacheControl), "no-store")
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(2)
        let witness = try await witnessProduct(intent, capability, transaction: "late-genuine", purchaseDate: purchaseDate)
        XCTAssertEqual(witness.status, .accepted, witness.body.string)
        try await backdateIntent(intent, by: 4 * day)
        let provider = try await webhook(revenueCatBody(transaction: "late-genuine", eventTimestamp: Date(),
                                                        purchasedAt: purchaseDate.addingTimeInterval(-4 * day)))
        XCTAssertEqual(provider.status, .ok, provider.body.string)

        let state = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:intent)")
            .first()?.decode(column: "state", as: String.self)
        XCTAssertEqual(state, "matched")
        // Confirmed at ingest: nothing left to wait for.
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "confirmed_origin")
        XCTAssertEqual(calls.first?.1["reportLag"] as? String, "over_72h")
        let ads = try await count("measurement_dispatch_jobs WHERE destination IN ('linkedin','singular')")
        XCTAssertEqual(ads, 0, "a product witness never creates advertising work")
        let durable = try await sql.raw("SELECT row_to_json(i)::text AS body FROM measurement_purchase_intents i WHERE id=\(bind:intent)")
            .first()!.decode(column: "body", as: String.self)
        XCTAssertFalse(durable.contains(capability)); XCTAssertFalse(durable.contains("late-genuine"))
    }

    /// The same late purchase without any witness stays in the ledger and is unknown, not dropped.
    func testLatePurchaseWithoutWitnessIsUnknownOriginAndStaysInTheLedger() async throws {
        try await grantProduct()
        let now = Date()
        let provider = try await webhook(revenueCatBody(transaction: "late-unwitnessed", eventTimestamp: now,
                                                        purchasedAt: now.addingTimeInterval(-4 * day)))
        XCTAssertEqual(provider.status, .ok)
        let charges = try await count("measurement_revenuecat_events WHERE TRUE")
        XCTAssertEqual(charges, 1)
        let jobs = try await count("measurement_dispatch_jobs WHERE destination='posthog' AND source_kind='revenueCatLifecycle'")
        XCTAssertEqual(jobs, 1, "an unconfirmed purchase is classified, not excluded")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let early = try await subscriptionCalls()
        XCTAssertTrue(early.isEmpty, "undecided initial purchases wait for the settle window")
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "unknown_origin")
        XCTAssertEqual(calls.first?.1["reportLag"] as? String, "over_72h")
    }

    /// Witness after the webhook, inside the settle window: the frozen classification is confirmed.
    func testWitnessArrivingAfterTheWebhookStillConfirmsBeforeTheClassificationFreezes() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(2)
        _ = try await webhook(revenueCatBody(transaction: "provider-first", eventTimestamp: purchaseDate,
                                             purchasedAt: purchaseDate))
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let beforeWitness = try await subscriptionCalls()
        XCTAssertTrue(beforeWitness.isEmpty)
        let witness = try await witnessProduct(intent, capability, transaction: "provider-first", purchaseDate: purchaseDate)
        XCTAssertEqual(witness.status, .accepted, witness.body.string)
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "confirmed_origin")
        XCTAssertEqual(calls.first?.1["reportLag"] as? String, "within_72h")
    }

    /// Product classification needs no advertising consent, and advertising evidence is
    /// neither required nor borrowed by it. LinkedIn keeps its exact cross-company witness rule.
    func testProductOriginIsIndependentOfAdvertisingConsentAndEvidence() async throws {
        for flag in ["crossCompanyAdsEnabled", "linkedInConversionsEnabled"] { try await enable(flag) }
        try await sql.raw("""
            INSERT INTO user_identities(id,user_id,provider,subject,verified_at)
            VALUES (\(bind:UUID()),\(bind:userID),'email',\(bind:"origin-verified@example.test"),NOW() - INTERVAL '1 hour')
            """).run()
        let productRevision = try await grantProduct()

        // Product witness only, no cross-company consent: confirmed product origin, no ad job.
        let product = try await prepareProduct(productRevision)
        let purchaseDate = Date().addingTimeInterval(2)
        _ = try await witnessProduct(try XCTUnwrap(product.1), try XCTUnwrap(product.2),
                                     transaction: "product-only", purchaseDate: purchaseDate)
        _ = try await webhook(revenueCatBody(transaction: "product-only", eventTimestamp: purchaseDate, purchasedAt: purchaseDate))

        // Cross-company witness only: the LinkedIn job still needs (and has) the exact witness,
        // while product analytics does not read that advertising evidence.
        let installation = UUID()
        let cross = try await request(.PUT, "api/v2/measurement/permissions/crossCompanyAds", token: jwt, object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date(),
            "installationId": installation.uuidString, "attStatus": "authorized", "attAssertedAt": date()
        ])
        XCTAssertEqual(cross.status, .ok, cross.body.string)
        let crossRevision = try revision("crossCompanyAds", in: cross)
        let crossIntent = try await request(.POST, "api/v2/measurement/purchase-intents", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": crossRevision.uuidString,
            "productId": "com.snaglist.pro.monthly"
        ])
        XCTAssertEqual(crossIntent.status, .created, crossIntent.body.string)
        let crossBody = try object(crossIntent)
        let crossDate = Date()
        let crossWitness = try await witnessProduct(try XCTUnwrap(UUID(uuidString: try XCTUnwrap(crossBody["intentId"] as? String))),
                                                    try XCTUnwrap(crossBody["capability"] as? String),
                                                    transaction: "cross-only", purchaseDate: crossDate, path: "purchase-intents")
        XCTAssertEqual(crossWitness.status, .accepted, crossWitness.body.string)
        _ = try await webhook(revenueCatBody(transaction: "cross-only", eventTimestamp: crossDate, purchasedAt: crossDate))

        let linkedIn = try await count("measurement_dispatch_jobs WHERE destination='linkedin'")
        XCTAssertEqual(linkedIn, 1, "only the cross-company witnessed charge creates LinkedIn work")
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let origins = try await subscriptionCalls().compactMap { $0.1["purchaseOrigin"] as? String }
        XCTAssertEqual(origins.sorted(), ["confirmed_origin", "unknown_origin"])
    }

    /// Renewals are recurring money on an existing chain, never a conversion candidate.
    func testRenewalCarriesNoOriginAndRelaysWithoutWaiting() async throws {
        try await grantProduct()
        let now = Date()
        _ = try await webhook(revenueCatBody(transaction: "renewal-one", type: "RENEWAL", eventTimestamp: now,
                                             purchasedAt: now.addingTimeInterval(-5 * day)))
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["lifecycleKind"] as? String, "renewal")
        XCTAssertNil(calls.first?.1["purchaseOrigin"])
        XCTAssertNil(calls.first?.1["reportLag"])
    }

    /// A refund of an unconfirmed charge maps once and carries no origin; the charge waits and is unknown.
    func testRefundOfAnUnconfirmedChargeMapsOnceWithoutOrigin() async throws {
        try await grantProduct()
        let purchasedAt = Date().addingTimeInterval(1), refundedAt = Date().addingTimeInterval(2)
        let charge = try revenueCatBody(transaction: "refund-unknown", eventID: "refund-unknown-charge",
                                        eventTimestamp: purchasedAt, purchasedAt: purchasedAt)
        let refund = try revenueCatBody(transaction: "refund-unknown", type: "CANCELLATION",
                                        eventID: "refund-unknown-refund", eventTimestamp: refundedAt,
                                        purchasedAt: purchasedAt, price: -14.99, cancellationReason: "CUSTOMER_SUPPORT")
        for body in [charge, refund, charge, refund] {
            let response = try await webhook(body)
            XCTAssertEqual(response.status, .ok, response.body.string)
        }
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let first = try await subscriptionCalls()
        XCTAssertEqual(first.map(\.0), ["subscription_refund"])
        XCTAssertNil(first.first?.1["purchaseOrigin"])
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.map(\.0).sorted(), ["subscription_payment", "subscription_refund"])
        XCTAssertEqual(calls.first { $0.0 == "subscription_payment" }?.1["purchaseOrigin"] as? String, "unknown_origin")
    }

    /// TRANSFER adds nothing, and a store transaction already in the ledger under another
    /// account (transfer, alias or restore onto a second Snaglist account) is recovered
    /// history for the second account: no second monetary product event.
    func testTransferAndCrossAccountAliasNeverBecomeASecondPaidEvent() async throws {
        try await grantProduct()
        let (second, secondToken) = try await makeUser("origin-alias")
        let secondID = try second.requireID(); others.append(secondID)
        try await grantProduct(token: secondToken, account: secondID)

        let transfer = try await webhook(transferBody(to: secondID))
        XCTAssertEqual(transfer.status, .badRequest, "TRANSFER carries no transaction fields and is refused as before")
        let purchasedAt = Date().addingTimeInterval(-3600)
        _ = try await webhook(revenueCatBody(transaction: "alias-shared", eventTimestamp: Date(), purchasedAt: purchasedAt))
        let aliased = try await webhook(revenueCatBody(transaction: "alias-shared", eventTimestamp: Date(),
                                                       purchasedAt: purchasedAt, appUserID: secondID))
        XCTAssertEqual(aliased.status, .ok)
        let totalCharges = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id IN (\(bind:userID),\(bind:secondID))")
            .first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(totalCharges, 1, "one charge in the ledger, owned by the first account")
        let secondAudit = try await count("measurement_revenuecat_lifecycle_events WHERE TRUE", secondID)
        XCTAssertEqual(secondAudit, 1, "the second delivery remains audit evidence")
        let secondJobs = try await count("measurement_dispatch_jobs WHERE destination='posthog'", secondID)
        XCTAssertEqual(secondJobs, 0, "recovered history from another account is never new money")
        try await elapseSettleWindow(); try await elapseSettleWindow(secondID)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "unknown_origin")
    }

    /// Duplicate deliveries and replays still yield one charge, one job and one event.
    func testDuplicateAndReplayDeliveriesStillProduceOneClassifiedEvent() async throws {
        try await grantProduct()
        let purchasedAt = Date().addingTimeInterval(1)
        let body = try revenueCatBody(transaction: "replayed", eventTimestamp: purchasedAt, purchasedAt: purchasedAt)
        let distinctEventID = try revenueCatBody(transaction: "replayed", eventTimestamp: purchasedAt, purchasedAt: purchasedAt)
        for delivery in [body, body, distinctEventID] {
            let response = try await webhook(delivery)
            XCTAssertEqual(response.status, .ok)
        }
        let charges = try await count("measurement_revenuecat_events WHERE TRUE")
        let jobs = try await count("measurement_dispatch_jobs WHERE destination='posthog'")
        XCTAssertEqual(charges, 1); XCTAssertEqual(jobs, 1)
        try await elapseSettleWindow()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let calls = try await subscriptionCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["purchaseOrigin"] as? String, "unknown_origin")
    }

    /// The product witness lives under product permission: withdrawal deletes it.
    func testProductWithdrawalDeletesTheProductWitness() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        _ = try await witnessProduct(intent, capability, transaction: "withdrawn-witness", purchaseDate: Date().addingTimeInterval(2))
        let withdrawn = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", token: jwt, object: [
            "requestId": UUID().uuidString, "decision": "withdrawn", "occurredAt": date(),
            "expectedRevision": revision.uuidString
        ])
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        let remaining = try await count("measurement_purchase_intents WHERE purpose='productAnalytics'")
        XCTAssertEqual(remaining, 0)
    }

    /// Only the exact accepted purchase callback can supply product evidence, on its own route,
    /// under current product permission and the product switch.
    func testProductWitnessRouteRefusesRestoreSourceOtherRoutesAndMissingPermission() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let restore = try await witnessProduct(intent, capability, transaction: "restore-source",
                                               purchaseDate: Date().addingTimeInterval(2), source: "restore")
        XCTAssertEqual(restore.status, .badRequest)
        try await enable("crossCompanyAdsEnabled")
        let crossRoute = try await witnessProduct(intent, capability, transaction: "wrong-route",
                                                  purchaseDate: Date().addingTimeInterval(2), path: "purchase-intents")
        XCTAssertEqual(crossRoute.status, .notFound, "a product capability cannot complete an advertising intent")
        let wrongRevision = try await prepareProduct(UUID())
        XCTAssertEqual(wrongRevision.0.status, .forbidden)
        try await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
        let off = try await prepareProduct(revision)
        XCTAssertEqual(off.0.status, .serviceUnavailable)
    }

    /// Account erasure removes product-purpose evidence with the rest of the account's intents.
    func testAccountErasureRemovesTheProductWitness() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        _ = try await witnessProduct(try XCTUnwrap(prepared.1), try XCTUnwrap(prepared.2),
                                     transaction: "erased-witness", purchaseDate: Date().addingTimeInterval(2))
        let deletionJob = UUID()
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:deletionJob),\(bind:userID),\(bind:SHA256Hasher.hash(token: "origin-deletion-\(deletionJob)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        try await app.db.transaction { tx in
            let txSQL = try VerifiedIdentityService.sql(tx)
            _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:self.userID) FOR UPDATE").first()
            try await MeasurementPrivacyService.eraseAccount(self.userID, accountDeletionJobID: deletionJob, now: Date(), on: tx)
        }
        let remaining = try await count("measurement_purchase_intents WHERE TRUE")
        XCTAssertEqual(remaining, 0)
        try await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_deletion_job_id=\(bind:deletionJob)").run()
        try await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind:deletionJob)").run()
    }

    /// Constraint-only and reversible: the revert removes only product-purpose evidence and
    /// restores the previous constraints; advertising purposes are untouched.
    func testProductPurposeMigrationIsConstraintOnlyAndReversible() async throws {
        let revision = try await grantProduct()
        let prepared = try await prepareProduct(revision)
        XCTAssertEqual(prepared.0.status, .created)
        try await AddProductPurchaseOriginPurpose().revert(on: app.db)
        let afterRevert = try await count("measurement_purchase_intents WHERE purpose='productAnalytics'")
        XCTAssertEqual(afterRevert, 0)
        let refused = try await prepareProduct(revision)
        XCTAssertNotEqual(refused.0.status, .created, "the previous constraints refuse the product purpose")
        try await AddProductPurchaseOriginPurpose().prepare(on: app.db)
        let again = try await prepareProduct(revision)
        XCTAssertEqual(again.0.status, .created)
        let checks = try await sql.raw("""
            SELECT count(*) AS n FROM pg_constraint WHERE conrelid='measurement_purchase_intents'::regclass
              AND contype='c' AND pg_get_constraintdef(oid) LIKE '%(purpose = ANY%'
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(checks, 1, "exactly one purpose check after a revert/prepare round trip")
    }
}

private actor OriginHTTPRecorder {
    struct Call: Sendable { let uri: String; let body: String }
    private var values: [Call] = []
    func record(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) -> MeasurementDispatchService.Reply {
        values.append(.init(uri: uri.string, body: String(decoding: body, as: UTF8.self)))
        return .init(status: 200, retryAfter: nil)
    }
    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, headers, body in await self.record(uri, headers, body) }
    }
    func calls() -> [Call] { values }
}
