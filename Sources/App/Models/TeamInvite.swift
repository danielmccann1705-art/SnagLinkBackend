import Fluent
import Vapor

enum TeamRole: String, Codable {
    case admin
    case editor
    case viewer
}

enum InviteStatus: String, Codable {
    case pending
    case accepted
    case declined
    case expired
    case revoked
}

final class TeamInvite: Model, Content, @unchecked Sendable {
    static let schema = "team_invites"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "role")
    var role: String

    @Field(key: "status")
    var status: String

    @Field(key: "token")
    var token: String

    @Field(key: "team_id")
    var teamId: UUID

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "invited_by_user_id")
    var invitedByUserId: UUID?

    @OptionalField(key: "invited_by_name")
    var invitedByName: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        role: TeamRole,
        token: String,
        teamId: UUID,
        expiresAt: Date,
        invitedByUserId: UUID? = nil,
        invitedByName: String? = nil
    ) {
        self.id = id
        self.email = email
        self.role = role.rawValue
        self.status = InviteStatus.pending.rawValue
        self.token = token
        self.teamId = teamId
        self.expiresAt = expiresAt
        self.invitedByUserId = invitedByUserId
        self.invitedByName = invitedByName
    }

    var isExpired: Bool {
        return Date() > expiresAt
    }

    var isPending: Bool {
        return status == InviteStatus.pending.rawValue
    }
}
