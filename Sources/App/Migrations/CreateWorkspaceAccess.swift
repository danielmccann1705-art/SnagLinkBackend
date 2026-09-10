import Vapor
import Fluent
import FluentSQL

/// Extend Team as the workspace record; old project.team_id remains historical
/// metadata and never grants company access or automatically transfers a project.
struct CreateWorkspaceAccess: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            ALTER TABLE teams ADD COLUMN kind TEXT NOT NULL DEFAULT 'company' CHECK (kind IN ('personal', 'company')),
                ADD COLUMN lifecycle_state TEXT NOT NULL DEFAULT 'active',
                ADD COLUMN timezone TEXT NOT NULL DEFAULT 'Europe/London',
                ADD COLUMN revision BIGINT NOT NULL DEFAULT 1
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX personal_workspace_owner ON teams(owner_user_id) WHERE kind = 'personal'").run()
        try await sql.raw("""
            CREATE TABLE workspace_memberships (
                workspace_id UUID NOT NULL REFERENCES teams(id), user_id UUID NOT NULL REFERENCES users(id),
                role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
                state TEXT NOT NULL CHECK (state IN ('active', 'removed')),
                revision BIGINT NOT NULL DEFAULT 1, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(workspace_id, user_id)
            )
            """).run()
        // Existing teams with a real owner acquire only that owner's membership.
        // Previously 'accepted' invitations are not evidence of verified membership.
        try await sql.raw("""
            INSERT INTO workspace_memberships (workspace_id, user_id, role, state, created_at, updated_at)
            SELECT t.id, t.owner_user_id, 'owner', 'active', NOW(), NOW() FROM teams t JOIN users u ON u.id = t.owner_user_id
            """).run()
        try await sql.raw("UPDATE teams SET lifecycle_state = 'quarantined' WHERE owner_user_id NOT IN (SELECT id FROM users)").run()
        try await sql.raw("""
            INSERT INTO teams (id, name, owner_user_id, created_at, updated_at, kind)
            SELECT gen_random_uuid(), 'Personal projects', id, NOW(), NOW(), 'personal' FROM users
            """).run()
        try await sql.raw("ALTER TABLE projects ADD COLUMN workspace_id UUID REFERENCES teams(id), ADD COLUMN revision BIGINT NOT NULL DEFAULT 1, ADD COLUMN archived_at TIMESTAMPTZ, ADD CONSTRAINT project_workspace_pair UNIQUE(id, workspace_id)").run()
        try await sql.raw("UPDATE projects p SET workspace_id = t.id FROM teams t WHERE t.kind = 'personal' AND t.owner_user_id = p.owner_id").run()
        try await sql.raw("CREATE INDEX projects_workspace ON projects(workspace_id, updated_at, id)").run()
        try await sql.raw("""
            CREATE TABLE project_access (
                project_id UUID NOT NULL, workspace_id UUID NOT NULL, user_id UUID NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('manager', 'member', 'viewer')),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY(project_id, user_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(workspace_id, user_id) REFERENCES workspace_memberships(workspace_id, user_id)
            )
            """).run()
        try await sql.raw("ALTER TABLE team_invites ADD COLUMN token_hash TEXT, ADD COLUMN accepted_user_id UUID REFERENCES users(id)").run()
        let invites = try await sql.raw("SELECT id, token FROM team_invites").all()
        for row in invites {
            let id = try row.decode(column: "id", as: UUID.self)
            let hash = SHA256Hasher.hash(token: try row.decode(column: "token", as: String.self))
            try await sql.raw("UPDATE team_invites SET token_hash = \(bind: hash), token = \(bind: "sha256:" + hash) WHERE id = \(bind: id)").run()
        }
        try await sql.raw("CREATE UNIQUE INDEX team_invite_hash ON team_invites(token_hash) WHERE token_hash IS NOT NULL").run()
        try await sql.raw("""
            CREATE TABLE invitation_project_grants (
                invitation_id UUID NOT NULL REFERENCES team_invites(id), project_id UUID NOT NULL,
                workspace_id UUID NOT NULL, role TEXT NOT NULL CHECK (role IN ('manager', 'member')),
                PRIMARY KEY(invitation_id, project_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE workspace_activity (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL REFERENCES teams(id),
                actor_user_id UUID NOT NULL REFERENCES users(id), action TEXT NOT NULL,
                target_id UUID, detail TEXT, created_at TIMESTAMPTZ NOT NULL
            )
            """).run()
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Workspace ownership is persistent; use a compatible image rollback")
    }
}
