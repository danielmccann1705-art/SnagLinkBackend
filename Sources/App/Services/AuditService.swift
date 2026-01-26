import Vapor
import Fluent

struct AuditService {
    /// Logs an audit event
    /// - Parameters:
    ///   - eventType: The type of event
    ///   - resourceType: The type of resource
    ///   - resourceId: The ID of the resource (optional)
    ///   - userId: The ID of the user performing the action (optional)
    ///   - request: The incoming request (for IP and user agent)
    ///   - success: Whether the action was successful
    ///   - details: Additional details about the event (optional)
    ///   - db: Database connection
    static func log(
        eventType: AuditEventType,
        resourceType: ResourceType,
        resourceId: UUID? = nil,
        userId: UUID? = nil,
        request: Request,
        success: Bool,
        details: String? = nil,
        on db: Database
    ) async throws {
        let auditLog = AuditLog(
            eventType: eventType,
            resourceType: resourceType,
            resourceId: resourceId,
            userId: userId,
            ipAddress: IPAddressExtractor.extract(from: request),
            userAgent: IPAddressExtractor.extractUserAgent(from: request),
            success: success,
            details: details
        )
        try await auditLog.save(on: db)
    }

    /// Logs a magic link access event
    static func logMagicLinkAccess(
        magicLink: MagicLink,
        request: Request,
        success: Bool,
        details: String? = nil,
        on db: Database
    ) async throws {
        try await log(
            eventType: .magicLinkValidated,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            request: request,
            success: success,
            details: details,
            on: db
        )
    }

    /// Logs a PIN verification attempt
    static func logPINVerification(
        magicLink: MagicLink,
        request: Request,
        success: Bool,
        on db: Database
    ) async throws {
        try await log(
            eventType: success ? .pinVerifySuccess : .pinVerifyFailure,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            request: request,
            success: success,
            on: db
        )
    }

    /// Logs a PIN lockout event
    static func logPINLockout(
        magicLink: MagicLink,
        request: Request,
        on db: Database
    ) async throws {
        try await log(
            eventType: .pinLockout,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            request: request,
            success: false,
            details: "Account locked after \(PINVerificationService.maxAttempts) failed attempts",
            on: db
        )
    }

    /// Logs a team invite action
    static func logTeamInviteAction(
        invite: TeamInvite,
        eventType: AuditEventType,
        userId: UUID? = nil,
        request: Request,
        success: Bool,
        on db: Database
    ) async throws {
        try await log(
            eventType: eventType,
            resourceType: .teamInvite,
            resourceId: invite.id,
            userId: userId,
            request: request,
            success: success,
            on: db
        )
    }

    /// Logs a rate limit exceeded event
    static func logRateLimitExceeded(
        resourceType: ResourceType,
        resourceId: UUID? = nil,
        request: Request,
        on db: Database
    ) async throws {
        try await log(
            eventType: .rateLimitExceeded,
            resourceType: resourceType,
            resourceId: resourceId,
            request: request,
            success: false,
            details: "Rate limit exceeded",
            on: db
        )
    }
}
