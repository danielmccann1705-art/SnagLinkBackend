@testable import App
import XCTVapor

final class SubscriptionVerificationTests: XCTestCase {
    private typealias Entitlement = SubscriptionVerificationService.Customer.Subscriber.Entitlement
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entitlement(expiry: Date?, grace: Date? = nil) -> Entitlement {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Entitlement(expires_date: expiry.map(formatter.string),
                           grace_period_expires_date: grace.map(formatter.string))
    }

    func testMissingEntitlementIsFree() throws {
        XCTAssertNil(try SubscriptionVerificationService.verifiedUntil(nil, now: now))
    }

    func testExpiredAndExactlyExpiringEntitlementsAreFree() throws {
        for offset in [-300.0, 0.0] {
            let value = entitlement(expiry: now.addingTimeInterval(offset))
            XCTAssertNil(try SubscriptionVerificationService.verifiedUntil(value, now: now))
        }
    }

    func testActiveVerificationIsCappedAtFiveMinutesAndNeverOutlivesEntitlement() throws {
        let longLived = entitlement(expiry: now.addingTimeInterval(3600))
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(longLived, now: now),
                       now.addingTimeInterval(300))
        let expiringSoon = entitlement(expiry: now.addingTimeInterval(90))
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(expiringSoon, now: now),
                       now.addingTimeInterval(90))
    }

    func testActiveGracePeriodExtendsExpiredEntitlementWithinVerificationCap() throws {
        let longGrace = entitlement(expiry: now.addingTimeInterval(-60), grace: now.addingTimeInterval(900))
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(longGrace, now: now),
                       now.addingTimeInterval(300))
        let shortGrace = entitlement(expiry: now.addingTimeInterval(-60), grace: now.addingTimeInterval(45))
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(shortGrace, now: now),
                       now.addingTimeInterval(45))
        let expiredGrace = entitlement(expiry: now.addingTimeInterval(-120), grace: now.addingTimeInterval(-1))
        XCTAssertNil(try SubscriptionVerificationService.verifiedUntil(expiredGrace, now: now))
    }

    func testInvalidExpiryOrGraceDateThrows() {
        let formatter = ISO8601DateFormatter()
        let invalidValues = [
            Entitlement(expires_date: "not-a-date", grace_period_expires_date: nil),
            Entitlement(expires_date: formatter.string(from: now.addingTimeInterval(60)),
                        grace_period_expires_date: "not-a-date")
        ]
        for value in invalidValues {
            XCTAssertThrowsError(try SubscriptionVerificationService.verifiedUntil(value, now: now)) { error in
                XCTAssertEqual((error as? Abort)?.status, .badGateway)
            }
        }
    }

    func testLifetimeEntitlementStillRequiresVerificationAfterFiveMinutes() throws {
        let lifetime = Entitlement(expires_date: nil, grace_period_expires_date: nil)
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(lifetime, now: now),
                       now.addingTimeInterval(300))
    }

    func testMissingExpiryIsRejectedButExplicitNullRepresentsLifetime() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(Entitlement.self, from: Data("{}".utf8)))
        let lifetime = try JSONDecoder().decode(Entitlement.self, from: Data(#"{"expires_date":null}"#.utf8))
        XCTAssertEqual(try SubscriptionVerificationService.verifiedUntil(lifetime, now: now),
                       now.addingTimeInterval(300))
    }

    // MARK: - The entitlement identifier, against a RevenueCat v1 subscriber response

    /// RevenueCat's only entitlement has the Identifier `Snaglist Pro`. Pinned as a
    /// literal here so a rename of the constant cannot pass unnoticed.
    func testTheProEntitlementIdentifierIsExactlyRevenueCats() {
        XCTAssertEqual(SubscriptionVerificationService.proEntitlementIdentifier, "Snaglist Pro")
    }

    func testAnActiveSnaglistProEntitlementIsPro() throws {
        let customer = try subscriber(entitlements: ["Snaglist Pro": active(for: 30 * 86_400)])
        XCTAssertEqual(try SubscriptionVerificationService.proVerifiedUntil(customer, now: now),
                       now.addingTimeInterval(300))
    }

    func testALifetimeSnaglistProEntitlementIsPro() throws {
        let customer = try subscriber(entitlements: ["Snaglist Pro": #"{"expires_date":null,"grace_period_expires_date":null,"product_identifier":"synthetic_lifetime","purchase_date":"2026-09-25T10:00:00Z"}"#])
        XCTAssertEqual(try SubscriptionVerificationService.proVerifiedUntil(customer, now: now),
                       now.addingTimeInterval(300))
    }

    /// The identifier the backend used before 25 September 2026. RevenueCat has no
    /// entitlement by that name, so an active one must not grant Pro on its own.
    func testAnActiveEntitlementNamedOnlyProIsFree() throws {
        let customer = try subscriber(entitlements: ["pro": active(for: 30 * 86_400)])
        XCTAssertNil(try SubscriptionVerificationService.proVerifiedUntil(customer, now: now))
    }

    func testTheIdentifierMatchIsExact() throws {
        for key in ["snaglist pro", "SNAGLIST PRO", "Snaglist Pro ", " Snaglist Pro", "SnaglistPro", "Snaglist_Pro", "Pro"] {
            let customer = try subscriber(entitlements: [key: active(for: 30 * 86_400)])
            XCTAssertNil(try SubscriptionVerificationService.proVerifiedUntil(customer, now: now), key)
        }
    }

    func testAnExpiredSnaglistProIsFreeEvenBesideAnActivePro() throws {
        let customer = try subscriber(entitlements: ["Snaglist Pro": active(for: -60), "pro": active(for: 30 * 86_400)])
        XCTAssertNil(try SubscriptionVerificationService.proVerifiedUntil(customer, now: now))
    }

    func testNoEntitlementsIsFree() throws {
        XCTAssertNil(try SubscriptionVerificationService.proVerifiedUntil(try subscriber(entitlements: [:]), now: now))
    }

    /// One entitlement object as RevenueCat v1 returns it, expiring `offset` seconds from `now`.
    private func active(for offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: now.addingTimeInterval(offset))
        let purchase = formatter.string(from: now.addingTimeInterval(-86_400))
        return #"{"expires_date":"\#(expiry)","grace_period_expires_date":null,"product_identifier":"synthetic_pro_monthly","purchase_date":"\#(purchase)"}"#
    }

    /// A synthetic `GET /v1/subscribers/{app_user_id}` body in RevenueCat's v1 shape.
    /// No real customer, receipt or transaction.
    private func subscriber(entitlements: [String: String]) throws -> SubscriptionVerificationService.Customer {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: now.addingTimeInterval(30 * 86_400))
        let purchase = formatter.string(from: now.addingTimeInterval(-86_400))
        // Keys here never contain a quote or backslash, so they need no escaping.
        let keyed = entitlements.keys.sorted().map { "\"\($0)\":" + entitlements[$0]! }.joined(separator: ",")
        let json = """
            {"request_date":"\(formatter.string(from: now))","request_date_ms":\(Int(now.timeIntervalSince1970 * 1000)),
             "subscriber":{"entitlements":{\(keyed)},
              "first_seen":"\(purchase)","last_seen":"\(purchase)","management_url":null,"non_subscriptions":{},
              "original_app_user_id":"00000000-0000-4000-8000-000000000000","original_application_version":null,
              "original_purchase_date":null,"other_purchases":{},
              "subscriptions":{"synthetic_pro_monthly":{"auto_resume_date":null,"billing_issues_detected_at":null,
                "expires_date":"\(expiry)","grace_period_expires_date":null,"is_sandbox":true,
                "original_purchase_date":"\(purchase)","ownership_type":"PURCHASED","period_type":"normal",
                "purchase_date":"\(purchase)","refunded_at":null,"store":"app_store",
                "store_transaction_id":"synthetic-0","unsubscribe_detected_at":null}}}}
            """
        return try JSONDecoder().decode(SubscriptionVerificationService.Customer.self, from: Data(json.utf8))
    }
}
