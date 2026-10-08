@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class MeasurementPrivacyTests: XCTestCase {
    private var app: Application!
    private var user: User!
    private var jwt: String!
    private var userID: UUID { try! user.requireID() }
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        user = User(appleUserId: nil, email: "measurement-\(UUID().uuidString.lowercased())@example.test",
                    name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: userID,
            authVersion: user.authVersion, authenticatedAt: Date()))
    }

    override func tearDown() async throws {
        if let app {
            try? await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE charge_id IN (SELECT id FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)) OR attribution_record_id IN (SELECT id FROM ad_attribution_records WHERE canonical_account_id=\(bind:userID))").run()
            try? await sql.raw("DELETE FROM measurement_purchase_intents WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_purchase_acquisitions WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_revenuecat_adjustments WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_revenuecat_events WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_product_events WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_device_bindings WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM ad_attribution_records WHERE canonical_account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_att_assertions WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_permission_current WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind: userID)").run()
            try? await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:userID)").run()
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]).delete()
            try? await User.query(on: app.db).filter(\.$id == userID).delete()
            try await app.asyncShutdown()
        }
        app = nil; user = nil; jwt = nil
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

    private func put(_ purpose: String, requestID: UUID = UUID(), expected: UUID? = nil,
                     decision: String, occurredAt: Date = Date(), installationID: UUID? = nil,
                     attStatus: String? = nil, attAssertedAt: Date? = nil,
                     token: String? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = [
            "requestId": requestID.uuidString,
            "decision": decision,
            "occurredAt": date(occurredAt)
        ]
        if let expected { body["expectedRevision"] = expected.uuidString }
        if let installationID { body["installationId"] = installationID.uuidString }
        if let attStatus { body["attStatus"] = attStatus }
        if let attAssertedAt { body["attAssertedAt"] = date(attAssertedAt) }
        return try await request(.PUT, "api/v2/measurement/permissions/\(purpose)", token: token ?? jwt, object: body)
    }

    private func object(_ response: XCTHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    private func permission(_ purpose: String, in response: XCTHTTPResponse) throws -> [String: Any] {
        let values = try XCTUnwrap(try object(response)["permissions"] as? [[String: Any]])
        return try XCTUnwrap(values.first { $0["purpose"] as? String == purpose })
    }

    private func uuid(_ value: Any?) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value as? String)))
    }

    private func enable(_ key: String) async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key == key).delete()
        try await FeatureFlag(key: key, enabled: true).save(on: app.db)
    }

    private func configurePurchaseOrigin(_ environment: LinkedInConversion.Environment = .sandbox) async throws {
        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: environment)
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("crossCompanyAdsEnabled")
    }

    private func configureApplePurchaseOrigin(_ environment: LinkedInConversion.Environment = .sandbox) async throws {
        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: environment)
        app.storage[ApplePurchaseOriginService.CampaignConfigurationKey.self] = .init(
            organizationID: 40_669_820, campaignIDs: [542_370_539])
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("adMeasurementEnabled")
    }

    private func queueProductAnalyticsDispatch() async throws -> UUID {
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let event = try await request(.POST, "api/v2/measurement/events", token: jwt, object: [
            "eventId": UUID().uuidString, "occurredAt": date(Date().addingTimeInterval(1)),
            "consentRevision": revision.uuidString, "installationId": UUID().uuidString,
            "event": ["schemaVersion": 1, "name": "first_project_created", "properties": [:]]
        ])
        XCTAssertEqual(event.status, .accepted, event.body.string)
        return try await sql.raw("""
            SELECT subject_id FROM measurement_permission_current
            WHERE account_id=\(bind:userID) AND purpose='productAnalytics'
            """).first()!.decode(column: "subject_id", as: UUID.self)
    }

    private func createMeasurementDeletionJob() async throws -> UUID {
        let id = UUID(), receipt = SHA256Hasher.hash(token: "measurement-deletion-\(id.uuidString)")
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:id),\(bind:userID),\(bind:receipt),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        return id
    }

    private func grantPurchaseOrigin(_ installation: UUID = UUID()) async throws -> (UUID, UUID) {
        let response = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                     attStatus: "authorized", attAssertedAt: Date())
        XCTAssertEqual(response.status, .ok, response.body.string)
        return (installation, try uuid(try permission("crossCompanyAds", in: response)["revision"]))
    }

    private func preparePurchase(_ installation: UUID, _ revision: UUID,
                                 product: String = "com.snaglist.pro.monthly",
                                 token: String? = nil) async throws -> (XCTHTTPResponse, UUID?, String?) {
        let response = try await request(.POST, "api/v2/measurement/purchase-intents", token: token ?? jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString, "productId": product
        ])
        guard response.status == .created else { return (response, nil, nil) }
        let body = try object(response)
        return (response, try uuid(body["intentId"]), try XCTUnwrap(body["capability"] as? String))
    }

    private func witnessPurchase(_ intent: UUID, _ capability: String, transaction: String,
                                 product: String = "com.snaglist.pro.monthly", purchaseDate: Date,
                                 source: String = "purchaseCallback", token: String? = nil) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/purchase-intents/\(intent.uuidString)/witness",
                          token: token ?? jwt, object: [
            "capability": capability, "transactionId": transaction, "productId": product,
            "purchaseDate": date(purchaseDate), "source": source
        ])
    }

    private func grantApple() async throws -> UUID {
        let response = try await put("appleAds", decision: "granted")
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try uuid(try permission("appleAds", in: response)["revision"])
    }

    @discardableResult
    private func canonicalApple(_ installation: UUID, _ revision: UUID, evidence: String,
                                createdAt: Date = Date().addingTimeInterval(-10)) async throws -> UUID {
        let reference = try await AdAttributionStore.insertCanonicalProcessing(
            accountID: userID, installationID: installation, consentRevision: revision,
            appVersion: "2.0.2", now: createdAt, on: app.db)
        let row = try await sql.raw("SELECT id FROM ad_attribution_records WHERE reference=\(bind:reference)").first()!
        let id = try row.decode(column: "id", as: UUID.self)
        try await sql.raw("""
            UPDATE ad_attribution_records SET exchange_state='done',exchange_attempts=1,exchanged_at=\(bind:createdAt),
              attribution=\(bind:evidence != "organic"),
              campaign_id=\(bind:evidence == "verified" ? Int64(542_370_539) : nil),
              evidence_class=\(bind:evidence),evidence_config_hash=\(bind:evidence == "verified" ? app.storage[ApplePurchaseOriginService.CampaignConfigurationKey.self]?.provenanceHash : nil),
              evidence_classified_at=\(bind:createdAt) WHERE id=\(bind:id)
            """).run()
        return id
    }

    private func prepareApple(_ installation: UUID, _ revision: UUID) async throws -> (XCTHTTPResponse, UUID?, String?) {
        let response = try await request(.POST, "api/v2/measurement/apple/purchase-intents", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "productId": "com.snaglist.pro.monthly"
        ])
        guard response.status == .created else { return (response, nil, nil) }
        let body = try object(response)
        return (response, try uuid(body["intentId"]), try XCTUnwrap(body["capability"] as? String))
    }

    private func witnessApple(_ intent: UUID, _ capability: String, transaction: String,
                              purchaseDate: Date) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/measurement/apple/purchase-intents/\(intent.uuidString)/witness",
                          token: jwt, object: [
            "capability": capability, "transactionId": transaction,
            "productId": "com.snaglist.pro.monthly", "purchaseDate": date(purchaseDate),
            "source": "purchaseCallback"
        ])
    }

    private func revenueCatBody(transaction: String = "synthetic-transaction", type: String = "INITIAL_PURCHASE",
                                eventID: String = UUID().uuidString, eventTimestamp: Date = Date(),
                                purchasedAt: Date? = nil, price: Any? = 14.99,
                                currency: String = "GBP",
                                cancellationReason: String? = nil, expirationReason: String? = nil,
                                originalTransaction: String? = nil, appUserID: UUID? = nil) throws -> Data {
        let purchasedAt = purchasedAt ?? eventTimestamp.addingTimeInterval(1)
        var event: [String: Any] = [
            "id": eventID, "app_id": "synthetic-rc-app", "app_user_id": (appUserID ?? userID).uuidString,
            "type": type, "environment": "SANDBOX", "store": "APP_STORE", "period_type": "NORMAL",
            "is_family_share": false, "product_id": "com.snaglist.pro.monthly", "entitlement_ids": ["Snaglist Pro"],
            "event_timestamp_ms": Int64(eventTimestamp.timeIntervalSince1970 * 1000),
            "purchased_at_ms": Int64(purchasedAt.timeIntervalSince1970 * 1000),
            "expiration_at_ms": Int64(purchasedAt.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000),
            "price_in_purchased_currency": price ?? NSNull(), "currency": currency, "transaction_id": transaction,
            "original_transaction_id": originalTransaction ?? "original-\(transaction)",
            "subscriber_attributes": ["email": "must-never-be-stored@example.test"]
        ]
        if let cancellationReason { event["cancel_reason"] = cancellationReason }
        if let expirationReason { event["expiration_reason"] = expirationReason }
        return try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": event])
    }

    private func webhook(_ body: Data, authorization: String = "Bearer synthetic-webhook-secret") async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(.POST, "api/v2/measurement/webhooks/revenuecat", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .authorization, value: authorization)
            req.headers.contentType = .json
            req.body = .init(data: body)
        }, afterResponse: { answer = $0 })
        return answer
    }

    func testFlagsAreIndependentAndDefaultFalse() async throws {
        let expected = [
            ("productAnalyticsEnabled", "FEATURE_PRODUCT_ANALYTICS_ENABLED"),
            ("crossCompanyAdsEnabled", "FEATURE_CROSS_COMPANY_ADS_ENABLED"),
            ("linkedInConversionsEnabled", "FEATURE_LINKEDIN_CONVERSIONS_ENABLED")
        ]
        for (key, variable) in expected {
            let entry = try XCTUnwrap(FeatureFlagService.registry.first { $0.key == key })
            XCTAssertEqual(entry.envVar, variable)
            XCTAssertFalse(entry.hardDefault)
            XCTAssertEqual(FeatureFlagService.registry.filter { $0.key == key }.count, 1)
        }
        let resolved = try await FeatureFlagService.resolve(on: app.db) { _ in nil }
        for (key, _) in expected { XCTAssertEqual(resolved[key], false) }
    }

    func testRoutesRequireAnActiveAuthenticatedAccountAndReturnTheStableEnvelope() async throws {
        let missing = try await request(.GET, "api/v2/measurement/permissions")
        XCTAssertEqual(missing.status, .unauthorized)

        let response = try await request(.GET, "api/v2/measurement/permissions", token: jwt)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let root = try object(response)
        XCTAssertEqual(Set(root.keys), ["permissions"])
        let values = try XCTUnwrap(root["permissions"] as? [[String: Any]])
        XCTAssertEqual(values.compactMap { $0["purpose"] as? String }, ["productAnalytics", "appleAds", "crossCompanyAds"])
        for value in values {
            XCTAssertEqual(value["decision"] as? String, "undecided")
            XCTAssertEqual(value["effective"] as? Bool, false)
            XCTAssertNil(value["revision"])
            XCTAssertNil(value["subjectId"])
        }

        user.lifecycleState = "deleted"
        user.authVersion += 1
        try await user.save(on: app.db)
        let deleted = try await request(.GET, "api/v2/measurement/permissions", token: jwt)
        XCTAssertEqual(deleted.status, .unauthorized)
    }

    func testProductGrantUsesOptimisticRevisionAndExactIdempotentReplay() async throws {
        let requestID = UUID()
        let occurredAt = Date().addingTimeInterval(-2)
        let first = try await put("productAnalytics", requestID: requestID, decision: "granted", occurredAt: occurredAt)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let granted = try permission("productAnalytics", in: first)
        XCTAssertEqual(granted["decision"] as? String, "granted")
        XCTAssertEqual(granted["effective"] as? Bool, true)
        let revision = try uuid(granted["revision"])
        let subjectRow = try await sql.raw("SELECT id FROM measurement_subjects WHERE account_id=\(bind:userID) AND purpose='productAnalytics' AND state='active'").first()
        let subject = try XCTUnwrap(subjectRow?.decode(column: "id", as: UUID.self))
        XCTAssertNotEqual(revision, subject)

        let replay = try await put("productAnalytics", requestID: requestID, decision: "granted", occurredAt: occurredAt)
        XCTAssertEqual(replay.status, .ok, replay.body.string)
        XCTAssertEqual(try uuid(try permission("productAnalytics", in: replay)["revision"]), revision)

        let conflictingReplay = try await put("productAnalytics", requestID: requestID, decision: "denied", occurredAt: occurredAt)
        XCTAssertEqual(conflictingReplay.status, .conflict)
        let stale = try await put("productAnalytics", expected: UUID(), decision: "withdrawn")
        XCTAssertEqual(stale.status, .conflict)

        let denied = try await put("productAnalytics", expected: revision, decision: "denied")
        XCTAssertEqual(denied.status, .ok, denied.body.string)
        let deniedPermission = try permission("productAnalytics", in: denied)
        XCTAssertEqual(deniedPermission["decision"] as? String, "denied")
        XCTAssertEqual(deniedPermission["effective"] as? Bool, false)
        XCTAssertNil(deniedPermission["subjectId"])

        let staleGrant = try await put("productAnalytics", expected: revision, decision: "granted")
        XCTAssertEqual(staleGrant.status, .conflict, staleGrant.body.string)
        let active = try await sql.raw("SELECT count(*) AS n FROM measurement_subjects WHERE account_id=\(bind:userID) AND purpose='productAnalytics' AND state='active'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(active, 0)
    }

    func testClientTimesAreBoundedAndNeverBecomeGrantAuthority() async throws {
        let stale = try await put("productAnalytics", decision: "granted", occurredAt: Date().addingTimeInterval(-86_401))
        XCTAssertEqual(stale.status, .badRequest)
        let future = try await put("productAnalytics", decision: "granted", occurredAt: Date().addingTimeInterval(301))
        XCTAssertEqual(future.status, .badRequest)

        let accepted = try await put("productAnalytics", decision: "granted", occurredAt: Date().addingTimeInterval(-30))
        XCTAssertEqual(accepted.status, .ok, accepted.body.string)
        let consentRow = try await sql.raw("SELECT occurred_at,received_at FROM measurement_consent_events WHERE account_id=\(bind:userID)").first()
        let row = try XCTUnwrap(consentRow)
        let occurred = try row.decode(column: "occurred_at", as: Date.self)
        let received = try row.decode(column: "received_at", as: Date.self)
        XCTAssertGreaterThan(received.timeIntervalSince(occurred), 20)
        XCTAssertEqual(try permission("productAnalytics", in: accepted)["effective"] as? Bool, true,
                       "server receipt establishes the effective grant; the client time is audit evidence only")
    }

    func testCrossCompanyGrantNeedsAFreshPerInstallationATTAssertion() async throws {
        let installationA = UUID(), installationB = UUID()
        let missing = try await put("crossCompanyAds", decision: "granted")
        XCTAssertEqual(missing.status, .badRequest)
        let staleATT = try await put("crossCompanyAds", decision: "granted", installationID: installationA,
                                     attStatus: "authorized", attAssertedAt: Date().addingTimeInterval(-901))
        XCTAssertEqual(staleATT.status, .badRequest)
        let wrongPurpose = try await put("productAnalytics", decision: "granted", installationID: installationA,
                                         attStatus: "authorized", attAssertedAt: Date())
        XCTAssertEqual(wrongPurpose.status, .badRequest)

        let denied = try await put("crossCompanyAds", decision: "granted", installationID: installationA,
                                   attStatus: "denied", attAssertedAt: Date())
        XCTAssertEqual(denied.status, .ok, denied.body.string)
        var state = try permission("crossCompanyAds", in: denied)
        XCTAssertEqual(state["decision"] as? String, "granted")
        XCTAssertEqual(state["effective"] as? Bool, false)
        XCTAssertNil(state["subjectId"])
        let revision = try uuid(state["revision"])

        let allowed = try await put("crossCompanyAds", expected: revision, decision: "granted", installationID: installationB,
                                    attStatus: "authorized", attAssertedAt: Date())
        XCTAssertEqual(allowed.status, .ok, allowed.body.string)
        state = try permission("crossCompanyAds", in: allowed)
        XCTAssertEqual(state["effective"] as? Bool, true)
        XCTAssertNotNil(state["subjectId"])
        XCTAssertEqual(state["attStatus"] as? String, "authorized")
        let expiry = try XCTUnwrap(state["attExpiresAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: expiry))

        let assertions = try await sql.raw("SELECT installation_id,status,EXTRACT(EPOCH FROM (expires_at-received_at))::bigint AS lifetime FROM measurement_att_assertions WHERE account_id=\(bind:userID) ORDER BY installation_id").all()
        XCTAssertEqual(assertions.count, 2)
        for row in assertions {
            XCTAssertEqual(try row.decode(column: "lifetime", as: Int64.self), 86_400)
        }
    }

    func testWithdrawalAtomicallyRevokesSubjectAndQueuesDurableErasure() async throws {
        let grant = try await put("productAnalytics", decision: "granted")
        let granted = try permission("productAnalytics", in: grant)
        let revision = try uuid(granted["revision"])
        let subjectRow = try await sql.raw("SELECT id FROM measurement_subjects WHERE account_id=\(bind:userID) AND purpose='productAnalytics' AND state='active'").first()
        let subject = try XCTUnwrap(subjectRow?.decode(column: "id", as: UUID.self))

        let withdrawalRequest = UUID()
        let withdrawn = try await put("productAnalytics", requestID: withdrawalRequest, expected: revision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        let state = try permission("productAnalytics", in: withdrawn)
        XCTAssertEqual(state["decision"] as? String, "withdrawn")
        XCTAssertEqual(state["effective"] as? Bool, false)
        XCTAssertNil(state["subjectId"])
        XCTAssertEqual(state["erasurePending"] as? Bool, false,
                       "a subject never delivered to PostHog is erased locally without blocking")

        let revokedSubjectRow = try await sql.raw("SELECT state,revoked_at FROM measurement_subjects WHERE id=\(bind:subject)").first()
        let row = try XCTUnwrap(revokedSubjectRow)
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "revoked")
        XCTAssertNotNil(try row.decode(column: "revoked_at", as: Date?.self))
        let jobs = try await sql.raw("SELECT destination,state FROM measurement_erasure_jobs WHERE subject_id=\(bind:subject)").all()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(try jobs[0].decode(column: "destination", as: String.self), "posthog")
        XCTAssertEqual(try jobs[0].decode(column: "state", as: String.self), "completed")

        let replay = try await put("productAnalytics", requestID: withdrawalRequest, expected: revision, decision: "withdrawn")
        XCTAssertEqual(replay.status, .ok)
        let erasureCount = try await sql.raw("SELECT count(*) AS n FROM measurement_erasure_jobs WHERE subject_id=\(bind:subject)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(erasureCount, 1)

        let withdrawnRevision = try uuid(state["revision"])
        let regrant = try await put("productAnalytics", expected: withdrawnRevision, decision: "granted")
        XCTAssertEqual(regrant.status, .ok, regrant.body.string)
        let newSubjectRow = try await sql.raw("SELECT id FROM measurement_subjects WHERE account_id=\(bind:userID) AND purpose='productAnalytics' AND state='active'").first()
        let newSubject = try XCTUnwrap(newSubjectRow?.decode(column: "id", as: UUID.self))
        XCTAssertNotEqual(newSubject, subject)
    }

    func testRequestCannotMutateAnotherAccountAndInvalidVocabularyFailsClosed() async throws {
        let other = User(appleUserId: nil, email: "other-\(UUID())@example.test", name: nil, authProvider: .magicLink)
        try await other.save(on: app.db)

        let injected = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", token: jwt, object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date(), "accountId": try other.requireID().uuidString
        ])
        XCTAssertEqual(injected.status, .badRequest)
        let otherID = try other.requireID()
        let otherCount = try await sql.raw("SELECT count(*) AS n FROM measurement_permission_current WHERE account_id=\(bind: otherID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(otherCount, 0)

        for purpose in ["unknown", "ProductAnalytics", "cross-company-ads"] {
            let response = try await put(purpose, decision: "granted")
            XCTAssertEqual(response.status, .badRequest)
        }
        let invalidDecision = try await put("productAnalytics", decision: "allow")
        XCTAssertEqual(invalidDecision.status, .badRequest)
        try await other.delete(on: app.db)
    }

    func testMeasurementPrivacyFilesDoNotLogPayloadsOrIdentifiers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Measurement")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("logger."), file.lastPathComponent)
            XCTAssertNil(text.range(of: #"(^|[^A-Za-z0-9_.])print\("#, options: .regularExpression), file.lastPathComponent)
        }
    }

    func testFreshATTObservationIsRevisionAndInstallationBoundAndGETDoesNotRenewIt() async throws {
        let installation = UUID()
        let grant = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                  attStatus: "authorized", attAssertedAt: Date().addingTimeInterval(-10))
        let revision = try uuid(try permission("crossCompanyAds", in: grant)["revision"])
        let deniedAt = Date()
        let denied = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "attStatus": "denied", "observedAt": date(deniedAt)
        ])
        XCTAssertEqual(denied.status, .ok, denied.body.string)
        XCTAssertEqual(try permission("crossCompanyAds", in: denied)["effective"] as? Bool, false)
        let beforeRow = try await sql.raw("SELECT expires_at FROM measurement_att_assertions WHERE account_id=\(bind:userID) AND installation_id=\(bind:installation)").first()
        let before = try XCTUnwrap(beforeRow?.decode(column: "expires_at", as: Date.self))

        let stale = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "attStatus": "authorized", "observedAt": date(deniedAt.addingTimeInterval(-5))
        ])
        XCTAssertEqual(stale.status, .conflict)
        let read = try await request(.GET, "api/v2/measurement/permissions", token: jwt)
        XCTAssertEqual(read.status, .ok)
        let afterRow = try await sql.raw("SELECT expires_at FROM measurement_att_assertions WHERE account_id=\(bind:userID) AND installation_id=\(bind:installation)").first()
        let after = try XCTUnwrap(afterRow?.decode(column: "expires_at", as: Date.self))
        XCTAssertEqual(before, after, "reading permissions must not renew an ATT observation")

        let wrongInstallation = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": UUID().uuidString, "consentRevision": UUID().uuidString,
            "attStatus": "authorized", "observedAt": date()
        ])
        XCTAssertEqual(wrongInstallation.status, .conflict)
    }

    func testFreshAuthorizedObservationActivatesAPreviouslyDeniedGrant() async throws {
        let installation = UUID()
        let denied = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                   attStatus: "denied", attAssertedAt: Date().addingTimeInterval(-2))
        let revision = try uuid(try permission("crossCompanyAds", in: denied)["revision"])
        XCTAssertNil(try permission("crossCompanyAds", in: denied)["subjectId"])
        let authorized = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "attStatus": "authorized", "observedAt": date()
        ])
        XCTAssertEqual(authorized.status, .ok)
        let state = try permission("crossCompanyAds", in: authorized)
        XCTAssertEqual(state["effective"] as? Bool, true)
        XCTAssertNotNil(state["subjectId"])
    }

    func testOfflineWithdrawalOlderThanOneDayIsAcceptedAndExactlyReplayable() async throws {
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let requestID = UUID(), occurred = Date().addingTimeInterval(-2 * 86_400)
        let first = try await put("productAnalytics", requestID: requestID, expected: revision,
                                  decision: "withdrawn", occurredAt: occurred)
        let replay = try await put("productAnalytics", requestID: requestID, expected: revision,
                                   decision: "withdrawn", occurredAt: occurred)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(replay.status, .ok)
        XCTAssertEqual(try uuid(try permission("productAnalytics", in: first)["revision"]),
                       try uuid(try permission("productAnalytics", in: replay)["revision"]))
    }

    func testSingularDeviceBindingRequiresEffectivePermissionAndEncryptsTheIdentifier() async throws {
        try await enable("crossCompanyAdsEnabled")
        let installation = UUID(), deviceID = "synthetic-sdid-a"
        let grant = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                  attStatus: "authorized", attAssertedAt: Date())
        let revision = try uuid(try permission("crossCompanyAds", in: grant)["revision"])
        let bound = try await request(.POST, "api/v2/measurement/devices", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString, "singularDeviceId": deviceID
        ])
        XCTAssertEqual(bound.status, .noContent, bound.body.string)
        let storedBinding = try await sql.raw("SELECT singular_device_id_ciphertext,singular_device_id_hash FROM measurement_device_bindings WHERE account_id=\(bind:userID)").first()
        let row = try XCTUnwrap(storedBinding)
        let ciphertext = try row.decode(column: "singular_device_id_ciphertext", as: String.self)
        XCTAssertFalse(ciphertext.contains(deviceID))
        XCTAssertEqual(try row.decode(column: "singular_device_id_hash", as: String.self), SHA256Hasher.hash(token: deviceID))

        let denied = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "attStatus": "denied", "observedAt": date(Date().addingTimeInterval(1))
        ])
        XCTAssertEqual(denied.status, .ok)
        let refused = try await request(.POST, "api/v2/measurement/devices", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString, "singularDeviceId": "synthetic-sdid-b"
        ])
        XCTAssertEqual(refused.status, .forbidden)
    }

    func testProductEventIsAllowlistedExactlyDeduplicatedAndSuppressedOnWithdrawal() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let eventID = UUID(), installation = UUID(), occurred = Date().addingTimeInterval(1)
        let body: [String: Any] = [
            "eventId": eventID.uuidString, "occurredAt": date(occurred), "consentRevision": revision.uuidString,
            "installationId": installation.uuidString,
            "event": ["schemaVersion": 1, "name": "onboarding_screen_duration",
                      "properties": ["screen_index": "1", "duration_seconds": "12.3"]]
        ]
        let first = try await request(.POST, "api/v2/measurement/events", token: jwt, object: body)
        XCTAssertEqual(first.status, .accepted, first.body.string)
        let replay = try await request(.POST, "api/v2/measurement/events", token: jwt, object: body)
        XCTAssertEqual(replay.status, .accepted)
        var changed = body; changed["occurredAt"] = date(occurred.addingTimeInterval(1))
        let conflict = try await request(.POST, "api/v2/measurement/events", token: jwt, object: changed)
        XCTAssertEqual(conflict.status, .conflict)
        var invalid = body
        invalid["eventId"] = UUID().uuidString
        invalid["event"] = ["schemaVersion": 1, "name": "onboarding_screen_duration",
                            "properties": ["screen_index": "1", "duration_seconds": "12.30"]]
        let invalidResponse = try await request(.POST, "api/v2/measurement/events", token: jwt, object: invalid)
        XCTAssertEqual(invalidResponse.status, .badRequest)
        var session = body
        session["eventId"] = UUID().uuidString
        session["event"] = ["schemaVersion": 1, "name": "session_started", "properties": [:]]
        let acceptedSession = try await request(.POST, "api/v2/measurement/events", token: jwt, object: session)
        XCTAssertEqual(acceptedSession.status, .accepted)
        session["eventId"] = UUID().uuidString
        session["event"] = ["schemaVersion": 1, "name": "session_started", "properties": ["source": "foreground"]]
        let invalidSession = try await request(.POST, "api/v2/measurement/events", token: jwt, object: session)
        XCTAssertEqual(invalidSession.status, .badRequest)
        session["eventId"] = UUID().uuidString
        session["event"] = ["schemaVersion": 1, "name": "completion_submitted", "properties": [:]]
        let clientOutcome = try await request(.POST, "api/v2/measurement/events", token: jwt, object: session)
        XCTAssertEqual(clientOutcome.status, .badRequest,
                       "server-authoritative outcomes cannot be uploaded by a client")
        let dispatchCount = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(dispatchCount, 2)

        let withdrawn = try await put("productAnalytics", expected: revision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok)
        let storedJob = try await sql.raw("SELECT state,payload FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()
        let job = try XCTUnwrap(storedJob)
        XCTAssertEqual(try job.decode(column: "state", as: String.self), "suppressed")
        XCTAssertNil(try job.decode(column: "payload", as: String?.self))
        let storedEvent = try await sql.raw("SELECT event_name,properties,revoked_at FROM measurement_product_events WHERE account_id=\(bind:userID)").first()
        let event = try XCTUnwrap(storedEvent)
        XCTAssertNil(try event.decode(column: "event_name", as: String?.self))
        XCTAssertNotNil(try event.decode(column: "revoked_at", as: Date?.self))
    }

    func testServerOutcomeCandidateCannotSurviveWithdrawalOrSubjectRotation() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let occurredAt = Date().addingTimeInterval(1)
        let candidate = try await app.db.transaction { db in
            await MeasurementRelayService.outcomeCandidate(
                accountID: self.userID, operationID: UUID(), installationID: UUID(),
                event: .completionSubmitted, occurredAt: occurredAt, on: db)
        }
        XCTAssertNotNil(candidate)

        let withdrawn = try await put("productAnalytics", expected: revision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        await MeasurementRelayService.recordOutcome(
            try XCTUnwrap(candidate), app: app, logger: app.logger, on: app.db)
        let count = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_product_events
            WHERE account_id=\(bind:userID) AND event_name='completion_submitted'
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 0)
    }

    func testServerOutcomeCandidateSkipsBusyPrivacyBarrier() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        XCTAssertEqual(grant.status, .ok)
        let barrier = MeasurementTransactionGate()
        let key = "measurement-permission:\(userID.uuidString):productAnalytics"
        let blocker = Task {
            try await self.app.db.transaction { db in
                try await VerifiedIdentityService.lock(key, on: db)
                await barrier.hold()
            }
        }
        await barrier.waitUntilHeld()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await barrier.release()
        }
        let clock = ContinuousClock(), started = clock.now
        let candidate = try await app.db.transaction { db in
            await MeasurementRelayService.outcomeCandidate(
                accountID: self.userID, operationID: UUID(), installationID: UUID(),
                event: .reportIssued, occurredAt: Date().addingTimeInterval(1), on: db)
        }
        let elapsed = started.duration(to: clock.now)
        await barrier.release()
        _ = await watchdog.result
        try await blocker.value
        XCTAssertNil(candidate)
        XCTAssertLessThan(elapsed, .milliseconds(500), "optional measurement must not wait for the provider/privacy barrier")
    }

    func testServerOutcomePostcommitRecorderSkipsBusyPrivacyBarrier() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        XCTAssertEqual(grant.status, .ok)
        let candidate = try await app.db.transaction { db in
            await MeasurementRelayService.outcomeCandidate(
                accountID: self.userID, operationID: UUID(), installationID: UUID(),
                event: .reportIssued, occurredAt: Date().addingTimeInterval(1), on: db)
        }
        let barrier = MeasurementTransactionGate()
        let key = "measurement-permission:\(userID.uuidString):productAnalytics"
        let blocker = Task {
            try await self.app.db.transaction { db in
                try await VerifiedIdentityService.lock(key, on: db)
                await barrier.hold()
            }
        }
        await barrier.waitUntilHeld()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await barrier.release()
        }
        let clock = ContinuousClock(), started = clock.now
        await MeasurementRelayService.recordOutcome(
            try XCTUnwrap(candidate), app: app, logger: app.logger, on: app.db)
        let elapsed = started.duration(to: clock.now)
        await barrier.release()
        watchdog.cancel(); _ = await watchdog.result
        try await blocker.value
        XCTAssertLessThan(elapsed, .milliseconds(500), "postcommit measurement must not delay the product response")
        let count = try await sql.raw("SELECT count(*) AS n FROM measurement_product_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 0)
    }

    func testServerOutcomeCandidateSQLFailureRollsBackOnlyItsSavepoint() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        XCTAssertEqual(grant.status, .ok)
        let marker = "synthetic-outcome-savepoint-\(UUID().uuidString.lowercased())"
        try await app.db.transaction { db in
            let transactionSQL = try VerifiedIdentityService.sql(db)
            try await transactionSQL.raw("INSERT INTO feature_flags(id,key,enabled) VALUES(\(bind:UUID()),\(bind:marker),true)").run()
            try await transactionSQL.raw("ALTER TABLE measurement_permission_current RENAME TO measurement_permission_current_hidden").run()
            let candidate = await MeasurementRelayService.outcomeCandidate(
                accountID: self.userID, operationID: UUID(), installationID: UUID(),
                event: .completionAccepted, occurredAt: Date().addingTimeInterval(1), on: db)
            XCTAssertNil(candidate)
            try await transactionSQL.raw("ALTER TABLE measurement_permission_current_hidden RENAME TO measurement_permission_current").run()
        }
        let persisted = try await sql.raw("SELECT enabled FROM feature_flags WHERE key=\(bind:marker)").first()
        XCTAssertEqual(try persisted?.decode(column: "enabled", as: Bool.self), true)
        try await sql.raw("DELETE FROM feature_flags WHERE key=\(bind:marker)").run()
    }

    func testSameClientEventUUIDFromTwoAccountsCreatesTwoAccountScopedDeliveries() async throws {
        try await enable("productAnalyticsEnabled")
        let firstGrant = try await put("productAnalytics", decision: "granted")
        let firstRevision = try uuid(try permission("productAnalytics", in: firstGrant)["revision"])
        let other = User(appleUserId: nil, email: "measurement-other-\(UUID())@example.test",
                         name: nil, authProvider: .magicLink)
        try await other.save(on: app.db)
        let otherID = try other.requireID()
        let otherJWT = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: otherID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: otherID,
            authVersion: other.authVersion, authenticatedAt: Date()))
        let secondGrant = try await put("productAnalytics", decision: "granted", token: otherJWT)
        let secondRevision = try uuid(try permission("productAnalytics", in: secondGrant)["revision"])
        let eventID = UUID(), occurred = Date().addingTimeInterval(1), installation = UUID()
        func body(_ revision: UUID) -> [String: Any] { [
            "eventId": eventID.uuidString, "occurredAt": date(occurred),
            "consentRevision": revision.uuidString, "installationId": installation.uuidString,
            "event": ["schemaVersion": 1, "name": "project_created",
                      "properties": ["creation_source": "fresh", "workspace_kind": "personal"]]
        ] }
        let first = try await request(.POST, "api/v2/measurement/events", token: jwt, object: body(firstRevision))
        let second = try await request(.POST, "api/v2/measurement/events", token: otherJWT, object: body(secondRevision))
        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(second.status, .accepted)
        let count = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE source_id=\(bind:eventID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 2)
        try await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE account_id=\(bind:otherID)").run()
        try await sql.raw("DELETE FROM measurement_product_events WHERE account_id=\(bind:otherID)").run()
        try await sql.raw("DELETE FROM measurement_permission_current WHERE account_id=\(bind:otherID)").run()
        try await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind:otherID)").run()
        try await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:otherID)").run()
        try await other.delete(on: app.db)
    }

    func testAuthenticatedAppleUsesCanonicalAccountAndNeverPersistsTheToken() async throws {
        try await enable("adMeasurementEnabled")
        let grant = try await put("appleAds", decision: "granted")
        let revision = try uuid(try permission("appleAds", in: grant)["revision"])
        let installation = UUID(), rawToken = Data("synthetic-canonical-token".utf8).base64EncodedString()
        let stub = AppleStub()
        await stub.reset([.success(AppleStub.reply(.ok, AppleStub.attributed))])
        app.storage[AppleAttributionExchangeService.TransportKey.self] = stub.transport
        app.storage[AppleAttributionExchangeService.SleepKey.self] = stub.sleeper
        let body: [String: Any] = ["token": rawToken, "installationId": installation.uuidString,
                                  "consentRevision": revision.uuidString, "appVersion": "2.0.2"]
        let first = try await request(.POST, "api/v2/measurement/apple", token: jwt, object: body)
        XCTAssertEqual(first.status, .created, first.body.string)
        let reference = try XCTUnwrap(try object(first)["reference"] as? String)
        let storedApple = try await sql.raw("""
            SELECT token,canonical_account_id,canonical_installation_id,canonical_consent_revision,rc_app_user_id,exchange_state
            FROM ad_attribution_records WHERE reference=\(bind:reference)
            """).first()
        let row = try XCTUnwrap(storedApple)
        XCTAssertNil(try row.decode(column: "token", as: String?.self))
        XCTAssertEqual(try row.decode(column: "canonical_account_id", as: UUID.self), userID)
        XCTAssertEqual(try row.decode(column: "canonical_installation_id", as: UUID.self), installation)
        XCTAssertEqual(try row.decode(column: "canonical_consent_revision", as: UUID.self), revision)
        XCTAssertEqual(try row.decode(column: "rc_app_user_id", as: String.self), userID.uuidString)
        XCTAssertEqual(try row.decode(column: "exchange_state", as: String.self), "done")
        let replay = try await request(.POST, "api/v2/measurement/apple", token: jwt, object: body)
        XCTAssertEqual(replay.status, .created)
        XCTAssertEqual(try object(replay)["reference"] as? String, reference)
        let callCount = await stub.calls().count
        XCTAssertEqual(callCount, 1)

        let legacy = try await AdAttributionStore.insert(.init(token: rawToken, rcAppUserID: userID.uuidString, appVersion: "2.0.2"), now: Date(), on: app.db)
        let storedLegacy = try await sql.raw("SELECT canonical_account_id FROM ad_attribution_records WHERE reference=\(bind:legacy)").first()
        let legacyRow = try XCTUnwrap(storedLegacy)
        XCTAssertNil(try legacyRow.decode(column: "canonical_account_id", as: UUID?.self), "v1 records are never canonical joins")
    }

    func testRevenueCatWebhookAuthenticatesDeduplicatesAndDispatchesOnlyOpaqueProviderPayloads() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: "https://singular.invalid/event",
            singularAPIKey: "singular_synthetic", linkedInAccessToken: "linkedin_synthetic",
            linkedInSignupRule: "101", linkedInSubscriptionRule: "102", linkedInEnvironment: .sandbox)
        let recorder = MeasurementHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        for flag in ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled"] { try await enable(flag) }
        try await sql.raw("""
            INSERT INTO user_identities(id,user_id,provider,subject,verified_at)
            VALUES (\(bind:UUID()),\(bind:userID),'email',\(bind:"measurement-verified@example.test"),NOW())
            """).run()
        _ = try await put("productAnalytics", decision: "granted")
        let installation = UUID()
        let cross = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                  attStatus: "authorized", attAssertedAt: Date())
        let revision = try uuid(try permission("crossCompanyAds", in: cross)["revision"])
        let bound = try await request(.POST, "api/v2/measurement/devices", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "singularDeviceId": "synthetic-sdid-webhook"
        ])
        XCTAssertEqual(bound.status, .noContent)

        let body = try revenueCatBody()
        let refused = try await webhook(body, authorization: "Bearer wrong")
        let accepted = try await webhook(body)
        let replay = try await webhook(body)
        XCTAssertEqual(refused.status, .unauthorized)
        XCTAssertEqual(accepted.status, .ok)
        XCTAssertEqual(replay.status, .ok)
        let sourceCount = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        let lifecycleJobCount = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(sourceCount, 1)
        XCTAssertEqual(lifecycleJobCount, 1, "RevenueCat has no authoritative originating installation, so ad relays are suppressed")
        let durableText = try await sql.raw("SELECT row_to_json(e)::text AS body FROM measurement_revenuecat_events e WHERE account_id=\(bind:userID)").first()!.decode(column: "body", as: String.self)
        XCTAssertFalse(durableText.contains("synthetic-transaction"))
        XCTAssertFalse(durableText.contains("must-never-be-stored"))

        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 1)
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.contains { $0.uri == "https://eu.i.posthog.com/capture/" })
        for call in calls {
            XCTAssertFalse(call.body.contains(userID.uuidString))
            XCTAssertFalse(call.body.contains(userID.uuidString.lowercased()))
            XCTAssertFalse(call.body.contains("must-never-be-stored"))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
            XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(object["timestamp"] as? String)))
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(object["uuid"] as? String)))
        }
    }

    func testRevenueCatDoesNotBorrowATTFromAnUnprovenOriginatingInstallation() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        for flag in ["crossCompanyAdsEnabled", "linkedInConversionsEnabled"] { try await enable(flag) }
        let installation = UUID()
        let grant = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                  attStatus: "authorized", attAssertedAt: Date())
        let revision = try uuid(try permission("crossCompanyAds", in: grant)["revision"])
        let bound = try await request(.POST, "api/v2/measurement/devices", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "singularDeviceId": "synthetic-sdid-expired-att"
        ])
        XCTAssertEqual(bound.status, .noContent)
        let accepted = try await webhook(revenueCatBody(transaction: "expired-att"))
        XCTAssertEqual(accepted.status, .ok)
        let jobs = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(jobs, 0)
    }

    func testRevenueCatRenewalUsesProviderEventTimeWhenTheBillingPeriodStartsLater() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")
        let eventTimestamp = Date().addingTimeInterval(1)
        let futurePeriodStart = eventTimestamp.addingTimeInterval(23 * 3_600)
        let response = try await webhook(revenueCatBody(transaction: "early-renewal-charge", type: "RENEWAL",
            eventTimestamp: eventTimestamp, purchasedAt: futurePeriodStart))
        XCTAssertEqual(response.status, .ok, response.body.string)
        let storedRow = try await sql.raw("""
            SELECT occurred_at,purchased_at FROM measurement_revenuecat_events
            WHERE account_id=\(bind:userID) AND event_kind='subscription_payment'
            """).first()
        let row = try XCTUnwrap(storedRow)
        let storedOccurrence = try row.decode(column: "occurred_at", as: Date.self)
        XCTAssertEqual(storedOccurrence.timeIntervalSince1970, eventTimestamp.timeIntervalSince1970,
                       accuracy: 0.002, "delivery uses RevenueCat's event-generation time, not the future period start")
        let storedPeriodStart = try row.decode(column: "purchased_at", as: Date.self)
        XCTAssertEqual(storedPeriodStart.timeIntervalSince1970, futurePeriodStart.timeIntervalSince1970,
                       accuracy: 0.002)

        let implausible = try await webhook(revenueCatBody(transaction: "too-early-renewal-charge", type: "RENEWAL",
            eventTimestamp: eventTimestamp, purchasedAt: eventTimestamp.addingTimeInterval(86_401)))
        XCTAssertEqual(implausible.status, .badRequest)
    }

    func testRevenueCatEventGeneratedAfterConsentCannotAuthoriseAnEarlierPurchase() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        let purchasedAt = Date().addingTimeInterval(-60)
        _ = try await put("productAnalytics", decision: "granted")
        let eventTimestamp = Date().addingTimeInterval(1)
        let response = try await webhook(revenueCatBody(transaction: "pre-consent-renewal", type: "RENEWAL",
            eventTimestamp: eventTimestamp, purchasedAt: purchasedAt))
        XCTAssertEqual(response.status, .ok)
        let sources = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        let jobs = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(sources, 1, "the authenticated provider fact remains deduplicated audit evidence")
        XCTAssertEqual(jobs, 0, "a later consent grant cannot authorise an earlier purchase")
    }

    func testRevenueCatProviderEventDedupIsSeparateFromGlobalChargeDedup() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")
        let eventID = UUID().uuidString
        let eventAt = Date().addingTimeInterval(1), purchasedAt = eventAt
        let first = try await webhook(revenueCatBody(transaction: "one-charge-many-deliveries", eventID: eventID,
            eventTimestamp: eventAt, purchasedAt: purchasedAt))
        let identicalChargeNewEvent = try await webhook(revenueCatBody(transaction: "one-charge-many-deliveries",
            eventTimestamp: eventAt, purchasedAt: purchasedAt))
        let conflictingEventReplay = try await webhook(revenueCatBody(transaction: "one-charge-many-deliveries",
            type: "RENEWAL", eventID: eventID, eventTimestamp: eventAt, purchasedAt: purchasedAt))
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(identicalChargeNewEvent.status, .ok)
        XCTAssertEqual(conflictingEventReplay.status, .ok, "durably quarantined provider conflicts must not trigger endless retries")
        let providerEvents = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        let charges = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(providerEvents, 2)
        XCTAssertEqual(charges, 1, "multiple provider deliveries cannot create a second monetary charge")
        let conflicted = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:userID) AND resolution='unresolved' AND conflict_hash IS NOT NULL").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(conflicted, 1)
        let dispatchRow = try await sql.raw("SELECT state,payload::text AS payload_text FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()
        let dispatch = try XCTUnwrap(dispatchRow)
        XCTAssertEqual(try dispatch.decode(column: "state", as: String.self), "suppressed")
        XCTAssertNil(try dispatch.decode(column: "payload_text", as: String?.self))
    }

    func testRevenueCatRefundBeforeChargeAndExactReversalReconcileWithoutDuplicateRevenue() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        let transaction = "refund-before-charge", purchasedAt = Date().addingTimeInterval(-120)
        let refund = try await webhook(revenueCatBody(transaction: transaction, type: "CANCELLATION",
            eventTimestamp: Date(), purchasedAt: purchasedAt, price: -14.99, cancellationReason: "CUSTOMER_SUPPORT"))
        XCTAssertEqual(refund.status, .ok)
        var adjustmentRow = try await sql.raw("SELECT state FROM measurement_revenuecat_adjustments WHERE account_id=\(bind:userID)").first()
        var adjustment = try XCTUnwrap(adjustmentRow)
        XCTAssertEqual(try adjustment.decode(column: "state", as: String.self), "pending_charge")

        let charge = try await webhook(revenueCatBody(transaction: transaction, eventTimestamp: Date().addingTimeInterval(1),
            purchasedAt: purchasedAt, price: 14.99))
        XCTAssertEqual(charge.status, .ok)
        adjustmentRow = try await sql.raw("SELECT state FROM measurement_revenuecat_adjustments WHERE account_id=\(bind:userID)").first()
        adjustment = try XCTUnwrap(adjustmentRow)
        XCTAssertEqual(try adjustment.decode(column: "state", as: String.self), "refunded")

        let reversal = try await webhook(revenueCatBody(transaction: transaction, type: "REFUND_REVERSED",
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: purchasedAt, price: 14.99))
        XCTAssertEqual(reversal.status, .ok)
        adjustmentRow = try await sql.raw("SELECT state,refund_amount,reversal_amount FROM measurement_revenuecat_adjustments WHERE account_id=\(bind:userID)").first()
        adjustment = try XCTUnwrap(adjustmentRow)
        XCTAssertEqual(try adjustment.decode(column: "state", as: String.self), "reversed")
        XCTAssertEqual(try adjustment.decode(column: "refund_amount", as: String.self), "-14.99")
        XCTAssertEqual(try adjustment.decode(column: "reversal_amount", as: String.self), "14.99")
        let charges = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(charges, 1, "a refund reversal is an adjustment, never a second purchase")
    }

    func testRevenueCatNoticesAndAmbiguousRefundRemainNonMonetaryOrUnresolved() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        let purchasedAt = Date().addingTimeInterval(-120)
        let cancellation = try await webhook(revenueCatBody(transaction: "notice-cancellation", type: "CANCELLATION",
            purchasedAt: purchasedAt, price: 14.99, cancellationReason: "UNSUBSCRIBE"))
        let expiration = try await webhook(revenueCatBody(transaction: "notice-expiration", type: "EXPIRATION",
            purchasedAt: purchasedAt, price: 0, expirationReason: "UNSUBSCRIBE"))
        let ambiguousRefund = try await webhook(revenueCatBody(transaction: "ambiguous-refund", type: "CANCELLATION",
            purchasedAt: purchasedAt, price: nil, cancellationReason: "CUSTOMER_SUPPORT"))
        XCTAssertEqual(cancellation.status, .ok)
        XCTAssertEqual(expiration.status, .ok)
        XCTAssertEqual(ambiguousRefund.status, .ok)
        let rows = try await sql.raw("SELECT effect,resolution,monetary_delta FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:userID)").all()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(try rows.contains { try $0.decode(column: "effect", as: String.self) == "cancellation_notice" && $0.decode(column: "monetary_delta", as: String?.self) == nil })
        XCTAssertTrue(try rows.contains { try $0.decode(column: "effect", as: String.self) == "expiration_notice" && $0.decode(column: "monetary_delta", as: String?.self) == nil })
        XCTAssertTrue(try rows.contains { try $0.decode(column: "effect", as: String.self) == "unresolved" && $0.decode(column: "resolution", as: String.self) == "unresolved" })
        let charges = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(charges, 0)
    }

    func testRevenueCatResolvedRefundRelaysOnlyToPostHogWithStableNormalizedFacts() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: "https://singular.invalid/event", singularAPIKey: "singular_synthetic",
            linkedInAccessToken: "linkedin_synthetic", linkedInSignupRule: "101",
            linkedInSubscriptionRule: "102", linkedInEnvironment: .sandbox)
        let recorder = MeasurementHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        for flag in ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled"] { try await enable(flag) }
        _ = try await put("productAnalytics", decision: "granted")
        let transaction = "posthog-refund-only", purchasedAt = Date().addingTimeInterval(1)
        let charge = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: purchasedAt))
        let refund = try await webhook(revenueCatBody(transaction: transaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: purchasedAt, price: -14.99,
            cancellationReason: "CUSTOMER_SUPPORT"))
        XCTAssertEqual(charge.status, .ok)
        XCTAssertEqual(refund.status, .ok)
        let destinations = try await sql.raw("SELECT destination FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) ORDER BY created_at").all()
        XCTAssertEqual(try destinations.map { try $0.decode(column: "destination", as: String.self) }, ["posthog", "posthog"])
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 2)
        let calls = await recorder.calls()
        let events = try calls.map { call -> String in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
            return try XCTUnwrap(body["event"] as? String)
        }
        XCTAssertEqual(Set(events), ["subscription_payment", "subscription_refund"])
        let refundCall = try XCTUnwrap(calls.first { $0.body.contains("subscription_refund") })
        XCTAssertTrue(refundCall.body.contains("-14.99"))
    }

    func testRevenueCatDuplicateRefundProviderIDsProduceOneEconomicDelivery() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")
        let transaction = "duplicate-refund-provider-ids", purchasedAt = Date().addingTimeInterval(1)
        _ = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: purchasedAt))
        _ = try await webhook(revenueCatBody(transaction: transaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: purchasedAt, price: -14.99,
            cancellationReason: "CUSTOMER_SUPPORT"))
        _ = try await webhook(revenueCatBody(transaction: transaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(4), purchasedAt: purchasedAt, price: -14.99,
            cancellationReason: "CUSTOMER_SUPPORT"))

        let providerRefunds = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_lifecycle_events
            WHERE account_id=\(bind:userID) AND effect='refund'
            """).first()!.decode(column: "n", as: Int.self)
        let refundJobs = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:userID) AND source_kind='revenueCatEvent'
              AND payload->>'event'='subscription_refund'
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(providerRefunds, 2, "both authenticated provider deliveries remain audit evidence")
        XCTAssertEqual(refundJobs, 1, "one economic refund may have only one canonical outbound fact")
    }

    func testRevenueCatRefundMustMatchChargeCurrencyAndAmountAndConflictStaysQuarantined() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")

        let currencyTransaction = "refund-currency-conflict", currencyPurchase = Date().addingTimeInterval(1)
        _ = try await webhook(revenueCatBody(transaction: currencyTransaction,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: currencyPurchase))
        _ = try await webhook(revenueCatBody(transaction: currencyTransaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: currencyPurchase, price: -14.99,
            currency: "USD", cancellationReason: "CUSTOMER_SUPPORT"))

        let amountTransaction = "refund-amount-conflict", amountPurchase = Date().addingTimeInterval(4)
        _ = try await webhook(revenueCatBody(transaction: amountTransaction,
            eventTimestamp: Date().addingTimeInterval(5), purchasedAt: amountPurchase))
        _ = try await webhook(revenueCatBody(transaction: amountTransaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(6), purchasedAt: amountPurchase, price: -10.00,
            cancellationReason: "CUSTOMER_SUPPORT"))
        _ = try await webhook(revenueCatBody(transaction: amountTransaction, type: "REFUND_REVERSED",
            eventTimestamp: Date().addingTimeInterval(7), purchasedAt: amountPurchase, price: 10.00))

        let unresolved = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_adjustments
            WHERE account_id=\(bind:userID) AND state='unresolved'
            """).first()!.decode(column: "n", as: Int.self)
        let conflicts = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_lifecycle_events
            WHERE account_id=\(bind:userID) AND conflict_hash IS NOT NULL AND resolution='unresolved'
            """).first()!.decode(column: "n", as: Int.self)
        let adjustmentJobs = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:userID) AND source_kind='revenueCatEvent'
              AND state IN ('pending','failing','leased')
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(unresolved, 2)
        XCTAssertGreaterThanOrEqual(conflicts, 2)
        XCTAssertEqual(adjustmentJobs, 0, "a later event cannot reactivate quarantined money")
    }

    func testRevenueCatReversalBeforeRefundEnqueuesBothReconciledCanonicalFacts() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")
        let transaction = "reversal-before-refund", purchasedAt = Date().addingTimeInterval(1)
        _ = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: purchasedAt))
        _ = try await webhook(revenueCatBody(transaction: transaction, type: "REFUND_REVERSED",
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: purchasedAt, price: 14.99))
        _ = try await webhook(revenueCatBody(transaction: transaction, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(4), purchasedAt: purchasedAt, price: -14.99,
            cancellationReason: "CUSTOMER_SUPPORT"))

        let state = try await sql.raw("SELECT state FROM measurement_revenuecat_adjustments WHERE account_id=\(bind:userID)").first()!.decode(column: "state", as: String.self)
        let events = try await sql.raw("""
            SELECT payload->>'event' AS event FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:userID) ORDER BY payload->>'event'
            """).all().map { try $0.decode(column: "event", as: String.self) }
        XCTAssertEqual(state, "reversed")
        XCTAssertEqual(events, ["subscription_payment", "subscription_refund", "subscription_refund_reversal"])
    }

    func testRevenueCatAdjustmentsRejectMixedCurrenciesInEitherArrivalOrder() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")

        let refundFirst = "mixed-reversal-after-refund", firstPurchase = Date().addingTimeInterval(1)
        _ = try await webhook(revenueCatBody(transaction: refundFirst,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: firstPurchase))
        _ = try await webhook(revenueCatBody(transaction: refundFirst, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: firstPurchase, price: -14.99,
            currency: "GBP", cancellationReason: "CUSTOMER_SUPPORT"))
        _ = try await webhook(revenueCatBody(transaction: refundFirst, type: "REFUND_REVERSED",
            eventTimestamp: Date().addingTimeInterval(4), purchasedAt: firstPurchase, price: 14.99,
            currency: "USD"))

        let reversalFirst = "mixed-refund-after-reversal", secondPurchase = Date().addingTimeInterval(5)
        _ = try await webhook(revenueCatBody(transaction: reversalFirst,
            eventTimestamp: Date().addingTimeInterval(6), purchasedAt: secondPurchase))
        _ = try await webhook(revenueCatBody(transaction: reversalFirst, type: "REFUND_REVERSED",
            eventTimestamp: Date().addingTimeInterval(7), purchasedAt: secondPurchase, price: 14.99,
            currency: "USD"))
        _ = try await webhook(revenueCatBody(transaction: reversalFirst, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(8), purchasedAt: secondPurchase, price: -14.99,
            currency: "GBP", cancellationReason: "CUSTOMER_SUPPORT"))

        let unresolved = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_adjustments
            WHERE account_id=\(bind:userID) AND state='unresolved'
            """).first()!.decode(column: "n", as: Int.self)
        let mixedCurrencyDeliveries = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs j
            JOIN measurement_revenuecat_lifecycle_events l ON l.id=j.source_id
            WHERE j.account_id=\(bind:userID) AND j.source_kind='revenueCatEvent'
              AND l.currency_code='USD' AND j.state IN ('pending','failing','leased','delivered')
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(unresolved, 2)
        XCTAssertEqual(mixedCurrencyDeliveries, 0)
    }

    func testRevenueCatChargeConflictsRemainStickyAndPendingRefundBlocksChargeDispatch() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")

        let chargeConflict = "sticky-charge-conflict", firstPurchase = Date().addingTimeInterval(1)
        _ = try await webhook(revenueCatBody(transaction: chargeConflict,
            eventTimestamp: Date().addingTimeInterval(2), purchasedAt: firstPurchase, price: 14.99))
        _ = try await webhook(revenueCatBody(transaction: chargeConflict,
            eventTimestamp: Date().addingTimeInterval(3), purchasedAt: firstPurchase, price: 10.00))
        _ = try await webhook(revenueCatBody(transaction: chargeConflict, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(4), purchasedAt: firstPurchase, price: -14.99,
            cancellationReason: "CUSTOMER_SUPPORT"))

        let refundFirst = "inconsistent-refund-before-charge", secondPurchase = Date().addingTimeInterval(5)
        _ = try await webhook(revenueCatBody(transaction: refundFirst, type: "CANCELLATION",
            eventTimestamp: Date().addingTimeInterval(6), purchasedAt: secondPurchase, price: -10.00,
            cancellationReason: "CUSTOMER_SUPPORT"))
        _ = try await webhook(revenueCatBody(transaction: refundFirst,
            eventTimestamp: Date().addingTimeInterval(7), purchasedAt: secondPurchase, price: 14.99))

        let noAdjustment = "zero-value-conflict-without-adjustment", zeroPurchase = Date().addingTimeInterval(8)
        let zeroEventID = UUID().uuidString
        _ = try await webhook(revenueCatBody(transaction: noAdjustment, eventID: zeroEventID,
            eventTimestamp: Date().addingTimeInterval(9), purchasedAt: zeroPurchase, price: 0.00))
        _ = try await webhook(revenueCatBody(transaction: noAdjustment, eventID: zeroEventID,
            eventTimestamp: Date().addingTimeInterval(9), purchasedAt: zeroPurchase, price: 14.99))
        _ = try await webhook(revenueCatBody(transaction: noAdjustment,
            eventTimestamp: Date().addingTimeInterval(10), purchasedAt: zeroPurchase, price: 14.99))

        let activeJobs = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:userID) AND state IN ('pending','failing','leased','delivered')
            """).first()!.decode(column: "n", as: Int.self)
        let conflicts = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_lifecycle_events
            WHERE account_id=\(bind:userID) AND conflict_hash IS NOT NULL AND resolution='unresolved'
            """).first()!.decode(column: "n", as: Int.self)
        let unresolvedAdjustments = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_revenuecat_adjustments
            WHERE account_id=\(bind:userID) AND state='unresolved'
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(activeJobs, 0)
        XCTAssertGreaterThanOrEqual(conflicts, 3)
        XCTAssertEqual(unresolvedAdjustments, 2)
    }

    func testAccountErasureScrubsRevenueCatAccountJoinsButKeepsDeduplicationTombstones() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let response = try await webhook(revenueCatBody(transaction: "erasure-tombstone"))
        XCTAssertEqual(response.status, .ok)
        let lifecycleID = try await sql.raw("SELECT id FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:userID)").first()!.decode(column: "id", as: UUID.self)
        let chargeID = try await sql.raw("SELECT id FROM measurement_revenuecat_events WHERE account_id=\(bind:userID)").first()!.decode(column: "id", as: UUID.self)
        let outboxBefore = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(outboxBefore, 1)
        _ = try await put("productAnalytics", expected: revision, decision: "withdrawn")
        try await app.db.transaction { tx in
            try await MeasurementPrivacyService.eraseAccount(self.userID, accountDeletionJobID: UUID(), now: Date(), on: tx)
        }
        let lifecycleRow = try await sql.raw("SELECT account_id,provider_event_key_hash FROM measurement_revenuecat_lifecycle_events WHERE id=\(bind:lifecycleID)").first()
        let chargeRow = try await sql.raw("SELECT account_id,durable_key_hash FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").first()
        let lifecycle = try XCTUnwrap(lifecycleRow)
        let charge = try XCTUnwrap(chargeRow)
        XCTAssertNil(try lifecycle.decode(column: "account_id", as: UUID?.self))
        XCTAssertEqual(try lifecycle.decode(column: "provider_event_key_hash", as: String.self).count, 64)
        XCTAssertNil(try charge.decode(column: "account_id", as: UUID?.self))
        XCTAssertEqual(try charge.decode(column: "durable_key_hash", as: String.self).count, 64)
        let linkedOutbox = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:userID) OR source_id IN (\(bind:lifecycleID),\(bind:chargeID))
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(linkedOutbox, 0, "deletion must sever outbox joins that reconstruct economic facts")
        try await sql.raw("DELETE FROM measurement_revenuecat_lifecycle_events WHERE id=\(bind:lifecycleID)").run()
        try await sql.raw("DELETE FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").run()
    }

    func testProviderWaitDoesNotLockUserRowAndDeletionWaitsThenPreservesExposureManifest() async throws {
        let subject = try await queueProductAnalyticsDispatch()
        let deletionJob = try await createMeasurementDeletionJob()
        let transport = SuspendedMeasurementHTTPTransport()
        app.storage[MeasurementDispatchService.TransportKey.self] = transport.transport
        let dispatch = Task { await MeasurementDispatchService.run(app: self.app, on: self.app.db) }
        await transport.waitUntilStarted()

        try await app.db.transaction { tx in
            let txSQL = try VerifiedIdentityService.sql(tx)
            try await txSQL.raw("SET LOCAL lock_timeout='250ms'").run()
            try await txSQL.raw("UPDATE users SET name='Available during provider wait' WHERE id=\(bind:self.userID)").run()
        }

        let probe = MeasurementTaskProbe()
        let deletion = Task {
            await probe.markStarted()
            try await self.app.db.transaction { tx in
                let txSQL = try VerifiedIdentityService.sql(tx)
                _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:self.userID) FOR UPDATE").first()
                try await MeasurementPrivacyService.eraseAccount(
                    self.userID, accountDeletionJobID: deletionJob, now: Date(), on: tx)
            }
            await probe.markFinished()
        }
        await probe.waitUntilStarted()
        try await Task.sleep(nanoseconds: 150_000_000)
        let deletionFinishedEarly = await probe.isFinished()
        XCTAssertFalse(deletionFinishedEarly, "deletion must wait for the in-flight purpose barrier")

        await transport.release()
        _ = await dispatch.value
        try await deletion.value
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
        let erasure = try await sql.raw("""
            SELECT state,account_deletion_job_id FROM measurement_erasure_jobs
            WHERE subject_id=\(bind:subject) AND destination='posthog'
            """).first()
        let row = try XCTUnwrap(erasure)
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "pending")
        XCTAssertEqual(try row.decode(column: "account_deletion_job_id", as: UUID?.self), deletionJob)
        let remainingDispatch = try await sql.raw("SELECT id FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()
        XCTAssertNil(remainingDispatch)

        try await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_deletion_job_id=\(bind:deletionJob)").run()
        try await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind:deletionJob)").run()
    }

    func testDeletionThatOwnsPurposeBarrierSuppressesClaimedWorkBeforeTransport() async throws {
        _ = try await queueProductAnalyticsDispatch()
        let deletionJob = try await createMeasurementDeletionJob()
        let recorder = MeasurementHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        let erased = MeasurementTaskProbe()
        let deletion = Task {
            try await self.app.db.transaction { tx in
                let txSQL = try VerifiedIdentityService.sql(tx)
                _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:self.userID) FOR UPDATE").first()
                try await MeasurementPrivacyService.eraseAccount(
                    self.userID, accountDeletionJobID: deletionJob, now: Date(), on: tx)
                await erased.markStarted()
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            await erased.markFinished()
        }
        await erased.waitUntilStarted()
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        try await deletion.value
        let calls = await recorder.calls()
        XCTAssertEqual(counts.delivered, 0)
        XCTAssertEqual(calls.count, 0)

        try await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_deletion_job_id=\(bind:deletionJob)").run()
        try await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind:deletionJob)").run()
    }

    func testSandboxRevenueCatFactCannotDispatchIntoProductionPostHog() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .production,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        let recorder = MeasurementHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        try await enable("productAnalyticsEnabled")
        _ = try await put("productAnalytics", decision: "granted")
        let accepted = try await webhook(revenueCatBody(transaction: "environment-isolation"))
        XCTAssertEqual(accepted.status, .ok)
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.suppressed, 1)
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRevenueCatWebhookWithProviderFlagsOffDoesNotBackfillOutbox() async throws {
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        _ = try await put("productAnalytics", decision: "granted")
        let response = try await webhook(revenueCatBody(transaction: "flags-off"))
        let before = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(before, 0)
        try await enable("productAnalyticsEnabled")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let after = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND source_kind='revenueCatLifecycle'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(after, 0)
    }

    func testAccountDeletionRowLockPreventsAnAlreadyAuthenticatedEventFromCommittingAfterDeletion() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let revision = try uuid(try permission("productAnalytics", in: grant)["revision"])
        let input = MeasurementProductEventUpload(eventId: UUID(), occurredAt: Date().addingTimeInterval(1),
            consentRevision: revision, installationId: UUID(),
            event: .init(schemaVersion: 1, name: "first_project_created", properties: [:]))
        let locked = expectation(description: "account deletion holds the row")
        let deletion = Task {
            try await self.app.db.transaction { tx in
                let txSQL = try VerifiedIdentityService.sql(tx)
                _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:self.userID) FOR UPDATE").first()
                locked.fulfill()
                try await Task.sleep(nanoseconds: 250_000_000)
                try await txSQL.raw("UPDATE users SET lifecycle_state='deleting',auth_version=auth_version+1 WHERE id=\(bind:self.userID)").run()
            }
        }
        await fulfillment(of: [locked], timeout: 2)
        let ingest = Task { try await MeasurementRelayService.acceptProductEvent(accountID: self.userID,
            input: input, now: Date().addingTimeInterval(2), on: self.app.db) }
        try await deletion.value
        do { try await ingest.value; XCTFail("deleted account admitted a measurement event") }
        catch let abort as AbortError { XCTAssertEqual(abort.status, .unauthorized) }
        try await sql.raw("UPDATE users SET lifecycle_state='active' WHERE id=\(bind:userID)").run()
        let count = try await sql.raw("SELECT count(*) AS n FROM measurement_product_events WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 0)
    }

    func testProviderErasureUsesPreservedEncryptedManifestAndCompletesWithMockReceipt() async throws {
        try await enable("crossCompanyAdsEnabled")
        let installation = UUID()
        let grant = try await put("crossCompanyAds", decision: "granted", installationID: installation,
                                  attStatus: "authorized", attAssertedAt: Date())
        let revision = try uuid(try permission("crossCompanyAds", in: grant)["revision"])
        let bound = try await request(.POST, "api/v2/measurement/devices", token: jwt, object: [
            "installationId": installation.uuidString, "consentRevision": revision.uuidString,
            "singularDeviceId": "synthetic-sdid-erasure"
        ])
        let withdrawn = try await put("crossCompanyAds", expected: revision, decision: "withdrawn")
        XCTAssertEqual(bound.status, .noContent)
        XCTAssertEqual(withdrawn.status, .ok)
        app.storage[MeasurementErasureService.ConfigurationKey.self] = .init(
            postHogURL: nil, postHogPersonalKey: nil,
            singularURL: "https://singular.invalid/erase", singularAPIKey: "singular_synthetic")
        let recorder = MeasurementErasureRecorder()
        app.storage[MeasurementErasureService.TransportKey.self] = recorder.transport
        let counts = await MeasurementErasureService.run(app: app, on: app.db)
        XCTAssertEqual(counts.completed, 1)
        let erasureCalls = await recorder.calls()
        let call = try XCTUnwrap(erasureCalls.first)
        XCTAssertEqual(call.uri, "https://singular.invalid/erase")
        XCTAssertTrue(call.body.contains("synthetic-sdid-erasure"))
        let bindingCount = try await sql.raw("SELECT count(*) AS n FROM measurement_device_bindings WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(bindingCount, 0, "the encrypted erasure manifest is purged only after provider receipt")
    }

    func testExpiredLeasesNeverBlindlyReplayOrLoseErasureManifest() async throws {
        try await enable("productAnalyticsEnabled")
        let grant = try await put("productAnalytics", decision: "granted")
        let permissionState = try permission("productAnalytics", in: grant)
        let revision = try uuid(permissionState["revision"])
        let subjectRow = try await sql.raw("SELECT subject_id FROM measurement_permission_current WHERE account_id=\(bind:userID) AND purpose='productAnalytics'").first()
        let subject = try XCTUnwrap(subjectRow?.decode(column: "subject_id", as: UUID.self))
        let dispatchID = UUID(), expiredToken = UUID()
        try await sql.raw("""
            INSERT INTO measurement_dispatch_jobs
                (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,state,attempts,
                 available_at,lease_token,lease_expires_at,payload,created_at)
            VALUES (\(bind:dispatchID),'posthog','productEvent',\(bind:UUID()),\(bind:userID),\(bind:subject),
                    \(bind:revision),'leased',1,NOW()-INTERVAL '2 minutes',\(bind:expiredToken),
                    NOW()-INTERVAL '1 minute','{}'::jsonb,NOW()-INTERVAL '3 minutes')
            """).run()
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let dispatchRow = try await sql.raw("SELECT state,payload FROM measurement_dispatch_jobs WHERE id=\(bind:dispatchID)").first()
        let dispatch = try XCTUnwrap(dispatchRow)
        XCTAssertEqual(try dispatch.decode(column: "state", as: String.self), "uncertain")
        XCTAssertNil(try dispatch.decode(column: "payload", as: String?.self))

        let withdrawn = try await put("productAnalytics", expected: revision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok)
        let erasureRow = try await sql.raw("SELECT id FROM measurement_erasure_jobs WHERE subject_id=\(bind:subject) AND destination='posthog'").first()
        let erasure = try XCTUnwrap(erasureRow?.decode(column: "id", as: UUID.self))
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='leased',completed_at=NULL,lease_token=\(bind:UUID()),
                lease_expires_at=NOW()-INTERVAL '1 minute' WHERE id=\(bind:erasure)
            """).run()
        _ = await MeasurementErasureService.run(app: app, on: app.db)
        let state = try await sql.raw("SELECT state FROM measurement_erasure_jobs WHERE id=\(bind:erasure)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(state, "manual_required")
        let subjectState = try await sql.raw("SELECT state FROM measurement_subjects WHERE id=\(bind:subject)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(subjectState, "revoked", "the manifest subject remains until verified provider completion")
    }

    func testApplePurchaseIntentPinsTheExactPreexistingInstallationWithoutATTOrCrossConsent() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple()
        let installation = UUID(), otherInstallation = UUID()
        _ = try await canonicalApple(otherInstallation, revision, evidence: "verified")
        let wrong = try await prepareApple(installation, revision)
        XCTAssertEqual(wrong.0.status, .forbidden, wrong.0.body.string)

        let attribution = try await canonicalApple(installation, revision, evidence: "verified")
        let prepared = try await prepareApple(installation, revision)
        XCTAssertEqual(prepared.0.status, .created, prepared.0.body.string)
        XCTAssertEqual(prepared.0.headers.first(name: .cacheControl), "no-store")
        let preparedID = try XCTUnwrap(prepared.1)
        let row = try await sql.raw("SELECT purpose,subject_id,attribution_record_id FROM measurement_purchase_intents WHERE id=\(bind:preparedID)").first()!
        XCTAssertEqual(try row.decode(column: "purpose", as: String.self), "appleAds")
        XCTAssertNil(try row.decode(column: "subject_id", as: UUID?.self))
        XCTAssertEqual(try row.decode(column: "attribution_record_id", as: UUID.self), attribution)
        let att = try await sql.raw("SELECT count(*) AS n FROM measurement_att_assertions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        let cross = try await sql.raw("SELECT count(*) AS n FROM measurement_permission_current WHERE account_id=\(bind:userID) AND purpose='crossCompanyAds'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(att, 0); XCTAssertEqual(cross, 0)
    }

    func testAppleVerifiedWitnessAndRevenueCatCreateOnlyAFirstPartyPaidLink() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        _ = try await canonicalApple(installation, revision, evidence: "verified")
        let prepared = try await prepareApple(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(2), transaction = "apple-paid-\(UUID().uuidString)"
        let witness = try await witnessApple(intent, capability, transaction: transaction, purchaseDate: purchaseDate)
        let replay = try await witnessApple(intent, capability, transaction: transaction, purchaseDate: purchaseDate)
        XCTAssertEqual(witness.status, .accepted, witness.body.string)
        XCTAssertEqual(replay.status, .accepted, replay.body.string)
        let provider = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        XCTAssertEqual(provider.status, .ok, provider.body.string)

        let linkRow = try await sql.raw("""
            SELECT l.outcome,a.purpose,a.installation_id,a.subject_id,r.origin_acquisition_id
            FROM measurement_purchase_charge_links l
            JOIN measurement_purchase_acquisitions a ON a.id=l.acquisition_id
            JOIN measurement_revenuecat_events r ON r.id=l.charge_id
            WHERE l.purpose='appleAds' AND a.account_id=\(bind:userID)
            """).first()
        let link = try XCTUnwrap(linkRow)
        XCTAssertEqual(try link.decode(column: "outcome", as: String.self), "paid_campaign")
        XCTAssertEqual(try link.decode(column: "purpose", as: String.self), "appleAds")
        XCTAssertEqual(try link.decode(column: "installation_id", as: UUID.self), installation)
        XCTAssertNil(try link.decode(column: "subject_id", as: UUID?.self))
        XCTAssertNil(try link.decode(column: "origin_acquisition_id", as: UUID?.self),
                     "the compatibility column remains cross-company only")
        let dispatch = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(dispatch, 0)

        let renewalDate = purchaseDate.addingTimeInterval(60)
        let renewal = try await webhook(revenueCatBody(transaction: "renewal-\(transaction)", type: "RENEWAL",
            eventTimestamp: renewalDate, purchasedAt: renewalDate, originalTransaction: "original-\(transaction)"))
        XCTAssertEqual(renewal.status, .ok, renewal.body.string)
        let acquisitionID = try await sql.raw("SELECT id FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND account_id=\(bind:userID)").first()!.decode(column: "id", as: UUID.self)
        let renewalLinks = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND acquisition_id=\(bind:acquisitionID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(renewalLinks, 2)
        app.storage[ApplePurchaseOriginService.CampaignConfigurationKey.self] = .init(
            organizationID: 40_669_820, campaignIDs: [999_999_999])
        let changedConfigDate = renewalDate.addingTimeInterval(60)
        _ = try await webhook(revenueCatBody(transaction: "changed-config-\(transaction)", type: "RENEWAL",
            eventTimestamp: changedConfigDate, purchasedAt: changedConfigDate,
            originalTransaction: "original-\(transaction)"))
        let afterConfigChange = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND acquisition_id=\(bind:acquisitionID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(afterConfigChange, 2)
    }

    func testAppleIntentCannotCrossRoutesAndRejectsRestoreOrExpiredEvidence() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        _ = try await canonicalApple(installation, revision, evidence: "verified")
        let first = try await prepareApple(installation, revision)
        let intent = try XCTUnwrap(first.1), capability = try XCTUnwrap(first.2)
        try await enable("crossCompanyAdsEnabled")
        let crossRoute = try await witnessPurchase(intent, capability, transaction: "wrong-purpose",
            purchaseDate: Date().addingTimeInterval(1))
        XCTAssertEqual(crossRoute.status, .notFound)
        let restore = try await witnessApple(intent, capability, transaction: "restore-before-intent",
            purchaseDate: Date().addingTimeInterval(-60))
        XCTAssertEqual(restore.status, .badRequest)

        let second = try await prepareApple(installation, revision)
        let secondID = try XCTUnwrap(second.1)
        try await sql.raw("UPDATE measurement_purchase_intents SET expires_at=NOW()-INTERVAL '1 second' WHERE id=\(bind:secondID)").run()
        let expired = try await witnessApple(secondID, try XCTUnwrap(second.2), transaction: "expired-apple",
            purchaseDate: Date().addingTimeInterval(1))
        XCTAssertEqual(expired.status, .gone)
    }

    func testAppleProviderConflictQuarantinesThePaidLink() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        _ = try await canonicalApple(installation, revision, evidence: "verified")
        let prepared = try await prepareApple(installation, revision)
        let transaction = "apple-conflict-\(UUID().uuidString)", purchaseDate = Date().addingTimeInterval(2)
        _ = try await witnessApple(try XCTUnwrap(prepared.1), try XCTUnwrap(prepared.2),
                                   transaction: transaction, purchaseDate: purchaseDate)
        let providerID = UUID().uuidString
        _ = try await webhook(revenueCatBody(transaction: transaction, eventID: providerID,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        let conflict = try await webhook(revenueCatBody(transaction: transaction, type: "RENEWAL",
            eventID: providerID, eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        XCTAssertEqual(conflict.status, .ok, conflict.body.string)
        let links = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        let state = try await sql.raw("SELECT state FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND account_id=\(bind:userID)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(links, 0); XCTAssertEqual(state, "conflict")
    }

    func testAppleSecondInstallationOnTheSameChainQuarantinesTheExistingAcquisition() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), firstInstallation = UUID(), secondInstallation = UUID()
        _ = try await canonicalApple(firstInstallation, revision, evidence: "verified")
        _ = try await canonicalApple(secondInstallation, revision, evidence: "verified")
        let first = try await prepareApple(firstInstallation, revision)
        let second = try await prepareApple(secondInstallation, revision)
        let chain = "apple-shared-chain-\(UUID().uuidString)"
        let firstDate = Date().addingTimeInterval(2), secondDate = firstDate.addingTimeInterval(1)
        _ = try await witnessApple(try XCTUnwrap(first.1), try XCTUnwrap(first.2),
                                   transaction: "first-\(chain)", purchaseDate: firstDate)
        _ = try await webhook(revenueCatBody(transaction: "first-\(chain)", eventTimestamp: firstDate,
            purchasedAt: firstDate, originalTransaction: chain))
        _ = try await witnessApple(try XCTUnwrap(second.1), try XCTUnwrap(second.2),
                                   transaction: "second-\(chain)", purchaseDate: secondDate)
        _ = try await webhook(revenueCatBody(transaction: "second-\(chain)", eventTimestamp: secondDate,
            purchasedAt: secondDate, originalTransaction: chain))
        let state = try await sql.raw("SELECT state FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND account_id=\(bind:userID)").first()!.decode(column: "state", as: String.self)
        let links = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(state, "conflict"); XCTAssertEqual(links, 0)

        let renewalDate = secondDate.addingTimeInterval(60)
        _ = try await webhook(revenueCatBody(transaction: "renewal-\(chain)", type: "RENEWAL",
            eventTimestamp: renewalDate, purchasedAt: renewalDate, originalTransaction: chain))
        let afterRenewal = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(afterRenewal, 0)
    }

    func testAppleRenewalForAnotherCanonicalAccountQuarantinesTheExistingChain() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        _ = try await canonicalApple(installation, revision, evidence: "verified")
        let prepared = try await prepareApple(installation, revision)
        let chain = "apple-account-conflict-\(UUID().uuidString)"
        let initialDate = Date().addingTimeInterval(2)
        _ = try await witnessApple(try XCTUnwrap(prepared.1), try XCTUnwrap(prepared.2),
                                   transaction: "initial-\(chain)", purchaseDate: initialDate)
        _ = try await webhook(revenueCatBody(transaction: "initial-\(chain)", eventTimestamp: initialDate,
            purchasedAt: initialDate, originalTransaction: chain))

        let other = User(appleUserId: nil, email: "apple-origin-other-\(UUID())@example.test",
                         name: "Other synthetic manager", authProvider: .magicLink)
        try await other.save(on: app.db)
        let otherID = try other.requireID()
        let conflictDate = initialDate.addingTimeInterval(60)
        _ = try await webhook(revenueCatBody(transaction: "other-account-\(chain)", type: "RENEWAL",
            eventTimestamp: conflictDate, purchasedAt: conflictDate, originalTransaction: chain,
            appUserID: otherID))

        let state = try await sql.raw("""
            SELECT state FROM measurement_purchase_acquisitions
            WHERE purpose='appleAds' AND account_id=\(bind:userID)
            """).first()!.decode(column: "state", as: String.self)
        let linksAfterConflict = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(state, "conflict")
        XCTAssertEqual(linksAfterConflict, 0)

        let originalDate = conflictDate.addingTimeInterval(60)
        _ = try await webhook(revenueCatBody(transaction: "original-account-\(chain)", type: "RENEWAL",
            eventTimestamp: originalDate, purchasedAt: originalDate, originalTransaction: chain))
        let linksAfterOriginal = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(linksAfterOriginal, 0)

        try await sql.raw("DELETE FROM measurement_revenuecat_lifecycle_events WHERE account_id=\(bind:otherID)").run()
        try await sql.raw("DELETE FROM measurement_revenuecat_events WHERE account_id=\(bind:otherID)").run()
        try await other.delete(on: app.db)
    }

    func testAppleRetentionRevokesThePinnedJoinBeforeDeletingTheCanonicalRecord() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        let attribution = try await canonicalApple(installation, revision, evidence: "verified")
        let prepared = try await prepareApple(installation, revision)
        let transaction = "apple-retention-\(UUID().uuidString)", purchaseDate = Date().addingTimeInterval(2)
        _ = try await witnessApple(try XCTUnwrap(prepared.1), try XCTUnwrap(prepared.2),
                                   transaction: transaction, purchaseDate: purchaseDate)
        _ = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        try await sql.raw("UPDATE ad_attribution_records SET created_at=\(bind:Date().addingTimeInterval(-AdMeasurementPolicy.retention-60)) WHERE id=\(bind:attribution)").run()
        let swept = try await AdAttributionStore.sweep(now: Date(), on: app.db)
        XCTAssertEqual(swept, 1)
        let record = try await sql.raw("SELECT count(*) AS n FROM ad_attribution_records WHERE id=\(bind:attribution)").first()!.decode(column: "n", as: Int.self)
        let links = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE attribution_record_id=\(bind:attribution)").first()!.decode(column: "n", as: Int.self)
        let tombstone = try await sql.raw("SELECT state,account_id,attribution_record_id FROM measurement_purchase_acquisitions WHERE purpose='appleAds'").first()!
        XCTAssertEqual(record, 0); XCTAssertEqual(links, 0)
        XCTAssertEqual(try tombstone.decode(column: "state", as: String.self), "revoked")
        XCTAssertNil(try tombstone.decode(column: "account_id", as: UUID?.self))
        XCTAssertNil(try tombstone.decode(column: "attribution_record_id", as: UUID?.self))
    }

    func testAppleProviderFirstOrganicIsResolvedWithoutCampaignAssociation() async throws {
        try await configureApplePurchaseOrigin()
        let revision = try await grantApple(), installation = UUID()
        let attribution = try await canonicalApple(installation, revision, evidence: "organic")
        let prepared = try await prepareApple(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(2), transaction = "apple-organic-\(UUID().uuidString)"
        let provider = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        XCTAssertEqual(provider.status, .ok, provider.body.string)
        let witness = try await witnessApple(intent, capability, transaction: transaction, purchaseDate: purchaseDate)
        XCTAssertEqual(witness.status, .accepted, witness.body.string)
        let linkRow = try await sql.raw("""
            SELECT outcome,acquisition_id,attribution_record_id FROM measurement_purchase_charge_links
            WHERE purpose='appleAds' AND attribution_record_id=\(bind:attribution)
            """).first()
        let link = try XCTUnwrap(linkRow)
        XCTAssertEqual(try link.decode(column: "outcome", as: String.self), "organic")
        XCTAssertNil(try link.decode(column: "acquisition_id", as: UUID?.self))
        let acquisitions = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(acquisitions, 0)
        let changed = try await witnessApple(intent, capability, transaction: transaction + "-changed",
                                             purchaseDate: purchaseDate)
        XCTAssertEqual(changed.status, .conflict)
        let remaining = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND attribution_record_id=\(bind:attribution)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(remaining, 0)
    }

    func testAppleWithdrawalRevokesAppleLinksButPreservesCrossCompanyOrigin() async throws {
        try await configureApplePurchaseOrigin()
        try await enable("crossCompanyAdsEnabled")
        let installation = UUID()
        let appleRevision = try await grantApple()
        _ = try await canonicalApple(installation, appleRevision, evidence: "verified")
        let cross = try await grantPurchaseOrigin(installation)
        let applePrepared = try await prepareApple(installation, appleRevision)
        let crossPrepared = try await preparePurchase(installation, cross.1)
        let transaction = "dual-purpose-\(UUID().uuidString)", purchaseDate = Date().addingTimeInterval(2)
        _ = try await witnessApple(try XCTUnwrap(applePrepared.1), try XCTUnwrap(applePrepared.2),
                                   transaction: transaction, purchaseDate: purchaseDate)
        _ = try await witnessPurchase(try XCTUnwrap(crossPrepared.1), try XCTUnwrap(crossPrepared.2),
                                      transaction: transaction, purchaseDate: purchaseDate)
        _ = try await webhook(revenueCatBody(transaction: transaction,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        let before = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE charge_id IN (SELECT id FROM measurement_revenuecat_events WHERE account_id=\(bind:userID))").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(before, 2)

        let withdrawn = try await put("appleAds", expected: appleRevision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        let appleLinks = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='appleAds'").first()!.decode(column: "n", as: Int.self)
        let crossLinks = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_charge_links WHERE purpose='crossCompanyAds'").first()!.decode(column: "n", as: Int.self)
        let crossState = try await sql.raw("SELECT state FROM measurement_purchase_acquisitions WHERE purpose='crossCompanyAds' AND account_id=\(bind:userID)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(appleLinks, 0); XCTAssertEqual(crossLinks, 1); XCTAssertEqual(crossState, "active")
    }

    func testPurchaseWitnessBeforeRevenueCatMatchesOnceWithoutAdDispatch() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        XCTAssertEqual(prepared.0.status, .created)
        XCTAssertEqual(prepared.0.headers.first(name: .cacheControl), "no-store")
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(1)
        let first = try await witnessPurchase(intent, capability, transaction: "origin-witness-first", purchaseDate: purchaseDate)
        let replay = try await witnessPurchase(intent, capability, transaction: "origin-witness-first", purchaseDate: purchaseDate)
        XCTAssertEqual(first.status, .accepted, first.body.string)
        XCTAssertEqual(replay.status, .accepted, replay.body.string)
        let provider = try await webhook(revenueCatBody(transaction: "origin-witness-first",
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        XCTAssertEqual(provider.status, .ok)

        let origin = try await sql.raw("""
            SELECT i.state,a.account_id,a.installation_id,e.origin_acquisition_id
            FROM measurement_purchase_intents i
            JOIN measurement_purchase_acquisitions a ON a.initial_charge_id=i.matched_charge_id
            JOIN measurement_revenuecat_events e ON e.id=i.matched_charge_id
            WHERE i.id=\(bind:intent)
            """).first()
        let row = try XCTUnwrap(origin)
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "matched")
        XCTAssertEqual(try row.decode(column: "account_id", as: UUID?.self), userID)
        XCTAssertEqual(try row.decode(column: "installation_id", as: UUID?.self), installation)
        XCTAssertNotNil(try row.decode(column: "origin_acquisition_id", as: UUID?.self))
        let jobs = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(jobs, 0, "an acquisition match is preparatory and cannot enable provider delivery")
        let durable = try await sql.raw("SELECT row_to_json(i)::text AS body FROM measurement_purchase_intents i WHERE id=\(bind:intent)").first()!.decode(column: "body", as: String.self)
        XCTAssertFalse(durable.contains(capability)); XCTAssertFalse(durable.contains("origin-witness-first"))
    }

    func testRevenueCatBeforeWitnessMatchesAndProviderEnvironmentMustAgree() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(1)
        let providerFirst = try await webhook(revenueCatBody(transaction: "origin-provider-first",
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        let witnessAfter = try await witnessPurchase(intent, capability, transaction: "origin-provider-first",
                                                     purchaseDate: purchaseDate)
        let matchedState = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:intent)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(providerFirst.status, .ok)
        XCTAssertEqual(witnessAfter.status, .accepted)
        XCTAssertEqual(matchedState, "matched")

        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: .production)
        let other = try await preparePurchase(installation, revision)
        let otherIntent = try XCTUnwrap(other.1), otherCapability = try XCTUnwrap(other.2)
        let otherDate = Date().addingTimeInterval(2)
        let wrongEnvironmentProvider = try await webhook(revenueCatBody(transaction: "origin-wrong-environment",
            eventTimestamp: otherDate, purchasedAt: otherDate))
        let wrongEnvironmentWitness = try await witnessPurchase(otherIntent, otherCapability,
            transaction: "origin-wrong-environment", purchaseDate: otherDate)
        let pendingState = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:otherIntent)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(wrongEnvironmentProvider.status, .ok)
        XCTAssertEqual(wrongEnvironmentWitness.status, .accepted)
        XCTAssertEqual(pendingState, "witnessed")
    }

    func testPurchaseWitnessRejectsChangedReplaySecondInstallationAndAccountSwap() async throws {
        try await configurePurchaseOrigin()
        let (installationA, revision) = try await grantPurchaseOrigin()
        let first = try await preparePurchase(installationA, revision)
        let firstID = try XCTUnwrap(first.1), firstCapability = try XCTUnwrap(first.2)
        let purchaseDate = Date().addingTimeInterval(1)
        let firstWitness = try await witnessPurchase(firstID, firstCapability, transaction: "origin-one-use",
                                                     purchaseDate: purchaseDate)
        XCTAssertEqual(firstWitness.status, .accepted)

        let installationB = UUID()
        let observed = try await request(.PUT, "api/v2/measurement/devices/att", token: jwt, object: [
            "installationId": installationB.uuidString, "consentRevision": revision.uuidString,
            "attStatus": "authorized", "observedAt": date()
        ])
        XCTAssertEqual(observed.status, .ok)
        let second = try await preparePurchase(installationB, revision)
        let secondID = try XCTUnwrap(second.1), secondCapability = try XCTUnwrap(second.2)
        let reused = try await witnessPurchase(secondID, secondCapability, transaction: "origin-one-use",
                                               purchaseDate: purchaseDate)
        let changed = try await witnessPurchase(firstID, firstCapability, transaction: "origin-changed",
                                                purchaseDate: purchaseDate)
        XCTAssertEqual(reused.status, .conflict)
        XCTAssertEqual(changed.status, .conflict)
        let states = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id IN (\(bind:firstID),\(bind:secondID))").all()
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(try states.allSatisfy { try $0.decode(column: "state", as: String.self) == "conflict" })

        let other = User(appleUserId: nil, email: "origin-other-\(UUID())@example.test",
                         name: "Other", authProvider: .magicLink)
        try await other.save(on: app.db)
        let otherID = try other.requireID()
        let otherJWT = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: otherID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: otherID,
            authVersion: other.authVersion, authenticatedAt: Date()))
        let accountSwap = try await witnessPurchase(firstID, firstCapability, transaction: "origin-one-use",
                                                    purchaseDate: purchaseDate, token: otherJWT)
        XCTAssertEqual(accountSwap.status, .notFound)
        try await other.delete(on: app.db)
    }

    func testExpiredAndRestoreWitnessesCannotCreateAnAcquisition() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let expired = try await preparePurchase(installation, revision)
        let expiredID = try XCTUnwrap(expired.1), expiredCapability = try XCTUnwrap(expired.2)
        try await sql.raw("UPDATE measurement_purchase_intents SET expires_at=NOW()-INTERVAL '1 second' WHERE id=\(bind:expiredID)").run()
        let expiredWitness = try await witnessPurchase(expiredID, expiredCapability, transaction: "origin-expired",
                                                       purchaseDate: Date())
        XCTAssertEqual(expiredWitness.status, .gone)

        let restored = try await preparePurchase(installation, revision)
        let restoredID = try XCTUnwrap(restored.1), restoredCapability = try XCTUnwrap(restored.2)
        let restoredWitness = try await witnessPurchase(restoredID, restoredCapability,
            transaction: "origin-restored-old", purchaseDate: Date().addingTimeInterval(-601))
        XCTAssertEqual(restoredWitness.status, .badRequest)
        let acquisitions = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(acquisitions, 0)
    }

    func testUnavailableOrUnusedPurchaseIntentHasNoOperationalEffect() async throws {
        let (installation, revision) = try await grantPurchaseOrigin()
        let unavailable = try await preparePurchase(installation, revision)
        XCTAssertEqual(unavailable.0.status, .serviceUnavailable)
        let unavailableCount = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_intents WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(unavailableCount, 0)

        try await configurePurchaseOrigin()
        let unused = try await preparePurchase(installation, revision)
        XCTAssertEqual(unused.0.status, .created)
        let acquisitions = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(acquisitions, 0)
        let lifecycle = try await sql.raw("SELECT lifecycle_state FROM users WHERE id=\(bind:userID)").first()!.decode(column: "lifecycle_state", as: String.self)
        XCTAssertEqual(lifecycle, "active", "measurement availability cannot change account or purchase fulfilment state")
    }

    func testProviderTimestampBeforeIntentCannotBeRetroactivelyBound() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let candidateDate = Date().addingTimeInterval(-120)
        let oldProvider = try await webhook(revenueCatBody(transaction: "origin-pre-intent",
            eventTimestamp: Date(), purchasedAt: candidateDate))
        let oldWitness = try await witnessPurchase(intent, capability, transaction: "origin-pre-intent",
                                                   purchaseDate: candidateDate)
        let state = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:intent)").first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(oldProvider.status, .ok)
        XCTAssertEqual(oldWitness.status, .conflict)
        XCTAssertEqual(state, "conflict")
        let acquisitions = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(acquisitions, 0)
    }

    func testWithdrawalScrubsMatchedOriginAndLateWitnessCannotReviveIt() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(1)
        _ = try await witnessPurchase(intent, capability, transaction: "origin-withdraw", purchaseDate: purchaseDate)
        _ = try await webhook(revenueCatBody(transaction: "origin-withdraw",
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        let acquisitionID = try await sql.raw("""
            SELECT id FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)
            """).first()!.decode(column: "id", as: UUID.self)
        let withdrawn = try await put("crossCompanyAds", expected: revision, decision: "withdrawn")
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        let lateWitness = try await witnessPurchase(intent, capability, transaction: "origin-withdraw",
                                                    purchaseDate: purchaseDate)
        XCTAssertEqual(lateWitness.status, .notFound)
        let acquisition = try await sql.raw("""
            SELECT state,account_id,installation_id,subject_id
            FROM measurement_purchase_acquisitions WHERE id=\(bind:acquisitionID)
            """).first()
        let row = try XCTUnwrap(acquisition)
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "revoked")
        XCTAssertNil(try row.decode(column: "account_id", as: UUID?.self))
        XCTAssertNil(try row.decode(column: "installation_id", as: UUID?.self))
        XCTAssertNil(try row.decode(column: "subject_id", as: UUID?.self))
        let remainingOrigin = try await sql.raw("SELECT origin_acquisition_id FROM measurement_revenuecat_events WHERE durable_key_hash IS NOT NULL").first()!.decode(column: "origin_acquisition_id", as: UUID?.self)
        XCTAssertNil(remainingOrigin)

        let renewalDate = purchaseDate.addingTimeInterval(60)
        let renewal = try await webhook(revenueCatBody(transaction: "origin-withdraw-renewal", type: "RENEWAL",
            eventTimestamp: renewalDate, purchasedAt: renewalDate,
            originalTransaction: "original-origin-withdraw"))
        XCTAssertEqual(renewal.status, .ok, renewal.body.string)
        let tombstoneState = try await sql.raw("SELECT state FROM measurement_purchase_acquisitions WHERE id=\(bind:acquisitionID)").first()!.decode(column: "state", as: String.self)
        let renewalOrigin = try await sql.raw("""
            SELECT origin_acquisition_id FROM measurement_revenuecat_events
            WHERE account_id=\(bind:userID) AND charge_kind='renewal'
            """).first()!.decode(column: "origin_acquisition_id", as: UUID?.self)
        XCTAssertEqual(tombstoneState, "revoked")
        XCTAssertNil(renewalOrigin, "late renewal is still accepted as a charge but cannot revive revoked origin")
        try await sql.raw("DELETE FROM measurement_purchase_acquisitions WHERE id=\(bind:acquisitionID)").run()
    }

    func testATTExpiryAndAccountDeletionPreventLateProviderJoin() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let purchaseDate = Date().addingTimeInterval(1)
        let witness = try await witnessPurchase(intent, capability, transaction: "origin-late-provider",
                                                purchaseDate: purchaseDate)
        XCTAssertEqual(witness.status, .accepted)
        try await sql.raw("""
            UPDATE measurement_att_assertions SET received_at=NOW()-INTERVAL '2 days',
                expires_at=NOW()-INTERVAL '1 day'
            WHERE account_id=\(bind:userID) AND installation_id=\(bind:installation)
            """).run()
        let late = try await webhook(revenueCatBody(transaction: "origin-late-provider",
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate))
        XCTAssertEqual(late.status, .ok)
        let state = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:intent)").first()!.decode(column: "state", as: String.self)
        let beforeDeletion = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(state, "witnessed")
        XCTAssertEqual(beforeDeletion, 0)

        try await PurchaseOriginService.eraseAccount(userID, now: Date(), on: sql)
        try await sql.raw("UPDATE users SET lifecycle_state='deleted' WHERE id=\(bind:userID)").run()
        let afterDeletion = try await webhook(revenueCatBody(transaction: "origin-after-delete",
            eventTimestamp: Date(), purchasedAt: Date(), originalTransaction: "origin-late-provider"))
        XCTAssertEqual(afterDeletion.status, .ok)
        let intentCount = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_intents WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        let acquisitionCount = try await sql.raw("SELECT count(*) AS n FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(intentCount, 0)
        XCTAssertEqual(acquisitionCount, 0)
    }

    func testRenewalReusesOnlyTheImmutableAcquisitionChain() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let original = "origin-chain-one", initialDate = Date().addingTimeInterval(1)
        _ = try await witnessPurchase(intent, capability, transaction: "origin-chain-initial", purchaseDate: initialDate)
        _ = try await webhook(revenueCatBody(transaction: "origin-chain-initial", eventTimestamp: initialDate,
            purchasedAt: initialDate, originalTransaction: original))
        let acquisitionID = try await sql.raw("SELECT id FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)").first()!.decode(column: "id", as: UUID.self)
        let renewalDate = initialDate.addingTimeInterval(60)
        _ = try await webhook(revenueCatBody(transaction: "origin-chain-renewal", type: "RENEWAL",
            eventTimestamp: renewalDate, purchasedAt: renewalDate, originalTransaction: original))
        let renewalOrigin = try await sql.raw("""
            SELECT origin_acquisition_id FROM measurement_revenuecat_events
            WHERE charge_kind='renewal' AND account_id=\(bind:userID)
            """).first()!.decode(column: "origin_acquisition_id", as: UUID?.self)
        XCTAssertEqual(renewalOrigin, acquisitionID)
        let acquisitionInstallation = try await sql.raw("SELECT installation_id FROM measurement_purchase_acquisitions WHERE id=\(bind:acquisitionID)").first()!.decode(column: "installation_id", as: UUID?.self)
        XCTAssertEqual(acquisitionInstallation, installation)
    }

    func testQuarantinedInitialChargeCannotAuthorizeLaterRenewalOrigin() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let suffix = UUID().uuidString, transaction = "origin-quarantine-\(suffix)"
        let original = "origin-quarantine-chain-\(suffix)", initialDate = Date().addingTimeInterval(1)
        _ = try await witnessPurchase(intent, capability, transaction: transaction, purchaseDate: initialDate)
        let providerEventID = UUID().uuidString
        _ = try await webhook(revenueCatBody(transaction: transaction, eventID: providerEventID,
            eventTimestamp: initialDate, purchasedAt: initialDate, originalTransaction: original))
        let conflictingReplay = try await webhook(revenueCatBody(transaction: transaction, type: "RENEWAL",
            eventID: providerEventID, eventTimestamp: initialDate, purchasedAt: initialDate,
            originalTransaction: original))
        XCTAssertEqual(conflictingReplay.status, .ok)
        let acquisitionState = try await sql.raw("""
            SELECT state FROM measurement_purchase_acquisitions WHERE account_id=\(bind:userID)
            """).first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(acquisitionState, "conflict")

        let renewalDate = initialDate.addingTimeInterval(60)
        let renewal = try await webhook(revenueCatBody(transaction: "origin-renewal-\(suffix)", type: "RENEWAL",
            eventTimestamp: renewalDate, purchasedAt: renewalDate, originalTransaction: original))
        XCTAssertEqual(renewal.status, .ok)
        let origin = try await sql.raw("""
            SELECT origin_acquisition_id FROM measurement_revenuecat_events
            WHERE account_id=\(bind:userID) AND charge_kind='renewal'
            ORDER BY received_at DESC LIMIT 1
            """).first()!.decode(column: "origin_acquisition_id", as: UUID?.self)
        XCTAssertNil(origin)
    }

    func testProviderFirstConflictCannotBeBoundByALaterWitness() async throws {
        try await configurePurchaseOrigin()
        let (installation, revision) = try await grantPurchaseOrigin()
        let prepared = try await preparePurchase(installation, revision)
        let intent = try XCTUnwrap(prepared.1), capability = try XCTUnwrap(prepared.2)
        let suffix = UUID().uuidString, transaction = "origin-provider-conflict-\(suffix)"
        let original = "origin-provider-conflict-chain-\(suffix)", purchaseDate = Date().addingTimeInterval(1)
        let providerEventID = UUID().uuidString
        let initial = try await webhook(revenueCatBody(transaction: transaction, eventID: providerEventID,
            eventTimestamp: purchaseDate, purchasedAt: purchaseDate, originalTransaction: original))
        let conflictingReplay = try await webhook(revenueCatBody(transaction: transaction, type: "RENEWAL",
            eventID: providerEventID, eventTimestamp: purchaseDate, purchasedAt: purchaseDate,
            originalTransaction: original))
        let witness = try await witnessPurchase(intent, capability, transaction: transaction,
                                                purchaseDate: purchaseDate)
        XCTAssertEqual(initial.status, .ok)
        XCTAssertEqual(conflictingReplay.status, .ok)
        XCTAssertEqual(witness.status, .conflict)
        let intentState = try await sql.raw("SELECT state FROM measurement_purchase_intents WHERE id=\(bind:intent)").first()!.decode(column: "state", as: String.self)
        let activeAcquisitions = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_purchase_acquisitions
            WHERE account_id=\(bind:userID) AND state='active'
            """).first()!.decode(column: "n", as: Int.self)
        let origin = try await sql.raw("""
            SELECT origin_acquisition_id FROM measurement_revenuecat_events
            WHERE account_id=\(bind:userID) AND durable_key_hash IS NOT NULL
            ORDER BY received_at DESC LIMIT 1
            """).first()!.decode(column: "origin_acquisition_id", as: UUID?.self)
        XCTAssertEqual(intentState, "conflict")
        XCTAssertEqual(activeAcquisitions, 0)
        XCTAssertNil(origin)
    }
}

private actor MeasurementTransactionGate {
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

private actor MeasurementHTTPRecorder {
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

private actor SuspendedMeasurementHTTPTransport {
    private var calls = 0
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    private func send(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) async -> MeasurementDispatchService.Reply {
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        return .init(status: 201, retryAfter: nil)
    }

    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, headers, body in await self.send(uri, headers, body) }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
    func callCount() -> Int { calls }
}

private actor MeasurementTaskProbe {
    private var started = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func markStarted() { started = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func markFinished() { finished = true }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func isFinished() -> Bool { finished }
}

private actor MeasurementErasureRecorder {
    struct Call: Sendable { let uri: String; let body: String }
    private var values: [Call] = []
    func record(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) -> MeasurementErasureService.Reply {
        values.append(.init(uri: uri.string, body: String(decoding: body, as: UTF8.self)))
        return .init(status: 204)
    }
    nonisolated var transport: MeasurementErasureService.Transport {
        { uri, headers, body in await self.record(uri, headers, body) }
    }
    func calls() -> [Call] { values }
}
