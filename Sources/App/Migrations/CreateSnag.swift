import Fluent
import FluentSQL

struct CreateSnag: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS snags (
                id UUID PRIMARY KEY,
                reference TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                priority TEXT NOT NULL DEFAULT 'medium',
                location TEXT,
                due_date TIMESTAMPTZ,
                closed_at TIMESTAMPTZ,
                cost_estimate DOUBLE PRECISION,
                actual_cost DOUBLE PRECISION,
                currency TEXT NOT NULL DEFAULT 'GBP',
                drawing_pin_x DOUBLE PRECISION,
                drawing_pin_y DOUBLE PRECISION,
                project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                contractor_id UUID,
                trade_id UUID,
                drawing_id UUID,
                assigned_at TIMESTAMPTZ,
                owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                tags TEXT[] NOT NULL DEFAULT '{}',
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snags_project_id ON snags(project_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snags_owner_id ON snags(owner_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snags_status ON snags(status)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snags_project_status ON snags(project_id, status)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snags_contractor_id ON snags(contractor_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("snags").delete()
    }
}
