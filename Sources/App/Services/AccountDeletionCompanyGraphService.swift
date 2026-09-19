import Fluent
import FluentSQL
import Vapor

extension AccountDeletionGraphService {
    /// Erases one company only after a separately confirmed closure has frozen the
    /// workspace and sealed its post-freeze inventory. The enclosing worker owns
    /// the parent lease and transaction; object cleanup remains on the parent job.
    static func eraseCompany(workspaceID: UUID, closureJobID: UUID, parentJobID: UUID,
                             on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        guard let child = try await sql.raw("""
            SELECT c.account_deletion_job_id,c.workspace_id,c.mode,c.state,c.project_count,c.snag_count,
                   c.other_member_count,c.erasure_inventory_hash,c.database_completed_at,
                   j.database_cleanup_state,j.user_id
            FROM company_closure_jobs c JOIN account_deletion_jobs j ON j.id=c.account_deletion_job_id
            JOIN company_closure_confirmations f ON f.id=c.confirmation_id
            WHERE c.id=\(bind:closureJobID) AND f.actor_user_id=j.user_id AND f.workspace_id=c.workspace_id
              AND f.receipt_hash=j.receipt_hash AND f.workspace_revision=c.confirmed_revision
              AND f.inventory_hash=c.inventory_hash AND f.project_count=c.project_count
              AND f.snag_count=c.snag_count AND f.other_member_count=c.other_member_count AND f.consumed_at IS NOT NULL
            FOR UPDATE OF c,j,f
            """).first(),
              try child.decode(column:"account_deletion_job_id",as:UUID.self) == parentJobID,
              try child.decode(column:"workspace_id",as:UUID.self) == workspaceID,
              try child.decode(column:"mode",as:String.self) == "explicit" else {
            throw Abort(.conflict, reason:"Company closure authority does not match this workspace",
                        identifier:"company_closure_scope_mismatch")
        }
        let childState = try child.decode(column:"state",as:String.self)
        if childState == "awaiting_objects" || childState == "completed" {
            guard try child.decode(column:"database_completed_at",as:Date?.self) != nil else {
                throw Abort(.conflict, reason:"Company closure progress is inconsistent",
                            identifier:"company_closure_scope_changed")
            }
            return
        }
        guard childState == "erasing",
              try child.decode(column:"database_cleanup_state",as:String.self) == "blocked",
              let sealedHash = try child.decode(column:"erasure_inventory_hash",as:String?.self) else {
            throw Abort(.conflict, reason:"Company closure is not ready for erasure",
                        identifier:"company_closure_scope_changed")
        }
        let ownerID = try child.decode(column:"user_id",as:UUID.self)
        guard let team = try await sql.raw("""
            SELECT id FROM teams WHERE id=\(bind:workspaceID) AND owner_user_id=\(bind:ownerID)
              AND kind='company' AND lifecycle_state='closing' FOR UPDATE
            """).first() else {
            throw Abort(.conflict, reason:"Company closure scope is unavailable",
                        identifier:"company_closure_scope_changed")
        }
        _ = team

        let inventory = try await companyInventory(workspaceID: workspaceID, on: database)
        guard inventory.fingerprint == sealedHash,
              inventory.projectCount == (try child.decode(column:"project_count",as:Int64.self)),
              inventory.snagCount == (try child.decode(column:"snag_count",as:Int64.self)),
              inventory.otherMemberCount == (try child.decode(column:"other_member_count",as:Int64.self)) else {
            throw Abort(.conflict, reason:"Company data changed after closure was accepted",
                        identifier:"company_closure_inventory_changed")
        }

        try await sql.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:parentJobID.uuidString),true)").run()
        try await sql.raw("SELECT set_config('snaglist.company_closure_job_id',\(bind:closureJobID.uuidString),true)").run()
        try await sql.raw("SET CONSTRAINTS ALL DEFERRED").run()
        try await createCompanyScope(workspaceID: workspaceID, on: sql)
        try await captureWriteIntents(jobID: parentJobID, userFallbackID: nil, on: sql)
        try await captureCompanyObjects(parentJobID: parentJobID, on: sql)
        try await deleteCompanyGraph(on: sql)
        try await assertCompanyScopeEmpty(workspaceID: workspaceID, on: sql)
        // A worker may process several children and then the personal graph on one
        // transaction handle. Remove this child's temporary scope and authority so
        // neither can be rebound accidentally by the next phase.
        try await sql.raw("""
            DROP TABLE account_deletion_discovery_snapshots,account_deletion_completions,account_deletion_links,
                account_deletion_commits,account_deletion_projections,account_deletion_sessions,
                account_deletion_projects,account_deletion_workspaces
            """).run()
        guard try await sql.raw("""
            UPDATE company_closure_jobs SET state='awaiting_objects',database_completed_at=NOW()
            WHERE id=\(bind:closureJobID) AND account_deletion_job_id=\(bind:parentJobID)
              AND workspace_id=\(bind:workspaceID) AND mode='explicit' AND state='erasing'
              AND erasure_inventory_hash=\(bind:sealedHash) RETURNING id
            """).first() != nil else {
            throw Abort(.conflict, reason:"Company closure authority changed during erasure",
                        identifier:"company_closure_scope_changed")
        }
        try await sql.raw("SELECT set_config('snaglist.company_closure_job_id','',true)").run()
    }

    private static func createCompanyScope(workspaceID: UUID, on sql: SQLDatabase) async throws {
        try await sql.raw("CREATE TEMP TABLE account_deletion_workspaces(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_workspaces VALUES(\(bind:workspaceID))").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_projects(id UUID PRIMARY KEY,workspace_id UUID) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_projects SELECT id,workspace_id FROM projects WHERE workspace_id=\(bind:workspaceID)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_sessions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_sessions
            SELECT id FROM staged_legacy_imports WHERE workspace_id=\(bind:workspaceID)
            UNION SELECT session_id FROM legacy_import_commits WHERE project_id IN (SELECT id FROM account_deletion_projects)
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_projections(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_projections SELECT id FROM legacy_canonical_projections WHERE session_id IN (SELECT id FROM account_deletion_sessions)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_commits(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_commits SELECT id FROM legacy_import_commits WHERE session_id IN (SELECT id FROM account_deletion_sessions) OR project_id IN (SELECT id FROM account_deletion_projects)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_links(id UUID PRIMARY KEY,token TEXT UNIQUE) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_links SELECT id,token FROM magic_links WHERE project_id IN (SELECT id FROM account_deletion_projects)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_completions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_completions
            SELECT c.id FROM completions c LEFT JOIN snags s ON s.id=c.snag_id
            WHERE c.magic_link_id IN (SELECT id FROM account_deletion_links)
               OR s.project_id IN (SELECT id FROM account_deletion_projects)
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_discovery_snapshots(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_discovery_snapshots SELECT DISTINCT snapshot_id FROM project_discovery_items WHERE project_id IN (SELECT id FROM account_deletion_projects)").run()
    }

    private static func captureCompanyObjects(parentJobID: UUID, on sql: SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'private_media',key FROM (
                SELECT original_key key FROM media_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT rendition_key FROM media_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)
            ) keys WHERE key IS NOT NULL ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'private_drawing',key FROM (
                SELECT original_key key FROM drawing_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT rendition_key FROM drawing_asset_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT thumbnail_key FROM drawing_asset_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)
            ) keys WHERE key IS NOT NULL ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'private_import',key FROM (
                SELECT rendition_key key FROM imported_file_objects WHERE project_id IN (SELECT id FROM account_deletion_projects) AND rendition_key IS NOT NULL
                UNION SELECT rendition_key FROM legacy_import_file_processing WHERE projection_id IN (SELECT id FROM account_deletion_projections) AND rendition_key IS NOT NULL
                UNION SELECT rendition_key FROM legacy_import_drawing_processing WHERE projection_id IN (SELECT id FROM account_deletion_projections) AND rendition_key IS NOT NULL
                UNION SELECT thumbnail_key FROM legacy_import_drawing_processing WHERE projection_id IN (SELECT id FROM account_deletion_projections) AND thumbnail_key IS NOT NULL
                UNION SELECT 'staged-import/'||lower(i.workspace_id::TEXT)||'/'||lower(f.session_id::TEXT)||'/'||lower(f.declaration_id::TEXT)||'/original'
                    FROM staged_legacy_import_files f JOIN staged_legacy_imports i ON i.id=f.session_id
                    WHERE f.session_id IN (SELECT id FROM account_deletion_sessions)
            ) keys ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'legacy_photo',key FROM (
                SELECT file_path key FROM synced_photos WHERE magic_link_token IN (SELECT token FROM account_deletion_links)
                UNION SELECT thumbnail_file_path FROM synced_photos WHERE magic_link_token IN (SELECT token FROM account_deletion_links) AND thumbnail_file_path IS NOT NULL
                UNION SELECT unnest(file_paths) FROM snag_deletions WHERE project_id IN (SELECT id FROM account_deletion_projects)
            ) keys WHERE key IS NOT NULL ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'legacy_drawing',file_path FROM synced_drawings
            WHERE magic_link_token IN (SELECT token FROM account_deletion_links) ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:parentJobID),'legacy_completion_photo',key FROM (
                SELECT storage_key key FROM completion_upload_objects WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT thumbnail_key FROM completion_upload_objects WHERE project_id IN (SELECT id FROM account_deletion_projects)
            ) keys ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            WITH candidates AS (
                SELECT cp.id source_id,'url' source_field,cp.url object_key FROM completion_photos cp
                    WHERE cp.completion_id IN (SELECT id FROM account_deletion_completions) AND cp.upload_object_id IS NULL
                UNION ALL
                SELECT cp.id,'thumbnail_url',cp.thumbnail_url FROM completion_photos cp
                    WHERE cp.completion_id IN (SELECT id FROM account_deletion_completions)
                      AND cp.upload_object_id IS NULL AND cp.thumbnail_url IS NOT NULL
            )
            INSERT INTO account_deletion_unresolved_objects(job_id,source_kind,source_id,source_field,object_reference,reason,created_at)
            SELECT \(bind:parentJobID),'completion_photo',c.source_id,c.source_field,c.object_key,
                CASE WHEN EXISTS(SELECT 1 FROM completion_photos other
                    WHERE other.completion_id NOT IN (SELECT id FROM account_deletion_completions)
                      AND (ltrim(other.url,'/')=ltrim(c.object_key,'/') OR ltrim(other.thumbnail_url,'/')=ltrim(c.object_key,'/')))
                    THEN 'shared_reference' ELSE 'unknown_local_namespace' END,NOW()
            FROM candidates c WHERE ltrim(c.object_key,'/') LIKE 'uploads/%' OR c.object_key ~ '^https?://[^/]+/uploads/'
            ON CONFLICT DO NOTHING
            """).run()
    }

    private static func deleteCompanyGraph(on sql: SQLDatabase) async throws {
        let statements: [SQLQueryString] = [
            "DELETE FROM audit_logs WHERE resource_type='magic_link' AND resource_id IN (SELECT id FROM account_deletion_links)",
            "DELETE FROM audit_logs WHERE resource_type='team_invite' AND resource_id IN (SELECT id FROM team_invites WHERE team_id IN (SELECT id FROM account_deletion_workspaces))",
            "DELETE FROM legacy_import_directory_publications WHERE commit_id IN (SELECT id FROM account_deletion_commits) OR identity_id IN (SELECT id FROM legacy_canonical_directory_identities WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces))",
            "DELETE FROM legacy_import_published_records WHERE commit_id IN (SELECT id FROM account_deletion_commits)",
            "DELETE FROM legacy_import_commits WHERE id IN (SELECT id FROM account_deletion_commits)",
            "DELETE FROM legacy_import_processing_attempts WHERE projection_id IN (SELECT id FROM account_deletion_projections)",
            "DELETE FROM legacy_import_file_processing WHERE projection_id IN (SELECT id FROM account_deletion_projections)",
            "DELETE FROM legacy_import_drawing_processing WHERE projection_id IN (SELECT id FROM account_deletion_projections)",
            "DELETE FROM legacy_canonical_projection_directories WHERE projection_id IN (SELECT id FROM account_deletion_projections) OR identity_id IN (SELECT id FROM legacy_canonical_directory_identities WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces))",
            "DELETE FROM legacy_canonical_allocations WHERE projection_id IN (SELECT id FROM account_deletion_projections)",
            "DELETE FROM legacy_canonical_directory_identities WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM legacy_canonical_projections WHERE id IN (SELECT id FROM account_deletion_projections)",
            "DELETE FROM imported_photos WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_snag_comments WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_status_changes WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_snag_deletions WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_drawing_provenance WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_file_uses WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM imported_file_objects WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM staged_import_original_receipts WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_import_file_operations WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_edges WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_file_uses WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_actions WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_sources WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_records WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_import_files WHERE session_id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM staged_legacy_imports WHERE id IN (SELECT id FROM account_deletion_sessions)",
            "DELETE FROM link_sessions WHERE grant_id IN (SELECT id FROM link_grants WHERE project_id IN (SELECT id FROM account_deletion_projects))",
            "DELETE FROM link_mutation_receipts WHERE grant_id IN (SELECT id FROM link_grants WHERE project_id IN (SELECT id FROM account_deletion_projects))",
            "DELETE FROM link_media WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM link_items WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM content_reports WHERE completion_id IN (SELECT id FROM account_deletion_completions)",
            "DELETE FROM completion_photos WHERE completion_id IN (SELECT id FROM account_deletion_completions)",
            "DELETE FROM completions WHERE id IN (SELECT id FROM account_deletion_completions)",
            "DELETE FROM completion_upload_objects WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM review_decisions WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM completion_evidence WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM completion_attempts WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM workflow_outbox WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_pin_events WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM snag_drawing_pins WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_version_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_versions WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawings WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_original_receipts WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_processing_jobs WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_asset_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM drawing_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM media_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM assignment_history WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_comments WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM snag_send_backs WHERE snag_id IN (SELECT id FROM snags WHERE project_id IN (SELECT id FROM account_deletion_projects))",
            "DELETE FROM snag_deletions WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM synced_photos WHERE magic_link_token IN (SELECT token FROM account_deletion_links)",
            "DELETE FROM synced_drawings WHERE magic_link_token IN (SELECT token FROM account_deletion_links)",
            "DELETE FROM synced_reports WHERE magic_link_token IN (SELECT token FROM account_deletion_links)",
            "DELETE FROM magic_link_accesses WHERE magic_link_id IN (SELECT id FROM account_deletion_links)",
            "DELETE FROM magic_link_sends WHERE magic_link_id IN (SELECT id FROM account_deletion_links)",
            "DELETE FROM magic_links WHERE id IN (SELECT id FROM account_deletion_links)",
            "DELETE FROM platform_changes WHERE project_id IN (SELECT id FROM account_deletion_projects) OR workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM project_change_cursors WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM register_snapshots WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_discovery_items WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_discovery_snapshots WHERE id IN (SELECT id FROM account_deletion_discovery_snapshots) AND NOT EXISTS(SELECT 1 FROM project_discovery_items i WHERE i.snapshot_id=project_discovery_snapshots.id)",
            "DELETE FROM mutation_receipts WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM invitation_project_grants WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_access WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_folder_links WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM project_tag_links WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM snags WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM workspace_activity WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM link_grants WHERE project_id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM projects WHERE id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM contractor_trades WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM contractors WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM trades WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM workspace_folders WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM workspace_tags WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM invitation_project_grants WHERE invitation_id IN (SELECT id FROM team_invites WHERE team_id IN (SELECT id FROM account_deletion_workspaces))",
            "DELETE FROM team_invites WHERE team_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM ownership_transfer_offers WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM workspace_memberships WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces)",
            "DELETE FROM teams WHERE id IN (SELECT id FROM account_deletion_workspaces)"
        ]
        for statement in statements { try await sql.raw(statement).run() }
    }

    private static func assertCompanyScopeEmpty(workspaceID: UUID, on sql: SQLDatabase) async throws {
        try await sql.raw("SELECT set_config('snaglist.company_erasure_workspace_id',\(bind:workspaceID.uuidString),true)").run()
        try await sql.raw("""
            DO $$ DECLARE item RECORD; scope_id UUID; remains BOOLEAN;
            BEGIN
                scope_id:=current_setting('snaglist.company_erasure_workspace_id')::UUID;
                FOR item IN
                    SELECT c.table_schema,c.table_name,
                        bool_or(c.column_name='workspace_id') has_workspace,
                        bool_or(c.column_name='team_id') has_team,
                        bool_or(c.column_name='project_id') has_project
                    FROM information_schema.columns c JOIN information_schema.tables t
                      ON t.table_schema=c.table_schema AND t.table_name=c.table_name
                    WHERE c.table_schema=current_schema() AND t.table_type='BASE TABLE'
                      AND c.column_name IN ('workspace_id','team_id','project_id')
                      AND c.table_name NOT IN ('company_closure_confirmations','company_closure_jobs',
                          'object_write_intents','account_deletion_write_intents')
                    GROUP BY c.table_schema,c.table_name ORDER BY c.table_name
                LOOP
                    IF item.has_workspace AND item.has_project THEN
                        EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE workspace_id=$1 OR project_id IN (SELECT id FROM pg_temp.account_deletion_projects))',item.table_schema,item.table_name) INTO remains USING scope_id;
                    ELSIF item.has_workspace THEN
                        EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE workspace_id=$1)',item.table_schema,item.table_name) INTO remains USING scope_id;
                    ELSIF item.has_team AND item.table_name='team_invites' THEN
                        EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE team_id=$1)',item.table_schema,item.table_name) INTO remains USING scope_id;
                    ELSIF item.has_project THEN
                        EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE project_id IN (SELECT id FROM pg_temp.account_deletion_projects))',item.table_schema,item.table_name) INTO remains;
                    ELSE remains:=FALSE;
                    END IF;
                    IF remains THEN RAISE EXCEPTION 'Company closure graph is incomplete: %',item.table_name USING ERRCODE='23514'; END IF;
                END LOOP;
            END $$
            """).run()
        guard try await sql.raw("SELECT id FROM teams WHERE id=\(bind:workspaceID)").first() == nil else {
            throw Abort(.conflict, reason:"Company closure graph is incomplete",identifier:"company_closure_graph_incomplete")
        }
    }
}
