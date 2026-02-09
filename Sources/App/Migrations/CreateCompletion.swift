import Fluent
import FluentSQL
import Vapor

// MARK: - Create Completion Migration
struct CreateCompletion: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS completions (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                snag_id UUID NOT NULL,
                magic_link_id UUID NOT NULL,
                contractor_name TEXT NOT NULL,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                rejection_reason TEXT,
                reviewed_by_user_id UUID,
                reviewed_by_name TEXT,
                submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                reviewed_at TIMESTAMPTZ
            )
        """).run()

        // Indexes for common queries
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_completions_snag_id ON completions(snag_id)
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_completions_magic_link_id ON completions(magic_link_id)
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_completions_status ON completions(status)
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_completions_reviewed_by_user_id ON completions(reviewed_by_user_id)
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("DROP TABLE IF EXISTS completions").run()
    }
}
