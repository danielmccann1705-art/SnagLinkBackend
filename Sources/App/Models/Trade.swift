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
    }
}
