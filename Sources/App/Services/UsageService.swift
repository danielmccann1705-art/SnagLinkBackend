import Vapor
import Fluent

/// Magic-link allowance accounting for the free tier (B4).
/// The counter is a row-count of `magic_link_sends` in the current calendar month (UTC). The
/// exempt onboarding send does not create a row (it only flips `User.onboardingLinkConsumed`).
struct UsageService {
    /// Monthly magic-link allowance for free-tier users.
    static let freeMonthlyLimit = 5

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Midnight UTC on the 1st of the current month.
    static func startOfCurrentMonth(_ now: Date = Date()) -> Date {
        let cal = utcCalendar
        return cal.date(from: cal.dateComponents([.year, .month], from: now))!
    }

    /// Midnight UTC on the 1st of next month — when the free allowance resets.
    static func monthlyResetDate(_ now: Date = Date()) -> Date {
        utcCalendar.date(byAdding: .month, value: 1, to: startOfCurrentMonth(now))!
    }

    /// Counted sends for a user in the current calendar month.
    static func currentMonthSendCount(userId: UUID, on db: Database, now: Date = Date()) async throws -> Int {
        try await MagicLinkSend.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sentAt >= startOfCurrentMonth(now))
            .count()
    }

    /// Links remaining this month. Pro is unlimited — reports the full allowance (the client hides
    /// the meter for pro, so the exact number is not shown).
    static func linksRemaining(tier: SubscriptionTier, count: Int) -> Int {
        switch tier {
        case .pro: return freeMonthlyLimit
        case .free: return max(0, freeMonthlyLimit - count)
        }
    }

    static func buildUsage(user: User, on db: Database) async throws -> UsageResponse {
        let tier: SubscriptionTier = user.subscriptionTier == "pro" &&
            (user.subscriptionVerifiedUntil ?? .distantPast) > Date() ? .pro : .free
        let count = try await currentMonthSendCount(userId: user.id!, on: db)
        return UsageResponse(
            linksRemainingThisMonth: linksRemaining(tier: tier, count: count),
            monthlyResetDate: monthlyResetDate(),
            tier: tier.rawValue,
            onboardingLinkConsumed: user.onboardingLinkConsumed
        )
    }
}
