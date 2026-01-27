import Fluent
import FluentSQL

struct CreateTeamInvite: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Use raw SQL with IF NOT EXISTS to handle partial migration state
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS team_invites (
                id UUID PRIMARY KEY,
                email TEXT NOT NULL,
                role TEXT NOT NULL,
                status TEXT NOT NULL,
                token TEXT NOT NULL,
                team_id UUID NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL,
                invited_by_user_id UUID,
                invited_by_name TEXT,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:team_invites.token" UNIQUE (token)
            )
            """).run()

        // Create indices for common queries
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_token ON team_invites(token)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_email ON team_invites(email)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_team_id ON team_invites(team_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("team_invites").delete()
    }
}
