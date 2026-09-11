import Fluent
import Vapor

/// How a user account was created / authenticates.
enum AuthProvider: String, Codable {
    case apple
    case magicLink = "magic_link"
    case google
}

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    /// Apple's stable subject identifier. Nil for accounts created via magic-link sign-in.
    @OptionalField(key: "apple_user_id")
    var appleUserId: String?

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "name")
    var name: String?

    /// How the account was created. Defaults to `apple` for legacy rows.
    @Field(key: "auth_provider")
    var authProvider: String

    @Field(key: "lifecycle_state")
    var lifecycleState: String

    @Field(key: "auth_version")
    var authVersion: Int

    /// Cached server-verified subscription tier, never assigned from a client claim.
    @Field(key: "subscription_tier")
    var subscriptionTier: String

    @OptionalField(key: "subscription_verified_until")
    var subscriptionVerifiedUntil: Date?

    /// Flips true on the user's first magic-link send and never resets. That first
    /// (onboarding) send is exempt from the monthly counter (B4).
    @Field(key: "onboarding_link_consumed")
    var onboardingLinkConsumed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    /// Sign in with Apple account.
    init(id: UUID? = nil, appleUserId: String, email: String?, name: String?) {
        self.id = id
        self.appleUserId = appleUserId
        self.email = email
        self.name = name
        self.authProvider = AuthProvider.apple.rawValue
        self.lifecycleState = "active"
        self.authVersion = 0
        self.subscriptionTier = SubscriptionTier.free.rawValue
        self.onboardingLinkConsumed = false
    }

    /// Generic initializer supporting any auth provider (e.g. magic-link accounts).
    init(
        id: UUID? = nil,
        appleUserId: String?,
        email: String?,
        name: String?,
        authProvider: AuthProvider
    ) {
        self.id = id
        self.appleUserId = appleUserId
        self.email = email
        self.name = name
        self.authProvider = authProvider.rawValue
        self.lifecycleState = "active"
        self.authVersion = 0
        self.subscriptionTier = SubscriptionTier.free.rawValue
        self.onboardingLinkConsumed = false
    }
}

/// Subscription tier for magic-link allowance (B4).
enum SubscriptionTier: String, Codable {
    case free
    case pro
}
