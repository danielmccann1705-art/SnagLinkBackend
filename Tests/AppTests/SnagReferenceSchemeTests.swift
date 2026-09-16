import XCTest
@testable import App

/// A register keeps one numbering scheme. Imported snags keep the references they arrived
/// with, so a snag logged afterwards continues that shape instead of starting "SL4" beside
/// WC-015-001. These cover the shape reading; the database rules for skipping a reference
/// already used live in `SnagReferenceScheme.next` and are exercised by the mutation suite.
final class SnagReferenceSchemeTests: XCTestCase {

    func testAnImportedRegisterKeepsItsPrefixAndPadding() throws {
        let scheme = try XCTUnwrap(SnagReferenceScheme(references: ["WC-015-001", "WC-015-002", "WC-015-003"]))
        XCTAssertEqual(scheme.prefix, "WC-015-")
        XCTAssertEqual(scheme.width, 3)
        XCTAssertEqual(scheme.highest, 3)
        XCTAssertEqual(scheme.reference(4), "WC-015-004")
        XCTAssertEqual(scheme.reference(1000), "WC-015-1000", "padding never truncates a number that has outgrown it")
    }

    func testARegisterCreatedHereCarriesOnAsItWas() throws {
        let scheme = try XCTUnwrap(SnagReferenceScheme(references: ["SL1", "SL2", "SL3"]))
        XCTAssertEqual(scheme.reference(4), "SL4", "the platform's own scheme is just another shape")
    }

    /// Widths that disagree are not a padding rule, so nothing is padded.
    func testMixedWidthsPadNothing() throws {
        let scheme = try XCTUnwrap(SnagReferenceScheme(references: ["SL8", "SL9", "SL10"]))
        XCTAssertEqual(scheme.width, 0)
        XCTAssertEqual(scheme.reference(11), "SL11")
    }

    /// One stray reference must not freeze the register's shape forever.
    func testAStrayReferenceDoesNotUnseatTheMajority() throws {
        let scheme = try XCTUnwrap(SnagReferenceScheme(references: ["WC-015-001", "WC-015-002", "WC-015-003", "SL4"]))
        XCTAssertEqual(scheme.prefix, "WC-015-")
        XCTAssertEqual(scheme.reference(5), "WC-015-005")
    }

    func testAnEvenSplitHasNoShape() {
        XCTAssertNil(SnagReferenceScheme(references: ["WC-015-001", "SL2"]))
    }

    func testAnEmptyRegisterHasNoShape() {
        XCTAssertNil(SnagReferenceScheme(references: []))
        XCTAssertNil(SnagReferenceScheme(references: ["", ""]))
    }

    /// References with no trailing number cannot be continued.
    func testFreeTextReferencesHaveNoShape() {
        XCTAssertNil(SnagReferenceScheme(references: ["Kitchen", "Hallway", "Landing"]))
    }

    /// The highest number already used decides the next one, not the count. An imported
    /// register with gaps must not hand out a reference that is already on site.
    func testTheNextNumberClearsTheHighestAlreadyUsed() throws {
        let scheme = try XCTUnwrap(SnagReferenceScheme(references: ["WC-015-010", "WC-015-011", "WC-015-012"]))
        XCTAssertEqual(scheme.highest, 12)
        XCTAssertEqual(scheme.reference(max(4, scheme.highest + 1)), "WC-015-013")
    }

    /// A number long enough to be a date or an identifier is not a register number.
    func testAnAbsurdlyLongNumberIsIgnored() {
        XCTAssertNil(SnagReferenceScheme(references: ["REF-1234567890123", "REF-1234567890124"]))
    }
}
