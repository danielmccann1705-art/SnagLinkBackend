import Vapor
import Fluent

/// Durable lifecycle work; does not enable retention or weaken immutable history.
struct CreateAccountDeletionJobs: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
        let sql = try VerifiedIdentityService.sql(transaction)
        try await sql.raw("""
            CREATE TABLE account_deletion_jobs (
                id UUID PRIMARY KEY, user_id UUID NOT NULL UNIQUE REFERENCES users(id),
                receipt_hash TEXT NOT NULL UNIQUE, requested_at TIMESTAMPTZ NOT NULL, completed_at TIMESTAMPTZ,
                state TEXT NOT NULL CHECK(state IN ('ready','leased','completed','blocked')),
                attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0), available_at TIMESTAMPTZ NOT NULL,
                lease_expires_at TIMESTAMPTZ, lease_token UUID,
                database_cleanup_state TEXT NOT NULL CHECK(database_cleanup_state IN ('pending','completed','blocked')),
                apple_revocation_state TEXT NOT NULL CHECK(apple_revocation_state IN
                    ('pending','not_applicable','revoked','already_revoked','misconfigured','failing','unavailable')),
                apple_credential_ciphertext TEXT, apple_client_id TEXT,
                object_cleanup_state TEXT NOT NULL CHECK(object_cleanup_state IN ('pending','completed','blocked')),
                last_error_kind TEXT,
                CHECK((state = 'leased' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
                   OR (state <> 'leased' AND lease_token IS NULL AND lease_expires_at IS NULL)),
                CHECK(state <> 'completed' OR (completed_at IS NOT NULL AND database_cleanup_state = 'completed'
                    AND object_cleanup_state = 'completed' AND apple_revocation_state IN ('not_applicable','revoked','already_revoked')
                    AND apple_credential_ciphertext IS NULL)),
                CHECK(state = 'completed' OR completed_at IS NULL)
            )
            """).run()
        try await sql.raw("CREATE INDEX account_deletion_ready ON account_deletion_jobs(state,available_at)").run()
        try await sql.raw("""
            CREATE TABLE account_deletion_objects (
                job_id UUID NOT NULL REFERENCES account_deletion_jobs(id),
                object_key TEXT NOT NULL, storage_kind TEXT NOT NULL CHECK(storage_kind IN ('private_media','private_import','private_drawing','legacy_photo','legacy_drawing','legacy_completion_photo')),
                completed_at TIMESTAMPTZ, attempts INTEGER NOT NULL DEFAULT 0,
                last_error_kind TEXT, PRIMARY KEY(job_id,storage_kind,object_key)
            )
            """).run()
        // A sign-in exchange or device registration already in flight must not
        // recreate personal credentials after the deletion transaction commits.
        try await sql.raw("""
            CREATE FUNCTION require_active_credential_owner() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE subject UUID;
            BEGIN
                subject := (to_jsonb(NEW)->>TG_ARGV[0])::UUID;
                IF subject IS NULL THEN RETURN NEW; END IF;
                PERFORM id FROM users WHERE id = subject AND lifecycle_state = 'active' FOR SHARE;
                IF NOT FOUND THEN RAISE EXCEPTION 'Credential owner unavailable' USING ERRCODE = '23514'; END IF;
                RETURN NEW;
            END $$
            """).run()
        for table in ["user_identities", "browser_sessions", "device_tokens", "apple_credentials"] {
            try await sql.raw("CREATE TRIGGER active_credential_owner BEFORE INSERT OR UPDATE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION require_active_credential_owner('user_id')").run()
        }
        for table in ["identity_challenges", "google_identity_challenges"] {
            try await sql.raw("CREATE TRIGGER active_credential_owner BEFORE INSERT OR UPDATE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION require_active_credential_owner('target_user_id')").run()
        }
        try await sql.raw("""
            CREATE FUNCTION preserve_deleted_account() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF OLD.lifecycle_state = 'deleted' AND
                    (NEW.lifecycle_state <> 'deleted' OR NEW.email IS NOT NULL OR NEW.name IS NOT NULL
                     OR NEW.apple_user_id IS NOT NULL OR NEW.auth_version < OLD.auth_version) THEN
                    RAISE EXCEPTION 'Account unavailable' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await sql.raw("CREATE TRIGGER deleted_account_is_terminal BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION preserve_deleted_account()").run()
        // An in-flight invitation or ownership transfer must not grant fresh
        // authority after erasure. Historical company rows remain editable when
        // their already-deleted attribution is unchanged.
        try await sql.raw("""
            CREATE FUNCTION require_active_authority_subject() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE subject UUID;
            BEGIN
                IF TG_TABLE_NAME = 'teams' THEN
                    IF TG_OP = 'UPDATE' AND NEW.owner_user_id IS NOT DISTINCT FROM OLD.owner_user_id THEN RETURN NEW; END IF;
                    subject := NEW.owner_user_id;
                ELSE
                    IF NEW.state <> 'active' THEN RETURN NEW; END IF;
                    subject := NEW.user_id;
                END IF;
                PERFORM id FROM users WHERE id = subject AND lifecycle_state = 'active' FOR SHARE;
                IF NOT FOUND THEN RAISE EXCEPTION 'Account unavailable' USING ERRCODE = '23514'; END IF;
                RETURN NEW;
            END $$
            """).run()
        for table in ["teams", "workspace_memberships", "project_access"] {
            try await sql.raw("CREATE TRIGGER active_authority_subject BEFORE INSERT OR UPDATE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION require_active_authority_subject()").run()
        }
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Deletion jobs must survive rollback; use a compatible image")
    }
}
