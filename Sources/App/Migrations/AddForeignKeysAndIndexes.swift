import Fluent
import FluentSQL

/// Adds missing foreign key constraints and performance indexes to existing tables
struct AddForeignKeysAndIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Indexes on existing tables (safe to add - IF NOT EXISTS)
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_links_created_by_id ON magic_links(created_by_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_magic_links_project_id ON magic_links(project_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_completions_magic_link_id ON completions(magic_link_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_completions_status ON completions(status)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_completion_photos_completion_id ON completion_photos(completion_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_synced_photos_snag_id ON synced_photos(snag_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invites_email ON team_invites(email)").run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("DROP INDEX IF EXISTS idx_magic_links_created_by_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_magic_links_project_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_completions_magic_link_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_completions_status").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_completion_photos_completion_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_device_tokens_user_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_audit_logs_user_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_audit_logs_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_synced_photos_snag_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_team_invites_email").run()
    }
}
