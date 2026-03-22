import Fluent
import FluentSQL

struct CreateTeam: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS teams (
                id UUID PRIMARY KEY,
                name TEXT NOT NULL,
                owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_teams_owner_user_id ON teams(owner_user_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("teams").delete()
    }
}
