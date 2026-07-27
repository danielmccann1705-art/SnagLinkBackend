import Fluent

struct CreateAnalyticsEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AnalyticsEvent.schema)
            .id()
            .field("event_name", .string, .required)
            .field("user_id", .uuid)
            .field("device_id", .string)
            .field("properties", .string)
            .field("app_version", .string, .required)
            .field("platform", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AnalyticsEvent.schema).delete()
    }
}
