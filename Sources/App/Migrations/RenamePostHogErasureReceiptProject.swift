import Fluent
import FluentSQL
import Vapor

/// `measurement_posthog_erasure_receipts.project_id` held the PostHog project number as TEXT.
/// The company inventory and company-graph erasure (`AccountDeletionCompanyInventory`,
/// `AccountDeletionCompanyGraphService`) find company-scoped tables dynamically by a column
/// named `workspace_id`, `team_id` or `project_id` and compare it with project UUIDs, so this
/// TEXT column made every company closure and company-graph account deletion fail with
/// `text = uuid`, both in this image and in any earlier image running on this schema (rollback
/// check, 9 October 2026). Renaming it removes the table from that scan. Metadata-only; the
/// CHECK constraints follow the column. Revert renames it back.
struct RenamePostHogErasureReceiptProject: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { tx in
            try await VerifiedIdentityService.sql(tx).raw("""
                ALTER TABLE measurement_posthog_erasure_receipts RENAME COLUMN project_id TO posthog_project_id
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.transaction { tx in
            try await VerifiedIdentityService.sql(tx).raw("""
                ALTER TABLE measurement_posthog_erasure_receipts RENAME COLUMN posthog_project_id TO project_id
                """).run()
        }
    }
}
