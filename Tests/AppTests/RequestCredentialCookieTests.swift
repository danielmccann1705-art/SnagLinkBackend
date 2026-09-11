@testable import App
import XCTest

final class RequestCredentialCookieTests: XCTestCase {
    let cookieName = "__Host-snaglist_session"
    func testProviderJSONBeforeCredentialAndMultipleHeaders() {
        XCTAssertEqual(RequestCredentialCookie.value(cookieName, in: [#"g_state={"i_l":0,"i_ll":123}; __Host-snaglist_session=synthetic_token-123; other=ok"#]), "synthetic_token-123")
        XCTAssertEqual(RequestCredentialCookie.value(cookieName, in: [#"g_state={"i_l":0,"i_ll":123}"#, "\(cookieName)=synthetic"]), "synthetic")
    }
    func testAmbiguousMalformedQuotedAndLookalikeCredentialsFailClosed() {
        for headers in [["\(cookieName)=a; \(cookieName)=b"], ["\(cookieName)=a", "\(cookieName)=a"], ["\(cookieName)=\"quoted\""], ["\(cookieName)=value,other=one"], ["\(cookieName)"], ["\(cookieName)="], ["\(cookieName)=white space"], ["\(cookieName)=back\\slash"], ["\(cookieName)=é"], ["prefix\(cookieName)=value"], ["\(cookieName.lowercased())=value"], ["\(cookieName)=value\n"], ["\(cookieName)=value\r"]] {
            XCTAssertNil(RequestCredentialCookie.value(cookieName, in: headers))
        }
    }
    func testLegacyPINSignedValueRetainsItsFormatAndBounds() {
        XCTAssertEqual(RequestCredentialCookie.value("snaglist_pin", in: ["g_state={\"i_l\":0,\"i_ll\":123}; snaglist_pin=123456789:abc/+def=="]), "123456789:abc/+def==")
        XCTAssertNil(RequestCredentialCookie.value(cookieName, in: ["\(cookieName)=" + String(repeating: "a", count: 129)]))
        XCTAssertNil(RequestCredentialCookie.value(cookieName, in: ["other=" + String(repeating: "x", count: 32_768), "\(cookieName)=a"]))
    }
}
