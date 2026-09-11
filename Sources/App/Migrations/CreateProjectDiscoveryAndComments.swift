import Vapor
import Fluent

/// Additive graph expansion. Existing project data and previously issued register
/// snapshots are unchanged; old snapshots retain their original coverage declaration.
struct CreateProjectDiscoveryAndComments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS project_discovery_snapshots (
                    id UUID PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
                    actor_id UUID NOT NULL REFERENCES users(id), access_fingerprint TEXT NOT NULL,
                    workspace_ids UUID[] NOT NULL, item_count INT NOT NULL CHECK(item_count >= 0),
                    created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL
                )
                """).run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS project_discovery_actor_expiry ON project_discovery_snapshots(actor_id, expires_at)").run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS project_discovery_items (
                    snapshot_id UUID NOT NULL REFERENCES project_discovery_snapshots(id) ON DELETE CASCADE,
                    position INT NOT NULL, project_id UUID NOT NULL, payload_json TEXT NOT NULL,
                    PRIMARY KEY(snapshot_id, position), UNIQUE(snapshot_id, project_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS project_comments (
                    id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                    snag_id UUID NOT NULL, parent_comment_id UUID,
                    author_user_id UUID NOT NULL REFERENCES users(id), author_name TEXT NOT NULL,
                    body TEXT NOT NULL CHECK(char_length(body) BETWEEN 1 AND 10000),
                    revision BIGINT NOT NULL DEFAULT 1 CHECK(revision > 0),
                    created_at TIMESTAMPTZ NOT NULL, redacted_at TIMESTAMPTZ,
                    redacted_by_user_id UUID REFERENCES users(id), redaction_reason TEXT,
                    UNIQUE(id, snag_id),
                    FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                    FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id),
                    FOREIGN KEY(parent_comment_id, snag_id) REFERENCES project_comments(id, snag_id),
                    CHECK(parent_comment_id IS NULL OR parent_comment_id <> id),
                    CHECK((redacted_at IS NULL AND redacted_by_user_id IS NULL AND redaction_reason IS NULL)
                        OR (redacted_at IS NOT NULL AND redacted_by_user_id IS NOT NULL AND redaction_reason IS NOT NULL AND char_length(redaction_reason) BETWEEN 1 AND 500))
                )
                """).run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS project_comments_graph ON project_comments(project_id, created_at, id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS project_comments_snag ON project_comments(snag_id, created_at, id)").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep project discovery and comment history; use a compatible image rollback")
    }
}
