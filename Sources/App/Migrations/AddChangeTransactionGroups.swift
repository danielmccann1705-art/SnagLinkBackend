import Fluent
import FluentSQL
import Vapor

/// Existing changes remain individually addressable. A compatible older binary
/// receives a per-row default; the current writer shares one UUID per transaction.
struct AddChangeTransactionGroups: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE platform_changes ADD COLUMN transaction_group UUID NOT NULL DEFAULT gen_random_uuid()").run()
        try await sql.raw("CREATE INDEX platform_change_transaction ON platform_changes(workspace_id, transaction_group, sequence)").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain change groups for clients; use a compatible rollback image")
    }
}
