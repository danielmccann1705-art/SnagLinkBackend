import Fluent
import Vapor

/// Retains existing ciphertext byte-for-byte. Native and Services-ID credentials
/// coexist, and each client has durable revocation work under the deletion lease.
struct CreateAppleMultiClientCredentials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("ALTER TABLE apple_credentials DROP CONSTRAINT apple_credentials_pkey, ADD PRIMARY KEY(user_id,client_id)").run()
            try await sql.raw("""
                CREATE TABLE account_deletion_apple_credentials (
                    id UUID PRIMARY KEY, job_id UUID NOT NULL REFERENCES account_deletion_jobs(id),
                    client_id TEXT, credential_ciphertext TEXT,
                    state TEXT NOT NULL CHECK(state IN ('pending','revoked','already_revoked','misconfigured','failing','unavailable')),
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0), last_attempt_at TIMESTAMPTZ,
                    completed_at TIMESTAMPTZ, UNIQUE(job_id,client_id),
                    CHECK(state NOT IN ('revoked','already_revoked') OR (credential_ciphertext IS NULL AND completed_at IS NOT NULL)),
                    CHECK(state IN ('revoked','already_revoked') OR completed_at IS NULL)
                )
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX deletion_apple_unknown_client ON account_deletion_apple_credentials(job_id) WHERE client_id IS NULL").run()
            // Copy the original encrypted envelope and audience intact. Keep the
            // legacy columns until successful revocation so old compatible images
            // cannot mistake lost credential material for completed work.
            try await sql.raw("""
                INSERT INTO account_deletion_apple_credentials(id,job_id,client_id,credential_ciphertext,state,completed_at)
                SELECT gen_random_uuid(),id,apple_client_id,apple_credential_ciphertext,
                    CASE WHEN apple_credential_ciphertext IS NOT NULL AND apple_client_id IS NOT NULL
                         AND apple_revocation_state IN ('pending','misconfigured','failing') THEN apple_revocation_state
                         ELSE 'unavailable' END,NULL
                FROM account_deletion_jobs WHERE apple_credential_ciphertext IS NOT NULL
                    OR apple_revocation_state IN ('pending','misconfigured','failing','unavailable')
                """).run()
            try await sql.raw("""
                CREATE FUNCTION require_complete_apple_revocations() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.state='completed' AND EXISTS (
                        SELECT 1 FROM account_deletion_apple_credentials c WHERE c.job_id=NEW.id
                            AND c.state NOT IN ('revoked','already_revoked')
                    ) THEN RAISE EXCEPTION 'Apple revocation remains outstanding' USING ERRCODE='23514'; END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER complete_apple_revocations BEFORE INSERT OR UPDATE ON account_deletion_jobs FOR EACH ROW EXECUTE FUNCTION require_complete_apple_revocations()").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_apple_revocation_work() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE parent_state TEXT;
                BEGIN
                    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Revocation work is durable' USING ERRCODE='23514'; END IF;
                    IF TG_OP='UPDATE' AND (NEW.id,NEW.job_id,NEW.client_id) IS DISTINCT FROM (OLD.id,OLD.job_id,OLD.client_id) THEN
                        RAISE EXCEPTION 'Revocation identity is immutable' USING ERRCODE='23514';
                    END IF;
                    SELECT state INTO parent_state FROM account_deletion_jobs WHERE id=NEW.job_id FOR UPDATE;
                    IF parent_state='completed' AND NEW.state NOT IN ('revoked','already_revoked') THEN
                        RAISE EXCEPTION 'Completed deletion cannot acquire outstanding work' USING ERRCODE='23514';
                    END IF;
                    IF TG_OP='UPDATE' AND OLD.state IN ('revoked','already_revoked') AND NEW IS DISTINCT FROM OLD THEN
                        RAISE EXCEPTION 'Completed revocation is immutable' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER durable_apple_revocation BEFORE INSERT OR UPDATE OR DELETE ON account_deletion_apple_credentials FOR EACH ROW EXECUTE FUNCTION preserve_apple_revocation_work()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep all Apple client credentials and revocation work; use a compatible image")
    }
}
