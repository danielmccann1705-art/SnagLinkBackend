import Fluent
import FluentSQL

struct CreateAuditLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("audit_logs")
            .id()
            .field("event_type", .string, .required)
            .field("resource_type", .string, .required)
            .field("resource_id", .uuid)
            .field("user_id", .uuid)
            .field("ip_address", .string, .required)
            .field("user_agent", .string)
            .field("success", .bool, .required)
            .field("details", .string)
            .field("created_at", .datetime)
            .create()

        // Create indices for common queries
        let sql = database as! SQLDatabase
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_event_type ON audit_logs(event_type)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_resource_id ON audit_logs(resource_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("audit_logs").delete()
    }
}
