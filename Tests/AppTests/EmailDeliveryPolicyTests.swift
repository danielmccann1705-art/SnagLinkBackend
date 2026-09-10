import XCTest
@testable import App

final class EmailDeliveryPolicyTests: XCTestCase {
    func testStagingCannotDeliverToAnUnapprovedAddress() {
        let approved = "reviewer@example.com"
        XCTAssertTrue(EmailDeliveryPolicy.allows(" REVIEWER@example.com ", configuredRecipients: approved))
        for recipient in ["customer@example.com", "reviewer+other@example.com", "reviewer@example.com.evil", "reviewer@example.com,customer@example.com", ""] {
            XCTAssertFalse(EmailDeliveryPolicy.allows(recipient, configuredRecipients: approved))
        }
    }

    func testAnExplicitEmptyListDisablesDelivery() {
        for setting in ["", " ", ", ,"] {
            XCTAssertFalse(EmailDeliveryPolicy.allows("reviewer@example.com", configuredRecipients: setting))
        }
    }

    func testAbsentRestrictionKeepsNormalDeliveryBehavior() {
        XCTAssertTrue(EmailDeliveryPolicy.allows("customer@example.com", configuredRecipients: nil))
    }
}
