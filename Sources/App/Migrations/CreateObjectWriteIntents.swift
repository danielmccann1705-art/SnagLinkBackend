import Fluent
import FluentSQL
import Vapor

/// Records the exact object and immutable ownership scope before external I/O.
/// These rows deliberately have no foreign keys to graph records: an upload may
/// still be in flight when its owning database graph is erased.
struct CreateObjectWriteIntents: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE object_write_intents (
                    id UUID PRIMARY KEY,
                    writer_token_hash TEXT NOT NULL UNIQUE CHECK(writer_token_hash ~ '^[0-9a-f]{64}$'),
                    source_kind TEXT NOT NULL CHECK(source_kind IN
                        ('media_asset','staged_original','import_derived','completion_upload','legacy_link','drawing_asset')),
                    source_id UUID NOT NULL,
                    source_session_id UUID,
                    ownership_kind TEXT NOT NULL CHECK(ownership_kind IN ('personal','workspace')),
                    scope_user_id UUID,
                    scope_workspace_id UUID,
                    scope_project_id UUID,
                    scope_magic_link_id UUID,
                    storage_kind TEXT NOT NULL CHECK(storage_kind IN
                        ('private_media','private_import','private_drawing','legacy_photo','legacy_drawing','legacy_completion_photo')),
                    object_key TEXT NOT NULL CHECK(length(object_key)>0),
                    sha256 TEXT NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
                    byte_count BIGINT NOT NULL CHECK(byte_count>=0),
                    content_type TEXT NOT NULL CHECK(length(btrim(content_type))>0),
                    state TEXT NOT NULL CHECK(state IN ('active','settled','uncertain')),
                    created_at TIMESTAMPTZ NOT NULL,
                    settled_at TIMESTAMPTZ,
                    CHECK((ownership_kind='personal' AND scope_user_id IS NOT NULL)
                       OR (ownership_kind='workspace' AND scope_workspace_id IS NOT NULL)),
                    CHECK(scope_magic_link_id IS NULL OR scope_project_id IS NOT NULL),
                    CHECK(source_kind<>'legacy_link' OR scope_magic_link_id IS NOT NULL),
                    CHECK((state='settled')=(settled_at IS NOT NULL)),
                    CHECK(settled_at IS NULL OR settled_at>=created_at)
                )
                """).run()
            try await sql.raw("CREATE INDEX object_write_intent_scope_workspace ON object_write_intents(scope_workspace_id,state)").run()
            try await sql.raw("CREATE INDEX object_write_intent_scope_project ON object_write_intents(scope_project_id,state) WHERE scope_project_id IS NOT NULL").run()
            try await sql.raw("CREATE INDEX object_write_intent_scope_link ON object_write_intents(scope_magic_link_id,state) WHERE scope_magic_link_id IS NOT NULL").run()
            try await sql.raw("CREATE INDEX object_write_intent_scope_user ON object_write_intents(scope_user_id,state) WHERE scope_user_id IS NOT NULL").run()
            try await sql.raw("CREATE INDEX object_write_intent_object ON object_write_intents(storage_kind,object_key)").run()
            try await sql.raw("""
                CREATE TABLE account_deletion_write_intents (
                    job_id UUID NOT NULL REFERENCES account_deletion_jobs(id),
                    intent_id UUID NOT NULL UNIQUE REFERENCES object_write_intents(id),
                    PRIMARY KEY(job_id,intent_id)
                )
                """).run()

            // Scope, key and measured-byte evidence never changes after the
            // pre-write commit. A crashed request remains active or uncertain
            // until an explicit token-authenticated reconciliation settles it.
            try await sql.raw("""
                CREATE FUNCTION preserve_object_write_intent() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE project_workspace UUID; project_owner UUID; link_project UUID; link_creator UUID;
                    session_workspace UUID; session_actor UUID; anchor_found BOOLEAN;
                BEGIN
                    IF TG_OP='DELETE' THEN
                        RAISE EXCEPTION 'Object write intent is durable' USING ERRCODE='23514';
                    END IF;
                    IF TG_OP='UPDATE' THEN
                        IF (to_jsonb(NEW)-ARRAY['state','settled_at']) IS DISTINCT FROM
                           (to_jsonb(OLD)-ARRAY['state','settled_at']) THEN
                            RAISE EXCEPTION 'Object write ownership is immutable' USING ERRCODE='23514';
                        END IF;
                        IF OLD.state='active' AND NEW.state IN ('settled','uncertain') THEN RETURN NEW; END IF;
                        IF OLD.state='uncertain' AND NEW.state='settled' THEN RETURN NEW; END IF;
                        IF to_jsonb(NEW)=to_jsonb(OLD) THEN RETURN NEW; END IF;
                        RAISE EXCEPTION 'Invalid object write transition' USING ERRCODE='23514';
                    END IF;
                    IF NEW.state<>'active' OR NEW.settled_at IS NOT NULL THEN
                        RAISE EXCEPTION 'New object writes must start active' USING ERRCODE='23514';
                    END IF;
                    IF NEW.ownership_kind='workspace' THEN
                        IF NOT EXISTS(SELECT 1 FROM teams WHERE id=NEW.scope_workspace_id AND lifecycle_state='active' FOR SHARE) THEN
                            RAISE EXCEPTION 'Object write workspace is unavailable' USING ERRCODE='23514';
                        END IF;
                    ELSIF NEW.scope_workspace_id IS NOT NULL AND NOT EXISTS(
                        SELECT 1 FROM teams WHERE id=NEW.scope_workspace_id AND kind='personal'
                          AND owner_user_id=NEW.scope_user_id AND lifecycle_state='active' FOR SHARE
                    ) THEN RAISE EXCEPTION 'Personal object write scope is invalid' USING ERRCODE='23514'; END IF;
                    -- Match closure/deletion lock order: workspace before user,
                    -- followed by project and Contractor link anchors.
                    IF NEW.scope_user_id IS NOT NULL AND NOT EXISTS(
                        SELECT 1 FROM users WHERE id=NEW.scope_user_id AND lifecycle_state='active' FOR SHARE
                    ) THEN RAISE EXCEPTION 'Object write owner is unavailable' USING ERRCODE='23514'; END IF;

                    IF NEW.scope_project_id IS NOT NULL THEN
                        SELECT workspace_id,owner_id INTO project_workspace,project_owner
                        FROM projects WHERE id=NEW.scope_project_id FOR SHARE;
                        anchor_found:=FOUND;
                        IF NOT anchor_found AND NEW.source_kind NOT IN ('legacy_link','completion_upload') THEN
                            RAISE EXCEPTION 'Object write project is unavailable' USING ERRCODE='23514';
                        END IF;
                        IF anchor_found AND NEW.ownership_kind='workspace' AND project_workspace IS DISTINCT FROM NEW.scope_workspace_id THEN
                            RAISE EXCEPTION 'Object write project crosses workspaces' USING ERRCODE='23514';
                        END IF;
                        IF anchor_found AND NEW.ownership_kind='personal' THEN
                            IF project_workspace IS NULL THEN
                                IF project_owner IS DISTINCT FROM NEW.scope_user_id THEN RAISE EXCEPTION 'Personal object write project is invalid' USING ERRCODE='23514'; END IF;
                            ELSIF NOT EXISTS(SELECT 1 FROM teams WHERE id=project_workspace AND kind='personal'
                                    AND owner_user_id=NEW.scope_user_id AND lifecycle_state='active' FOR SHARE) THEN
                                RAISE EXCEPTION 'Personal object write project is invalid' USING ERRCODE='23514';
                            END IF;
                            IF NEW.scope_workspace_id IS NOT NULL AND project_workspace IS DISTINCT FROM NEW.scope_workspace_id THEN
                                RAISE EXCEPTION 'Personal object write project crosses workspaces' USING ERRCODE='23514';
                            END IF;
                        END IF;
                    END IF;
                    IF NEW.scope_magic_link_id IS NOT NULL THEN
                        SELECT project_id,created_by_id INTO link_project,link_creator FROM magic_links
                        WHERE id=NEW.scope_magic_link_id AND revoked_at IS NULL AND expires_at>CURRENT_TIMESTAMP FOR SHARE;
                        IF NOT FOUND THEN RAISE EXCEPTION 'Object write link is unavailable' USING ERRCODE='23514'; END IF;
                        IF NEW.scope_project_id IS NOT NULL AND link_project IS DISTINCT FROM NEW.scope_project_id THEN
                            RAISE EXCEPTION 'Object write link crosses projects' USING ERRCODE='23514';
                        END IF;
                        IF NEW.scope_user_id IS NOT NULL AND link_creator IS DISTINCT FROM NEW.scope_user_id THEN
                            RAISE EXCEPTION 'Object write link owner is invalid' USING ERRCODE='23514';
                        END IF;
                        SELECT workspace_id,owner_id INTO project_workspace,project_owner FROM projects WHERE id=link_project FOR SHARE;
                        IF FOUND THEN
                            IF NEW.ownership_kind='workspace' AND project_workspace IS DISTINCT FROM NEW.scope_workspace_id THEN
                                RAISE EXCEPTION 'Object write link crosses workspaces' USING ERRCODE='23514';
                            ELSIF NEW.ownership_kind='personal' AND project_workspace IS NOT NULL AND NOT EXISTS(
                                SELECT 1 FROM teams WHERE id=project_workspace AND kind='personal'
                                  AND owner_user_id=NEW.scope_user_id AND lifecycle_state='active' FOR SHARE
                            ) THEN RAISE EXCEPTION 'Personal object write link is invalid' USING ERRCODE='23514'; END IF;
                        ELSIF NEW.ownership_kind<>'personal' THEN
                            RAISE EXCEPTION 'Workspace object write link has no canonical project' USING ERRCODE='23514';
                        END IF;
                    END IF;
                    IF NEW.source_session_id IS NOT NULL THEN
                        SELECT workspace_id,actor_id INTO session_workspace,session_actor FROM staged_legacy_imports
                        WHERE id=NEW.source_session_id FOR SHARE;
                        IF NOT FOUND THEN RAISE EXCEPTION 'Object write import is unavailable' USING ERRCODE='23514'; END IF;
                        IF NEW.ownership_kind='workspace' AND session_workspace IS DISTINCT FROM NEW.scope_workspace_id THEN
                            RAISE EXCEPTION 'Object write import crosses workspaces' USING ERRCODE='23514';
                        ELSIF NEW.ownership_kind='personal' AND (session_actor IS DISTINCT FROM NEW.scope_user_id
                            OR (NEW.scope_workspace_id IS NOT NULL AND session_workspace IS DISTINCT FROM NEW.scope_workspace_id)) THEN
                            RAISE EXCEPTION 'Personal object write import is invalid' USING ERRCODE='23514';
                        END IF;
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER object_write_intent_durable BEFORE INSERT OR UPDATE OR DELETE ON object_write_intents FOR EACH ROW EXECUTE FUNCTION preserve_object_write_intent()").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_account_deletion_write_intent() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE scoped_job UUID; scoped_child UUID; deletion_user UUID; closure_workspace UUID;
                    intent_ownership TEXT; intent_user UUID; intent_workspace UUID;
                BEGIN
                    IF TG_OP<>'INSERT' THEN
                        RAISE EXCEPTION 'Deletion write-intent evidence is durable' USING ERRCODE='23514';
                    END IF;
                    BEGIN scoped_job:=NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN scoped_job:=NULL; END;
                    BEGIN scoped_child:=NULLIF(current_setting('snaglist.company_closure_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN scoped_child:=NULL; END;
                    IF scoped_job IS DISTINCT FROM NEW.job_id THEN
                        RAISE EXCEPTION 'Deletion write-intent scope is unavailable' USING ERRCODE='23514';
                    END IF;
                    SELECT user_id INTO deletion_user FROM account_deletion_jobs
                    WHERE id=NEW.job_id AND database_cleanup_state='blocked' FOR SHARE;
                    IF deletion_user IS NULL THEN
                        RAISE EXCEPTION 'Deletion write-intent job is unavailable' USING ERRCODE='23514';
                    END IF;
                    SELECT ownership_kind,scope_user_id,scope_workspace_id
                    INTO intent_ownership,intent_user,intent_workspace
                    FROM object_write_intents WHERE id=NEW.intent_id FOR SHARE;
                    IF NOT FOUND THEN
                        RAISE EXCEPTION 'Object write intent is unavailable' USING ERRCODE='23514';
                    END IF;
                    IF scoped_child IS NOT NULL THEN
                        SELECT workspace_id INTO closure_workspace FROM company_closure_jobs
                        WHERE id=scoped_child AND account_deletion_job_id=NEW.job_id AND mode='explicit' AND state='erasing' FOR SHARE;
                        IF closure_workspace IS NULL OR intent_ownership<>'workspace'
                           OR intent_workspace IS DISTINCT FROM closure_workspace
                           OR NOT company_closure_write_allowed(closure_workspace) THEN
                            RAISE EXCEPTION 'Company write intent is outside closure scope' USING ERRCODE='23514';
                        END IF;
                    ELSIF NOT (
                        (intent_ownership='personal' AND intent_user=deletion_user)
                        OR (intent_ownership='workspace' AND EXISTS(
                            SELECT 1 FROM teams WHERE id=intent_workspace AND kind='personal'
                              AND owner_user_id=deletion_user FOR SHARE))
                    ) THEN
                        RAISE EXCEPTION 'Personal write intent is outside deletion scope' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER account_deletion_write_intent_durable BEFORE INSERT OR UPDATE OR DELETE ON account_deletion_write_intents FOR EACH ROW EXECUTE FUNCTION preserve_account_deletion_write_intent()").run()

            // A job cannot claim object completion while any captured write can
            // still create or may already have created its exact object.
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION require_complete_company_closures() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.object_cleanup_state='completed' AND EXISTS(
                        SELECT 1 FROM account_deletion_write_intents d
                        JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=NEW.id AND i.state<>'settled'
                    ) THEN
                        RAISE EXCEPTION 'Object write settlement is unfinished' USING ERRCODE='23514';
                    END IF;
                    IF NEW.state='completed' AND EXISTS(
                        SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=NEW.id AND state<>'completed'
                    ) THEN
                        RAISE EXCEPTION 'Company closure is unfinished' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Object write evidence must survive rollback; use a compatible image")
    }
}
