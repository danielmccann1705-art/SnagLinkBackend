import Fluent
import Vapor

enum AuditEventType: String, Codable {
    case magicLinkCreated = "magic_link.created"
    case magicLinkValidated = "magic_link.validated"
    case magicLinkRevoked = "magic_link.revoked"
    case pinVerifySuccess = "pin.verify.success"
    case pinVerifyFailure = "pin.verify.failure"
    case pinLockout = "pin.lockout"
    case teamInviteCreated = "team_invite.created"
    case teamInviteAccepted = "team_invite.accepted"
    case teamInviteDeclined = "team_invite.declined"
    case teamInviteRevoked = "team_invite.revoked"
    case rateLimitExceeded = "rate_limit.exceeded"
}

enum ResourceType: String, Codable {
    case magicLink = "magic_link"
    case teamInvite = "team_invite"
    case user
}

final class AuditLog: Model, Content, @unchecked Sendable {
    static let schema = "audit_logs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "resource_type")
    var resourceType: String

    @OptionalField(key: "resource_id")
    var resourceId: UUID?

    @OptionalField(key: "user_id")
    var userId: UUID?

    @Field(key: "ip_address")
    var ipAddress: String

    @OptionalField(key: "user_agent")
    var userAgent: String?

    @Field(key: "success")
    var success: Bool

    @OptionalField(key: "details")
    var details: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        eventType: AuditEventType,
        resourceType: ResourceType,
        resourceId: UUID? = nil,
        userId: UUID? = nil,
        ipAddress: String,
        userAgent: String? = nil,
        success: Bool,
        details: String? = nil
    ) {
        self.id = id
        self.eventType = eventType.rawValue
        self.resourceType = resourceType.rawValue
        self.resourceId = resourceId
        self.userId = userId
        self.ipAddress = ipAddress
        self.userAgent = userAgent
        self.success = success
        self.details = details
    }
}
