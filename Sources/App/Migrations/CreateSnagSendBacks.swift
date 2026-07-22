import Fluent
import FluentSQL

/// B5: audit table for approval-workflow "send back" decisions.
struct CreateSnagSendBacks: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS snag_send_backs (
                id UUID PRIMARY KEY,
                snag_id UUID NOT NULL REFERENCES snags(id) ON DELETE CASCADE,
                reason TEXT NOT NULL,
                note TEXT,
                sent_back_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                sent_back_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_snag_send_backs_snag_id ON snag_send_backs(snag_id)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("snag_send_backs").delete()
    }
}
