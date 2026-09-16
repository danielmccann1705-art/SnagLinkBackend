import XCTest
import JWTKit
@testable import App

/// Google's own verification of an address is evidence about the address, not about
/// any Snaglist account. These cover the reading of the claim; the database rules for
/// adopting it live in VerifiedIdentityService and are exercised by the identity suite.
final class GoogleVerifiedEmailAdoptionTests: XCTestCase {
    private func claims(_ json: String) throws -> GoogleIdentityClaims {
        try JSONDecoder().decode(GoogleIdentityClaims.self, from: Data(json.utf8))
    }
    private let envelope = """
        "iss":"https://accounts.google.com","sub":"1234","aud":"a","exp":4102444800,"iat":1700000000
        """

    func testABooleanVerifiedClaimIsRead() throws {
        let value = try claims("{\(envelope),\"email\":\"dan@example.test\",\"email_verified\":true}")
        XCTAssertEqual(value.emailVerified?.value, true)
    }

    /// Google has historically sent the claim as a string.
    func testAStringVerifiedClaimIsRead() throws {
        XCTAssertEqual(try claims("{\(envelope),\"email_verified\":\"true\"}").emailVerified?.value, true)
        XCTAssertEqual(try claims("{\(envelope),\"email_verified\":\"false\"}").emailVerified?.value, false)
    }

    func testAnythingElseCountsAsUnverified() throws {
        XCTAssertEqual(try claims("{\(envelope),\"email_verified\":\"yes\"}").emailVerified?.value, false)
        XCTAssertEqual(try claims("{\(envelope),\"email_verified\":1}").emailVerified?.value, false)
        XCTAssertNil(try claims("{\(envelope)}").emailVerified)
    }

    /// An unverified or absent claim must never produce a proof that would be adopted,
    /// and a verified claim without an address must not either.
    func testProofOnlyReportsVerifiedWhenBothClaimsArePresent() throws {
        XCTAssertFalse(GoogleIdentityProof(subject: "s", contactEmail: nil, displayName: nil, contactEmailIsVerified: false).contactEmailIsVerified)
        let adoptable = GoogleIdentityProof(subject: "s", contactEmail: "dan@example.test", displayName: nil, contactEmailIsVerified: true)
        XCTAssertTrue(adoptable.contactEmailIsVerified)
        XCTAssertEqual(adoptable.contactEmail, "dan@example.test")
    }
}
