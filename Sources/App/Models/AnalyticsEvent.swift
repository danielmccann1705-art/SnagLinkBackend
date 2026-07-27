import Fluent
import Vapor

final class AnalyticsEvent: Model, Content, @unchecked Sendable {
    static let schema = "analytics_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "event_name")
    var eventName: String

    @OptionalField(key: "user_id")
    var userId: UUID?

    @OptionalField(key: "device_id")
    var deviceId: String?

    @OptionalField(key: "properties")
    var properties: String?  // JSON-encoded

    @Field(key: "app_version")
    var appVersion: String

    @Field(key: "platform")
    var platform: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        eventName: String,
        userId: UUID? = nil,
        deviceId: String? = nil,
        properties: String? = nil,
        appVersion: String = "unknown",
        platform: String = "ios"
    ) {
        self.id = id
        self.eventName = eventName
        self.userId = userId
        self.deviceId = deviceId
        self.properties = properties
        self.appVersion = appVersion
        self.platform = platform
    }
}
