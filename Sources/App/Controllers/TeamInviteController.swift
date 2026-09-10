import Vapor
import Fluent

struct TeamInviteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let teamInvites = routes.grouped("api", "v1", "team-invites")

        // Routes with consistent parameter name ":inviteId"
        // Note: Using same param name at each route level is required by Vapor's TrieRouter
        teamInvites.get(":inviteId", "validate", use: validateToken)

        // Authenticated routes (JWT required)
        let authenticated = teamInvites.grouped(JWTAuthMiddleware())
        authenticated.post(use: create)
        authenticated.get("pending", use: listPending)
        authenticated.post(":inviteId", "accept", use: accept)
        authenticated.post(":inviteId", "decline", use: decline)
        authenticated.delete(":inviteId", use: revoke)
    }

    // MARK: - Public Endpoints

    /// Validates a team invite token
    /// GET /api/v1/team-invites/:token/validate
    @Sendable
    func validateToken(req: Request) async throws -> TeamInviteValidationResponse {
        guard let token = req.parameters.get("inviteId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        do {
            let invite = try await TokenValidationService.validateTeamInvite(
                token: token,
                on: req.db
            )

            return TeamInviteValidationResponse.valid(invite: invite)
        } catch let error as TokenValidationService.ValidationError {
            return TeamInviteValidationResponse.invalid(reason: error.reason)
        } catch let error as AbortError {
            return TeamInviteValidationResponse.invalid(reason: error.reason)
        }
    }

    // MARK: - Authenticated Endpoints

    /// Creates a new team invite
    /// POST /api/v1/team-invites
    @Sendable
    func create(req: Request) async throws -> TeamInviteResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createRequest = try req.content.decode(CreateTeamInviteRequest.self)
        try createRequest.validate()

        guard createRequest.role != "viewer" else {
            throw Abort(.conflict, reason: "Ask an admin to invite a Member using the current app")
        }
        let result = try await req.db.transaction { db in
            try await WorkspaceInvitationService.issue(workspaceID: createRequest.teamId,
                email: createRequest.email, role: createRequest.role == "admin" ? "admin" : "member",
                projects: [], actorID: userId, on: db)
        }
        return TeamInviteResponse(from: result.0, rawToken: result.1, legacyRoles: true)
    }

    /// Lists pending invites for the authenticated user's email
    /// GET /api/v1/team-invites/pending
    @Sendable
    func listPending(req: Request) async throws -> [TeamInviteResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let emails = try await VerifiedIdentityService.verifiedEmails(for: userId, on: req.db)
        guard !emails.isEmpty else { return [] }
        let invites = try await TeamInvite.query(on: req.db)
            .filter(\.$email ~~ emails).filter(\.$status == InviteStatus.pending.rawValue)
            .filter(\.$expiresAt > Date()).sort(\.$createdAt, .descending).limit(100).all()
        return invites.map { TeamInviteResponse(from: $0, legacyRoles: true) }
    }

    /// Accepts a team invite
    /// POST /api/v1/team-invites/:inviteId/accept
    @Sendable
    func accept(req: Request) async throws -> TeamInviteActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("inviteId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        let invite = try await req.db.transaction { db in
            try await WorkspaceInvitationService.accept(token: token, actorID: userId, on: db)
        }
        return TeamInviteActionResponse(success: true, message: "You have joined the company", teamId: invite.teamId,
                                        role: invite.role == "member" ? "editor" : invite.role)
    }

    /// Declines a team invite
    /// POST /api/v1/team-invites/:inviteId/decline
    @Sendable
    func decline(req: Request) async throws -> TeamInviteActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("inviteId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        try await req.db.transaction { db in
            let initial = try await WorkspaceInvitationService.resolve(token: token, on: db)
            try await WorkspaceAccessService.lock(initial.teamId, on: db)
            let invite = try await WorkspaceInvitationService.resolve(token: token, on: db)
            let emails = try await VerifiedIdentityService.verifiedEmails(for: userId, on: db)
            guard emails.contains(EmailValidator.normalize(invite.email)) else { throw Abort(.forbidden, reason: "Verify the invited email first") }
            guard invite.isPending, !invite.isExpired else { throw Abort(.gone) }
            invite.status = InviteStatus.declined.rawValue
            try await invite.save(on: db)
            try await WorkspaceAccessService.activity(workspaceID: invite.teamId, actorID: userId, action: "invitation_declined", targetID: invite.requireID(), on: db)
        }
        return TeamInviteActionResponse(success: true, message: "Invitation declined", teamId: nil, role: nil)
    }

    /// Revokes a team invite
    /// DELETE /api/v1/team-invites/:inviteId
    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("inviteId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid team invite ID")
        }

        try await req.db.transaction { db in
            try await WorkspaceInvitationService.revoke(invitationID: id, actorID: userId, on: db)
        }
        return .noContent
    }
}
