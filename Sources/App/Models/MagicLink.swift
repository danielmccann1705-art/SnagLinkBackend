import Fluent
import Vapor

enum AccessLevel: String, Codable {
    case view
    case update
    case full
}

final class MagicLink: Model, Content, @unchecked Sendable {
    static let schema = "magic_links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "token")
    var token: String

    @Field(key: "access_level")
    var accessLevel: String

    @OptionalField(key: "pin_hash")
    var pinHash: String?

    @OptionalField(key: "pin_salt")
    var pinSalt: String?

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Field(key: "open_count")
    var openCount: Int

    @OptionalField(key: "last_opened_at")
    var lastOpenedAt: Date?

    @Field(key: "failed_pin_attempts")
    var failedPinAttempts: Int

    @OptionalField(key: "locked_until")
    var lockedUntil: Date?

    @Field(key: "snag_ids")
    var snagIds: [UUID]

    @Field(key: "project_id")
    var projectId: UUID

    @OptionalField(key: "contractor_id")
    var contractorId: UUID?

    @Field(key: "created_by_id")
    var createdById: UUID

    @OptionalField(key: "slug")
    var slug: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        token: String,
        accessLevel: AccessLevel,
        pinHash: String? = nil,
        pinSalt: String? = nil,
        expiresAt: Date,
        snagIds: [UUID],
        projectId: UUID,
        contractorId: UUID? = nil,
        createdById: UUID,
        slug: String? = nil
    ) {
        self.id = id
        self.token = token
        self.accessLevel = accessLevel.rawValue
        self.pinHash = pinHash
        self.pinSalt = pinSalt
        self.expiresAt = expiresAt
        self.openCount = 0
        self.failedPinAttempts = 0
        self.snagIds = snagIds
        self.projectId = projectId
        self.contractorId = contractorId
        self.createdById = createdById
        self.slug = slug
    }

    var isExpired: Bool {
        return Date() > expiresAt
    }

    var isRevoked: Bool {
        return revokedAt != nil
    }

    var isLocked: Bool {
        guard let lockedUntil = lockedUntil else { return false }
        return Date() < lockedUntil
    }

    var requiresPIN: Bool {
        return pinHash != nil && pinSalt != nil
    }
}
