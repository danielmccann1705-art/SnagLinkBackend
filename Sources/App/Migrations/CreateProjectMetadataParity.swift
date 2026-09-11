import Vapor
import Fluent
import FluentSQL

/// Nullable additions retain prior project data and unknown date intent. No
/// report JSON or old device timestamps are silently promoted to canonical dates.
struct CreateProjectMetadataParity: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                ALTER TABLE projects
                    ADD COLUMN IF NOT EXISTS custom_project_type TEXT,
                    ADD COLUMN IF NOT EXISTS start_date TIMESTAMPTZ,
                    ADD COLUMN IF NOT EXISTS expected_end_date TIMESTAMPTZ,
                    ADD COLUMN IF NOT EXISTS start_on TEXT,
                    ADD COLUMN IF NOT EXISTS expected_end_on TEXT
                """).run()
            // Unknown prior cursor coverage stays unknown, never upgraded by the
            // new server. A new client needs a new manifest for added entities.
            try await sql.raw("ALTER TABLE project_change_cursors ADD COLUMN IF NOT EXISTS coverage TEXT[] NOT NULL DEFAULT '{}'::TEXT[]").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS assignment_history_project_order ON assignment_history (project_id, snag_id, snag_revision, id)").run()
            let constraint = try await sql.raw("SELECT 1 FROM pg_constraint WHERE conrelid = 'projects'::regclass AND conname = 'project_calendar_dates_valid'").first()
            if constraint == nil {
                try await sql.raw("""
                    ALTER TABLE projects ADD CONSTRAINT project_calendar_dates_valid CHECK (
                        (start_on IS NULL OR (start_on ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND (start_on::date)::text = start_on)) AND
                        (expected_end_on IS NULL OR (expected_end_on ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND (expected_end_on::date)::text = expected_end_on)) AND
                        (start_on IS NULL OR expected_end_on IS NULL OR start_on <= expected_end_on))
                    """).run()
            }
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Preserve project dates and assignment history; roll back only to a compatible image")
    }
}
