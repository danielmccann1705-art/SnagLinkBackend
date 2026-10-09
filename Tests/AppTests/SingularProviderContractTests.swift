@testable import App
import XCTest

/// The held Singular request shapes (SINGULAR-CONTROLS-OCT9.md). Pure: no network, no credential,
/// no database. They pin what was verified in Singular's documentation and refuse everything else.
final class SingularProviderContractTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_369_000)
    let subject = "6F1C1D2E-3A4B-4C5D-8E6F-7A8B9C0D1E2F"
    let sdid = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    func device(ip: String = "203.0.113.7", att: Int = 3) -> SingularServerEventContract.Device {
        .init(sdid: sdid, bundleID: "com.snaglist.app", osVersion: "27.0", ipAddress: ip, attAuthorizationStatus: att)
    }
    func fields(_ data: Data?) -> [String: String] {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            result[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return result
    }

    func testSignUpIsAFormEncodedV2EventKeyedBySDIDAndTheOpaqueSubject() {
        XCTAssertEqual(SingularServerEventContract.endpoint, "https://s2s.singular.net/api/v2/evt")
        XCTAssertEqual(SingularServerEventContract.contentType, "application/x-www-form-urlencoded")
        let body = SingularServerEventContract.formBody(sdkKey: "synthetic-sdk-key", device: device(),
            event: .init(name: .signUp, occurredAt: now, customUserID: subject, revenue: nil))
        let sent = fields(body)
        XCTAssertEqual(sent["n"], "sng_complete_registration")
        XCTAssertEqual(sent["p"], "iOS")
        XCTAssertEqual(sent["i"], "com.snaglist.app")
        XCTAssertEqual(sent["sdid"], sdid.lowercased())
        XCTAssertEqual(sent["custom_user_id"], subject.lowercased())
        XCTAssertEqual(sent["att_authorization_status"], "3")
        XCTAssertEqual(sent["utime"], "1791369000")
        XCTAssertEqual(sent["ip"], "203.0.113.7")
        XCTAssertNil(sent["amt"], "sign-up carries no money")
        XCTAssertNil(sent["is_revenue_event"])
        for absent in ["idfa", "idfv", "use_ip", "e", "data_sharing_options", "purchase_receipt"] {
            XCTAssertNil(sent[absent], "\(absent) is not part of the verified held shape")
        }
        XCTAssertFalse(String(data: body ?? Data(), encoding: .utf8)!.hasPrefix("{"), "never a JSON body")
    }

    func testSubscriptionEventsCarryOnlyVerifiedLedgerMoney() {
        let money = SingularServerEventContract.Revenue(amount: "59.99", currencyCode: "GBP",
                                                        productID: "pro_annual", transactionID: "2000000123456789")
        let sent = fields(SingularServerEventContract.formBody(sdkKey: "synthetic-sdk-key", device: device(),
            event: .init(name: .subscriptionStarted, occurredAt: now, customUserID: subject, revenue: money)))
        XCTAssertEqual(sent["n"], "sng_subscribe")
        XCTAssertEqual(sent["is_revenue_event"], "true")
        XCTAssertEqual(sent["amt"], "59.99")
        XCTAssertEqual(sent["cur"], "GBP")
        XCTAssertEqual(sent["purchase_transaction_id"], "2000000123456789")
        XCTAssertEqual(SingularServerEventContract.Name.subscriptionRenewed.rawValue, "subscription_renewed")
    }

    func testUnverifiableRequestsAreRefusedRatherThanGuessed() {
        let money = SingularServerEventContract.Revenue(amount: "4.99", currencyCode: "GBP", productID: "p", transactionID: "t")
        let sign = SingularServerEventContract.Event(name: .signUp, occurredAt: now, customUserID: subject, revenue: nil)
        let paid = SingularServerEventContract.Event(name: .subscriptionStarted, occurredAt: now, customUserID: subject, revenue: money)
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "", device: device(), event: sign), "no key")
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(ip: ""), event: sign), "no device IP: server IP is never substituted")
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(ip: "2001:db8::1"), event: sign))
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(ip: "256.1.1.1"), event: sign))
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(att: 4), event: sign))
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: .init(sdid: "not-a-uuid", bundleID: "com.snaglist.app",
            osVersion: "27.0", ipAddress: "203.0.113.7", attAuthorizationStatus: 3), event: sign))
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(),
            event: .init(name: .signUp, occurredAt: now, customUserID: subject, revenue: money)), "sign-up never carries money")
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(),
            event: .init(name: .subscriptionRenewed, occurredAt: now, customUserID: subject, revenue: nil)), "money events need ledger money")
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(),
            event: .init(name: .signUp, occurredAt: now, customUserID: "person@example.test", revenue: nil)), "no PII as custom user ID")
        for bad in ["-1", "0", "1,99", "£4.99", "4.99 "] {
            let wrong = SingularServerEventContract.Revenue(amount: bad, currencyCode: "GBP", productID: "p", transactionID: "t")
            XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(),
                event: .init(name: .subscriptionStarted, occurredAt: now, customUserID: subject, revenue: wrong)), bad)
        }
        let lower = SingularServerEventContract.Revenue(amount: "4.99", currencyCode: "gbp", productID: "p", transactionID: "t")
        XCTAssertNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(),
            event: .init(name: .subscriptionStarted, occurredAt: now, customUserID: subject, revenue: lower)))
        XCTAssertNotNil(SingularServerEventContract.formBody(sdkKey: "k", device: device(), event: paid))
    }

    func testOpenDSRErasureUsesTheCustomUserIDNeverTheSDID() throws {
        let request = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let data = try XCTUnwrap(SingularOpenDSRContract.erasureRequestBody(requestID: request, submittedAt: now, customUserID: subject))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["subject_request_id"] as? String, request.uuidString.lowercased())
        XCTAssertEqual(body["subject_request_type"] as? String, "erasure")
        XCTAssertEqual(body["property_id"] as? String, "iOS:com.snaglist.app")
        XCTAssertNotNil(body["submitted_time"] as? String)
        let identities = try XCTUnwrap(body["subject_identities"] as? [[String: String]])
        XCTAssertEqual(identities, [["identity_type": "user_id", "identity_value": subject.lowercased(), "identity_format": "raw"]])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains(sdid.lowercased()))
        XCTAssertNil(SingularOpenDSRContract.erasureRequestBody(requestID: request, submittedAt: now, customUserID: "person@example.test"))
    }

    func testAcceptanceIsNeverCompletionAndOnlyAMatchingCompletedStatusCloses() {
        let request = UUID()
        let other = UUID()
        func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let id = request.uuidString.lowercased()

        XCTAssertEqual(SingularOpenDSRContract.classifySubmission(status: 201,
            body: json(["subject_request_id": id, "expected_completion_time": "2026-11-08T00:00:00Z"]), requestID: request),
            .accepted(expectedCompletion: "2026-11-08T00:00:00Z"))
        XCTAssertEqual(SingularOpenDSRContract.classifySubmission(status: 200, body: Data(), requestID: request), .manual,
                       "a bare 2xx is not a receipt")
        XCTAssertEqual(SingularOpenDSRContract.classifySubmission(status: 200,
            body: json(["subject_request_id": other.uuidString]), requestID: request), .manual)
        XCTAssertEqual(SingularOpenDSRContract.classifySubmission(status: 404, body: Data(), requestID: request), .manual,
                       "404 is never treated as already erased")

        XCTAssertEqual(SingularOpenDSRContract.classifyStatus(status: 200,
            body: json(["subject_request_id": id, "request_status": "pending"]), requestID: request), .pending)
        XCTAssertEqual(SingularOpenDSRContract.classifyStatus(status: 200,
            body: json(["subject_request_id": id, "request_status": "completed"]), requestID: request), .completed)
        XCTAssertEqual(SingularOpenDSRContract.classifyStatus(status: 200,
            body: json(["subject_request_id": other.uuidString, "request_status": "completed"]), requestID: request), .manual)
        for unknown in ["in_progress", "cancelled", "COMPLETED", ""] {
            XCTAssertEqual(SingularOpenDSRContract.classifyStatus(status: 200,
                body: json(["subject_request_id": id, "request_status": unknown]), requestID: request), .manual, unknown)
        }
        XCTAssertEqual(SingularOpenDSRContract.classifyStatus(status: 500,
            body: json(["subject_request_id": id, "request_status": "completed"]), requestID: request), .manual)
    }
}
