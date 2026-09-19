import Fluent
import FluentSQL
import Vapor

/// Adds a row-scoped escape hatch for the otherwise immutable import and drawing
/// ledgers. The authority is transaction-local and is valid only for the user on
/// a durable deletion job and rows inside that user's personal graph.
struct CreateAccountDeletionGraphErasure: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { database in
        let sql = try VerifiedIdentityService.sql(database)

        try await sql.raw("ALTER TABLE mutation_receipts ADD COLUMN IF NOT EXISTS account_deletion_redacted_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE link_mutation_receipts ADD COLUMN IF NOT EXISTS account_deletion_redacted_at TIMESTAMPTZ").run()
        try await sql.raw("""
            CREATE TABLE account_deletion_unresolved_objects (
                job_id UUID NOT NULL REFERENCES account_deletion_jobs(id), source_kind TEXT NOT NULL,
                source_id UUID NOT NULL, source_field TEXT NOT NULL, object_reference TEXT NOT NULL,
                reason TEXT NOT NULL CHECK(reason IN ('shared_reference','unknown_local_namespace')),
                created_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(job_id,source_kind,source_id,source_field)
            )
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION account_deletion_redact_json(value JSONB, subject_ids TEXT[]) RETURNS JSONB
            LANGUAGE plpgsql IMMUTABLE AS $$
            DECLARE item RECORD; result JSONB; identifies_subject BOOLEAN;
            BEGIN
                IF jsonb_typeof(value) = 'array' THEN
                    SELECT COALESCE(jsonb_agg(account_deletion_redact_json(element, subject_ids)), '[]'::JSONB)
                    INTO result FROM jsonb_array_elements(value) element;
                    RETURN result;
                ELSIF jsonb_typeof(value) <> 'object' THEN
                    RETURN value;
                END IF;

                SELECT EXISTS (
                    SELECT 1 FROM jsonb_each_text(value) pair
                    WHERE pair.key IN ('userId','user_id','actorId','actor_id','authorUserId','author_user_id',
                        'reviewedByUserId','reviewed_by_user_id','invitedByUserId','invited_by_user_id',
                        'commentId','comment_id','completionId','completion_id','inviteId','invite_id','id')
                      AND lower(pair.value) = ANY(subject_ids)
                ) INTO identifies_subject;

                result := '{}'::JSONB;
                FOR item IN SELECT * FROM jsonb_each(value) LOOP
                    IF identifies_subject AND item.key IN ('authorName','author_name','reviewedByName','reviewed_by_name',
                        'invitedByName','invited_by_name','userName','user_name','displayName','display_name') THEN
                        result := result || jsonb_build_object(item.key, 'Former member');
                    ELSIF identifies_subject AND item.key IN ('email','userEmail','user_email','phone','userPhone','user_phone') THEN
                        result := result || jsonb_build_object(item.key, NULL);
                    ELSE
                        result := result || jsonb_build_object(item.key, account_deletion_redact_json(item.value, subject_ids));
                    END IF;
                END LOOP;
                RETURN result;
            END $$
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION account_deletion_erasure_allowed(old_row JSONB) RETURNS BOOLEAN
            LANGUAGE plpgsql VOLATILE AS $$
            DECLARE deletion_job UUID; deletion_user UUID; scoped_project UUID; scoped_workspace UUID; scoped_session UUID; scoped_projection UUID;
            BEGIN
                BEGIN deletion_job := NULLIF(current_setting('snaglist.account_deletion_job_id', true), '')::UUID;
                EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                IF deletion_job IS NULL THEN RETURN FALSE; END IF;
                SELECT user_id INTO deletion_user FROM account_deletion_jobs
                WHERE id = deletion_job AND database_cleanup_state = 'blocked' FOR SHARE;
                IF deletion_user IS NULL THEN RETURN FALSE; END IF;

                BEGIN scoped_project := NULLIF(old_row->>'project_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                BEGIN scoped_workspace := NULLIF(old_row->>'workspace_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                BEGIN scoped_session := NULLIF(old_row->>'session_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                BEGIN scoped_projection := NULLIF(old_row->>'projection_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;

                IF scoped_projection IS NULL AND old_row ? 'first_projection_id' THEN
                    SELECT id INTO scoped_projection FROM legacy_canonical_projections WHERE id=(old_row->>'first_projection_id')::UUID;
                END IF;
                IF scoped_session IS NULL AND old_row ? 'commit_id' THEN
                    SELECT session_id,project_id INTO scoped_session,scoped_project FROM legacy_import_commits WHERE id=(old_row->>'commit_id')::UUID;
                END IF;
                IF scoped_workspace IS NULL AND old_row ? 'identity_id' THEN
                    SELECT workspace_id,first_projection_id INTO scoped_workspace,scoped_projection
                    FROM legacy_canonical_directory_identities WHERE id=(old_row->>'identity_id')::UUID;
                END IF;

                IF scoped_project IS NULL AND old_row ? 'asset_id' THEN
                    SELECT project_id INTO scoped_project FROM drawing_assets WHERE id = (old_row->>'asset_id')::UUID;
                END IF;
                IF scoped_project IS NULL AND old_row ? 'drawing_id' THEN
                    SELECT project_id INTO scoped_project FROM drawings WHERE id = (old_row->>'drawing_id')::UUID;
                END IF;
                IF scoped_project IS NULL AND old_row ? 'snag_id' THEN
                    SELECT project_id INTO scoped_project FROM snags WHERE id = (old_row->>'snag_id')::UUID;
                END IF;
                IF scoped_session IS NULL AND scoped_projection IS NOT NULL THEN
                    SELECT session_id INTO scoped_session FROM legacy_canonical_projections WHERE id = scoped_projection;
                END IF;

                IF scoped_project IS NOT NULL AND EXISTS (
                    SELECT 1 FROM projects p LEFT JOIN teams t ON t.id = p.workspace_id
                    WHERE p.id = scoped_project AND ((t.kind = 'personal' AND t.owner_user_id = deletion_user)
                        OR (p.workspace_id IS NULL AND p.owner_id = deletion_user))
                ) THEN RETURN TRUE; END IF;
                IF scoped_workspace IS NOT NULL AND EXISTS (
                    SELECT 1 FROM teams t WHERE t.id = scoped_workspace AND t.kind = 'personal' AND t.owner_user_id = deletion_user
                ) THEN RETURN TRUE; END IF;
                IF scoped_session IS NOT NULL AND EXISTS (
                    SELECT 1 FROM staged_legacy_imports i JOIN teams t ON t.id = i.workspace_id
                    WHERE i.id = scoped_session AND i.actor_id = deletion_user AND t.kind = 'personal' AND t.owner_user_id = deletion_user
                ) THEN RETURN TRUE; END IF;
                RETURN FALSE;
            END $$
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION staged_legacy_import_state_transition() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Retained import binding is immutable' USING ERRCODE = '23514'; END IF;
                IF (to_jsonb(NEW) - ARRAY['state','revision','updated_at','summary_json']) <> (to_jsonb(OLD) - ARRAY['state','revision','updated_at','summary_json'])
                    OR OLD.state <> 'staged_incomplete' OR NEW.state <> 'aborted' OR NEW.revision <> OLD.revision + 1 THEN
                    RAISE EXCEPTION 'Import permits only its explicit abort transition' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION staged_legacy_import_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                RAISE EXCEPTION 'Retained import source is immutable' USING ERRCODE = '23514';
            END $$
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION legacy_import_processing_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Retained import processing is immutable' USING ERRCODE = '23514'; END IF;
                IF OLD.state <> 'opaque' OR NEW.state <> 'decoded_image' OR OLD.projection_id <> NEW.projection_id
                   OR OLD.declaration_id <> NEW.declaration_id OR OLD.session_id <> NEW.session_id OR OLD.receipt_id <> NEW.receipt_id THEN
                    RAISE EXCEPTION 'Retained import processing is immutable' USING ERRCODE = '23514';
                END IF;
                IF EXISTS (SELECT 1 FROM legacy_import_commits WHERE session_id = OLD.session_id) THEN
                    RAISE EXCEPTION 'This preparation was already published' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION preserve_drawing_source() RETURNS trigger AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Drawing source identity must be retained'; END IF;
                IF (OLD.id,OLD.workspace_id,OLD.project_id,OLD.uploader_id,OLD.purpose,OLD.original_sha256,OLD.original_size,OLD.original_mime,OLD.original_filename,OLD.original_key,OLD.processor_profile,OLD.created_at,OLD.expires_at)
                   IS DISTINCT FROM
                   (NEW.id,NEW.workspace_id,NEW.project_id,NEW.uploader_id,NEW.purpose,NEW.original_sha256,NEW.original_size,NEW.original_mime,NEW.original_filename,NEW.original_key,NEW.processor_profile,NEW.created_at,NEW.expires_at)
                THEN RAISE EXCEPTION 'Drawing source identity is immutable'; END IF;
                IF OLD.result_hash IS NOT NULL AND (OLD.result_hash,OLD.ready_at) IS DISTINCT FROM (NEW.result_hash,NEW.ready_at)
                THEN RAISE EXCEPTION 'Processed drawing identity is immutable'; END IF;
                IF OLD.published_at IS NOT NULL AND OLD.published_at IS DISTINCT FROM NEW.published_at
                THEN RAISE EXCEPTION 'Drawing publication is immutable'; END IF;
                RETURN NEW;
            END; $$ LANGUAGE plpgsql
            """).run()
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION preserve_drawing_history() RETURNS trigger AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                RAISE EXCEPTION 'Drawing version, page and history records are immutable';
            END; $$ LANGUAGE plpgsql
            """).run()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION preserve_drawing_original_receipt() RETURNS trigger AS $$
            BEGIN
                IF TG_OP = 'DELETE' AND account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                IF TG_OP != 'INSERT' THEN RAISE EXCEPTION 'Drawing original receipt is immutable'; END IF;
                IF NOT EXISTS (
                    SELECT 1 FROM drawing_assets a WHERE a.id = NEW.asset_id AND a.project_id = NEW.project_id
                    AND a.workspace_id = NEW.workspace_id AND a.uploader_id = NEW.uploader_id
                    AND a.purpose = 'drawing_source' AND a.state = 'allocated'
                    AND a.original_sha256 = NEW.measured_sha256 AND a.original_size = NEW.measured_size
                    AND a.original_mime = NEW.measured_mime AND a.processor_profile = NEW.processor_profile
                    AND a.revision + 1 = NEW.asset_revision
                ) THEN RAISE EXCEPTION 'Drawing original receipt does not match source'; END IF;
                RETURN NEW;
            END; $$ LANGUAGE plpgsql
            """).run()

        // Legacy tables predate workspace-scoped foreign keys. Refuse creation of a
        // fresh personal graph for a terminal user, including work already in flight
        // when credentials were revoked.
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION require_active_legacy_owner() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE new_owner UUID; old_owner UUID;
            BEGIN
                new_owner := NULLIF(to_jsonb(NEW)->>TG_ARGV[0], '')::UUID;
                IF TG_OP = 'UPDATE' THEN old_owner := NULLIF(to_jsonb(OLD)->>TG_ARGV[0], '')::UUID; END IF;
                IF TG_OP = 'INSERT' OR new_owner IS DISTINCT FROM old_owner THEN
                    IF new_owner IS NULL THEN
                        RAISE EXCEPTION 'Owner unavailable' USING ERRCODE='23514';
                    END IF;
                    PERFORM id FROM users WHERE id=new_owner AND lifecycle_state='active' FOR SHARE;
                    IF NOT FOUND THEN RAISE EXCEPTION 'Owner unavailable' USING ERRCODE='23514'; END IF;
                END IF;
                RETURN NEW;
            END $$
            """).run()
        for (table, column) in [("projects", "owner_id"), ("snags", "owner_id"), ("contractors", "owner_id"),
                                ("trades", "owner_id"), ("snag_deletions", "owner_id"), ("magic_links", "created_by_id")] {
            try await sql.raw("CREATE TRIGGER account_deletion_active_owner BEFORE INSERT OR UPDATE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION require_active_legacy_owner(\(literal: column))").run()
        }
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION require_live_legacy_link() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE link_id UUID; link_token TEXT; link_owner UUID;
            BEGIN
                link_id := NULLIF(to_jsonb(NEW)->>'magic_link_id','')::UUID;
                link_token := NULLIF(to_jsonb(NEW)->>'magic_link_token','');
                SELECT m.created_by_id INTO link_owner FROM magic_links m
                    WHERE (link_id IS NOT NULL AND m.id=link_id OR link_token IS NOT NULL AND m.token=link_token)
                      AND m.revoked_at IS NULL AND m.expires_at>CURRENT_TIMESTAMP;
                IF link_owner IS NULL THEN RAISE EXCEPTION 'Contractor link unavailable' USING ERRCODE='23514'; END IF;
                PERFORM id FROM users WHERE id=link_owner AND lifecycle_state='active' FOR SHARE;
                IF NOT FOUND THEN RAISE EXCEPTION 'Contractor link unavailable' USING ERRCODE='23514'; END IF;
                IF NOT EXISTS (
                    SELECT 1 FROM magic_links m WHERE m.created_by_id=link_owner
                      AND (link_id IS NOT NULL AND m.id=link_id OR link_token IS NOT NULL AND m.token=link_token)
                      AND m.revoked_at IS NULL AND m.expires_at>CURRENT_TIMESTAMP
                ) THEN RAISE EXCEPTION 'Contractor link unavailable' USING ERRCODE='23514'; END IF;
                RETURN NEW;
            END $$
            """).run()
        for table in ["completions", "synced_photos", "synced_drawings", "synced_reports"] {
            try await sql.raw("CREATE TRIGGER account_deletion_live_link BEFORE INSERT ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION require_live_legacy_link()").run()
        }
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Account erasure guards are persistent; use a compatible image")
    }
}
