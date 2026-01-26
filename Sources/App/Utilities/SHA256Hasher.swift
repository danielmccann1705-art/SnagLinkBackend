import Foundation
import Crypto

struct SHA256Hasher {
    /// Hashes a PIN with a salt using SHA256
    /// - Parameters:
    ///   - pin: The PIN to hash
    ///   - salt: The salt to use
    /// - Returns: Hex-encoded hash string
    static func hash(pin: String, salt: String) -> String {
        let input = "\(salt)\(pin)"
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verifies a PIN against a stored hash using constant-time comparison
    /// - Parameters:
    ///   - pin: The PIN to verify
    ///   - salt: The salt used during hashing
    ///   - storedHash: The stored hash to compare against
    /// - Returns: true if PIN is correct, false otherwise
    static func verify(pin: String, salt: String, storedHash: String) -> Bool {
        let computedHash = hash(pin: pin, salt: salt)
        return ConstantTimeComparison.compare(computedHash, storedHash)
    }
}
