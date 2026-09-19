import Fluent
import FluentSQL
import Vapor

/// Builds the exact database graph sealed by an explicit company-closure confirmation.
/// The caller must run inside a transaction. Rows are canonicalised and hashed in
/// PostgreSQL; only one fixed-size digest is returned to the application.
enum AccountDeletionCompanyInventoryService {
    static func inspect(workspaceID: UUID, on database: Database) async throws -> CompanyClosureInventory {
        guard database.inTransaction else {
            throw Abort(.internalServerError, reason: "Company inventory requires a transaction")
        }
        let sql=try VerifiedIdentityService.sql(database)
        guard let team=try await sql.raw("SELECT owner_user_id FROM teams WHERE id=\(bind:workspaceID) AND kind='company' FOR UPDATE").first() else {
            throw Abort(.conflict, reason:"Company closure scope is unavailable",identifier:"company_closure_scope_changed")
        }
        let ownerID=try team.decode(column:"owner_user_id",as:UUID.self)
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_projects(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_links(id UUID PRIMARY KEY,token TEXT UNIQUE) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_completions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_sessions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_projections(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_commits(id UUID PRIMARY KEY) ON COMMIT DROP").run()
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_rows(table_name TEXT NOT NULL,row_data TEXT NOT NULL) ON COMMIT DROP").run()
        for table in ["company_inventory_projects","company_inventory_links","company_inventory_completions","company_inventory_sessions","company_inventory_projections","company_inventory_commits","company_inventory_rows"] {
            try await sql.raw("TRUNCATE \(unsafeRaw:table)").run()
        }
        try await sql.raw("INSERT INTO company_inventory_projects SELECT id FROM projects WHERE workspace_id=\(bind:workspaceID) ORDER BY id").run()
        // Lock every root in stable order. Project-scoped writers either finish
        // before this snapshot or wait until the closing workspace rejects them.
        _ = try await sql.raw("SELECT id FROM projects WHERE id IN (SELECT id FROM company_inventory_projects) ORDER BY id FOR UPDATE").all()
        try await sql.raw("INSERT INTO company_inventory_links SELECT id,token FROM magic_links WHERE project_id IN (SELECT id FROM company_inventory_projects) ORDER BY id").run()
        _ = try await sql.raw("SELECT id FROM magic_links WHERE id IN (SELECT id FROM company_inventory_links) ORDER BY id FOR UPDATE").all()
        try await sql.raw("""
            INSERT INTO company_inventory_completions
            SELECT c.id FROM completions c LEFT JOIN snags s ON s.id=c.snag_id
            WHERE c.magic_link_id IN (SELECT id FROM company_inventory_links)
               OR s.project_id IN (SELECT id FROM company_inventory_projects) ORDER BY c.id
            """).run()
        try await sql.raw("""
            INSERT INTO company_inventory_sessions
            SELECT id FROM staged_legacy_imports WHERE workspace_id=\(bind:workspaceID)
            UNION SELECT c.session_id FROM legacy_import_commits c
                JOIN projects p ON p.id=c.project_id WHERE p.workspace_id=\(bind:workspaceID)
            """).run()
        try await sql.raw("INSERT INTO company_inventory_projections SELECT id FROM legacy_canonical_projections WHERE session_id IN (SELECT id FROM company_inventory_sessions) ORDER BY id").run()
        try await sql.raw("INSERT INTO company_inventory_commits SELECT id FROM legacy_import_commits WHERE session_id IN (SELECT id FROM company_inventory_sessions) OR project_id IN (SELECT id FROM company_inventory_projects) ORDER BY id").run()

        // Historical rows without composite FKs can name two different companies.
        // Such a row is not safe to assign to either graph, so confirmation and
        // erasure both fail closed instead of deleting retained-company evidence.
        if try await sql.raw("""
            SELECT 1 WHERE
              EXISTS(SELECT 1 FROM completions c
                LEFT JOIN snags s ON s.id=c.snag_id LEFT JOIN projects sp ON sp.id=s.project_id
                LEFT JOIN magic_links m ON m.id=c.magic_link_id LEFT JOIN projects mp ON mp.id=m.project_id
                WHERE (sp.workspace_id=\(bind:workspaceID) OR mp.workspace_id=\(bind:workspaceID))
                  AND ((sp.workspace_id=\(bind:workspaceID) AND mp.id IS NOT NULL AND mp.workspace_id IS DISTINCT FROM \(bind:workspaceID))
                    OR (mp.workspace_id=\(bind:workspaceID) AND sp.id IS NOT NULL AND sp.workspace_id IS DISTINCT FROM \(bind:workspaceID))))
              OR EXISTS(SELECT 1 FROM legacy_import_commits c
                JOIN staged_legacy_imports i ON i.id=c.session_id JOIN projects p ON p.id=c.project_id
                WHERE (i.workspace_id=\(bind:workspaceID) OR p.workspace_id=\(bind:workspaceID)) AND i.workspace_id IS DISTINCT FROM p.workspace_id)
              OR EXISTS(SELECT 1 FROM legacy_canonical_projection_directories d
                JOIN legacy_canonical_projections p ON p.id=d.projection_id
                JOIN legacy_canonical_directory_identities i ON i.id=d.identity_id
                WHERE (p.workspace_id=\(bind:workspaceID) OR i.workspace_id=\(bind:workspaceID)) AND p.workspace_id IS DISTINCT FROM i.workspace_id)
              OR EXISTS(SELECT 1 FROM legacy_import_directory_publications d
                JOIN legacy_import_commits c ON c.id=d.commit_id
                JOIN legacy_canonical_directory_identities i ON i.id=d.identity_id
                WHERE (c.workspace_id=\(bind:workspaceID) OR i.workspace_id=\(bind:workspaceID)) AND c.workspace_id IS DISTINCT FROM i.workspace_id)
            """).first() != nil {
            throw Abort(.conflict,reason:"Historical data crosses company boundaries",identifier:"company_closure_scope_ambiguous")
        }

        // Cover every current direct workspace/project row, including tables added
        // after this source was written. Special indirect children are added below.
        try await sql.raw("SELECT set_config('snaglist.company_inventory_workspace_id',\(bind:workspaceID.uuidString),true)").run()
        try await sql.raw("""
            DO $$ DECLARE item RECORD; scope_id UUID;
            BEGIN
                scope_id:=current_setting('snaglist.company_inventory_workspace_id')::UUID;
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
                          'account_deletion_jobs','account_deletion_objects','account_deletion_unresolved_objects',
                          'object_write_intents','account_deletion_write_intents')
                    GROUP BY c.table_schema,c.table_name ORDER BY c.table_name
                LOOP
                    IF item.has_workspace AND item.has_project THEN
                        EXECUTE format('INSERT INTO company_inventory_rows SELECT %L,to_jsonb(source)::text FROM %I.%I source WHERE workspace_id=$1 OR project_id IN (SELECT id FROM pg_temp.company_inventory_projects)',item.table_name,item.table_schema,item.table_name) USING scope_id;
                    ELSIF item.has_workspace THEN
                        EXECUTE format('INSERT INTO company_inventory_rows SELECT %L,to_jsonb(source)::text FROM %I.%I source WHERE workspace_id=$1',item.table_name,item.table_schema,item.table_name) USING scope_id;
                    ELSIF item.has_team AND item.table_name='team_invites' THEN
                        EXECUTE format('INSERT INTO company_inventory_rows SELECT %L,to_jsonb(source)::text FROM %I.%I source WHERE team_id=$1',item.table_name,item.table_schema,item.table_name) USING scope_id;
                    ELSIF item.has_project THEN
                        EXECUTE format('INSERT INTO company_inventory_rows SELECT %L,to_jsonb(source)::text FROM %I.%I source WHERE project_id IN (SELECT id FROM pg_temp.company_inventory_projects)',item.table_name,item.table_schema,item.table_name);
                    END IF;
                END LOOP;
            END $$
            """).run()
        try await sql.raw("INSERT INTO company_inventory_rows SELECT 'teams',to_jsonb(t)::text FROM teams t WHERE id=\(bind:workspaceID)").run()
        let indirect: [SQLQueryString] = [
            "INSERT INTO company_inventory_rows SELECT 'register_snapshot_items',to_jsonb(i)::text FROM register_snapshot_items i JOIN register_snapshots s ON s.id=i.snapshot_id WHERE s.project_id IN (SELECT id FROM company_inventory_projects)",
            "INSERT INTO company_inventory_rows SELECT 'project_discovery_snapshots',to_jsonb(s)::text FROM project_discovery_snapshots s WHERE EXISTS(SELECT 1 FROM project_discovery_items i WHERE i.snapshot_id=s.id AND i.project_id IN (SELECT id FROM company_inventory_projects)) AND NOT EXISTS(SELECT 1 FROM project_discovery_items i WHERE i.snapshot_id=s.id AND i.project_id NOT IN (SELECT id FROM company_inventory_projects))",
            "INSERT INTO company_inventory_rows SELECT 'link_sessions',to_jsonb(s)::text FROM link_sessions s JOIN link_grants g ON g.id=s.grant_id WHERE g.project_id IN (SELECT id FROM company_inventory_projects)",
            "INSERT INTO company_inventory_rows SELECT 'link_mutation_receipts',to_jsonb(r)::text FROM link_mutation_receipts r JOIN link_grants g ON g.id=r.grant_id WHERE g.project_id IN (SELECT id FROM company_inventory_projects)",
            "INSERT INTO company_inventory_rows SELECT 'completion_photos',to_jsonb(p)::text FROM completion_photos p WHERE completion_id IN (SELECT id FROM company_inventory_completions)",
            "INSERT INTO company_inventory_rows SELECT 'content_reports',to_jsonb(r)::text FROM content_reports r WHERE completion_id IN (SELECT id FROM company_inventory_completions)",
            "INSERT INTO company_inventory_rows SELECT 'completions',to_jsonb(c)::text FROM completions c WHERE id IN (SELECT id FROM company_inventory_completions)",
            "INSERT INTO company_inventory_rows SELECT 'synced_photos',to_jsonb(p)::text FROM synced_photos p WHERE magic_link_token IN (SELECT token FROM company_inventory_links)",
            "INSERT INTO company_inventory_rows SELECT 'synced_drawings',to_jsonb(d)::text FROM synced_drawings d WHERE magic_link_token IN (SELECT token FROM company_inventory_links)",
            "INSERT INTO company_inventory_rows SELECT 'synced_reports',to_jsonb(r)::text FROM synced_reports r WHERE magic_link_token IN (SELECT token FROM company_inventory_links)",
            "INSERT INTO company_inventory_rows SELECT 'magic_link_accesses',to_jsonb(a)::text FROM magic_link_accesses a WHERE magic_link_id IN (SELECT id FROM company_inventory_links)",
            "INSERT INTO company_inventory_rows SELECT 'magic_link_sends',to_jsonb(s)::text FROM magic_link_sends s WHERE magic_link_id IN (SELECT id FROM company_inventory_links)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_sources',to_jsonb(r)::text FROM staged_legacy_import_sources r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_records',to_jsonb(r)::text FROM staged_legacy_import_records r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_edges',to_jsonb(r)::text FROM staged_legacy_import_edges r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_files',to_jsonb(r)::text FROM staged_legacy_import_files r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_file_uses',to_jsonb(r)::text FROM staged_legacy_import_file_uses r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_legacy_import_actions',to_jsonb(r)::text FROM staged_legacy_import_actions r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_import_file_operations',to_jsonb(r)::text FROM staged_import_file_operations r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'staged_import_original_receipts',to_jsonb(r)::text FROM staged_import_original_receipts r WHERE session_id IN (SELECT id FROM company_inventory_sessions)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_canonical_projections',to_jsonb(r)::text FROM legacy_canonical_projections r WHERE id IN (SELECT id FROM company_inventory_projections)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_import_processing_attempts',to_jsonb(r)::text FROM legacy_import_processing_attempts r WHERE projection_id IN (SELECT id FROM company_inventory_projections)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_import_file_processing',to_jsonb(r)::text FROM legacy_import_file_processing r WHERE projection_id IN (SELECT id FROM company_inventory_projections)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_import_drawing_processing',to_jsonb(r)::text FROM legacy_import_drawing_processing r WHERE projection_id IN (SELECT id FROM company_inventory_projections)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_canonical_allocations',to_jsonb(r)::text FROM legacy_canonical_allocations r WHERE projection_id IN (SELECT id FROM company_inventory_projections)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_canonical_projection_directories',to_jsonb(r)::text FROM legacy_canonical_projection_directories r WHERE projection_id IN (SELECT id FROM company_inventory_projections) OR identity_id IN (SELECT id FROM legacy_canonical_directory_identities WHERE workspace_id=\(bind:workspaceID))",
            "INSERT INTO company_inventory_rows SELECT 'legacy_import_published_records',to_jsonb(r)::text FROM legacy_import_published_records r WHERE commit_id IN (SELECT id FROM company_inventory_commits)",
            "INSERT INTO company_inventory_rows SELECT 'legacy_import_directory_publications',to_jsonb(r)::text FROM legacy_import_directory_publications r WHERE commit_id IN (SELECT id FROM company_inventory_commits) OR identity_id IN (SELECT id FROM legacy_canonical_directory_identities WHERE workspace_id=\(bind:workspaceID))",
            "INSERT INTO company_inventory_rows SELECT 'invitation_project_grants',to_jsonb(g)::text FROM invitation_project_grants g WHERE invitation_id IN (SELECT id FROM team_invites WHERE team_id=\(bind:workspaceID))",
            "INSERT INTO company_inventory_rows SELECT 'audit_logs',to_jsonb(a)::text FROM audit_logs a WHERE (resource_type='magic_link' AND resource_id IN (SELECT id FROM company_inventory_links)) OR (resource_type='team_invite' AND resource_id IN (SELECT id FROM team_invites WHERE team_id=\(bind:workspaceID)))"
        ]
        for statement in indirect { try await sql.raw(statement).run() }
        let counts=try await sql.raw("""
            SELECT (SELECT count(*) FROM company_inventory_projects) projects,
              (SELECT count(*) FROM snags WHERE project_id IN (SELECT id FROM company_inventory_projects)) snags,
              (SELECT count(*) FROM workspace_memberships WHERE workspace_id=\(bind:workspaceID) AND user_id<>\(bind:ownerID)) other_members
            """).first()!
        try await sql.raw("CREATE TEMP TABLE IF NOT EXISTS company_inventory_ordered(n BIGSERIAL PRIMARY KEY,item TEXT NOT NULL) ON COMMIT DROP").run()
        try await sql.raw("TRUNCATE company_inventory_ordered RESTART IDENTITY").run()
        try await sql.raw("""
            INSERT INTO company_inventory_ordered(item)
            SELECT jsonb_build_array(table_name,row_data)::TEXT
            FROM (SELECT DISTINCT table_name,row_data FROM company_inventory_rows) rows
            ORDER BY table_name,row_data
            """).run()
        let digest=try await sql.raw("""
            WITH RECURSIVE chain(n,digest) AS (
              SELECT n,sha256(convert_to(item,'UTF8')) FROM company_inventory_ordered WHERE n=1
              UNION ALL
              SELECT next.n,sha256(chain.digest || convert_to(next.item,'UTF8'))
              FROM chain JOIN company_inventory_ordered next ON next.n=chain.n+1
            )
            SELECT encode(COALESCE((SELECT digest FROM chain ORDER BY n DESC LIMIT 1),sha256(''::bytea)),'hex') fingerprint
            """).first()!
        return try .init(projectCount:counts.decode(column:"projects",as:Int64.self),
                         snagCount:counts.decode(column:"snags",as:Int64.self),
                         otherMemberCount:counts.decode(column:"other_members",as:Int64.self),
                         fingerprint:digest.decode(column:"fingerprint",as:String.self))
    }
}

extension AccountDeletionGraphService {
    static func companyInventory(workspaceID: UUID, on database: Database) async throws -> CompanyClosureInventory {
        try await AccountDeletionCompanyInventoryService.inspect(workspaceID: workspaceID, on: database)
    }
}
