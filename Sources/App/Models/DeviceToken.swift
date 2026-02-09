import Fluent
import Vapor

final class DeviceToken: Model, Content, @unchecked Sendable {
    static let schema = "device_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "device_token")
    var deviceToken: String

    @Field(key: "platform")
    var platform: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, deviceToken: String, platform: String) {
        self.id = id
        self.userId = userId
        self.deviceToken = deviceToken
        self.platform = platform
    }
}
