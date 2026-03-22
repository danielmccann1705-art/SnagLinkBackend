import Fluent
import Vapor

final class Team: Model, Content, @unchecked Sendable {
    static let schema = "teams"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "owner_user_id")
    var ownerUserId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, ownerUserId: UUID) {
        self.id = id
        self.name = name
        self.ownerUserId = ownerUserId
    }
}
