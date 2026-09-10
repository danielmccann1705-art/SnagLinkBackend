import Fluent
import FluentSQL

/// Additive and idempotent; existing snag/report data is untouched during migration.
struct CreateSnagDeletion: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS snag_deletions (
                id UUID PRIMARY KEY,
                snag_id UUID NOT NULL,
                owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                project_id UUID NOT NULL,
                file_paths TEXT[] NOT NULL DEFAULT '{}',
                created_at TIMESTAMPTZ,
                UNIQUE(owner_id, project_id, snag_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snag_deletions_owner ON snag_deletions(owner_id)").run()
    }
    func revert(on database: Database) async throws {
        // Deliberately retain receipts: removing them would allow stale clients to restore deleted data.
    }
}
