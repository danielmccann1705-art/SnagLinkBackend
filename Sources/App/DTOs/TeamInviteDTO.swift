import Vapor

// MARK: - Request DTOs

struct CreateTeamInviteRequest: Content {
    let email: String
    let role: String
    let teamId: UUID
    let expiresInDays: Int?
    let inviterName: String?

    func validate() throws {
        guard isValidEmail(email) else {
            throw Abort(.badRequest, reason: "Invalid email address")
        }

        guard TeamRole(rawValue: role) != nil else {
            throw Abort(.badRequest, reason: "Invalid role. Must be: admin, editor, or viewer")
        }

        if let days = expiresInDays, days < 1 || days > 30 {
            throw Abort(.badRequest, reason: "Expiration must be between 1 and 30 days")
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: emailRegex, options: .regularExpression) != nil
    }
}

// MARK: - Response DTOs

struct TeamInviteResponse: Content {
    let id: UUID
    let email: String
    let role: String
    let status: String
    let token: String
    let teamId: UUID
    let expiresAt: Date
    let invitedByUserId: UUID?
    let invitedByName: String?
    let createdAt: Date?

    init(from invite: TeamInvite, includeToken: Bool = false) {
        self.id = invite.id!
        self.email = invite.email
        self.role = invite.role
        self.status = invite.status
        self.token = includeToken ? invite.token : "***"
        self.teamId = invite.teamId
        self.expiresAt = invite.expiresAt
        self.invitedByUserId = invite.invitedByUserId
        self.invitedByName = invite.invitedByName
        self.createdAt = invite.createdAt
    }
}

struct TeamInviteValidationResponse: Content {
    let valid: Bool
    let email: String?
    let role: String?
    let teamId: UUID?
    let invitedByName: String?
    let expiresAt: Date?
    let message: String?

    static func valid(invite: TeamInvite) -> TeamInviteValidationResponse {
        return TeamInviteValidationResponse(
            valid: true,
            email: invite.email,
            role: invite.role,
            teamId: invite.teamId,
            invitedByName: invite.invitedByName,
            expiresAt: invite.expiresAt,
            message: nil
        )
    }

    static func invalid(reason: String) -> TeamInviteValidationResponse {
        return TeamInviteValidationResponse(
            valid: false,
            email: nil,
            role: nil,
            teamId: nil,
            invitedByName: nil,
            expiresAt: nil,
            message: reason
        )
    }
}

struct TeamInviteActionResponse: Content {
    let success: Bool
    let message: String
    let teamId: UUID?
    let role: String?
}
