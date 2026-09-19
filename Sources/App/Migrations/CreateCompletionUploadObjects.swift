import Fluent
import Vapor

/// Prospective ownership evidence for the historical public completion upload
/// route. Existing completion-photo URLs are deliberately not backfilled.
struct CreateCompletionUploadObjects: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { database in
            let sql = try VerifiedIdentityService.sql(database)
            // This migration is compatible with databases which already ran the
            // account-deletion draft before this storage kind was introduced.
            try await sql.raw("ALTER TABLE account_deletion_objects DROP CONSTRAINT account_deletion_objects_storage_kind_check").run()
            try await sql.raw("""
                ALTER TABLE account_deletion_objects ADD CONSTRAINT account_deletion_objects_storage_kind_check
                CHECK(storage_kind IN ('private_media','private_import','private_drawing','legacy_photo','legacy_drawing','legacy_completion_photo'))
                """).run()
            try await sql.raw("ALTER TABLE magic_links ADD CONSTRAINT magic_link_project_pair UNIQUE(id,project_id)").run()
            try await sql.raw("""
                CREATE TABLE completion_upload_objects (
                    id UUID PRIMARY KEY,
                    storage_key TEXT NOT NULL UNIQUE,
                    thumbnail_key TEXT NOT NULL UNIQUE,
                    issued_url TEXT NOT NULL UNIQUE,
                    issued_thumbnail_url TEXT,
                    filename TEXT NOT NULL,
                    content_type TEXT NOT NULL,
                    file_size INTEGER NOT NULL CHECK(file_size BETWEEN 1 AND 10485760),
                    uploaded_by_user_id UUID REFERENCES users(id),
                    magic_link_id UUID,
                    project_id UUID,
                    state TEXT NOT NULL CHECK(state IN ('allocated','ready','attached')),
                    thumbnail_ready BOOLEAN NOT NULL DEFAULT FALSE,
                    created_at TIMESTAMPTZ NOT NULL,
                    ready_at TIMESTAMPTZ,
                    attached_at TIMESTAMPTZ,
                    CHECK((uploaded_by_user_id IS NOT NULL AND magic_link_id IS NULL AND project_id IS NULL)
                       OR (uploaded_by_user_id IS NULL AND magic_link_id IS NOT NULL AND project_id IS NOT NULL)),
                    CHECK(state='allocated' OR (ready_at IS NOT NULL AND issued_thumbnail_url IS NOT NULL)),
                    CHECK(state<>'attached' OR attached_at IS NOT NULL),
                    FOREIGN KEY(magic_link_id,project_id) REFERENCES magic_links(id,project_id)
                )
                """).run()
            try await sql.raw("CREATE INDEX completion_upload_owner ON completion_upload_objects(uploaded_by_user_id,created_at) WHERE uploaded_by_user_id IS NOT NULL").run()
            try await sql.raw("CREATE INDEX completion_upload_project ON completion_upload_objects(project_id,created_at) WHERE project_id IS NOT NULL").run()
            try await sql.raw("ALTER TABLE completion_photos ADD COLUMN upload_object_id UUID UNIQUE REFERENCES completion_upload_objects(id)").run()
            // Existing rows remain historical and nullable. Every insert after this
            // migration must carry the exact server-issued ownership record, which
            // also fences old application binaries during a rolling transition.
            try await sql.raw("""
                CREATE FUNCTION require_trusted_completion_photo() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF TG_OP='UPDATE' THEN
                        IF (NEW.id,NEW.completion_id,NEW.url,NEW.thumbnail_url,NEW.filename,NEW.content_type,NEW.file_size,NEW.upload_object_id)
                           IS DISTINCT FROM
                           (OLD.id,OLD.completion_id,OLD.url,OLD.thumbnail_url,OLD.filename,OLD.content_type,OLD.file_size,OLD.upload_object_id) THEN
                            RAISE EXCEPTION 'Completion photo ownership is immutable' USING ERRCODE='23514';
                        END IF;
                        RETURN NEW;
                    END IF;
                    IF NEW.upload_object_id IS NULL THEN
                        RAISE EXCEPTION 'A trusted completion upload is required' USING ERRCODE='23514';
                    END IF;
                    PERFORM o.id FROM completion_upload_objects o
                    JOIN completions c ON c.id=NEW.completion_id
                    JOIN magic_links m ON m.id=c.magic_link_id
                    WHERE o.id=NEW.upload_object_id AND NEW.id=o.id AND o.state='ready'
                      AND o.magic_link_id=c.magic_link_id AND o.project_id=m.project_id
                      AND (NEW.url,NEW.thumbnail_url,NEW.filename,NEW.content_type,NEW.file_size)
                          IS NOT DISTINCT FROM
                          (o.issued_url,o.issued_thumbnail_url,o.filename,o.content_type,o.file_size)
                    FOR SHARE OF o;
                    IF NOT FOUND THEN
                        RAISE EXCEPTION 'Completion photo does not match its trusted upload' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER completion_photo_trusted_insert BEFORE INSERT OR UPDATE ON completion_photos FOR EACH ROW EXECUTE FUNCTION require_trusted_completion_photo()").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_completion_upload_object() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE deletion_job UUID; deletion_user UUID;
                BEGIN
                    IF TG_OP='DELETE' THEN
                        IF account_deletion_erasure_allowed(to_jsonb(OLD)) THEN RETURN OLD; END IF;
                        BEGIN deletion_job := NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                        EXCEPTION WHEN invalid_text_representation THEN deletion_job := NULL; END;
                        IF deletion_job IS NOT NULL THEN
                            SELECT user_id INTO deletion_user FROM account_deletion_jobs
                            WHERE id=deletion_job AND database_cleanup_state='blocked' FOR SHARE;
                            IF OLD.uploaded_by_user_id=deletion_user AND NOT EXISTS(
                                SELECT 1 FROM completion_photos WHERE upload_object_id=OLD.id
                            ) THEN RETURN OLD; END IF;
                        END IF;
                        RAISE EXCEPTION 'Completion upload ownership is immutable' USING ERRCODE='23514';
                    END IF;
                    IF (to_jsonb(NEW)-ARRAY['state','thumbnail_ready','issued_thumbnail_url','ready_at','attached_at'])
                       <> (to_jsonb(OLD)-ARRAY['state','thumbnail_ready','issued_thumbnail_url','ready_at','attached_at']) THEN
                        RAISE EXCEPTION 'Completion upload ownership is immutable' USING ERRCODE='23514';
                    END IF;
                    IF OLD.state='allocated' AND NEW.state='ready' AND NEW.ready_at IS NOT NULL AND NEW.issued_thumbnail_url IS NOT NULL THEN
                        RETURN NEW;
                    END IF;
                    IF OLD.state='ready' AND NEW.state='attached' AND NEW.ready_at=OLD.ready_at
                       AND NEW.issued_thumbnail_url=OLD.issued_thumbnail_url AND NEW.thumbnail_ready=OLD.thumbnail_ready
                       AND NEW.attached_at IS NOT NULL THEN RETURN NEW; END IF;
                    RAISE EXCEPTION 'Invalid completion upload transition' USING ERRCODE='23514';
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER completion_upload_object_immutable BEFORE UPDATE OR DELETE ON completion_upload_objects FOR EACH ROW EXECUTE FUNCTION preserve_completion_upload_object()").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Completion upload ownership evidence must survive rollback; use a compatible image")
    }
}
