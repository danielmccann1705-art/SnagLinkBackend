import Fluent
import FluentSQL
import Vapor

// MARK: - Create Completion Photo Migration
struct CreateCompletionPhoto: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS completion_photos (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                completion_id UUID NOT NULL REFERENCES completions(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                thumbnail_url TEXT,
                filename TEXT,
                content_type TEXT,
                file_size INTEGER,
                uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """).run()

        // Index for completion relationship queries
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_completion_photos_completion_id ON completion_photos(completion_id)
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQL-based")
        }

        try await sql.raw("DROP TABLE IF EXISTS completion_photos").run()
    }
}
