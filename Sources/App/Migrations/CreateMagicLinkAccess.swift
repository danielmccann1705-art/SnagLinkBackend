import Fluent

struct CreateMagicLinkAccess: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("magic_link_accesses")
            .id()
            .field("magic_link_id", .uuid, .required, .references("magic_links", "id", onDelete: .cascade))
            .field("ip_address", .string, .required)
            .field("user_agent", .string)
            .field("country", .string)
            .field("city", .string)
            .field("pin_verified", .bool, .required, .custom("DEFAULT false"))
            .field("accessed_at", .datetime)
            .create()

        // Create index on magic_link_id for fast lookups
        try await database.schema("magic_link_accesses")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_magic_link_accesses_magic_link_id ON magic_link_accesses(magic_link_id)"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("magic_link_accesses").delete()
    }
}
