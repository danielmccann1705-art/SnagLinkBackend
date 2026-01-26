import Fluent

struct CreateTeamInvite: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("team_invites")
            .id()
            .field("email", .string, .required)
            .field("role", .string, .required)
            .field("status", .string, .required)
            .field("token", .string, .required)
            .field("team_id", .uuid, .required)
            .field("expires_at", .datetime, .required)
            .field("invited_by_user_id", .uuid)
            .field("invited_by_name", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()

        // Create indices for common queries
        try await database.schema("team_invites")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_team_invites_token ON team_invites(token)"))
            .update()

        try await database.schema("team_invites")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_team_invites_email ON team_invites(email)"))
            .update()

        try await database.schema("team_invites")
            .constraint(.custom("CREATE INDEX IF NOT EXISTS idx_team_invites_team_id ON team_invites(team_id)"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("team_invites").delete()
    }
}
