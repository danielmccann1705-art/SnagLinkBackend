import Vapor

struct UpdateUserProfileRequest: Content {
    let name: String?
    let email: String?
    /// B4: client pushes its RevenueCat entitlement ("free"/"pro") here after purchase/restore.
    let subscriptionTier: String?
}

/// B4: magic-link allowance snapshot for the free-tier meter (`GET /users/me/usage`).
struct UsageResponse: Content {
    let linksRemainingThisMonth: Int
    let monthlyResetDate: Date
    let tier: String
    let onboardingLinkConsumed: Bool
}

struct UserProfileResponse: Content {
    let id: UUID
    /// Nil for magic-link accounts.
    let appleUserId: String?
    let authProvider: String
    let subscriptionTier: String
    let onboardingLinkConsumed: Bool
    let email: String?
    let name: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from user: User) {
        self.id = user.id!
        self.appleUserId = user.appleUserId
        self.authProvider = user.authProvider
        self.subscriptionTier = user.subscriptionTier
        self.onboardingLinkConsumed = user.onboardingLinkConsumed
        self.email = user.email
        self.name = user.name
        self.createdAt = user.createdAt
        self.updatedAt = user.updatedAt
    }
}
