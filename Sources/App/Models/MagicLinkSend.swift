import Fluent
import Vapor

/// A counted magic-link send (B4). One row per counted send; the free tier allows 5 per calendar
/// month. The exempt onboarding send does NOT create a row (it only flips
/// `User.onboardingLinkConsumed`), so a monthly row-count is the counter.
final class MagicLinkSend: Model, Content, @unchecked Sendable {
    static let schema = "magic_link_sends"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "magic_link_id")
    var magicLinkId: UUID

    @Timestamp(key: "sent_at", on: .create)
    var sentAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, magicLinkId: UUID) {
        self.id = id
        self.userId = userId
        self.magicLinkId = magicLinkId
    }
}
