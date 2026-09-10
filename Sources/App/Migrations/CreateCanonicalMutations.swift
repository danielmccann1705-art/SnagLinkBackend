import Vapor
import Fluent
import FluentSQL

/// Additive v2 write boundary. Legacy projects are not silently claimed/imported.
struct CreateCanonicalMutations: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE projects ADD COLUMN platform_managed BOOLEAN NOT NULL DEFAULT FALSE, ADD COLUMN next_snag_number BIGINT NOT NULL DEFAULT 1").run()
        try await sql.raw("ALTER TABLE teams ADD COLUMN change_sequence BIGINT NOT NULL DEFAULT 0").run()
        try await sql.raw("""
            ALTER TABLE snags ADD COLUMN revision BIGINT NOT NULL DEFAULT 1,
                ADD COLUMN workflow_revision BIGINT NOT NULL DEFAULT 1,
                ADD COLUMN display_number BIGINT, ADD COLUMN published_at TIMESTAMPTZ,
                ADD COLUMN archived_at TIMESTAMPTZ, ADD COLUMN archive_reason TEXT,
                ADD CONSTRAINT snag_project_pair UNIQUE(id, project_id)
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX snag_display_number ON snags(project_id, display_number) WHERE display_number IS NOT NULL").run()
        try await sql.raw("""
            CREATE TABLE mutation_receipts (
                actor_id UUID NOT NULL REFERENCES users(id), operation_id UUID NOT NULL,
                device_id UUID NOT NULL, workspace_id UUID NOT NULL REFERENCES teams(id),
                request_hash TEXT NOT NULL, result_json TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(actor_id, operation_id)
            )
            """).run()
        // Sequence is advanced under the workspace's transaction lock, not a
        // PostgreSQL sequence. Later commits cannot skip an earlier uncommitted row.
        try await sql.raw("""
            CREATE TABLE platform_changes (
                workspace_id UUID NOT NULL REFERENCES teams(id), sequence BIGINT NOT NULL,
                project_id UUID, entity_type TEXT NOT NULL, entity_id UUID NOT NULL,
                revision BIGINT NOT NULL, kind TEXT NOT NULL, changed_fields TEXT[] NOT NULL,
                payload_json TEXT NOT NULL, actor_id UUID NOT NULL REFERENCES users(id),
                created_at TIMESTAMPTZ NOT NULL, PRIMARY KEY(workspace_id, sequence),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX platform_project_changes ON platform_changes(project_id, sequence)").run()
        try await sql.raw("""
            CREATE TABLE project_change_cursors (
                token_hash TEXT PRIMARY KEY, actor_id UUID NOT NULL REFERENCES users(id),
                workspace_id UUID NOT NULL REFERENCES teams(id), project_id UUID NOT NULL,
                sequence BIGINT NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id)
            )
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Canonical revisions and retry receipts must be retained; roll back to a compatible image")
    }
}
