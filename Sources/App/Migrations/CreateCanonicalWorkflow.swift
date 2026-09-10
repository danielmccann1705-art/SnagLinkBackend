import Vapor
import Fluent

struct CreateCanonicalWorkflow: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE completion_attempts (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL, snag_id UUID NOT NULL,
                attempt_number BIGINT NOT NULL CHECK(attempt_number > 0),
                actor_id UUID NOT NULL REFERENCES users(id), actor_kind TEXT NOT NULL CHECK(actor_kind IN ('internal', 'internal_fix')),
                notes TEXT, state TEXT NOT NULL CHECK(state IN ('pending', 'accepted', 'sent_back')),
                revision BIGINT NOT NULL DEFAULT 1 CHECK(revision > 0), submitted_at TIMESTAMPTZ NOT NULL,
                UNIQUE(snag_id, attempt_number), UNIQUE(id, snag_id, project_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX one_pending_attempt ON completion_attempts(snag_id) WHERE state = 'pending'").run()
        try await sql.raw("CREATE INDEX completion_project_queue ON completion_attempts(project_id, state, submitted_at, id)").run()
        try await sql.raw("""
            CREATE TABLE completion_evidence (
                attempt_id UUID NOT NULL, asset_id UUID NOT NULL UNIQUE, snag_id UUID NOT NULL, project_id UUID NOT NULL,
                position INTEGER NOT NULL CHECK(position >= 0), PRIMARY KEY(attempt_id, asset_id),
                UNIQUE(attempt_id, position),
                FOREIGN KEY(attempt_id, snag_id, project_id) REFERENCES completion_attempts(id, snag_id, project_id),
                FOREIGN KEY(asset_id, snag_id, project_id) REFERENCES media_assets(id, snag_id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE review_decisions (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL, snag_id UUID NOT NULL,
                attempt_id UUID, actor_id UUID NOT NULL REFERENCES users(id),
                kind TEXT NOT NULL CHECK(kind IN ('accept', 'send_back', 'reopen', 'internal_fix', 'waiver')),
                reason TEXT, expected_snag_revision BIGINT NOT NULL, expected_workflow_revision BIGINT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL,
                CHECK(kind = 'accept' OR (reason IS NOT NULL AND length(trim(reason)) > 0)),
                CHECK((kind = 'reopen' AND attempt_id IS NULL) OR (kind != 'reopen' AND attempt_id IS NOT NULL)),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id),
                FOREIGN KEY(attempt_id, snag_id, project_id) REFERENCES completion_attempts(id, snag_id, project_id)
            )
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX one_attempt_outcome ON review_decisions(attempt_id) WHERE kind IN ('accept', 'send_back', 'internal_fix')").run()
        try await sql.raw("CREATE UNIQUE INDEX one_attempt_waiver ON review_decisions(attempt_id) WHERE kind = 'waiver'").run()
        try await sql.raw("CREATE INDEX snag_review_history ON review_decisions(snag_id, created_at, id)").run()
        try await sql.raw("""
            CREATE TABLE workflow_outbox (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL, snag_id UUID NOT NULL,
                actor_id UUID NOT NULL REFERENCES users(id), event_kind TEXT NOT NULL, payload_json TEXT NOT NULL,
                dedupe_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL DEFAULT 'ready' CHECK(state IN ('ready', 'leased', 'delivered', 'failed')),
                attempts INTEGER NOT NULL DEFAULT 0, available_at TIMESTAMPTZ NOT NULL, lease_expires_at TIMESTAMPTZ,
                last_error_kind TEXT, created_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX workflow_outbox_ready ON workflow_outbox(state, available_at)").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain completion evidence and decisions; use a compatible rollback image")
    }
}
