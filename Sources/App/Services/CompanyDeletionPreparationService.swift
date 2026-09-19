import Vapor
import Fluent
import FluentSQL

struct EmptyCompanyAcknowledgement: Content, Sendable {
    let workspaceID: UUID
    let expectedRevision: Int64
}
struct CompanyDeletionPreparation: Content, Sendable {
    let workspaceID: UUID
    let name: String
    let revision: Int64
    let projectCount: Int64
    let snagCount: Int64
    let otherMemberCount: Int64
    let genuinelyEmpty: Bool
    let action: String
}
struct AccountDeletionPreparation: Content, Sendable { let companies: [CompanyDeletionPreparation] }

enum CompanyDeletionPreparationService {
    static func prepare(userID: UUID, on db: Database) async throws -> AccountDeletionPreparation {
        let sql = try VerifiedIdentityService.sql(db)
        let scopes = try await sql.raw("SELECT id FROM teams WHERE owner_user_id=\(bind: userID) AND kind='company' AND lifecycle_state='active' ORDER BY id").all()
        var result: [CompanyDeletionPreparation] = []
        for row in scopes {
            let id = try row.decode(column: "id", as: UUID.self)
            try await WorkspaceAccessService.lock(id, on: db)
            result.append(try await inspect(workspaceID: id, ownerID: userID, on: db))
        }
        _ = try await VerifiedIdentityService.activeUser(userID, on: db)
        return .init(companies: result)
    }
    /// Caller holds sorted workspace locks and the deleting user row. No company
    /// is removed until every acknowledgement and complete inventory is valid.
    static func confirmedEmpty(userID: UUID, acknowledgements: [EmptyCompanyAcknowledgement], excluding: Set<UUID> = [], on db: Database) async throws -> [CompanyDeletionPreparation] {
        let sql = try VerifiedIdentityService.sql(db)
        let rows = try await sql.raw("SELECT id FROM teams WHERE owner_user_id=\(bind: userID) AND kind='company' AND lifecycle_state='active' ORDER BY id").all()
        let allIDs = Set(try rows.map { try $0.decode(column: "id", as: UUID.self) })
        guard excluding.isSubset(of: allIDs) else { throw actionRequired() }
        let ids = allIDs.subtracting(excluding).sorted { $0.uuidString < $1.uuidString }
        guard Set(acknowledgements.map(\.workspaceID)).count == acknowledgements.count,
              Set(ids) == Set(acknowledgements.map(\.workspaceID)) else { throw actionRequired() }
        var result: [CompanyDeletionPreparation] = []
        for id in ids {
            let company = try await inspect(workspaceID: id, ownerID: userID, on: db)
            guard company.genuinelyEmpty else { throw actionRequired() }
            guard acknowledgements.first(where: { $0.workspaceID == id })?.expectedRevision == company.revision else {
                throw Abort(.conflict, reason: "Company details changed. Review the companies that will close", identifier: "company_closure_confirmation_changed")
            }
            result.append(company)
        }
        return result
    }
    static func closeEmpty(_ companies: [CompanyDeletionPreparation], userID: UUID, jobID: UUID, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        for company in companies {
            // Scope row remains locked by inspect. Inventory permits these two
            // bootstrapped records only; every other dependency blocks closure.
            try await sql.raw("DELETE FROM workspace_activity WHERE workspace_id=\(bind: company.workspaceID) AND action='company_created' AND actor_user_id=\(bind: userID) AND target_id=\(bind: company.workspaceID) AND detail IS NULL").run()
            try await sql.raw("DELETE FROM workspace_memberships WHERE workspace_id=\(bind: company.workspaceID) AND user_id=\(bind: userID)").run()
            try await sql.raw("DELETE FROM teams WHERE id=\(bind: company.workspaceID) AND owner_user_id=\(bind: userID) AND kind='company' AND lifecycle_state='active'").run()
            try await sql.raw("""
                INSERT INTO company_closure_jobs(id,account_deletion_job_id,workspace_id,confirmed_revision,mode,project_count,snag_count,other_member_count,state,requested_at,completed_at)
                VALUES(\(bind: UUID()),\(bind: jobID),\(bind: company.workspaceID),\(bind: company.revision),'empty',0,0,0,'completed',NOW(),NOW())
                """).run()
        }
    }
    private static func inspect(workspaceID: UUID, ownerID: UUID, on db: Database) async throws -> CompanyDeletionPreparation {
        let sql = try VerifiedIdentityService.sql(db)
        // The DB insertion fence takes FOR SHARE, so this lock closes the gap
        // between counting an empty scope and deleting its workspace row.
        guard let team = try await sql.raw("SELECT name,revision FROM teams WHERE id=\(bind: workspaceID) AND owner_user_id=\(bind: ownerID) AND kind='company' AND lifecycle_state='active' FOR UPDATE").first() else { throw actionRequired() }
        let projectCount = try await count("SELECT count(*) AS total FROM projects WHERE workspace_id=\(bind: workspaceID)", on: sql)
        let snagCount = try await count("SELECT count(*) AS total FROM snags WHERE project_id IN (SELECT id FROM projects WHERE workspace_id=\(bind: workspaceID))", on: sql)
        let members = try await count("SELECT count(*) AS total FROM workspace_memberships WHERE workspace_id=\(bind: workspaceID) AND user_id<>\(bind: ownerID)", on: sql)
        // Durable object writes can survive their original database rows. A
        // zero-project company with retained object evidence is not empty.
        let retainedWrites = try await count("SELECT count(*) AS total FROM object_write_intents WHERE ownership_kind='workspace' AND scope_workspace_id=\(bind: workspaceID)", on: sql)
        var empty = projectCount == 0 && snagCount == 0 && members == 0 && retainedWrites == 0
        // Discover all present scope columns, including legacy tables and future
        // table additions. Unknown data makes the company nonempty; never guess
        // that absence of active projects or members means absence of history.
        let columns = try await sql.raw("""
            SELECT c.table_schema,c.table_name,c.column_name FROM information_schema.columns c
            JOIN information_schema.tables t ON t.table_schema=c.table_schema AND t.table_name=c.table_name
            WHERE c.table_schema=current_schema() AND t.table_type='BASE TABLE' AND c.udt_name='uuid'
              AND c.column_name IN ('workspace_id','team_id') ORDER BY c.table_name,c.column_name
            """).all()
        for column in columns {
            let schema = try column.decode(column: "table_schema", as: String.self)
            let table = try column.decode(column: "table_name", as: String.self)
            let field = try column.decode(column: "column_name", as: String.self)
            if ["company_closure_confirmations", "company_closure_jobs"].contains(table) { continue }
            let query: SQLQueryString
            if table == "workspace_memberships" {
                query = "SELECT count(*) AS total FROM workspace_memberships WHERE workspace_id=\(bind: workspaceID) AND (user_id<>\(bind: ownerID) OR state<>'active' OR role<>'owner')"
            } else if table == "workspace_activity" {
                query = "SELECT count(*) AS total FROM workspace_activity WHERE workspace_id=\(bind: workspaceID) AND (action='company_created' AND actor_user_id=\(bind: ownerID) AND target_id=\(bind: workspaceID) AND detail IS NULL) IS NOT TRUE"
            } else {
                query = "SELECT count(*) AS total FROM \(ident: schema).\(ident: table) WHERE \(ident: field)=\(bind: workspaceID)"
            }
            if try await count(query, on: sql) > 0 { empty = false }
        }
        // FK-less historical links without a canonical project cannot establish
        // company emptiness. Leave them for explicit scoped closure/disposition.
        let ambiguous = try await count("SELECT count(*) AS total FROM magic_links m LEFT JOIN projects p ON p.id=m.project_id WHERE m.created_by_id=\(bind: ownerID) AND p.id IS NULL", on: sql)
        if ambiguous > 0 { empty = false }
        return try .init(workspaceID: workspaceID, name: team.decode(column: "name", as: String.self), revision: team.decode(column: "revision", as: Int64.self), projectCount: projectCount, snagCount: snagCount, otherMemberCount: members, genuinelyEmpty: empty, action: empty ? "closes_with_account" : "transfer_or_confirm_closure")
    }
    private static func count(_ query: SQLQueryString, on sql: SQLDatabase) async throws -> Int64 {
        try await sql.raw(query).first()?.decode(column: "total", as: Int64.self) ?? 0
    }
    static func actionRequired() -> Abort {
        Abort(.conflict, reason: "Review company closure or complete an accepted ownership transfer before deleting your account", identifier: "company_owner_action_required")
    }
}
