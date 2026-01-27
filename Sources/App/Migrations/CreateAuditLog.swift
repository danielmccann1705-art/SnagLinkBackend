import Fluent
import FluentSQL

struct CreateAuditLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Use raw SQL with IF NOT EXISTS to handle partial migration state
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS audit_logs (
                id UUID PRIMARY KEY,
                event_type TEXT NOT NULL,
                resource_type TEXT NOT NULL,
                resource_id UUID,
                user_id UUID,
                ip_address TEXT NOT NULL,
                user_agent TEXT,
                success BOOLEAN NOT NULL,
                details TEXT,
                created_at TIMESTAMPTZ
            )
            """).run()

        // Create indices for common queries
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_event_type ON audit_logs(event_type)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_resource_id ON audit_logs(resource_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("audit_logs").delete()
    }
}
