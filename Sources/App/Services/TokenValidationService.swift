import Vapor
import Fluent

struct TokenValidationService {
    enum ValidationError: Error {
        case notFound
        case expired
        case revoked
        case locked
    }

    /// Validates a magic link token
    /// - Parameters:
    ///   - token: The token to validate
    ///   - db: Database connection
    /// - Returns: The MagicLink if valid
    /// - Throws: ValidationError if token is invalid
    static func validateMagicLink(
        token: String,
        on db: Database
    ) async throws -> MagicLink {
        guard let magicLink = try await MagicLink.query(on: db)
            .filter(\.$token == token)
            .first() else {
            throw ValidationError.notFound
        }

        if magicLink.isRevoked {
            throw ValidationError.revoked
        }

        if magicLink.isExpired {
            throw ValidationError.expired
        }

        if magicLink.isLocked {
            throw ValidationError.locked
        }

        return magicLink
    }

    /// Validates a team invite token
    /// - Parameters:
    ///   - token: The token to validate
    ///   - db: Database connection
    /// - Returns: The TeamInvite if valid
    /// - Throws: ValidationError if token is invalid
    static func validateTeamInvite(
        token: String,
        on db: Database
    ) async throws -> TeamInvite {
        guard let invite = try await TeamInvite.query(on: db)
            .filter(\.$token == token)
            .first() else {
            throw ValidationError.notFound
        }

        if invite.status == InviteStatus.revoked.rawValue {
            throw ValidationError.revoked
        }

        if invite.isExpired || invite.status == InviteStatus.expired.rawValue {
            throw ValidationError.expired
        }

        if invite.status != InviteStatus.pending.rawValue {
            throw Abort(.badRequest, reason: "Invite has already been \(invite.status)")
        }

        return invite
    }

    /// Records an access to a magic link
    /// - Parameters:
    ///   - magicLink: The magic link being accessed
    ///   - request: The incoming request (for IP and user agent)
    ///   - pinVerified: Whether the PIN was successfully verified
    ///   - db: Database connection
    static func recordAccess(
        magicLink: MagicLink,
        request: Request,
        pinVerified: Bool,
        on db: Database
    ) async throws {
        // Update the magic link
        magicLink.openCount += 1
        magicLink.lastOpenedAt = Date()
        try await magicLink.save(on: db)

        // Create access record
        let access = MagicLinkAccess(
            magicLinkId: magicLink.id!,
            ipAddress: IPAddressExtractor.extract(from: request),
            userAgent: IPAddressExtractor.extractUserAgent(from: request),
            pinVerified: pinVerified
        )
        try await access.save(on: db)
    }
}

extension TokenValidationService.ValidationError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .notFound:
            return .notFound
        case .expired:
            return .gone
        case .revoked:
            return .gone
        case .locked:
            return .tooManyRequests
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            return "Token not found"
        case .expired:
            return "Token has expired"
        case .revoked:
            return "Token has been revoked"
        case .locked:
            return "Token is temporarily locked due to too many failed attempts"
        }
    }
}
