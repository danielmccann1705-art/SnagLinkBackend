import Fluent
import FluentSQL

struct CreateMagicLink: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("magic_links")
            .id()
            .field("token", .string, .required)
            .field("access_level", .string, .required)
            .field("pin_hash", .string)
            .field("pin_salt", .string)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("open_count", .int, .required, .custom("DEFAULT 0"))
            .field("last_opened_at", .datetime)
            .field("failed_pin_attempts", .int, .required, .custom("DEFAULT 0"))
            .field("locked_until", .datetime)
            .field("snag_ids", .array(of: .uuid), .required)
            .field("project_id", .uuid, .required)
            .field("contractor_id", .uuid)
            .field("created_by_id", .uuid, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()

        // Create index on token for fast lookups
        let sql = database as! SQLDatabase
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_links_token ON magic_links(token)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_links").delete()
    }
}
