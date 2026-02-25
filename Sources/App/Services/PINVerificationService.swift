import Vapor
import Fluent

struct PINVerificationService {
    static let maxAttempts = 5
    static let lockoutDuration: TimeInterval = 60 * 60 // 1 hour

    /// Verifies a PIN for a magic link with brute-force protection.
    /// Supports both bcrypt (new) and SHA256 (legacy) hashes.
    /// Legacy hashes are transparently upgraded to bcrypt on successful verification.
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

        guard let pinHash = magicLink.pinHash else {
            throw Abort(.badRequest, reason: "This magic link does not require a PIN")
        }

        // Determine hash type and verify accordingly
        let isValid: Bool
        let isLegacyHash = !pinHash.hasPrefix("$2")

        if isLegacyHash {
            // Legacy SHA256 verification (requires pinSalt)
            guard let pinSalt = magicLink.pinSalt else {
                throw Abort(.badRequest, reason: "This magic link does not require a PIN")
            }
            isValid = SHA256Hasher.verify(pin: pin, salt: pinSalt, storedHash: pinHash)
        } else {
            // Bcrypt verification
            isValid = try Bcrypt.verify(pin, created: pinHash)
        }

        if isValid {
            // Reset failed attempts on success
            magicLink.failedPinAttempts = 0
            magicLink.lockedUntil = nil

            // Transparently upgrade legacy SHA256 hash to bcrypt
            if isLegacyHash {
                magicLink.pinHash = try Bcrypt.hash(pin)
                magicLink.pinSalt = nil
            }

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
                throw Abort(.tooManyRequests, reason: "Too many failed attempts. Try again later.")
            }
        }
    }

    /// Hashes a new PIN using bcrypt
    static func hashPIN(_ pin: String) throws -> (hash: String, salt: String?) {
        let hash = try Bcrypt.hash(pin)
        return (hash, nil)
    }
}
