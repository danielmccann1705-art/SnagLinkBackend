import Vapor
import Fluent
import FluentSQL

struct InvitationProjectGrant: Content {
    let projectId: UUID
    let role: String
}

struct InvitationPreview: Content {
    struct ProjectGrant: Content { let name: String; let role: String }
    let companyName: String
    let invitedByName: String?
    let email: String
    let role: String
    let projects: [ProjectGrant]
    let expiresAt: Date
    let alreadyAccepted: Bool
}

struct WorkspaceInvitationService {
    /// Authenticated preview proves the recipient before disclosing company/project
    /// names, and never consumes the invitation or creates a membership.
    static func preview(token: String, actorID: UUID, on db: Database) async throws -> InvitationPreview {
        let initial = try await resolve(token: token, on: db)
        try await WorkspaceAccessService.lock(initial.teamId, on: db)
        let invite = try await resolve(token: token, on: db)
        let verified = try await VerifiedIdentityService.verifiedEmails(for: actorID, on: db)
        guard verified.contains(EmailValidator.normalize(invite.email)) else {
            throw Abort(.forbidden, reason: "Verify the invited email on your existing Snaglist account before accepting", identifier: "invited_email_required")
        }
        guard let company = try await Team.find(invite.teamId, on: db), company.kind == "company", company.lifecycleState == "active" else { throw Abort(.gone, reason: "Company unavailable") }
        let accepted = invite.status == "accepted" && invite.acceptedUserId == actorID
        if accepted { _ = try await WorkspaceAccessService.role(actorID: actorID, workspace: company, on: db) }
        else {
            guard invite.isPending, !invite.isExpired, let inviter = invite.invitedByUserId else { throw Abort(.gone, reason: "Invitation expired, revoked or already used") }
            _ = try await WorkspaceAccessService.requireCompany(invite.teamId, actorID: inviter, admin: true, on: db)
        }
        guard ["admin", "member", "editor"].contains(invite.role) else { throw Abort(.conflict, reason: "Ask the company admin to replace this older invitation") }
        if !accepted { try await validateGrantRevisions(invite: invite, actorID: actorID, on: db) }
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT p.id, p.name, g.role FROM invitation_project_grants g JOIN projects p ON p.id = g.project_id AND p.workspace_id = g.workspace_id WHERE g.invitation_id = \(bind: invite.requireID()) AND p.archived_at IS NULL ORDER BY lower(p.name), p.id").all()
        var grants: [InvitationPreview.ProjectGrant] = []
        for row in rows {
            if accepted {
                do { _ = try await ProjectAccessService.require(.read, projectID: row.decode(column: "id", as: UUID.self), actorID: actorID, on: db) }
                catch let error as Abort where error.status == .notFound || error.status == .forbidden { continue }
            }
            grants.append(try .init(name: row.decode(column: "name", as: String.self), role: row.decode(column: "role", as: String.self)))
        }
        return .init(companyName: company.name, invitedByName: invite.invitedByName, email: invite.email, role: invite.role == "editor" ? "member" : invite.role, projects: grants, expiresAt: invite.expiresAt, alreadyAccepted: accepted)
    }

    static func issue(workspaceID: UUID, email: String, role: String, projects: [InvitationProjectGrant],
                      actorID: UUID, on db: Database) async throws -> (TeamInvite, String) {
        _ = try await WorkspaceAccessService.requireCompany(workspaceID, actorID: actorID, admin: true, on: db)
        let email = EmailValidator.normalize(email)
        guard EmailValidator.isAcceptable(email), email.count <= 254, ["admin", "member"].contains(role), projects.count <= 50,
              Set(projects.map(\.projectId)).count == projects.count else { throw Abort(.badRequest, reason: "Check the email, company role and project selection") }
        let sql = try VerifiedIdentityService.sql(db)
        guard try await sql.raw("SELECT id FROM team_invites WHERE team_id = \(bind: workspaceID) AND lower(btrim(email)) = \(bind: email) AND status = 'pending' AND expires_at > \(bind: Date()) LIMIT 1").first() == nil else {
            throw Abort(.conflict, reason: "An active invitation already exists for this email")
        }
        for grant in projects {
            guard ["manager", "member"].contains(grant.role),
                  let project = try await Project.find(grant.projectId, on: db), project.workspaceId == workspaceID,
                  project.archivedAt == nil else { throw Abort(.badRequest, reason: "The selected projects must belong to this company") }
        }
        let token = try SecureTokenGenerator.generate(byteCount: 32)
        let hash = SHA256Hasher.hash(token: token)
        let user = try await VerifiedIdentityService.activeUser(actorID, on: db)
        let invite = TeamInvite(email: email, role: role == "admin" ? .admin : .editor, token: "sha256:" + hash,
                                teamId: workspaceID, expiresAt: Date().addingTimeInterval(7 * 86400), invitedByUserId: actorID, invitedByName: user.name)
        invite.role = role; invite.tokenHash = hash
        try await invite.save(on: db)
        let recipient = try await sql.raw("SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)").first()
        let recipientID = try recipient?.decode(column: "user_id", as: UUID.self)
        for grant in projects {
            let revision: Int64
            if let recipientID { revision = try await ProjectGrantService.current(projectID: grant.projectId, targetID: recipientID, on: db).revision }
            else { revision = 0 }
            try await sql.raw("INSERT INTO invitation_project_grants (invitation_id, project_id, workspace_id, role, base_grant_revision) VALUES (\(bind: invite.requireID()), \(bind: grant.projectId), \(bind: workspaceID), \(bind: grant.role), \(bind: revision))").run()
        }
        try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID, action: "invitation_created", targetID: invite.requireID(), on: db)
        return (invite, token)
    }

    static func resolve(token: String, on db: Database) async throws -> TeamInvite {
        guard !token.isEmpty, token.count <= 256 else { throw Abort(.gone, reason: "Invitation unavailable") }
        guard let invite = try await TeamInvite.query(on: db).group(.or, { query in
            query.filter(\.$tokenHash == SHA256Hasher.hash(token: token)).filter(\.$token == token)
        }).first() else { throw Abort(.gone, reason: "Invitation unavailable") }
        return invite
    }

    /// Token status and membership/project grants commit together. A changed
    /// profile email is never proof of being the intended recipient.
    static func accept(token: String, actorID: UUID, on db: Database) async throws -> TeamInvite {
        let initial = try await resolve(token: token, on: db)
        try await WorkspaceAccessService.lock(initial.teamId, on: db)
        let invite = try await resolve(token: token, on: db)
        let verified = try await VerifiedIdentityService.verifiedEmails(for: actorID, on: db)
        guard verified.contains(EmailValidator.normalize(invite.email)) else {
            throw Abort(.forbidden, reason: "Verify the invited email on your existing Snaglist account before accepting", identifier: "invited_email_required")
        }
        if invite.status == "accepted", invite.acceptedUserId == actorID {
            guard let team = try await Team.find(invite.teamId, on: db) else { throw Abort(.gone) }
            _ = try await WorkspaceAccessService.role(actorID: actorID, workspace: team, on: db)
            return invite
        }
        guard invite.isPending, !invite.isExpired, let inviter = invite.invitedByUserId else { throw Abort(.gone, reason: "Invitation expired, revoked or already used") }
        // An invitation is not an enduring power of a removed/demoted inviter.
        _ = try await WorkspaceAccessService.requireCompany(invite.teamId, actorID: inviter, admin: true, on: db)
        let role: String
        switch invite.role {
        case "admin": role = "admin"
        case "member", "editor": role = "member"
        default: throw Abort(.conflict, reason: "Ask the company admin to replace this older invitation")
        }
        let sql = try VerifiedIdentityService.sql(db)
        let existing = try await sql.raw("SELECT role, state FROM workspace_memberships WHERE workspace_id = \(bind: invite.teamId) AND user_id = \(bind: actorID)").first()
        // Accepting another invite cannot downgrade an existing role or resurrect
        // old project grants that were cleared when a member left.
        let existingState = try existing?.decode(column: "state", as: String.self)
        if existingState != "active" {
            try await WorkspaceAccessService.putMembership(workspaceID: invite.teamId, userID: actorID, role: role, on: db)
        }
        try await validateGrantRevisions(invite: invite, actorID: actorID, on: db)
        let grants = try await sql.raw("SELECT project_id, role FROM invitation_project_grants WHERE invitation_id = \(bind: invite.requireID())").all()
        for row in grants {
            let projectID = try row.decode(column: "project_id", as: UUID.self)
            let grantRole = try row.decode(column: "role", as: String.self)
            guard let project = try await Project.find(projectID, on: db), project.workspaceId == invite.teamId, project.archivedAt == nil else {
                throw Abort(.conflict, reason: "The invitation's project access has changed. Ask for a new invitation")
            }
            try await sql.raw("""
                INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: projectID), \(bind: invite.teamId), \(bind: actorID), \(bind: grantRole))
                ON CONFLICT (project_id, user_id) DO UPDATE SET role = CASE WHEN project_access.state = 'active' AND project_access.role = 'manager' THEN 'manager' ELSE EXCLUDED.role END, state = 'active', revision = project_access.revision + 1, updated_at = NOW()
                """).run()
        }
        invite.status = "accepted"; invite.acceptedUserId = actorID
        try await invite.save(on: db)
        try await WorkspaceAccessService.activity(workspaceID: invite.teamId, actorID: actorID, action: "invitation_accepted", targetID: invite.requireID(), on: db)
        return invite
    }

    private static func validateGrantRevisions(invite: TeamInvite, actorID: UUID, on db: Database) async throws {
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT project_id, base_grant_revision FROM invitation_project_grants WHERE invitation_id = \(bind: invite.requireID())").all()
        for row in rows {
            let current = try await ProjectGrantService.current(projectID: row.decode(column: "project_id", as: UUID.self), targetID: actorID, on: db)
            guard current.revision == (try row.decode(column: "base_grant_revision", as: Int64.self)) else {
                throw Abort(.conflict, reason: "Project access changed after this invitation was issued. Ask the company admin for a new invitation", identifier: "invitation_grant_changed")
            }
        }
    }

    static func revoke(invitationID: UUID, actorID: UUID, on db: Database) async throws {
        guard let invite = try await TeamInvite.find(invitationID, on: db) else { throw Abort(.notFound) }
        _ = try await WorkspaceAccessService.requireCompany(invite.teamId, actorID: actorID, admin: true, on: db)
        guard let fresh = try await TeamInvite.find(invitationID, on: db) else { throw Abort(.notFound) }
        if fresh.status == "revoked" { return }
        guard fresh.isPending else { throw Abort(.conflict, reason: "This invitation is no longer pending") }
        fresh.status = "revoked"; try await fresh.save(on: db)
        try await WorkspaceAccessService.activity(workspaceID: fresh.teamId, actorID: actorID, action: "invitation_revoked", targetID: invitationID, on: db)
    }
}
