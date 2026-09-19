import Vapor
import Fluent

struct CreateEmptyCompanyClosure: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE company_closure_jobs (
                    id UUID PRIMARY KEY, account_deletion_job_id UUID NOT NULL REFERENCES account_deletion_jobs(id),
                    workspace_id UUID NOT NULL UNIQUE, confirmed_revision BIGINT NOT NULL,
                    mode TEXT NOT NULL CHECK(mode='empty'),
                    project_count BIGINT NOT NULL CHECK(project_count=0), snag_count BIGINT NOT NULL CHECK(snag_count=0),
                    other_member_count BIGINT NOT NULL CHECK(other_member_count=0),
                    state TEXT NOT NULL CHECK(state='completed'),
                    requested_at TIMESTAMPTZ NOT NULL, completed_at TIMESTAMPTZ NOT NULL
                )
                """).run()
            // Lock the referenced live workspace even in legacy tables without
            // FKs. Empty closure holds FOR UPDATE until its deletion commits;
            // an in-flight INSERT then either precedes inventory or fails.
            try await sql.raw("""
                CREATE FUNCTION require_live_workspace_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE scope_id UUID; old_scope UUID;
                BEGIN
                    scope_id := NULLIF(to_jsonb(NEW)->>TG_ARGV[0],'')::UUID;
                    IF TG_OP='UPDATE' THEN
                        old_scope := NULLIF(to_jsonb(OLD)->>TG_ARGV[0],'')::UUID;
                        IF old_scope IS NOT DISTINCT FROM scope_id THEN RETURN NEW; END IF;
                    END IF;
                    IF scope_id IS NOT NULL THEN
                        PERFORM id FROM teams WHERE id=scope_id AND lifecycle_state='active' FOR SHARE;
                        IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514'; END IF;
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("""
                DO $$ DECLARE item RECORD; BEGIN
                    FOR item IN
                        SELECT c.table_schema,c.table_name,c.column_name FROM information_schema.columns c
                        JOIN information_schema.tables t ON t.table_schema=c.table_schema AND t.table_name=c.table_name
                        WHERE c.table_schema=current_schema() AND t.table_type='BASE TABLE' AND c.udt_name='uuid'
                          AND (c.column_name='workspace_id' OR (c.table_name='team_invites' AND c.column_name='team_id'))
                          AND c.table_name<>'company_closure_jobs'
                    LOOP
                        EXECUTE format('CREATE TRIGGER account_closure_workspace_insert BEFORE INSERT OR UPDATE OF %I ON %I.%I FOR EACH ROW EXECUTE FUNCTION require_live_workspace_insert(%L)',
                            item.column_name,item.table_schema,item.table_name,item.column_name);
                    END LOOP;
                END $$
                """).run()
        }
    }
    func revert(on database: Database) async throws { throw Abort(.conflict, reason: "Company closure receipts are persistent; use a compatible image") }
}
