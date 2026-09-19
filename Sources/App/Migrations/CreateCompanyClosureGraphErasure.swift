import Fluent
import FluentSQL
import Vapor

/// Adds a closure-child authority without widening personal-account erasure.
/// It also fences inserts and updates which resolve to a closing company,
/// including legacy rows whose workspace is only reachable through a parent.
struct CreateCompanyClosureGraphErasure: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE FUNCTION company_closure_write_allowed(scope_id UUID) RETURNS BOOLEAN
                LANGUAGE plpgsql VOLATILE AS $$
                DECLARE deletion_job UUID; closure_job UUID;
                BEGIN
                    BEGIN deletion_job:=NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    BEGIN closure_job:=NULLIF(current_setting('snaglist.company_closure_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    IF deletion_job IS NULL OR closure_job IS NULL THEN RETURN FALSE; END IF;
                    RETURN EXISTS(
                        SELECT 1 FROM company_closure_jobs c JOIN account_deletion_jobs j ON j.id=c.account_deletion_job_id
                        JOIN company_closure_confirmations f ON f.id=c.confirmation_id JOIN teams t ON t.id=c.workspace_id
                        WHERE c.id=closure_job AND c.account_deletion_job_id=deletion_job AND c.workspace_id=scope_id
                          AND c.mode='explicit' AND c.state='erasing'
                          AND f.actor_user_id=j.user_id AND f.actor_user_id=t.owner_user_id AND f.workspace_id=c.workspace_id
                          AND f.receipt_hash=j.receipt_hash AND f.workspace_revision=c.confirmed_revision
                          AND f.inventory_hash=c.inventory_hash AND f.project_count=c.project_count
                          AND f.snag_count=c.snag_count AND f.other_member_count=c.other_member_count AND f.consumed_at IS NOT NULL
                          AND j.database_cleanup_state='blocked' AND t.kind='company' AND t.lifecycle_state='closing'
                    );
                END $$
                """).run()
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION account_deletion_erasure_allowed(old_row JSONB) RETURNS BOOLEAN
                LANGUAGE plpgsql VOLATILE AS $$
                DECLARE deletion_job UUID; closure_job UUID; deletion_user UUID; closure_workspace UUID;
                    scoped_project UUID; scoped_workspace UUID; scoped_session UUID; scoped_projection UUID;
                BEGIN
                    BEGIN deletion_job:=NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    IF deletion_job IS NULL THEN RETURN FALSE; END IF;
                    BEGIN closure_job:=NULLIF(current_setting('snaglist.company_closure_job_id',true),'')::UUID;
                    EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;

                    IF closure_job IS NOT NULL THEN
                        SELECT c.workspace_id,j.user_id INTO closure_workspace,deletion_user
                        FROM company_closure_jobs c JOIN account_deletion_jobs j ON j.id=c.account_deletion_job_id
                        JOIN company_closure_confirmations f ON f.id=c.confirmation_id JOIN teams t ON t.id=c.workspace_id
                        WHERE c.id=closure_job AND c.account_deletion_job_id=deletion_job
                          AND c.mode='explicit' AND c.state='erasing' AND c.erasure_inventory_hash IS NOT NULL
                          AND f.actor_user_id=j.user_id AND f.actor_user_id=t.owner_user_id AND f.workspace_id=c.workspace_id
                          AND f.receipt_hash=j.receipt_hash AND f.workspace_revision=c.confirmed_revision
                          AND f.inventory_hash=c.inventory_hash AND f.project_count=c.project_count
                          AND f.snag_count=c.snag_count AND f.other_member_count=c.other_member_count AND f.consumed_at IS NOT NULL
                          AND j.database_cleanup_state='blocked' AND t.kind='company' AND t.lifecycle_state='closing'
                        FOR SHARE OF c,j,t;
                        IF closure_workspace IS NULL THEN RETURN FALSE; END IF;
                    ELSE
                        SELECT user_id INTO deletion_user FROM account_deletion_jobs
                        WHERE id=deletion_job AND database_cleanup_state='blocked' FOR SHARE;
                        IF deletion_user IS NULL THEN RETURN FALSE; END IF;
                    END IF;

                    BEGIN scoped_project:=NULLIF(old_row->>'project_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    BEGIN scoped_workspace:=NULLIF(old_row->>'workspace_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    BEGIN scoped_session:=NULLIF(old_row->>'session_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
                    BEGIN scoped_projection:=NULLIF(old_row->>'projection_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN FALSE; END;
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
                    IF scoped_project IS NULL AND old_row ? 'asset_id' THEN SELECT project_id INTO scoped_project FROM drawing_assets WHERE id=(old_row->>'asset_id')::UUID; END IF;
                    IF scoped_project IS NULL AND old_row ? 'drawing_id' THEN SELECT project_id INTO scoped_project FROM drawings WHERE id=(old_row->>'drawing_id')::UUID; END IF;
                    IF scoped_project IS NULL AND old_row ? 'snag_id' THEN SELECT project_id INTO scoped_project FROM snags WHERE id=(old_row->>'snag_id')::UUID; END IF;
                    IF scoped_session IS NULL AND scoped_projection IS NOT NULL THEN
                        SELECT session_id INTO scoped_session FROM legacy_canonical_projections WHERE id=scoped_projection;
                    END IF;

                    IF closure_workspace IS NOT NULL THEN
                        IF scoped_workspace=closure_workspace THEN RETURN TRUE; END IF;
                        IF scoped_project IS NOT NULL AND EXISTS(SELECT 1 FROM projects WHERE id=scoped_project AND workspace_id=closure_workspace) THEN RETURN TRUE; END IF;
                        IF scoped_session IS NOT NULL AND EXISTS(SELECT 1 FROM staged_legacy_imports WHERE id=scoped_session AND workspace_id=closure_workspace) THEN RETURN TRUE; END IF;
                        RETURN FALSE;
                    END IF;
                    IF scoped_project IS NOT NULL AND EXISTS(
                        SELECT 1 FROM projects p LEFT JOIN teams t ON t.id=p.workspace_id
                        WHERE p.id=scoped_project AND ((t.kind='personal' AND t.owner_user_id=deletion_user)
                            OR (p.workspace_id IS NULL AND p.owner_id=deletion_user))
                    ) THEN RETURN TRUE; END IF;
                    IF scoped_workspace IS NOT NULL AND EXISTS(
                        SELECT 1 FROM teams WHERE id=scoped_workspace AND kind='personal' AND owner_user_id=deletion_user
                    ) THEN RETURN TRUE; END IF;
                    IF scoped_session IS NOT NULL AND EXISTS(
                        SELECT 1 FROM staged_legacy_imports i JOIN teams t ON t.id=i.workspace_id
                        WHERE i.id=scoped_session AND i.actor_id=deletion_user AND t.kind='personal' AND t.owner_user_id=deletion_user
                    ) THEN RETURN TRUE; END IF;
                    RETURN FALSE;
                END $$
                """).run()
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION require_live_workspace_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                DECLARE source JSONB; scope_id UUID; claimed BOOLEAN; resolved_parent BOOLEAN;
                    scope_state TEXT; scope_kind TEXT; deletion_job UUID; closure_setting TEXT;
                BEGIN
                  FOR source IN
                    SELECT value FROM jsonb_array_elements(CASE TG_OP WHEN 'INSERT' THEN jsonb_build_array(to_jsonb(NEW))
                        WHEN 'UPDATE' THEN jsonb_build_array(to_jsonb(OLD),to_jsonb(NEW)) ELSE jsonb_build_array(to_jsonb(OLD)) END)
                  LOOP
                    scope_id:=NULL; claimed:=FALSE; resolved_parent:=FALSE;
                    BEGIN scope_id:=NULLIF(source->>'workspace_id','')::UUID; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514'; END;
                    claimed:=scope_id IS NOT NULL;
                    IF scope_id IS NULL AND TG_TABLE_NAME='team_invites' AND NULLIF(source->>'team_id','') IS NOT NULL THEN
                        claimed:=TRUE; scope_id:=(source->>'team_id')::UUID;
                    END IF;
                    IF scope_id IS NULL AND TG_TABLE_NAME='audit_logs' AND source->>'resource_type'='magic_link'
                       AND NULLIF(source->>'resource_id','') IS NOT NULL THEN
                        claimed:=TRUE; SELECT p.workspace_id INTO scope_id FROM magic_links m LEFT JOIN projects p ON p.id=m.project_id
                            WHERE m.id=(source->>'resource_id')::UUID; resolved_parent:=FOUND;
                    END IF;
                    IF scope_id IS NULL AND TG_TABLE_NAME='audit_logs' AND source->>'resource_type'='team_invite'
                       AND NULLIF(source->>'resource_id','') IS NOT NULL THEN
                        claimed:=TRUE; SELECT team_id INTO scope_id FROM team_invites WHERE id=(source->>'resource_id')::UUID; resolved_parent:=FOUND;
                    END IF;
                    IF scope_id IS NULL AND TG_TABLE_NAME='snag_deletions' THEN
                        claimed:=TRUE;
                        SELECT workspace_id INTO scope_id FROM projects WHERE id=(source->>'project_id')::UUID;
                        resolved_parent:=FOUND;
                        IF NOT resolved_parent THEN
                            IF TG_OP='UPDATE' THEN
                                IF NEW.owner_id=OLD.owner_id AND NEW.project_id=OLD.project_id AND NEW.snag_id=OLD.snag_id
                                   AND EXISTS(SELECT 1 FROM users WHERE id=NEW.owner_id AND lifecycle_state='active' FOR SHARE) THEN
                                    resolved_parent:=TRUE;
                                END IF;
                            ELSIF TG_OP='INSERT' THEN
                                IF EXISTS(SELECT 1 FROM users WHERE id=(source->>'owner_id')::UUID AND lifecycle_state='active' FOR SHARE)
                                   AND EXISTS(SELECT 1 FROM magic_links WHERE project_id=(source->>'project_id')::UUID
                                       AND created_by_id=(source->>'owner_id')::UUID) THEN
                                    resolved_parent:=TRUE;
                                END IF;
                            ELSE
                                BEGIN deletion_job:=NULLIF(current_setting('snaglist.account_deletion_job_id',true),'')::UUID;
                                EXCEPTION WHEN invalid_text_representation THEN deletion_job:=NULL; END;
                                closure_setting:=NULLIF(current_setting('snaglist.company_closure_job_id',true),'');
                                IF closure_setting IS NULL AND EXISTS(
                                    SELECT 1 FROM account_deletion_jobs WHERE id=deletion_job
                                      AND user_id=(source->>'owner_id')::UUID AND database_cleanup_state='blocked' FOR SHARE
                                ) THEN resolved_parent:=TRUE; END IF;
                            END IF;
                        END IF;
                        IF NOT resolved_parent THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514'; END IF;
                        IF scope_id IS NULL THEN CONTINUE; END IF;
                    END IF;
                    IF scope_id IS NULL AND TG_TABLE_NAME<>'snag_deletions' AND NULLIF(source->>'project_id','') IS NOT NULL THEN
                        claimed:=TRUE; SELECT workspace_id INTO scope_id FROM projects WHERE id=(source->>'project_id')::UUID; resolved_parent:=FOUND;
                        -- Released legacy Contractor links may intentionally have no
                        -- canonical project row. Their active creator/link guards
                        -- remain authoritative and must keep this path compatible.
                        IF TG_TABLE_NAME='magic_links' AND NOT resolved_parent THEN resolved_parent:=TRUE; END IF;
                    END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'snag_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM snags WHERE id=(source->>'snag_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'magic_link_id','') IS NOT NULL THEN claimed:=TRUE; SELECT p.workspace_id INTO scope_id FROM magic_links m LEFT JOIN projects p ON p.id=m.project_id WHERE m.id=(source->>'magic_link_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'magic_link_token','') IS NOT NULL THEN claimed:=TRUE; SELECT p.workspace_id INTO scope_id FROM magic_links m LEFT JOIN projects p ON p.id=m.project_id WHERE m.token=source->>'magic_link_token'; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'completion_id','') IS NOT NULL THEN
                        claimed:=TRUE;
                        SELECT COALESCE(sp.workspace_id,mp.workspace_id) INTO scope_id FROM completions c
                        LEFT JOIN snags s ON s.id=c.snag_id LEFT JOIN projects sp ON sp.id=s.project_id
                        LEFT JOIN magic_links m ON m.id=c.magic_link_id LEFT JOIN projects mp ON mp.id=m.project_id
                        WHERE c.id=(source->>'completion_id')::UUID;
                        resolved_parent:=FOUND;
                        -- The parent's guarded DELETE has already succeeded when
                        -- PostgreSQL invokes these exact ON DELETE CASCADE children.
                        -- A direct orphan DELETE remains at trigger depth one.
                        IF NOT resolved_parent AND TG_OP='DELETE'
                           AND TG_TABLE_NAME IN ('completion_photos','content_reports')
                           AND pg_trigger_depth()>1 THEN resolved_parent:=TRUE; END IF;
                    END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'grant_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM link_grants WHERE id=(source->>'grant_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'session_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM staged_legacy_imports WHERE id=(source->>'session_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'projection_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM legacy_canonical_projections WHERE id=(source->>'projection_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'commit_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM legacy_import_commits WHERE id=(source->>'commit_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'asset_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM drawing_assets WHERE id=(source->>'asset_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'drawing_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM drawings WHERE id=(source->>'drawing_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'identity_id','') IS NOT NULL THEN claimed:=TRUE; SELECT workspace_id INTO scope_id FROM legacy_canonical_directory_identities WHERE id=(source->>'identity_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'invitation_id','') IS NOT NULL THEN claimed:=TRUE; SELECT team_id INTO scope_id FROM team_invites WHERE id=(source->>'invitation_id')::UUID; resolved_parent:=FOUND; END IF;
                    IF scope_id IS NULL AND NULLIF(source->>'snapshot_id','') IS NOT NULL THEN
                        claimed:=TRUE; SELECT workspace_id INTO scope_id FROM register_snapshots WHERE id=(source->>'snapshot_id')::UUID; resolved_parent:=FOUND;
                    END IF;
                    IF scope_id IS NULL THEN
                        IF resolved_parent THEN CONTINUE; END IF;
                        IF claimed THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514'; END IF;
                        CONTINUE;
                    END IF;
                    SELECT kind,lifecycle_state INTO scope_kind,scope_state FROM teams WHERE id=scope_id FOR SHARE;
                    IF scope_state='active' THEN CONTINUE; END IF;
                    IF scope_kind='company' AND scope_state='closing' AND company_closure_write_allowed(scope_id) THEN CONTINUE; END IF;
                    RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514';
                  END LOOP;
                  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
                  RETURN NEW;
                END $$
                """).run()
            // Each listed table has one of the relationships resolved by the
            // function above. Do not infer semantics from a generic column name:
            // session_id, asset_id and snapshot_id exist in unrelated domains.
            let guardedTables = [
                "workspace_memberships","project_access","projects","snags","team_invites",
                "invitation_project_grants","workspace_activity","mutation_receipts","platform_changes",
                "project_change_cursors","register_snapshots","register_snapshot_items","contractors","trades",
                "contractor_trades","workspace_folders","workspace_tags","assignment_history","media_assets",
                "completion_attempts","completion_evidence","review_decisions","workflow_outbox","drawing_assets",
                "drawing_processing_jobs","drawing_asset_pages","drawings","drawing_versions","drawing_version_pages",
                "drawing_original_receipts","snag_drawing_pins","drawing_pin_events","staged_legacy_imports",
                "staged_legacy_import_sources","staged_legacy_import_records","staged_legacy_import_edges",
                "staged_legacy_import_files","staged_legacy_import_file_uses","staged_legacy_import_actions",
                "staged_import_file_operations","staged_import_original_receipts","legacy_canonical_projections",
                "legacy_canonical_allocations","legacy_canonical_directory_identities",
                "legacy_canonical_projection_directories","legacy_import_processing_attempts",
                "legacy_import_file_processing","legacy_import_drawing_processing","legacy_import_commits",
                "legacy_import_published_records","legacy_import_directory_publications","imported_file_objects",
                "imported_file_uses","imported_photos","imported_snag_comments","imported_status_changes",
                "imported_snag_deletions","imported_drawing_provenance","project_folder_links","project_tag_links",
                "project_comments","project_discovery_items","link_grants","link_items","link_media","link_sessions",
                "link_mutation_receipts","magic_links","magic_link_accesses","magic_link_sends","completions",
                "completion_photos","content_reports","completion_upload_objects","snag_deletions","snag_send_backs",
                "synced_photos","synced_drawings","synced_reports","ownership_transfer_offers","audit_logs"
            ]
            for table in guardedTables {
                try await sql.raw("DROP TRIGGER IF EXISTS account_closure_workspace_insert ON \(unsafeRaw:table)").run()
                try await sql.raw("DROP TRIGGER IF EXISTS account_closure_graph_write ON \(unsafeRaw:table)").run()
                try await sql.raw("CREATE TRIGGER account_closure_graph_write BEFORE INSERT OR UPDATE OR DELETE ON \(unsafeRaw:table) FOR EACH ROW EXECUTE FUNCTION require_live_workspace_insert()").run()
            }
            try await sql.raw("""
                CREATE FUNCTION preserve_closing_company() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF OLD.kind='company' AND OLD.lifecycle_state='closing' AND NOT company_closure_write_allowed(OLD.id) THEN
                        RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23514';
                    END IF;
                    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER account_closure_team_write BEFORE UPDATE OR DELETE ON teams FOR EACH ROW EXECUTE FUNCTION preserve_closing_company()").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason:"Company closure erasure guards are persistent; use a compatible image")
    }
}
