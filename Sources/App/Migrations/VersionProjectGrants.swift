import Vapor
import Fluent
import FluentSQL

struct VersionProjectGrants: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await VerifiedIdentityService.sql(database).raw("""
            ALTER TABLE project_access ADD COLUMN state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active', 'removed')),
                ADD COLUMN revision BIGINT NOT NULL DEFAULT 1 CHECK(revision > 0),
                ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            """).run()
        try await VerifiedIdentityService.sql(database).raw("CREATE INDEX project_access_active_member ON project_access(workspace_id, user_id, project_id) WHERE state = 'active'").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Removed project access must not become active again during rollback")
    }
}
