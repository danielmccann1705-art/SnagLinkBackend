import Fluent
import Vapor

final class Trade: Model, Content, @unchecked Sendable {
    static let schema = "trades"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "color_hex")
    var colorHex: String

    @Field(key: "sort_order")
    var sortOrder: Int

    @Field(key: "is_archived")
    var isArchived: Bool

    @Field(key: "is_default")
    var isDefault: Bool

    @Field(key: "owner_id")
    var ownerId: UUID

    @OptionalField(key: "workspace_id") var workspaceId: UUID?
    @Field(key: "revision") var revision: Int64
    @Field(key: "platform_managed") var platformManaged: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        colorHex: String,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        isDefault: Bool = false,
        ownerId: UUID
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.isDefault = isDefault
        self.ownerId = ownerId
        self.revision = 1
        self.platformManaged = false
    }
}
