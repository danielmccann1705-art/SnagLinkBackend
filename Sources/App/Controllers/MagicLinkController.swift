import Vapor
import Fluent

struct MagicLinkController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let magicLinks = routes.grouped("api", "v1", "magic-links")

        // Public endpoints (with rate limiting)
        let publicRoutes = magicLinks.grouped(RateLimitMiddleware(action: .tokenLookup))
        publicRoutes.get(":token", "validate", use: validateToken)
        publicRoutes.grouped(RateLimitMiddleware(action: .pinAttempt))
            .post(":token", "verify-pin", use: verifyPIN)

        // Authenticated endpoints
        let authRoutes = magicLinks.grouped(JWTAuthMiddleware())
        authRoutes.post(use: create)
        authRoutes.get(use: list)
        authRoutes.delete(":id", use: revoke)
        authRoutes.get(":id", "analytics", use: getAnalytics)
    }

    // MARK: - Public Endpoints

    /// Validates a magic link token
    /// GET /api/v1/magic-links/:token/validate
    @Sendable
    func validateToken(req: Request) async throws -> MagicLinkValidationResponse {
        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        do {
            let magicLink = try await TokenValidationService.validateMagicLink(
                token: token,
                on: req.db
            )

            // Log the access
            try await AuditService.logMagicLinkAccess(
                magicLink: magicLink,
                request: req,
                success: true,
                on: req.db
            )

            return MagicLinkValidationResponse.valid(magicLink: magicLink)
        } catch let error as TokenValidationService.ValidationError {
            // Log failed validation
            try? await AuditService.log(
                eventType: .magicLinkValidated,
                resourceType: .magicLink,
                request: req,
                success: false,
                details: error.reason,
                on: req.db
            )

            return MagicLinkValidationResponse.invalid(reason: error.reason)
        }
    }

    /// Verifies a PIN for a magic link
    /// POST /api/v1/magic-links/:token/verify-pin
    @Sendable
    func verifyPIN(req: Request) async throws -> PINVerificationResponse {
        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        let pinRequest = try req.content.decode(VerifyPINRequest.self)
        try pinRequest.validate()

        // First validate the token
        let magicLink = try await TokenValidationService.validateMagicLink(
            token: token,
            on: req.db
        )

        // Check if PIN is required
        guard magicLink.requiresPIN else {
            throw Abort(.badRequest, reason: "This magic link does not require a PIN")
        }

        do {
            let verified = try await PINVerificationService.verify(
                pin: pinRequest.pin,
                magicLink: magicLink,
                on: req.db
            )

            if verified {
                // Log successful verification
                try await AuditService.logPINVerification(
                    magicLink: magicLink,
                    request: req,
                    success: true,
                    on: req.db
                )

                // Record the access with PIN verified
                try await TokenValidationService.recordAccess(
                    magicLink: magicLink,
                    request: req,
                    pinVerified: true,
                    on: req.db
                )

                return PINVerificationResponse.success(magicLink: magicLink)
            } else {
                // Log failed verification
                try await AuditService.logPINVerification(
                    magicLink: magicLink,
                    request: req,
                    success: false,
                    on: req.db
                )

                return PINVerificationResponse.failure(reason: "Invalid PIN")
            }
        } catch let error as AbortError {
            // Log failed attempt
            try await AuditService.logPINVerification(
                magicLink: magicLink,
                request: req,
                success: false,
                on: req.db
            )

            // Check if locked
            if magicLink.failedPinAttempts >= PINVerificationService.maxAttempts {
                try await AuditService.logPINLockout(
                    magicLink: magicLink,
                    request: req,
                    on: req.db
                )
            }

            throw error
        }
    }

    // MARK: - Authenticated Endpoints

    /// Creates a new magic link
    /// POST /api/v1/magic-links
    @Sendable
    func create(req: Request) async throws -> MagicLinkResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createRequest = try req.content.decode(CreateMagicLinkRequest.self)
        try createRequest.validate()

        // Generate secure token
        let token = try SecureTokenGenerator.generate()

        // Hash PIN if provided
        var pinHash: String? = nil
        var pinSalt: String? = nil
        if let pin = createRequest.pin {
            let hashResult = try PINVerificationService.hashPIN(pin)
            pinHash = hashResult.hash
            pinSalt = hashResult.salt
        }

        let magicLink = MagicLink(
            token: token,
            accessLevel: AccessLevel(rawValue: createRequest.accessLevel)!,
            pinHash: pinHash,
            pinSalt: pinSalt,
            expiresAt: createRequest.expiresAt,
            snagIds: createRequest.snagIds,
            projectId: createRequest.projectId,
            contractorId: createRequest.contractorId,
            createdById: userId
        )

        try await magicLink.save(on: req.db)

        // Log creation
        try await AuditService.log(
            eventType: .magicLinkCreated,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return MagicLinkResponse(from: magicLink, includeToken: true)
    }

    /// Lists magic links created by the authenticated user
    /// GET /api/v1/magic-links
    @Sendable
    func list(req: Request) async throws -> [MagicLinkResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let magicLinks = try await MagicLink.query(on: req.db)
            .filter(\.$createdById == userId)
            .sort(\.$createdAt, .descending)
            .all()

        return magicLinks.map { MagicLinkResponse(from: $0, includeToken: false) }
    }

    /// Revokes a magic link
    /// DELETE /api/v1/magic-links/:id
    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid magic link ID")
        }

        guard let magicLink = try await MagicLink.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Verify ownership
        guard magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You do not have permission to revoke this magic link")
        }

        // Already revoked
        if magicLink.isRevoked {
            throw Abort(.badRequest, reason: "Magic link is already revoked")
        }

        magicLink.revokedAt = Date()
        try await magicLink.save(on: req.db)

        // Log revocation
        try await AuditService.log(
            eventType: .magicLinkRevoked,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            userId: userId,
            request: req,
            success: true,
            on: req.db
        )

        return .noContent
    }

    /// Gets analytics for a magic link
    /// GET /api/v1/magic-links/:id/analytics
    @Sendable
    func getAnalytics(req: Request) async throws -> MagicLinkAnalyticsResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid magic link ID")
        }

        guard let magicLink = try await MagicLink.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Verify ownership
        guard magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You do not have permission to view analytics for this magic link")
        }

        // Get all accesses
        let accesses = try await MagicLinkAccess.query(on: req.db)
            .filter(\.$magicLink.$id == id)
            .sort(\.$accessedAt, .descending)
            .all()

        // Calculate unique IPs
        let uniqueIPs = Set(accesses.map { $0.ipAddress }).count

        return MagicLinkAnalyticsResponse(
            id: id,
            totalAccesses: accesses.count,
            uniqueIPs: uniqueIPs,
            lastAccessedAt: magicLink.lastOpenedAt,
            accesses: accesses.map { MagicLinkAnalyticsResponse.AccessRecord(from: $0) }
        )
    }
}
