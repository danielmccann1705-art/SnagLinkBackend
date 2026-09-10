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
}
