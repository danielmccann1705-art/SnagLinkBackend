import Fluent
import FluentSQL

struct CreateProject: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS projects (
                id UUID PRIMARY KEY,
                name TEXT NOT NULL,
                reference TEXT NOT NULL,
                client_name TEXT,
                client_email TEXT,
                client_phone TEXT,
                address TEXT,
                notes TEXT,
                project_type TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                is_favorite BOOLEAN NOT NULL DEFAULT false,
                cover_image_path TEXT,
                latitude DOUBLE PRECISION,
                longitude DOUBLE PRECISION,
                owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                team_id UUID,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_projects_owner_id ON projects(owner_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_projects_team_id ON projects(team_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects").delete()
    }
}
