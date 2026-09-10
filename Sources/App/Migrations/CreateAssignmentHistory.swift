import Vapor
import Fluent
import FluentSQL

struct CreateAssignmentHistory: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await VerifiedIdentityService.sql(database).raw("""
            CREATE TABLE assignment_history (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL REFERENCES teams(id), project_id UUID NOT NULL,
                snag_id UUID NOT NULL, from_contractor_id UUID, to_contractor_id UUID,
                from_trade_id UUID, to_trade_id UUID, snag_revision BIGINT NOT NULL,
                actor_id UUID NOT NULL REFERENCES users(id), created_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        // Historical IDs remain attribution when projects/directories are transferred;
        // current assignment scope is enforced by snags' composite foreign keys.
    }
    func revert(on database: Database) async throws { throw Abort(.conflict, reason: "Assignment history must be retained") }
}
