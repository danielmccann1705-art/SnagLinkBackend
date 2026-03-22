import Fluent
import FluentSQL

struct CreateContractor: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS contractors (
                id UUID PRIMARY KEY,
                company_name TEXT NOT NULL,
                contact_name TEXT,
                email TEXT,
                phone TEXT,
                notes TEXT,
                is_archived BOOLEAN NOT NULL DEFAULT false,
                trade_ids UUID[] NOT NULL DEFAULT '{}',
                owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_contractors_owner_id ON contractors(owner_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("contractors").delete()
    }
}
