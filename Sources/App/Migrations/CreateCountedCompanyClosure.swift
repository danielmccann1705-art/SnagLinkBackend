import Vapor
import Fluent

struct CreateCountedCompanyClosure: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE company_closure_confirmations (
                    id UUID PRIMARY KEY, actor_user_id UUID NOT NULL REFERENCES users(id), workspace_id UUID NOT NULL,
                    reference_hash TEXT NOT NULL UNIQUE, receipt_hash TEXT NOT NULL,
                    workspace_revision BIGINT NOT NULL, project_count BIGINT NOT NULL CHECK(project_count>=0),
                    snag_count BIGINT NOT NULL CHECK(snag_count>=0), other_member_count BIGINT NOT NULL CHECK(other_member_count>=0),
                    inventory_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                    consumed_at TIMESTAMPTZ, CHECK(expires_at>created_at), CHECK(consumed_at IS NULL OR consumed_at>=created_at)
                )
                """).run()
            try await sql.raw("""
                ALTER TABLE company_closure_jobs
                    DROP CONSTRAINT company_closure_jobs_mode_check,
                    DROP CONSTRAINT company_closure_jobs_state_check,
                    DROP CONSTRAINT company_closure_jobs_project_count_check,
                    DROP CONSTRAINT company_closure_jobs_snag_count_check,
                    DROP CONSTRAINT company_closure_jobs_other_member_count_check,
                    ALTER COLUMN completed_at DROP NOT NULL,
                    ADD COLUMN confirmation_id UUID REFERENCES company_closure_confirmations(id),
                    ADD COLUMN inventory_hash TEXT,
                    ADD COLUMN erasure_inventory_hash TEXT,
                    ADD COLUMN database_completed_at TIMESTAMPTZ,
                    ADD CONSTRAINT company_closure_mode CHECK(mode IN ('empty','explicit')),
                    ADD CONSTRAINT company_closure_state CHECK(state IN ('pending','erasing','awaiting_objects','completed','blocked')),
                    ADD CONSTRAINT company_closure_counts CHECK(project_count>=0 AND snag_count>=0 AND other_member_count>=0),
                    ADD CONSTRAINT company_closure_completion CHECK((state='completed')=(completed_at IS NOT NULL)),
                    ADD CONSTRAINT company_closure_empty CHECK(mode<>'empty' OR (state='completed' AND project_count=0 AND snag_count=0 AND other_member_count=0)),
                    ADD CONSTRAINT company_closure_confirmed CHECK(mode<>'explicit' OR (confirmation_id IS NOT NULL AND inventory_hash IS NOT NULL))
                """).run()
            try await sql.raw("UPDATE company_closure_jobs SET database_completed_at=completed_at WHERE mode='empty'").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_company_closure_confirmation() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF TG_OP='INSERT' THEN
                        IF NEW.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'New confirmation must be unconsumed' USING ERRCODE='23514'; END IF;
                        RETURN NEW;
                    END IF;
                    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Closure confirmation is durable' USING ERRCODE='23514'; END IF;
                    IF (to_jsonb(NEW)-'consumed_at') IS DISTINCT FROM (to_jsonb(OLD)-'consumed_at')
                       OR OLD.consumed_at IS NOT NULL OR NEW.consumed_at IS NULL
                       OR NEW.consumed_at<OLD.created_at OR NEW.consumed_at>=OLD.expires_at THEN
                        RAISE EXCEPTION 'Closure confirmation evidence is immutable' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER company_closure_confirmation_evidence BEFORE INSERT OR UPDATE OR DELETE ON company_closure_confirmations FOR EACH ROW EXECUTE FUNCTION preserve_company_closure_confirmation()").run()
            try await sql.raw("CREATE INDEX company_closure_parent_state ON company_closure_jobs(account_deletion_job_id,state)").run()
            try await sql.raw("""
                CREATE FUNCTION preserve_company_closure_work() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE parent_state TEXT; parent_expiry TIMESTAMPTZ; scoped_parent UUID; scoped_child UUID;
                BEGIN
                    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Closure receipt is durable' USING ERRCODE='23514'; END IF;
                    IF TG_OP='UPDATE' THEN
                        IF (NEW.id,NEW.account_deletion_job_id,NEW.workspace_id,NEW.confirmed_revision,NEW.mode,NEW.confirmation_id,NEW.inventory_hash,NEW.project_count,NEW.snag_count,NEW.other_member_count,NEW.requested_at)
                            IS DISTINCT FROM
                           (OLD.id,OLD.account_deletion_job_id,OLD.workspace_id,OLD.confirmed_revision,OLD.mode,OLD.confirmation_id,OLD.inventory_hash,OLD.project_count,OLD.snag_count,OLD.other_member_count,OLD.requested_at) THEN
                            RAISE EXCEPTION 'Closure authority is immutable' USING ERRCODE='23514';
                        END IF;
                        IF OLD.erasure_inventory_hash IS NOT NULL AND NEW.erasure_inventory_hash IS DISTINCT FROM OLD.erasure_inventory_hash THEN
                            RAISE EXCEPTION 'Accepted inventory is immutable' USING ERRCODE='23514';
                        END IF;
                        IF OLD.state='completed' AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
                            RAISE EXCEPTION 'Completed closure is immutable' USING ERRCODE='23514';
                        END IF;
                    END IF;
                    SELECT state,lease_expires_at INTO parent_state,parent_expiry FROM account_deletion_jobs WHERE id=NEW.account_deletion_job_id FOR UPDATE;
                    IF NEW.mode='explicit' THEN
                        IF TG_OP='INSERT' THEN
                            IF NEW.state<>'erasing' OR NEW.erasure_inventory_hash IS NOT NULL OR NEW.database_completed_at IS NOT NULL
                               OR NOT EXISTS(
                                SELECT 1 FROM company_closure_confirmations c
                                JOIN account_deletion_jobs j ON j.id=NEW.account_deletion_job_id
                                JOIN teams t ON t.id=NEW.workspace_id
                                WHERE c.id=NEW.confirmation_id AND c.actor_user_id=j.user_id AND t.owner_user_id=j.user_id
                                  AND c.workspace_id=NEW.workspace_id AND c.receipt_hash=j.receipt_hash
                                  AND c.workspace_revision=NEW.confirmed_revision AND t.revision=NEW.confirmed_revision
                                  AND c.project_count=NEW.project_count AND c.snag_count=NEW.snag_count
                                  AND c.other_member_count=NEW.other_member_count AND c.inventory_hash=NEW.inventory_hash
                                  AND c.consumed_at IS NOT NULL AND c.consumed_at<c.expires_at
                                  AND t.kind='company' AND t.lifecycle_state='active' AND j.database_cleanup_state='blocked'
                               ) THEN RAISE EXCEPTION 'Closure confirmation does not authorize this company' USING ERRCODE='23514'; END IF;
                        ELSE
                            BEGIN
                                scoped_parent:=NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                                scoped_child:=NULLIF(current_setting('snaglist.company_closure_job_id',true),'')::UUID;
                            EXCEPTION WHEN invalid_text_representation THEN
                                RAISE EXCEPTION 'Closure progress authority is invalid' USING ERRCODE='23514';
                            END;
                            IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
                                IF scoped_parent IS DISTINCT FROM NEW.account_deletion_job_id OR scoped_child IS DISTINCT FROM NEW.id THEN
                                    RAISE EXCEPTION 'Closure progress requires exact context' USING ERRCODE='23514';
                                END IF;
                                IF OLD.database_completed_at IS NOT NULL AND NEW.database_completed_at IS DISTINCT FROM OLD.database_completed_at THEN
                                    RAISE EXCEPTION 'Database closure progress is immutable' USING ERRCODE='23514';
                                END IF;
                                IF OLD.state='erasing' AND NEW.state='erasing' THEN
                                    IF OLD.erasure_inventory_hash IS NOT NULL OR NEW.erasure_inventory_hash IS NULL OR NEW.database_completed_at IS NOT NULL THEN
                                        RAISE EXCEPTION 'Invalid accepted inventory seal' USING ERRCODE='23514';
                                    END IF;
                                ELSIF OLD.state='erasing' AND NEW.state='awaiting_objects' THEN
                                    IF NEW.erasure_inventory_hash IS NULL OR NEW.database_completed_at IS NULL
                                       OR parent_state<>'leased' OR parent_expiry IS NULL OR parent_expiry<=clock_timestamp() THEN
                                        RAISE EXCEPTION 'Database closure requires current leased work' USING ERRCODE='23514';
                                    END IF;
                                ELSIF OLD.state='awaiting_objects' AND NEW.state='completed' THEN
                                    IF parent_state<>'leased' OR parent_expiry IS NULL OR parent_expiry<=clock_timestamp()
                                       OR EXISTS(SELECT 1 FROM account_deletion_jobs WHERE id=NEW.account_deletion_job_id AND database_cleanup_state<>'completed')
                                       OR EXISTS(SELECT 1 FROM account_deletion_objects WHERE job_id=NEW.account_deletion_job_id AND completed_at IS NULL)
                                       OR EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=NEW.account_deletion_job_id) THEN
                                        RAISE EXCEPTION 'Object closure is unfinished or unleased' USING ERRCODE='23514';
                                    END IF;
                                ELSE RAISE EXCEPTION 'Invalid company closure transition' USING ERRCODE='23514'; END IF;
                            END IF;
                        END IF;
                    END IF;
                    IF parent_state='completed' AND NEW.state<>'completed' THEN
                        RAISE EXCEPTION 'Parent already completed' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER company_closure_durable_work BEFORE INSERT OR UPDATE OR DELETE ON company_closure_jobs FOR EACH ROW EXECUTE FUNCTION preserve_company_closure_work()").run()
            // Completion remains impossible even if a future caller forgets the
            // worker's closure dependency check.
            try await sql.raw("""
                CREATE FUNCTION require_complete_company_closures() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.state='completed' AND EXISTS(SELECT 1 FROM company_closure_jobs WHERE account_deletion_job_id=NEW.id AND state<>'completed') THEN
                        RAISE EXCEPTION 'Company closure is unfinished' USING ERRCODE='23514';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER account_deletion_company_dependencies BEFORE INSERT OR UPDATE ON account_deletion_jobs FOR EACH ROW EXECUTE FUNCTION require_complete_company_closures()").run()
        }
    }
    func revert(on database: Database) async throws { throw Abort(.conflict, reason: "Counted company closure authority must remain durable; use a compatible image") }
}
