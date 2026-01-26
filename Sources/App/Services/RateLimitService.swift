import Vapor
import Fluent

enum RateLimitAction: String {
    case tokenLookup = "token_lookup"
    case pinAttempt = "pin_attempt"
    case apiCall = "api_call"

    var limit: Int {
        switch self {
        case .tokenLookup: return 20
        case .pinAttempt: return 5
        case .apiCall: return 100
        }
    }

    var windowSeconds: Int {
        switch self {
        case .tokenLookup: return 60      // 1 minute
        case .pinAttempt: return 300      // 5 minutes
        case .apiCall: return 60          // 1 minute
        }
    }
}

struct RateLimitService {
    /// Checks if a request should be rate limited (database-backed)
    /// - Parameters:
    ///   - key: The rate limit key (usually IP address or user ID)
    ///   - action: The action being rate limited
    ///   - db: Database connection
    /// - Returns: Tuple of (isAllowed, remaining attempts, reset time)
    static func check(
        key: String,
        action: RateLimitAction,
        on db: Database
    ) async throws -> (allowed: Bool, remaining: Int, resetAt: Date) {
        let now = Date()

        // Find existing entry for this key and action within the current window
        let existingEntry = try await RateLimitEntry.query(on: db)
            .filter(\.$key == key)
            .filter(\.$action == action.rawValue)
            .filter(\.$windowEnd > now)
            .first()

        if let entry = existingEntry {
            // Check if limit exceeded
            if entry.count >= action.limit {
                return (false, 0, entry.windowEnd)
            }

            // Increment count
            entry.count += 1
            try await entry.save(on: db)

            let remaining = action.limit - entry.count
            return (true, remaining, entry.windowEnd)
        } else {
            // Create new entry
            let windowEnd = now.addingTimeInterval(TimeInterval(action.windowSeconds))
            let entry = RateLimitEntry(
                key: key,
                action: action.rawValue,
                windowStart: now,
                windowEnd: windowEnd
            )
            try await entry.save(on: db)

            let remaining = action.limit - 1
            return (true, remaining, windowEnd)
        }
    }

    /// Enforces rate limiting, throwing an error if limit exceeded
    /// - Parameters:
    ///   - key: The rate limit key
    ///   - action: The action being rate limited
    ///   - db: Database connection
    /// - Throws: Abort error if rate limit exceeded
    static func enforce(
        key: String,
        action: RateLimitAction,
        on db: Database
    ) async throws {
        let result = try await check(key: key, action: action, on: db)

        if !result.allowed {
            let retryAfter = Int(result.resetAt.timeIntervalSince(Date()))
            var headers = HTTPHeaders()
            headers.add(name: "Retry-After", value: String(retryAfter))
            headers.add(name: "X-RateLimit-Limit", value: String(action.limit))
            headers.add(name: "X-RateLimit-Remaining", value: "0")
            headers.add(name: "X-RateLimit-Reset", value: String(Int(result.resetAt.timeIntervalSince1970)))

            throw Abort(.tooManyRequests, headers: headers, reason: "Rate limit exceeded. Try again in \(retryAfter) seconds.")
        }
    }

    /// Cleans up expired rate limit entries
    /// - Parameter db: Database connection
    static func cleanup(on db: Database) async throws {
        try await RateLimitEntry.query(on: db)
            .filter(\.$windowEnd < Date())
            .delete()
    }
}
