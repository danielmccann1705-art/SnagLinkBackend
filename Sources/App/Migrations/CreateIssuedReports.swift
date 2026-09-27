import Vapor
import Fluent

/// Issued project reports (F07/F12 report contract v1).
///
/// One row per report a manager issued: the canonical snapshot bytes that were built
/// from the authorised register at that moment, their SHA-256, the normalised filter
/// scope, the counts, who issued it and when. A row is a record of what was issued,
/// so it is never updated: the trigger refuses every UPDATE, and there is no delete
/// route. It goes only with its project — explicitly in the account-deletion and
/// company-closure graphs, and by `ON DELETE CASCADE` for any other path that removes
/// the project row.
///
/// No person's name is stored here. The issuer (and any reviewer named inside the
/// snapshot) is a user id; names are resolved when the record is read, so a deleted
/// company member reads "Former member" as everywhere else.
///
/// An image older than this migration ignores the table; rolling back loses the
/// history routes, not data.
struct CreateIssuedReports: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE issued_reports (
                    id UUID PRIMARY KEY,
                    workspace_id UUID NOT NULL,
                    project_id UUID NOT NULL,
                    number INTEGER NOT NULL CHECK (number > 0),
                    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
                    issued_by_user_id UUID NOT NULL REFERENCES users(id),
                    issued_at TIMESTAMPTZ NOT NULL,
                    scope_json TEXT NOT NULL,
                    summary_json TEXT NOT NULL,
                    snag_count INTEGER NOT NULL CHECK (snag_count >= 0 AND snag_count <= 2000),
                    format_version INTEGER NOT NULL CHECK (format_version = 1),
                    snapshot_json TEXT NOT NULL CHECK (octet_length(snapshot_json) <= 16777216),
                    snapshot_sha256 TEXT NOT NULL CHECK (snapshot_sha256 ~ '^[a-f0-9]{64}$'),
                    UNIQUE (project_id, number),
                    FOREIGN KEY (project_id, workspace_id) REFERENCES projects(id, workspace_id) ON DELETE CASCADE
                )
                """).run()
            try await sql.raw("CREATE INDEX issued_reports_history ON issued_reports(project_id, issued_at DESC, number DESC)").run()
            try await sql.raw("""
                CREATE FUNCTION issued_report_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'An issued report is immutable' USING ERRCODE = 'integrity_constraint_violation';
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER issued_report_immutable BEFORE UPDATE ON issued_reports FOR EACH ROW EXECUTE FUNCTION issued_report_immutable()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Issued reports are records; use a compatible image instead of reverting")
    }
}
