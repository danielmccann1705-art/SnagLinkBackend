import Foundation

struct ConstantTimeComparison {
    /// Performs a constant-time comparison of two strings to prevent timing attacks
    /// - Parameters:
    ///   - a: First string to compare
    ///   - b: Second string to compare
    /// - Returns: true if strings are equal, false otherwise
    static func compare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        // If lengths differ, we still compare to avoid timing leaks
        // but we know the result will be false
        let length = max(aBytes.count, bBytes.count)

        var result: UInt8 = 0

        // XOR all bytes together - any difference will set bits in result
        for i in 0..<length {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            result |= aByte ^ bByte
        }

        // Also check length equality (constant time)
        // This XOR will be non-zero if lengths differ
        let lengthDiff = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        result |= lengthDiff

        return result == 0
    }

    /// Performs a constant-time comparison of two Data objects
    /// - Parameters:
    ///   - a: First Data to compare
    ///   - b: Second Data to compare
    /// - Returns: true if data is equal, false otherwise
    static func compare(_ a: Data, _ b: Data) -> Bool {
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)

        let length = max(aBytes.count, bBytes.count)

        var result: UInt8 = 0

        for i in 0..<length {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            result |= aByte ^ bByte
        }

        let lengthDiff = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        result |= lengthDiff

        return result == 0
    }
}
