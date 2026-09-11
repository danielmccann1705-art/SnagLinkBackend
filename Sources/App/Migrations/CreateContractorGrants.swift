import Vapor
import Fluent

/// Additive contractor capabilities. A grant is an actor, never a synthetic user.
struct CreateContractorGrants: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE link_grants (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                creator_id UUID NOT NULL REFERENCES users(id), contractor_id UUID,
                mode TEXT NOT NULL CHECK(mode IN ('completion', 'read_only', 'preview')),
                state TEXT NOT NULL DEFAULT 'prepared' CHECK(state IN ('prepared', 'active', 'revoked')),
                revision BIGINT NOT NULL DEFAULT 1, token_hash TEXT UNIQUE, token_ciphertext TEXT,
                pin_hash TEXT, pin_failures INTEGER NOT NULL DEFAULT 0, pin_locked_until TIMESTAMPTZ,
                duration_days INTEGER NOT NULL CHECK(duration_days BETWEEN 1 AND 90),
                created_at TIMESTAMPTZ NOT NULL, activated_at TIMESTAMPTZ, expires_at TIMESTAMPTZ NOT NULL,
                revoked_at TIMESTAMPTZ, issuance_json TEXT,
                CHECK(mode != 'completion' OR contractor_id IS NOT NULL),
                CHECK(state != 'active' OR (token_hash IS NOT NULL AND token_ciphertext IS NOT NULL AND activated_at IS NOT NULL AND issuance_json IS NOT NULL)),
                UNIQUE(id, project_id), UNIQUE(id, workspace_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(contractor_id, workspace_id) REFERENCES contractors(id, workspace_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX link_grant_project ON link_grants(project_id, created_at, id)").run()
        try await sql.raw("""
            CREATE TABLE link_items (
                grant_id UUID NOT NULL, snag_id UUID NOT NULL, project_id UUID NOT NULL,
                position INTEGER NOT NULL, assignment_id UUID, revoked_at TIMESTAMPTZ,
                PRIMARY KEY(grant_id, snag_id), UNIQUE(grant_id, position),
                FOREIGN KEY(grant_id, project_id) REFERENCES link_grants(id, project_id),
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX link_item_snag ON link_items(snag_id) WHERE revoked_at IS NULL").run()
        try await sql.raw("""
            CREATE TABLE link_media (
                grant_id UUID NOT NULL, snag_id UUID NOT NULL, project_id UUID NOT NULL, asset_id UUID NOT NULL,
                PRIMARY KEY(grant_id, asset_id), FOREIGN KEY(grant_id, snag_id) REFERENCES link_items(grant_id, snag_id),
                FOREIGN KEY(asset_id, snag_id, project_id) REFERENCES media_assets(id, snag_id, project_id),
                FOREIGN KEY(grant_id, project_id) REFERENCES link_grants(id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE link_sessions (
                token_hash TEXT PRIMARY KEY, grant_id UUID NOT NULL REFERENCES link_grants(id),
                expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL
            )
            """).run()
        try await sql.raw("CREATE INDEX link_session_expiry ON link_sessions(expires_at)").run()
        try await sql.raw("""
            CREATE TABLE link_mutation_receipts (
                grant_id UUID NOT NULL REFERENCES link_grants(id), operation_id UUID NOT NULL, device_id UUID NOT NULL,
                request_hash TEXT NOT NULL, result_json TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(grant_id, operation_id)
            )
            """).run()
        try await sql.raw("ALTER TABLE media_assets ALTER COLUMN creator_id DROP NOT NULL, ADD COLUMN creator_grant_id UUID, ADD CONSTRAINT media_grant_scope FOREIGN KEY(creator_grant_id, project_id) REFERENCES link_grants(id, project_id), ADD CONSTRAINT media_actor CHECK((creator_id IS NULL) != (creator_grant_id IS NULL)), ADD CONSTRAINT contractor_media_purpose CHECK(creator_grant_id IS NULL OR purpose = 'completion')").run()
        try await sql.raw("ALTER TABLE completion_attempts ALTER COLUMN actor_id DROP NOT NULL, ADD COLUMN actor_grant_id UUID, DROP CONSTRAINT completion_attempts_actor_kind_check, ADD CONSTRAINT attempt_grant_scope FOREIGN KEY(actor_grant_id, project_id) REFERENCES link_grants(id, project_id), ADD CONSTRAINT attempt_actor CHECK((actor_id IS NOT NULL AND actor_grant_id IS NULL AND actor_kind IN ('internal', 'internal_fix')) OR (actor_id IS NULL AND actor_grant_id IS NOT NULL AND actor_kind = 'contractor_link'))").run()
        try await sql.raw("ALTER TABLE platform_changes ALTER COLUMN actor_id DROP NOT NULL, ADD COLUMN actor_grant_id UUID, ADD CONSTRAINT change_grant_scope FOREIGN KEY(actor_grant_id, workspace_id) REFERENCES link_grants(id, workspace_id), ADD CONSTRAINT change_actor CHECK((actor_id IS NULL) != (actor_grant_id IS NULL))").run()
        try await sql.raw("ALTER TABLE workflow_outbox ALTER COLUMN actor_id DROP NOT NULL, ADD COLUMN actor_grant_id UUID, ADD CONSTRAINT outbox_grant_scope FOREIGN KEY(actor_grant_id, project_id) REFERENCES link_grants(id, project_id), ADD CONSTRAINT outbox_actor CHECK((actor_id IS NULL) != (actor_grant_id IS NULL))").run()
        try await sql.raw("ALTER TABLE workspace_activity ALTER COLUMN actor_user_id DROP NOT NULL, ADD COLUMN actor_grant_id UUID, ADD CONSTRAINT activity_grant_scope FOREIGN KEY(actor_grant_id, workspace_id) REFERENCES link_grants(id, workspace_id), ADD CONSTRAINT activity_actor CHECK((actor_user_id IS NULL) != (actor_grant_id IS NULL))").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain issued grants and contractor evidence attribution; use a compatible rollback image")
    }
}
