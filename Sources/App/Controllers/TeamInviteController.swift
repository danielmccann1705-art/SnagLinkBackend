import Vapor
import Fluent

struct TeamInviteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let teamInvites = routes.grouped("api", "v1", "team-invites")

        // Public endpoints (with rate limiting)
        let publicRoutes = teamInvites.grouped(RateLimitMiddleware(action: .tokenLookup))
        publicRoutes.get(":token", "validate", use: validateToken)

        // Authenticated endpoints
        let authRoutes = teamInvites.grouped(JWTAuthMiddleware())
        authRoutes.post(use: create)
        authRoutes.get("pending", use: listPending)
        authRoutes.post(":token", "accept", use: accept)
        authRoutes.post(":token", "decline", use: decline)
        authRoutes.delete(":id", use: revoke)
    }

    // MARK: - Public Endpoints

    /// Validates a team invite token
    /// GET /api/v1/team-invites/:token/validate
    @Sendable
    func validateToken(req: Request) async throws -> TeamInviteValidationResponse {
        guard let token = req.parameters.get("token") else {
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

        // Check for existing pending invite
        let existingInvite = try await TeamInvite.query(on: req.db)
            .filter(\.$email == createRequest.email)
            .filter(\.$teamId == createRequest.teamId)
            .filter(\.$status == InviteStatus.pending.rawValue)
            .first()

        if existingInvite != nil {
            throw Abort(.conflict, reason: "A pending invite already exists for this email")
        }

        // Generate secure token
        let token = try SecureTokenGenerator.generate()

        // Calculate expiration (default 7 days)
        let expiresInDays = createRequest.expiresInDays ?? 7
        let expiresAt = Calendar.current.date(byAdding: .day, value: expiresInDays, to: Date())!

        let invite = TeamInvite(
            email: createRequest.email.lowercased(),
            role: TeamRole(rawValue: createRequest.role)!,
            token: token,
            teamId: createRequest.teamId,
            expiresAt: expiresAt,
            invitedByUserId: userId,
            invitedByName: createRequest.inviterName
        )

        try await invite.save(on: req.db)

        // Log creation
        try await AuditService.logTeamInviteAction(
            invite: invite,
            eventType: .teamInviteCreated,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return TeamInviteResponse(from: invite, includeToken: true)
    }

    /// Lists pending invites for the authenticated user's email
    /// GET /api/v1/team-invites/pending
    @Sendable
    func listPending(req: Request) async throws -> [TeamInviteResponse] {
        // Note: In a real app, you'd get the user's email from the JWT or a user service
        // For now, we'll accept an email query parameter
        guard let email = req.query[String.self, at: "email"] else {
            throw Abort(.badRequest, reason: "Email query parameter is required")
        }

        let invites = try await TeamInvite.query(on: req.db)
            .filter(\.$email == email.lowercased())
            .filter(\.$status == InviteStatus.pending.rawValue)
            .filter(\.$expiresAt > Date())
            .sort(\.$createdAt, .descending)
            .all()

        return invites.map { TeamInviteResponse(from: $0, includeToken: false) }
    }

    /// Accepts a team invite
    /// POST /api/v1/team-invites/:token/accept
    @Sendable
    func accept(req: Request) async throws -> TeamInviteActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        let invite = try await TokenValidationService.validateTeamInvite(
            token: token,
            on: req.db
        )

        // Update status
        invite.status = InviteStatus.accepted.rawValue
        try await invite.save(on: req.db)

        // Log acceptance
        try await AuditService.logTeamInviteAction(
            invite: invite,
            eventType: .teamInviteAccepted,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return TeamInviteActionResponse(
            success: true,
            message: "Invite accepted successfully",
            teamId: invite.teamId,
            role: invite.role
        )
    }

    /// Declines a team invite
    /// POST /api/v1/team-invites/:token/decline
    @Sendable
    func decline(req: Request) async throws -> TeamInviteActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        let invite = try await TokenValidationService.validateTeamInvite(
            token: token,
            on: req.db
        )

        // Update status
        invite.status = InviteStatus.declined.rawValue
        try await invite.save(on: req.db)

        // Log decline
        try await AuditService.logTeamInviteAction(
            invite: invite,
            eventType: .teamInviteDeclined,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return TeamInviteActionResponse(
            success: true,
            message: "Invite declined",
            teamId: nil,
            role: nil
        )
    }

    /// Revokes a team invite
    /// DELETE /api/v1/team-invites/:id
    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid team invite ID")
        }

        guard let invite = try await TeamInvite.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Team invite not found")
        }

        // Verify the user is the one who created the invite
        guard invite.invitedByUserId == userId else {
            throw Abort(.forbidden, reason: "You do not have permission to revoke this invite")
        }

        // Can only revoke pending invites
        guard invite.status == InviteStatus.pending.rawValue else {
            throw Abort(.badRequest, reason: "Can only revoke pending invites")
        }

        invite.status = InviteStatus.revoked.rawValue
        try await invite.save(on: req.db)

        // Log revocation
        try await AuditService.logTeamInviteAction(
            invite: invite,
            eventType: .teamInviteRevoked,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return .noContent
    }
}
