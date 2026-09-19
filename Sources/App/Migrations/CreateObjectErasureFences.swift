import Fluent
import FluentSQL
import Vapor

/// Additive only. No installed writer is promoted to the create-only protocol.
struct CreateObjectErasureFences: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                ALTER TABLE object_write_intents
                    ADD COLUMN storage_backend TEXT,
                    ADD COLUMN storage_backend_identity TEXT,
                    ADD COLUMN storage_bucket TEXT,
                    ADD COLUMN storage_namespace TEXT,
                    ADD COLUMN write_protocol TEXT NOT NULL DEFAULT 'legacy_unknown'
                        CHECK(write_protocol IN ('legacy_unknown','create_only_v1')),
                    ADD CONSTRAINT object_write_target_complete CHECK(
                        (storage_backend IS NULL AND storage_backend_identity IS NULL AND storage_bucket IS NULL
                            AND storage_namespace IS NULL AND write_protocol='legacy_unknown') OR
                        (storage_backend='r2' AND length(storage_backend_identity) BETWEEN 1 AND 128
                            AND length(storage_bucket) BETWEEN 1 AND 128
                            AND storage_namespace ~ '^[A-Za-z0-9_-]+/$'
                            AND left(object_key,length(storage_namespace))=storage_namespace
                            AND storage_backend_identity IS NOT NULL AND storage_bucket IS NOT NULL AND storage_namespace IS NOT NULL))
                """).run()
            try await sql.raw("""
                CREATE TABLE object_erasure_fences (
                    id UUID PRIMARY KEY, job_id UUID NOT NULL REFERENCES account_deletion_jobs(id),
                    storage_kind TEXT NOT NULL, object_key TEXT NOT NULL,
                    storage_backend TEXT NOT NULL CHECK(storage_backend='r2'),
                    storage_backend_identity TEXT NOT NULL, storage_bucket TEXT NOT NULL,
                    storage_namespace TEXT NOT NULL, write_protocol TEXT NOT NULL CHECK(write_protocol='create_only_v1'),
                    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
                    FOREIGN KEY(job_id,storage_kind,object_key) REFERENCES account_deletion_objects(job_id,storage_kind,object_key),
                    UNIQUE(storage_backend,storage_backend_identity,storage_bucket,object_key)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE object_erasure_fence_attempts (
                    id UUID PRIMARY KEY, fence_id UUID NOT NULL REFERENCES object_erasure_fences(id),
                    lease_token UUID NOT NULL, capability_hash TEXT NOT NULL UNIQUE CHECK(capability_hash ~ '^[0-9a-f]{64}$'),
                    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), expires_at TIMESTAMPTZ NOT NULL,
                    CHECK(expires_at>requested_at)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE object_erasure_fence_attestations (
                    id UUID PRIMARY KEY, fence_id UUID NOT NULL UNIQUE REFERENCES object_erasure_fences(id),
                    attempt_id UUID NOT NULL UNIQUE REFERENCES object_erasure_fence_attempts(id),
                    storage_backend TEXT NOT NULL, storage_backend_identity TEXT NOT NULL,
                    storage_bucket TEXT NOT NULL, storage_namespace TEXT NOT NULL, object_key TEXT NOT NULL,
                    object_sha256 TEXT NOT NULL CHECK(object_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
                    byte_count BIGINT NOT NULL CHECK(byte_count=0),
                    content_type TEXT NOT NULL CHECK(content_type='application/x-snaglist-erased'),
                    marker TEXT NOT NULL CHECK(marker='snaglist-erased-v1'),
                    provider_etag TEXT NOT NULL CHECK(length(provider_etag) BETWEEN 1 AND 512),
                    verified_at TIMESTAMPTZ NOT NULL, recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
                )
                """).run()
            // One physical-key lock also serializes legacy/unknown admission.
            // Unknown bucket identity is deliberately not separated by storage_kind.
            try await sql.raw("""
                CREATE FUNCTION object_erasure_lock(key TEXT) RETURNS void LANGUAGE sql AS $$
                    SELECT pg_advisory_xact_lock(hashtextextended('object-erasure:'||ltrim(key,'/'),0))
                $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION object_erasure_has_graph_reference(kind TEXT,key TEXT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
                BEGIN
                    CASE kind
                    WHEN 'private_media' THEN RETURN EXISTS(SELECT 1 FROM media_assets WHERE original_key=key OR rendition_key=key);
                    WHEN 'private_drawing' THEN RETURN EXISTS(SELECT 1 FROM drawing_assets a LEFT JOIN drawing_asset_pages p ON p.asset_id=a.id
                        WHERE a.original_key=key OR p.rendition_key=key OR p.thumbnail_key=key);
                    WHEN 'private_import' THEN RETURN EXISTS(SELECT 1 FROM imported_file_objects WHERE rendition_key=key)
                        OR EXISTS(SELECT 1 FROM legacy_import_file_processing WHERE rendition_key=key)
                        OR EXISTS(SELECT 1 FROM legacy_import_drawing_processing WHERE rendition_key=key OR thumbnail_key=key)
                        OR EXISTS(SELECT 1 FROM staged_legacy_import_files f JOIN staged_legacy_imports s ON s.id=f.session_id
                            WHERE 'staged-import/'||lower(s.workspace_id::TEXT)||'/'||lower(f.session_id::TEXT)||'/'||lower(f.declaration_id::TEXT)||'/original'=key);
                    WHEN 'legacy_photo','legacy_drawing' THEN RETURN
                        EXISTS(SELECT 1 FROM synced_photos WHERE ltrim(file_path,'/')=ltrim(key,'/') OR ltrim(thumbnail_file_path,'/')=ltrim(key,'/'))
                        OR EXISTS(SELECT 1 FROM synced_drawings WHERE ltrim(file_path,'/')=ltrim(key,'/'))
                        OR EXISTS(SELECT 1 FROM snag_deletions d CROSS JOIN LATERAL unnest(d.file_paths) AS p(value) WHERE ltrim(p.value,'/')=ltrim(key,'/'));
                    WHEN 'legacy_completion_photo' THEN RETURN
                        EXISTS(SELECT 1 FROM completion_upload_objects WHERE storage_key=key OR thumbnail_key=key)
                        OR EXISTS(SELECT 1 FROM completion_photos WHERE upload_object_id IS NULL AND
                            (ltrim(url,'/')=ltrim(key,'/') OR ltrim(thumbnail_url,'/')=ltrim(key,'/') OR url LIKE '%/'||ltrim(key,'/') OR thumbnail_url LIKE '%/'||ltrim(key,'/')));
                    ELSE RETURN true;
                    END CASE;
                END $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION object_erasure_fence_eligible(f object_erasure_fences) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
                    SELECT EXISTS(SELECT 1 FROM account_deletion_jobs j WHERE j.id=f.job_id AND j.database_cleanup_state='completed')
                    AND NOT EXISTS(SELECT 1 FROM company_closure_jobs c WHERE c.account_deletion_job_id=f.job_id
                        AND c.mode='explicit' AND c.state NOT IN ('awaiting_objects','completed'))
                    AND EXISTS(SELECT 1 FROM object_write_intents i JOIN account_deletion_write_intents d ON d.intent_id=i.id
                        WHERE d.job_id=f.job_id AND i.storage_kind=f.storage_kind AND i.object_key=f.object_key
                        AND i.write_protocol='create_only_v1' AND i.storage_backend=f.storage_backend
                        AND i.storage_backend_identity=f.storage_backend_identity AND i.storage_bucket=f.storage_bucket
                        AND i.storage_namespace=f.storage_namespace)
                    AND NOT EXISTS(SELECT 1 FROM object_write_intents i WHERE ltrim(i.object_key,'/')=ltrim(f.object_key,'/') AND (
                        i.write_protocol='legacy_unknown' OR i.storage_backend IS NULL OR
                        (i.storage_backend=f.storage_backend AND i.storage_backend_identity=f.storage_backend_identity
                            AND i.storage_bucket=f.storage_bucket AND (
                                i.object_key<>f.object_key OR i.storage_namespace<>f.storage_namespace OR i.storage_kind<>f.storage_kind OR
                                NOT EXISTS(SELECT 1 FROM account_deletion_write_intents d WHERE d.intent_id=i.id AND d.job_id=f.job_id))) OR
                        (i.storage_kind=f.storage_kind AND EXISTS(SELECT 1 FROM account_deletion_write_intents d WHERE d.intent_id=i.id AND d.job_id=f.job_id)
                            AND (i.storage_backend,i.storage_backend_identity,i.storage_bucket,i.storage_namespace)
                                IS DISTINCT FROM (f.storage_backend,f.storage_backend_identity,f.storage_bucket,f.storage_namespace))))
                    AND NOT EXISTS(SELECT 1 FROM unnest(ARRAY['private_media','private_drawing','private_import','legacy_photo','legacy_drawing','legacy_completion_photo']) k(kind)
                        WHERE object_erasure_has_graph_reference(k.kind,f.object_key))
                $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION object_write_is_resolved(job UUID,intent UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
                    SELECT EXISTS(SELECT 1 FROM object_write_intents i WHERE i.id=intent AND (i.state='settled' OR
                        (i.write_protocol='create_only_v1' AND EXISTS(
                            SELECT 1 FROM object_erasure_fences f JOIN object_erasure_fence_attestations a ON a.fence_id=f.id
                            JOIN account_deletion_write_intents d ON d.intent_id=i.id AND d.job_id=f.job_id
                            WHERE f.job_id=job AND f.storage_backend=i.storage_backend
                                AND f.storage_backend_identity=i.storage_backend_identity AND f.storage_bucket=i.storage_bucket
                                AND f.storage_namespace=i.storage_namespace AND f.object_key=i.object_key))))
                $$
                """).run()
            try await sql.raw("""
                CREATE FUNCTION prevent_fenced_object_admission() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM object_erasure_lock(NEW.object_key);
                    IF EXISTS(SELECT 1 FROM object_erasure_fences f WHERE ltrim(f.object_key,'/')=ltrim(NEW.object_key,'/')
                        AND (NEW.write_protocol='legacy_unknown' OR NEW.storage_backend IS NULL OR
                            (f.storage_backend=NEW.storage_backend AND f.storage_backend_identity=NEW.storage_backend_identity AND f.storage_bucket=NEW.storage_bucket))) THEN
                        RAISE EXCEPTION 'Object key has an erasure fence' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER z_object_write_fence_admission BEFORE INSERT ON object_write_intents FOR EACH ROW EXECUTE FUNCTION prevent_fenced_object_admission()").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_object_erasure_fence() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE f object_erasure_fences; a object_erasure_fence_attempts; parent_lease UUID; parent_expiry TIMESTAMPTZ;
                    supplied_lease UUID; capability TEXT;
                BEGIN
                    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Erasure fence evidence is immutable' USING ERRCODE='23514'; END IF;
                    IF TG_TABLE_NAME='object_erasure_fences' THEN f:=NEW;
                    ELSE SELECT * INTO f FROM object_erasure_fences WHERE id=NEW.fence_id; END IF;
                    IF f.id IS NULL THEN RAISE EXCEPTION 'Erasure fence is unavailable' USING ERRCODE='23514'; END IF;
                    -- Caller must lock parent before key; consistent with the worker.
                    SELECT lease_token,lease_expires_at INTO parent_lease,parent_expiry FROM account_deletion_jobs
                        WHERE id=f.job_id AND state='leased' FOR UPDATE;
                    BEGIN supplied_lease:=NULLIF(current_setting('snaglist.object_erasure_lease',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN supplied_lease:=NULL; END;
                    IF parent_lease IS NULL OR parent_lease IS DISTINCT FROM supplied_lease OR parent_expiry<=clock_timestamp() THEN
                        RAISE EXCEPTION 'Erasure lease is unavailable' USING ERRCODE='23514';
                    END IF;
                    PERFORM object_erasure_lock(f.object_key);
                    IF NOT object_erasure_fence_eligible(f) THEN
                        RAISE EXCEPTION 'Object is not exclusively fenceable' USING ERRCODE='23514';
                    END IF;
                    IF TG_TABLE_NAME='object_erasure_fences' THEN
                        IF NOT EXISTS(SELECT 1 FROM account_deletion_objects WHERE job_id=f.job_id AND storage_kind=f.storage_kind
                            AND object_key=f.object_key AND completed_at IS NULL) THEN
                            RAISE EXCEPTION 'Erasure manifest is unavailable' USING ERRCODE='23514'; END IF;
                    ELSIF TG_TABLE_NAME='object_erasure_fence_attempts' THEN
                        IF NEW.lease_token IS DISTINCT FROM parent_lease OR NEW.expires_at>parent_expiry
                            OR NEW.requested_at>clock_timestamp() OR NEW.expires_at<=clock_timestamp()
                            OR EXISTS(SELECT 1 FROM object_erasure_fence_attestations WHERE fence_id=f.id) THEN
                            RAISE EXCEPTION 'Erasure attempt is unavailable' USING ERRCODE='23514'; END IF;
                    ELSE
                        SELECT * INTO a FROM object_erasure_fence_attempts WHERE id=NEW.attempt_id AND fence_id=f.id;
                        capability:=current_setting('snaglist.object_erasure_capability',true);
                        IF a.id IS NULL OR a.lease_token IS DISTINCT FROM parent_lease OR a.expires_at<=clock_timestamp()
                            OR capability IS NULL OR encode(sha256(convert_to('object-erasure-fence:'||capability,'UTF8')),'hex')<>a.capability_hash
                            OR (NEW.storage_backend,NEW.storage_backend_identity,NEW.storage_bucket,NEW.storage_namespace,NEW.object_key)
                                IS DISTINCT FROM (f.storage_backend,f.storage_backend_identity,f.storage_bucket,f.storage_namespace,f.object_key)
                            OR NEW.verified_at<a.requested_at OR NEW.verified_at>clock_timestamp() OR NEW.verified_at>a.expires_at THEN
                            RAISE EXCEPTION 'Erasure attestation is unavailable' USING ERRCODE='23514'; END IF;
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            for table in ["object_erasure_fences", "object_erasure_fence_attempts", "object_erasure_fence_attestations"] {
                try await sql.raw("CREATE TRIGGER erasure_fence_durable BEFORE INSERT OR UPDATE OR DELETE ON \(unsafeRaw:table) FOR EACH ROW EXECUTE FUNCTION preserve_object_erasure_fence()").run()
            }
            try await sql.raw("""
                CREATE FUNCTION preserve_pending_erasure_manifest() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.completed_at IS NOT NULL AND EXISTS(SELECT 1 FROM object_erasure_fences f
                        WHERE f.job_id=NEW.job_id AND f.storage_kind=NEW.storage_kind AND f.object_key=NEW.object_key
                          AND NOT EXISTS(SELECT 1 FROM object_erasure_fence_attestations a WHERE a.fence_id=f.id)) THEN
                        RAISE EXCEPTION 'Object erasure fence is unfinished' USING ERRCODE='23514'; END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER object_erasure_manifest_complete BEFORE UPDATE ON account_deletion_objects FOR EACH ROW EXECUTE FUNCTION preserve_pending_erasure_manifest()").run()
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION require_complete_company_closures() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.object_cleanup_state='completed' AND EXISTS(
                        SELECT 1 FROM object_erasure_fences f WHERE f.job_id=NEW.id AND NOT EXISTS(
                            SELECT 1 FROM object_erasure_fence_attestations a WHERE a.fence_id=f.id)
                    ) THEN RAISE EXCEPTION 'Object erasure fence is unfinished' USING ERRCODE='23514'; END IF;
                    IF NEW.object_cleanup_state='completed' AND EXISTS(
                        SELECT 1 FROM account_deletion_write_intents d WHERE d.job_id=NEW.id AND NOT object_write_is_resolved(NEW.id,d.intent_id)
                    ) THEN RAISE EXCEPTION 'Object write resolution is unfinished' USING ERRCODE='23514'; END IF;
                    IF NEW.state='completed' AND EXISTS(
                        SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=NEW.id AND state<>'completed'
                    ) THEN RAISE EXCEPTION 'Company closure is unfinished' USING ERRCODE='23514'; END IF;
                    RETURN NEW;
                END $$
                """).run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Erasure fences must survive rollback; use a compatible image")
    }
}
