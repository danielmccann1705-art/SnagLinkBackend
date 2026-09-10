import Vapor
import Fluent
import FluentSQL

/// Add exact values alongside the released timestamp/Double columns. Existing
/// device/legacy records are deliberately left for the verified import process.
struct CreateCanonicalValues: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        let invalid = try await sql.raw("""
            SELECT count(*) AS count FROM snags s JOIN projects p ON s.project_id = p.id
            WHERE p.platform_managed AND (
                (s.cost_estimate IS NOT NULL AND NOT (s.cost_estimate >= 0 AND s.cost_estimate <= 1000000000 AND scale(s.cost_estimate::numeric) <= 6)) OR
                (s.actual_cost IS NOT NULL AND NOT (s.actual_cost >= 0 AND s.actual_cost <= 1000000000 AND scale(s.actual_cost::numeric) <= 6)))
            """).first()
        guard try invalid?.decode(column: "count", as: Int.self) == 0 else {
            throw Abort(.conflict, reason: "A managed candidate cost needs reconciliation before exact-value migration; no rounding was performed")
        }
        try await sql.raw("""
            ALTER TABLE snags ADD COLUMN due_on TEXT,
                ADD COLUMN cost_estimate_decimal NUMERIC,
                ADD COLUMN actual_cost_decimal NUMERIC,
                ADD CONSTRAINT snag_due_on_calendar_date CHECK (
                    due_on IS NULL OR (due_on ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND (due_on::date)::text = due_on)),
                ADD CONSTRAINT snag_estimate_decimal_range CHECK (
                    cost_estimate_decimal IS NULL OR (cost_estimate_decimal >= 0 AND cost_estimate_decimal <= 1000000000 AND scale(cost_estimate_decimal) <= 6)),
                ADD CONSTRAINT snag_actual_decimal_range CHECK (
                    actual_cost_decimal IS NULL OR (actual_cost_decimal >= 0 AND actual_cost_decimal <= 1000000000 AND scale(actual_cost_decimal) <= 6))
            """).run()
        // Only the new candidate's managed records can be converted here. Preserve
        // the original values as well; imported device deadlines need their own
        // source timezone confirmation and receipts.
        try await sql.raw("""
            UPDATE snags s SET
                due_on = CASE WHEN s.due_date IS NULL THEN NULL ELSE to_char(s.due_date AT TIME ZONE t.timezone, 'YYYY-MM-DD') END,
                cost_estimate_decimal = CASE WHEN s.cost_estimate >= 0 AND s.cost_estimate <= 1000000000 AND scale(s.cost_estimate::numeric) <= 6 THEN s.cost_estimate::numeric ELSE NULL END,
                actual_cost_decimal = CASE WHEN s.actual_cost >= 0 AND s.actual_cost <= 1000000000 AND scale(s.actual_cost::numeric) <= 6 THEN s.actual_cost::numeric ELSE NULL END
            FROM projects p JOIN teams t ON t.id = p.workspace_id
            WHERE s.project_id = p.id AND p.platform_managed
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep exact dates and costs; roll back only to a compatible image")
    }
}
