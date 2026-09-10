import Vapor
import Fluent
import FluentSQL

struct CreateRegisterSnapshots: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE project_change_cursors ADD COLUMN access_fingerprint TEXT NOT NULL DEFAULT ''").run()
        try await sql.raw("""
            CREATE TABLE register_snapshots (
                id UUID PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
                actor_id UUID NOT NULL REFERENCES users(id), workspace_id UUID NOT NULL REFERENCES teams(id),
                project_id UUID NOT NULL, access_fingerprint TEXT NOT NULL,
                high_watermark BIGINT NOT NULL, item_count INT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE register_snapshot_items (
                snapshot_id UUID NOT NULL REFERENCES register_snapshots(id) ON DELETE CASCADE,
                position INT NOT NULL, entity_type TEXT NOT NULL, entity_id UUID NOT NULL,
                payload_json TEXT NOT NULL, PRIMARY KEY(snapshot_id, position)
            )
            """).run()
        try await sql.raw("CREATE INDEX register_snapshot_expiry ON register_snapshots(expires_at)").run()
        try await sql.raw("CREATE INDEX project_cursor_expiry ON project_change_cursors(expires_at)").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Use a compatible image rollback; do not invalidate active sync state by downgrading schema")
    }
}
