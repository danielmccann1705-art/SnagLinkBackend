import Vapor
import Fluent
import FluentSQL

struct VersionInvitationGrants: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("ALTER TABLE invitation_project_grants ADD COLUMN base_grant_revision BIGINT NOT NULL DEFAULT 0 CHECK(base_grant_revision >= 0)").run()
        try await sql.raw("""
            UPDATE invitation_project_grants g SET base_grant_revision = a.revision
            FROM team_invites i JOIN user_identities identity ON identity.provider = 'email' AND identity.subject = lower(btrim(i.email))
                JOIN project_access a ON a.user_id = identity.user_id AND a.workspace_id = i.team_id
            WHERE g.invitation_id = i.id AND g.project_id = a.project_id AND i.status = 'pending' AND a.state = 'active'
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Old invitations must not restore access changed after they were issued")
    }
}
