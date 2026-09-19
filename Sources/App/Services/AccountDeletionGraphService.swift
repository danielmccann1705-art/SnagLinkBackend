import Fluent
import FluentSQL
import Vapor

enum AccountDeletionGraphService {
    /// Runs inside AccountDeletionService's transaction after access revocation and
    /// shared structured-name replacement. Any failure rolls the entire request back.
    static func erase(userID: UUID, jobID: UUID, on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        guard let job = try await sql.raw("""
            SELECT user_id,database_cleanup_state FROM account_deletion_jobs WHERE id=\(bind: jobID) FOR UPDATE
            """).first(), try job.decode(column: "user_id", as: UUID.self) == userID else {
            throw Abort(.conflict, reason: "Deletion job does not belong to this account", identifier: "deletion_job_scope_mismatch")
        }
        if try job.decode(column: "database_cleanup_state", as: String.self) == "completed" { return }

        // Local to this transaction. Every immutable trigger also verifies job/user/row scope.
        try await sql.raw("SELECT set_config('snaglist.account_deletion_job_id', \(bind: jobID.uuidString), true)").run()
        try await sql.raw("SET CONSTRAINTS ALL DEFERRED").run()

        try await sql.raw("CREATE TEMP TABLE account_deletion_workspaces(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_workspaces SELECT id FROM teams WHERE kind='personal' AND owner_user_id=\(bind:userID)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_projects(id UUID PRIMARY KEY, workspace_id UUID) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_projects(id,workspace_id)
            SELECT p.id,p.workspace_id FROM projects p LEFT JOIN teams t ON t.id=p.workspace_id
            WHERE (t.kind='personal' AND t.owner_user_id=\(bind: userID)) OR (p.workspace_id IS NULL AND p.owner_id=\(bind: userID))
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_sessions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_sessions(id)
            SELECT i.id FROM staged_legacy_imports i WHERE i.workspace_id IN (SELECT id FROM account_deletion_workspaces)
            UNION SELECT c.session_id FROM legacy_import_commits c JOIN account_deletion_projects p ON p.id=c.project_id
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_projections(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_projections SELECT id FROM legacy_canonical_projections WHERE session_id IN (SELECT id FROM account_deletion_sessions)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_commits(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_commits SELECT id FROM legacy_import_commits WHERE session_id IN (SELECT id FROM account_deletion_sessions) OR project_id IN (SELECT id FROM account_deletion_projects)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_links(id UUID PRIMARY KEY,token TEXT UNIQUE) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_links
            SELECT m.id,m.token FROM magic_links m LEFT JOIN projects p ON p.id=m.project_id
            WHERE m.created_by_id=\(bind:userID) AND (p.id IS NULL OR p.id IN (SELECT id FROM account_deletion_projects))
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_completions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("""
            INSERT INTO account_deletion_completions
            SELECT c.id FROM completions c LEFT JOIN snags s ON s.id=c.snag_id
            WHERE c.magic_link_id IN (SELECT id FROM account_deletion_links)
               OR s.project_id IN (SELECT id FROM account_deletion_projects)
            """).run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_discovery_snapshots(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_discovery_snapshots SELECT DISTINCT snapshot_id FROM project_discovery_items WHERE project_id IN (SELECT id FROM account_deletion_projects)").run()
        try await sql.raw("CREATE TEMP TABLE account_deletion_subject_ids(id TEXT PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("INSERT INTO account_deletion_subject_ids VALUES (lower(\(bind: userID.uuidString)))").run()
        try await sql.raw("""
            INSERT INTO account_deletion_subject_ids SELECT c.id::TEXT FROM project_comments c JOIN teams t ON t.id=c.workspace_id
            WHERE c.author_user_id=\(bind: userID) AND t.kind='company' ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_subject_ids SELECT c.id::TEXT FROM completions c JOIN snags s ON s.id=c.snag_id
            JOIN projects p ON p.id=s.project_id JOIN teams t ON t.id=p.workspace_id
            WHERE c.reviewed_by_user_id=\(bind: userID) AND t.kind='company' ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_subject_ids SELECT i.id::TEXT FROM team_invites i JOIN teams t ON t.id=i.team_id
            WHERE i.invited_by_user_id=\(bind: userID) AND t.kind='company' ON CONFLICT DO NOTHING
            """).run()

        // Capture every write which was authorised before access revocation but
        // may still be crossing the storage boundary. The durable intent remains
        // usable after the project/link rows below have been removed.
        try await captureWriteIntents(jobID: jobID, userFallbackID: userID, on: sql)

        // Queue exact keys before deleting any reference rows. A key is never inferred
        // from uploader identity; every source below is inside the personal graph.
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind: jobID),'private_media',key FROM (
                SELECT original_key AS key FROM media_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT rendition_key FROM media_assets WHERE project_id IN (SELECT id FROM account_deletion_projects) AND rendition_key IS NOT NULL
            ) keys WHERE key IS NOT NULL ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind: jobID),'private_drawing',key FROM (
                SELECT original_key AS key FROM drawing_assets WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT rendition_key FROM drawing_asset_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)
                UNION SELECT thumbnail_key FROM drawing_asset_pages WHERE project_id IN (SELECT id FROM account_deletion_projects)
            ) keys ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind: jobID),'private_import',key FROM (
                SELECT rendition_key AS key FROM imported_file_objects WHERE project_id IN (SELECT id FROM account_deletion_projects) AND rendition_key IS NOT NULL
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
            SELECT \(bind: jobID),'legacy_photo',key FROM (
                SELECT sp.file_path AS key FROM synced_photos sp WHERE sp.magic_link_token IN (SELECT token FROM account_deletion_links)
                UNION SELECT sp.thumbnail_file_path FROM synced_photos sp
                    WHERE sp.magic_link_token IN (SELECT token FROM account_deletion_links) AND sp.thumbnail_file_path IS NOT NULL
                UNION SELECT unnest(d.file_paths) FROM snag_deletions d LEFT JOIN projects p ON p.id=d.project_id
                    WHERE d.owner_id=\(bind:userID) AND (p.id IS NULL OR p.id IN (SELECT id FROM account_deletion_projects))
            ) keys WHERE key IS NOT NULL ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind: jobID),'legacy_drawing',sd.file_path FROM synced_drawings sd
            WHERE sd.magic_link_token IN (SELECT token FROM account_deletion_links) ON CONFLICT DO NOTHING
            """).run()
        // This registry is authoritative for prospective completion uploads.
        // Company objects follow their project, never the link creator/uploader.
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:jobID),'legacy_completion_photo',key FROM (
                SELECT o.storage_key key FROM completion_upload_objects o
                WHERE o.project_id IN (SELECT id FROM account_deletion_projects)
                   OR (o.uploaded_by_user_id=\(bind:userID) AND NOT EXISTS(
                        SELECT 1 FROM completion_photos cp
                        WHERE cp.upload_object_id=o.id AND cp.completion_id NOT IN (SELECT id FROM account_deletion_completions)))
                UNION
                SELECT o.thumbnail_key FROM completion_upload_objects o
                WHERE o.project_id IN (SELECT id FROM account_deletion_projects)
                   OR (o.uploaded_by_user_id=\(bind:userID) AND NOT EXISTS(
                        SELECT 1 FROM completion_photos cp
                        WHERE cp.upload_object_id=o.id AND cp.completion_id NOT IN (SELECT id FROM account_deletion_completions)))
            ) keys ON CONFLICT DO NOTHING
            """).run()
        // CompletionPhoto.url is client supplied and the historical upload endpoint did
        // not persist an owner. Even an unshared local-looking path is not proof that the
        // target account owns the object, so retain durable unresolved evidence instead
        // of creating a deletion manifest from the URL alone.
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
            SELECT \(bind:jobID),'completion_photo',c.source_id,c.source_field,c.object_key,
                CASE WHEN EXISTS (
                    SELECT 1 FROM completion_photos other
                    WHERE other.completion_id NOT IN (SELECT id FROM account_deletion_completions)
                      AND (ltrim(other.url,'/')=ltrim(c.object_key,'/') OR ltrim(other.thumbnail_url,'/')=ltrim(c.object_key,'/'))
                ) THEN 'shared_reference' ELSE 'unknown_local_namespace' END,CURRENT_TIMESTAMP
            FROM candidates c
            WHERE ltrim(c.object_key,'/') LIKE 'uploads/%' OR c.object_key ~ '^https?://[^/]+/uploads/'
            ON CONFLICT DO NOTHING
            """).run()

        try await redactCopiedPayloads(userID: userID, on: database)
        try await deleteGraph(userID: userID, on: database)

        try await sql.raw("""
            UPDATE account_deletion_jobs SET database_cleanup_state='completed',
                object_cleanup_state=CASE
                    WHEN EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind:jobID)) THEN 'blocked'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:jobID) AND i.state='uncertain' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'blocked'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:jobID) AND i.state='active' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'blocked'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind: jobID) AND completed_at IS NULL) THEN 'pending'
                    ELSE 'completed' END,
                last_error_kind=CASE WHEN EXISTS(SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind:jobID))
                    THEN 'unresolved_legacy_object_ownership'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:jobID) AND i.state='uncertain' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'object_write_uncertain'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id
                        WHERE d.job_id=\(bind:jobID) AND i.state='active' AND NOT object_write_is_resolved(d.job_id,i.id)) THEN 'object_write_pending'
                    ELSE NULL END WHERE id=\(bind: jobID)
            """).run()
    }

    private static func redactCopiedPayloads(userID: UUID, on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        let ids = "ARRAY(SELECT id FROM account_deletion_subject_ids)"
        // Personal rows are deleted below, so never decode their historical JSON.
        // For retained rows, an exact structured subject UUID prefilter avoids
        // parsing unrelated malformed legacy payloads. A candidate which names the
        // subject but is malformed still fails closed and rolls back the erasure.
        for (table, column, retainedScope) in [
            ("platform_changes", "payload_json", "NOT EXISTS(SELECT 1 FROM account_deletion_workspaces w WHERE w.id=source.workspace_id) AND (source.project_id IS NULL OR NOT EXISTS(SELECT 1 FROM account_deletion_projects p WHERE p.id=source.project_id))"),
            ("register_snapshot_items", "payload_json", "NOT EXISTS(SELECT 1 FROM register_snapshots s WHERE s.id=source.snapshot_id AND (s.workspace_id IN (SELECT id FROM account_deletion_workspaces) OR s.project_id IN (SELECT id FROM account_deletion_projects)))"),
            ("project_discovery_items", "payload_json", "NOT EXISTS(SELECT 1 FROM account_deletion_projects p WHERE p.id=source.project_id)"),
            ("workflow_outbox", "payload_json", "NOT EXISTS(SELECT 1 FROM account_deletion_workspaces w WHERE w.id=source.workspace_id) AND NOT EXISTS(SELECT 1 FROM account_deletion_projects p WHERE p.id=source.project_id)"),
            ("synced_reports", "report_json", "NOT EXISTS(SELECT 1 FROM account_deletion_links l WHERE l.token=source.magic_link_token)")
        ] {
            try await sql.raw("""
                WITH candidates AS MATERIALIZED (
                    SELECT source.ctid FROM \(unsafeRaw: table) source
                    WHERE \(unsafeRaw: retainedScope) AND EXISTS (
                        SELECT 1 FROM account_deletion_subject_ids subject
                        WHERE strpos(lower(source.\(unsafeRaw: column)),subject.id)>0
                    )
                )
                UPDATE \(unsafeRaw: table) target
                SET \(unsafeRaw: column)=account_deletion_redact_json(target.\(unsafeRaw: column)::JSONB,\(unsafeRaw: ids))::TEXT
                FROM candidates WHERE target.ctid=candidates.ctid
                """).run()
        }
        // Keep operation identity/fingerprint/outcome, but remove the replay body.
        try await sql.raw("""
            UPDATE mutation_receipts SET result_json='{"accountDeletionRedacted":true}',account_deletion_redacted_at=CURRENT_TIMESTAMP
            WHERE actor_id=\(bind: userID)
            """).run()
        try await sql.raw("""
            WITH candidates AS MATERIALIZED (
                SELECT source.ctid FROM mutation_receipts source WHERE source.actor_id<>\(bind:userID)
                  AND NOT EXISTS(SELECT 1 FROM account_deletion_workspaces w WHERE w.id=source.workspace_id)
                  AND EXISTS(SELECT 1 FROM account_deletion_subject_ids subject WHERE strpos(lower(source.result_json),subject.id)>0)
            )
            UPDATE mutation_receipts target SET result_json=account_deletion_redact_json(target.result_json::JSONB,\(unsafeRaw: ids))::TEXT
            FROM candidates WHERE target.ctid=candidates.ctid
            """).run()
        try await sql.raw("""
            WITH candidates AS MATERIALIZED (
                SELECT source.ctid FROM link_mutation_receipts source JOIN link_grants g ON g.id=source.grant_id
                WHERE NOT EXISTS(SELECT 1 FROM account_deletion_projects p WHERE p.id=g.project_id)
                  AND EXISTS(SELECT 1 FROM account_deletion_subject_ids subject WHERE strpos(lower(source.result_json),subject.id)>0)
            )
            UPDATE link_mutation_receipts target SET result_json=account_deletion_redact_json(target.result_json::JSONB,\(unsafeRaw: ids))::TEXT,
                account_deletion_redacted_at=CURRENT_TIMESTAMP
            FROM candidates WHERE target.ctid=candidates.ctid
            """).run()
    }

    private static func deleteGraph(userID: UUID, on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        let statements: [SQLQueryString] = [
            "DELETE FROM audit_logs WHERE resource_type='magic_link' AND resource_id IN (SELECT id FROM account_deletion_links)",
            "DELETE FROM audit_logs WHERE resource_type='team_invite' AND resource_id IN (SELECT id FROM team_invites WHERE team_id IN (SELECT id FROM account_deletion_workspaces))",
            "UPDATE audit_logs SET user_id=NULL,resource_id=CASE WHEN resource_type='user' AND resource_id=\(bind:userID) THEN NULL ELSE resource_id END,ip_address='redacted',user_agent=NULL,details=NULL WHERE user_id=\(bind:userID)",
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
            "DELETE FROM completion_upload_objects o WHERE o.project_id IN (SELECT id FROM account_deletion_projects) OR (o.uploaded_by_user_id=\(bind:userID) AND NOT EXISTS(SELECT 1 FROM completion_photos cp WHERE cp.upload_object_id=o.id))",
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
            "DELETE FROM snag_deletions d USING projects p WHERE d.project_id=p.id AND p.id IN (SELECT id FROM account_deletion_projects)",
            "DELETE FROM snag_deletions d WHERE d.owner_id=\(bind:userID) AND NOT EXISTS(SELECT 1 FROM projects p WHERE p.id=d.project_id)",
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
            "DELETE FROM project_discovery_snapshots s WHERE s.id IN (SELECT id FROM account_deletion_discovery_snapshots) AND NOT EXISTS (SELECT 1 FROM project_discovery_items i WHERE i.snapshot_id=s.id)",
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
            "DELETE FROM contractors WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces) OR (workspace_id IS NULL AND owner_id=\(bind: userID))",
            "DELETE FROM trades WHERE workspace_id IN (SELECT id FROM account_deletion_workspaces) OR (workspace_id IS NULL AND owner_id=\(bind: userID))",
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

    /// Captures exact pre-write evidence against the temporary graph scope and
    /// adds its key to the normal deletion manifest. User-only fallback is valid
    /// solely when the writer recorded no workspace, project, session or link.
    static func captureWriteIntents(jobID: UUID, userFallbackID: UUID?, on sql: SQLDatabase) async throws {
        if try await sql.raw("""
            SELECT 1 FROM object_write_intents i WHERE
              ((i.ownership_kind='workspace' AND i.scope_workspace_id IN (SELECT id FROM account_deletion_workspaces))
                OR (CAST(\(bind:userFallbackID) AS UUID) IS NOT NULL AND i.ownership_kind='personal'
                    AND i.scope_user_id=CAST(\(bind:userFallbackID) AS UUID)))
              AND ((i.scope_workspace_id IS NOT NULL AND i.scope_workspace_id NOT IN (SELECT id FROM account_deletion_workspaces))
                OR (i.scope_project_id IS NOT NULL AND EXISTS(SELECT 1 FROM projects p WHERE p.id=i.scope_project_id)
                    AND i.scope_project_id NOT IN (SELECT id FROM account_deletion_projects))
                OR (i.source_session_id IS NOT NULL AND EXISTS(SELECT 1 FROM staged_legacy_imports s WHERE s.id=i.source_session_id)
                    AND i.source_session_id NOT IN (SELECT id FROM account_deletion_sessions))
                OR (i.scope_magic_link_id IS NOT NULL AND EXISTS(SELECT 1 FROM magic_links m WHERE m.id=i.scope_magic_link_id)
                    AND i.scope_magic_link_id NOT IN (SELECT id FROM account_deletion_links)))
            LIMIT 1
            """).first() != nil {
            throw Abort(.conflict, reason: "Object write crosses deletion scopes",
                        identifier: "object_write_scope_ambiguous")
        }
        try await sql.raw("""
            WITH captured AS MATERIALIZED (
                SELECT i.id FROM object_write_intents i
                WHERE (i.ownership_kind='workspace' AND i.scope_workspace_id IN (SELECT id FROM account_deletion_workspaces))
                   OR (CAST(\(bind:userFallbackID) AS UUID) IS NOT NULL AND i.ownership_kind='personal'
                       AND i.scope_user_id=CAST(\(bind:userFallbackID) AS UUID)
                       AND (i.scope_workspace_id IS NULL OR i.scope_workspace_id IN (SELECT id FROM account_deletion_workspaces)))
                FOR SHARE
            )
            INSERT INTO account_deletion_write_intents(job_id,intent_id)
            SELECT \(bind:jobID),id FROM captured ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key)
            SELECT \(bind:jobID),i.storage_kind,i.object_key
            FROM object_write_intents i JOIN account_deletion_write_intents d ON d.intent_id=i.id
            WHERE d.job_id=\(bind:jobID) ON CONFLICT DO NOTHING
            """).run()
    }

    /// Storage workers must recheck a manifest key immediately before delete.
    /// A same-job settled intent is evidence for this deletion, while any other
    /// durable intent remains a live reference even if its source row is absent.
    static func objectIsReferenced(kind: String, key: String, excludingJobID: UUID? = nil,
                                   on database: Database) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(database)
        let query: SQLQueryString
        switch kind {
        case "private_media":
            query = "SELECT 1 FROM media_assets WHERE original_key=\(bind: key) OR rendition_key=\(bind: key) LIMIT 1"
        case "private_drawing":
            query = "SELECT 1 FROM drawing_assets a LEFT JOIN drawing_asset_pages p ON p.asset_id=a.id WHERE a.original_key=\(bind: key) OR p.rendition_key=\(bind: key) OR p.thumbnail_key=\(bind: key) LIMIT 1"
        case "private_import":
            query = "SELECT 1 WHERE EXISTS(SELECT 1 FROM imported_file_objects WHERE rendition_key=\(bind: key)) OR EXISTS(SELECT 1 FROM legacy_import_file_processing WHERE rendition_key=\(bind: key)) OR EXISTS(SELECT 1 FROM legacy_import_drawing_processing WHERE rendition_key=\(bind: key) OR thumbnail_key=\(bind: key)) OR EXISTS(SELECT 1 FROM staged_legacy_import_files f JOIN staged_legacy_imports i ON i.id=f.session_id WHERE 'staged-import/'||lower(i.workspace_id::TEXT)||'/'||lower(f.session_id::TEXT)||'/'||lower(f.declaration_id::TEXT)||'/original'=\(bind: key))"
        case "legacy_photo":
            query = "SELECT 1 WHERE EXISTS(SELECT 1 FROM synced_photos WHERE ltrim(file_path,'/')=ltrim(\(bind: key),'/') OR ltrim(thumbnail_file_path,'/')=ltrim(\(bind: key),'/')) OR EXISTS(SELECT 1 FROM synced_drawings WHERE ltrim(file_path,'/')=ltrim(\(bind: key),'/')) OR EXISTS(SELECT 1 FROM snag_deletions d CROSS JOIN LATERAL unnest(d.file_paths) AS path(value) WHERE ltrim(path.value,'/')=ltrim(\(bind:key),'/'))"
        case "legacy_drawing":
            query = "SELECT 1 WHERE EXISTS(SELECT 1 FROM synced_drawings WHERE ltrim(file_path,'/')=ltrim(\(bind: key),'/')) OR EXISTS(SELECT 1 FROM synced_photos WHERE ltrim(file_path,'/')=ltrim(\(bind: key),'/') OR ltrim(thumbnail_file_path,'/')=ltrim(\(bind: key),'/')) OR EXISTS(SELECT 1 FROM snag_deletions d CROSS JOIN LATERAL unnest(d.file_paths) AS path(value) WHERE ltrim(path.value,'/')=ltrim(\(bind:key),'/'))"
        case "legacy_completion_photo":
            query = "SELECT 1 WHERE EXISTS(SELECT 1 FROM completion_upload_objects WHERE storage_key=\(bind:key) OR thumbnail_key=\(bind:key)) OR EXISTS(SELECT 1 FROM completion_photos WHERE upload_object_id IS NULL AND (ltrim(url,'/')=ltrim(\(bind:key),'/') OR ltrim(thumbnail_url,'/')=ltrim(\(bind:key),'/') OR url LIKE '%/'||ltrim(\(bind:key),'/') OR thumbnail_url LIKE '%/'||ltrim(\(bind:key),'/')))"
        default:
            throw Abort(.internalServerError, reason: "Unsupported deletion object kind")
        }
        if try await sql.raw(query).first() != nil { return true }
        return try await sql.raw("""
            SELECT 1 FROM object_write_intents i
            WHERE i.storage_kind=\(bind:kind) AND i.object_key=\(bind:key)
              AND (CAST(\(bind:excludingJobID) AS UUID) IS NULL OR NOT EXISTS(
                SELECT 1 FROM account_deletion_write_intents d
                WHERE d.intent_id=i.id AND d.job_id=CAST(\(bind:excludingJobID) AS UUID)))
              AND (i.state<>'settled' OR NOT EXISTS(
                SELECT 1 FROM account_deletion_write_intents d WHERE d.intent_id=i.id))
            LIMIT 1
            """).first() != nil
    }
}
