import Vapor
import Fluent

struct PINVerificationService {
    static let maxAttempts = 5
    static let lockoutDuration: TimeInterval = 5 * 60 // 5 minutes

    /// Verifies a PIN for a magic link with brute-force protection
    /// - Parameters:
    ///   - pin: The PIN to verify
    ///   - magicLink: The magic link to verify against
    ///   - db: Database connection
    /// - Returns: true if PIN is correct and link is not locked
    /// - Throws: Abort error if link is locked or PIN is incorrect
    static func verify(
        pin: String,
        magicLink: MagicLink,
        on db: Database
    ) async throws -> Bool {
        // Check if link is locked
        if magicLink.isLocked {
            let remainingTime = magicLink.lockedUntil!.timeIntervalSince(Date())
            let minutes = Int(ceil(remainingTime / 60))
            throw Abort(.tooManyRequests, reason: "Too many failed attempts. Try again in \(minutes) minute(s).")
        }

        // Verify PIN requires both hash and salt
        guard let pinHash = magicLink.pinHash, let pinSalt = magicLink.pinSalt else {
            throw Abort(.badRequest, reason: "This magic link does not require a PIN")
        }

        // Verify the PIN using constant-time comparison
        let isValid = SHA256Hasher.verify(pin: pin, salt: pinSalt, storedHash: pinHash)

        if isValid {
            // Reset failed attempts on success
            magicLink.failedPinAttempts = 0
            magicLink.lockedUntil = nil
            try await magicLink.save(on: db)
            return true
        } else {
            // Increment failed attempts
            magicLink.failedPinAttempts += 1

            // Lock if max attempts reached
            if magicLink.failedPinAttempts >= maxAttempts {
                magicLink.lockedUntil = Date().addingTimeInterval(lockoutDuration)
            }

            try await magicLink.save(on: db)

            let attemptsRemaining = maxAttempts - magicLink.failedPinAttempts
            if attemptsRemaining > 0 {
                throw Abort(.unauthorized, reason: "Invalid PIN. \(attemptsRemaining) attempt(s) remaining.")
            } else {
                throw Abort(.tooManyRequests, reason: "Too many failed attempts. Try again in 5 minutes.")
            }
        }
    }

    /// Hashes a new PIN with a generated salt
    /// - Parameter pin: The PIN to hash
    /// - Returns: Tuple of (hash, salt)
    static func hashPIN(_ pin: String) throws -> (hash: String, salt: String) {
        let salt = try SecureTokenGenerator.generateSalt()
        let hash = SHA256Hasher.hash(pin: pin, salt: salt)
        return (hash, salt)
    }
}
