@testable import App
import XCTVapor
import Foundation

final class AppTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testHealthEndpoint() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }
}

// MARK: - Unit Tests for Utilities

final class SecureTokenGeneratorTests: XCTestCase {
    func testGeneratesURLSafeTokens() throws {
        let token = try SecureTokenGenerator.generate()

        // Should not contain URL-unsafe characters
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))

        // Should be reasonably long (32 bytes = ~43 base64 chars)
        XCTAssertGreaterThanOrEqual(token.count, 40)
    }

    func testGeneratesUniqueTokens() throws {
        let token1 = try SecureTokenGenerator.generate()
        let token2 = try SecureTokenGenerator.generate()

        XCTAssertNotEqual(token1, token2)
    }

    func testGeneratesSaltInHexFormat() throws {
        let salt = try SecureTokenGenerator.generateSalt()

        // 16 bytes = 32 hex characters
        XCTAssertEqual(salt.count, 32)

        // Should only contain hex characters
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(salt.unicodeScalars.allSatisfy { hexCharacters.contains($0) })
    }
}

final class ConstantTimeComparisonTests: XCTestCase {
    func testEqualStringsReturnTrue() {
        let result = ConstantTimeComparison.compare("hello", "hello")
        XCTAssertTrue(result)
    }

    func testDifferentStringsReturnFalse() {
        let result = ConstantTimeComparison.compare("hello", "world")
        XCTAssertFalse(result)
    }

    func testDifferentLengthStringsReturnFalse() {
        let result = ConstantTimeComparison.compare("hello", "hello!")
        XCTAssertFalse(result)
    }

    func testEmptyStringsAreEqual() {
        let result = ConstantTimeComparison.compare("", "")
        XCTAssertTrue(result)
    }
}

final class SHA256HasherTests: XCTestCase {
    func testHashesPINWithSalt() {
        let hash = SHA256Hasher.hash(pin: "1234", salt: "testsalt")

        // SHA256 produces 64 hex characters
        XCTAssertEqual(hash.count, 64)
    }

    func testSameInputProducesSameHash() {
        let hash1 = SHA256Hasher.hash(pin: "1234", salt: "testsalt")
        let hash2 = SHA256Hasher.hash(pin: "1234", salt: "testsalt")

        XCTAssertEqual(hash1, hash2)
    }

    func testDifferentSaltProducesDifferentHash() {
        let hash1 = SHA256Hasher.hash(pin: "1234", salt: "salt1")
        let hash2 = SHA256Hasher.hash(pin: "1234", salt: "salt2")

        XCTAssertNotEqual(hash1, hash2)
    }

    func testVerifyReturnsTrueForCorrectPIN() {
        let salt = "testsalt123"
        let pin = "5678"
        let hash = SHA256Hasher.hash(pin: pin, salt: salt)

        let result = SHA256Hasher.verify(pin: pin, salt: salt, storedHash: hash)
        XCTAssertTrue(result)
    }

    func testVerifyReturnsFalseForIncorrectPIN() {
        let salt = "testsalt123"
        let hash = SHA256Hasher.hash(pin: "5678", salt: salt)

        let result = SHA256Hasher.verify(pin: "1234", salt: salt, storedHash: hash)
        XCTAssertFalse(result)
    }
}
