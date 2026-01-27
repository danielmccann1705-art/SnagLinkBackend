import Fluent
import FluentSQL

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
        let sql = database as! SQLDatabase
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_token ON team_invites(token)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_email ON team_invites(email)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_team_id ON team_invites(team_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("team_invites").delete()
    }
}
