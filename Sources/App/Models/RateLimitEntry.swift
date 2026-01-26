import Fluent
import Vapor

final class RateLimitEntry: Model, Content, @unchecked Sendable {
    static let schema = "rate_limit_entries"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "key")
    var key: String

    @Field(key: "action")
    var action: String

    @Field(key: "count")
    var count: Int

    @Field(key: "window_start")
    var windowStart: Date

    @Field(key: "window_end")
    var windowEnd: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        key: String,
        action: String,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.id = id
        self.key = key
        self.action = action
        self.count = 1
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    var isExpired: Bool {
        return Date() > windowEnd
    }
}
