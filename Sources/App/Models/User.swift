import Fluent
import Vapor

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "apple_user_id")
    var appleUserId: String

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "name")
    var name: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, appleUserId: String, email: String?, name: String?) {
        self.id = id
        self.appleUserId = appleUserId
        self.email = email
        self.name = name
    }
}
