import Fluent

struct CreateContentReport: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ContentReport.schema)
            .id()
            .field("reporter_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("completion_id", .uuid, .required, .references("completions", "id", onDelete: .cascade))
            .field("reason", .string, .required)
            .field("details", .string, .required)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("resolved_at", .datetime)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema(ContentReport.schema).delete()
    }
}
