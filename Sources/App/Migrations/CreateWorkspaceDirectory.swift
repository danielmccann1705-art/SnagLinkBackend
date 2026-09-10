import Vapor
import Fluent
import FluentSQL

struct CreateWorkspaceDirectory: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE contractors ADD COLUMN workspace_id UUID REFERENCES teams(id), ADD COLUMN revision BIGINT NOT NULL DEFAULT 1, ADD COLUMN platform_managed BOOLEAN NOT NULL DEFAULT FALSE, ADD CONSTRAINT contractor_workspace_pair UNIQUE(id, workspace_id)").run()
        try await sql.raw("ALTER TABLE trades ADD COLUMN workspace_id UUID REFERENCES teams(id), ADD COLUMN revision BIGINT NOT NULL DEFAULT 1, ADD COLUMN platform_managed BOOLEAN NOT NULL DEFAULT FALSE, ADD CONSTRAINT trade_workspace_pair UNIQUE(id, workspace_id)").run()
        // Preserve legacy ownership signals without claiming/importing the directory.
        try await sql.raw("UPDATE contractors c SET workspace_id = t.id FROM teams t WHERE t.kind = 'personal' AND t.owner_user_id = c.owner_id").run()
        try await sql.raw("UPDATE trades c SET workspace_id = t.id FROM teams t WHERE t.kind = 'personal' AND t.owner_user_id = c.owner_id").run()
        try await sql.raw("""
            CREATE TABLE contractor_trades (
                contractor_id UUID NOT NULL, trade_id UUID NOT NULL, workspace_id UUID NOT NULL,
                PRIMARY KEY(contractor_id, trade_id),
                FOREIGN KEY(contractor_id, workspace_id) REFERENCES contractors(id, workspace_id),
                FOREIGN KEY(trade_id, workspace_id) REFERENCES trades(id, workspace_id)
            )
            """).run()
        try await sql.raw("ALTER TABLE snags ADD COLUMN workspace_id UUID REFERENCES teams(id)").run()
        // Legacy invalid references require import reconciliation. Only already
        // managed records gain the strict composite scope constraints now.
        try await sql.raw("UPDATE snags s SET workspace_id = p.workspace_id FROM projects p WHERE s.project_id = p.id AND p.platform_managed").run()
        try await sql.raw("""
            ALTER TABLE snags ADD CONSTRAINT snag_workspace_project FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                ADD CONSTRAINT snag_workspace_contractor FOREIGN KEY(contractor_id, workspace_id) REFERENCES contractors(id, workspace_id),
                ADD CONSTRAINT snag_workspace_trade FOREIGN KEY(trade_id, workspace_id) REFERENCES trades(id, workspace_id),
                ADD CONSTRAINT managed_snag_requires_workspace CHECK (display_number IS NULL OR workspace_id IS NOT NULL)
            """).run()
        try await sql.raw("CREATE INDEX directory_contractors_scope ON contractors(workspace_id, company_name, id)").run()
        try await sql.raw("CREATE INDEX directory_trades_scope ON trades(workspace_id, sort_order, id)").run()
        // A change's workspace is historical, unlike a project's current workspace.
        // Preserve old-scope tombstones when explicit transfer is implemented.
        try await sql.raw("ALTER TABLE platform_changes DROP CONSTRAINT platform_changes_project_id_workspace_id_fkey, ADD CONSTRAINT platform_change_project_history FOREIGN KEY(project_id) REFERENCES projects(id)").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep directory ownership and history; use a compatible image rollback")
    }
}
