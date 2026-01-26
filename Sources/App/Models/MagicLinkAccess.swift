import Fluent
import Vapor

final class MagicLinkAccess: Model, Content, @unchecked Sendable {
    static let schema = "magic_link_accesses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "magic_link_id")
    var magicLink: MagicLink

    @Field(key: "ip_address")
    var ipAddress: String

    @OptionalField(key: "user_agent")
    var userAgent: String?

    @OptionalField(key: "country")
    var country: String?

    @OptionalField(key: "city")
    var city: String?

    @Field(key: "pin_verified")
    var pinVerified: Bool

    @Timestamp(key: "accessed_at", on: .create)
    var accessedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        magicLinkId: UUID,
        ipAddress: String,
        userAgent: String? = nil,
        country: String? = nil,
        city: String? = nil,
        pinVerified: Bool = false
    ) {
        self.id = id
        self.$magicLink.id = magicLinkId
        self.ipAddress = ipAddress
        self.userAgent = userAgent
        self.country = country
        self.city = city
        self.pinVerified = pinVerified
    }
}
