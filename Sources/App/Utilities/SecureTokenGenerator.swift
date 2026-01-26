import Foundation
import Vapor

struct SecureTokenGenerator {
    /// Generates a cryptographically secure random token
    /// - Parameter byteCount: Number of random bytes (default 32)
    /// - Returns: URL-safe base64 encoded token
    static func generate(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)

        guard status == errSecSuccess else {
            throw Abort(.internalServerError, reason: "Failed to generate secure random bytes")
        }

        // Convert to URL-safe base64
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a secure salt for PIN hashing
    /// - Parameter byteCount: Number of random bytes (default 16)
    /// - Returns: Hex-encoded salt string
    static func generateSalt(byteCount: Int = 16) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)

        guard status == errSecSuccess else {
            throw Abort(.internalServerError, reason: "Failed to generate secure salt")
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
