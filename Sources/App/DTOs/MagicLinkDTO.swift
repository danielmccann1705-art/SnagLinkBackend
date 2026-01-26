import Vapor

// MARK: - Request DTOs

struct CreateMagicLinkRequest: Content {
    let accessLevel: String
    let pin: String?
    let expiresAt: Date
    let snagIds: [UUID]
    let projectId: UUID
    let contractorId: UUID?

    func validate() throws {
        guard AccessLevel(rawValue: accessLevel) != nil else {
            throw Abort(.badRequest, reason: "Invalid access level. Must be: view, update, or full")
        }

        if let pin = pin {
            guard pin.count >= 4 && pin.count <= 8 else {
                throw Abort(.badRequest, reason: "PIN must be between 4 and 8 characters")
            }
            guard pin.allSatisfy({ $0.isNumber }) else {
                throw Abort(.badRequest, reason: "PIN must contain only digits")
            }
        }

        guard expiresAt > Date() else {
            throw Abort(.badRequest, reason: "Expiration date must be in the future")
        }

        guard !snagIds.isEmpty else {
            throw Abort(.badRequest, reason: "At least one snag ID is required")
        }
    }
}

struct VerifyPINRequest: Content {
    let pin: String

    func validate() throws {
        guard !pin.isEmpty else {
            throw Abort(.badRequest, reason: "PIN is required")
        }
    }
}

// MARK: - Response DTOs

struct MagicLinkResponse: Content {
    let id: UUID
    let token: String
    let accessLevel: String
    let requiresPIN: Bool
    let expiresAt: Date
    let revokedAt: Date?
    let openCount: Int
    let lastOpenedAt: Date?
    let snagIds: [UUID]
    let projectId: UUID
    let contractorId: UUID?
    let createdAt: Date?

    init(from magicLink: MagicLink, includeToken: Bool = false) {
        self.id = magicLink.id!
        self.token = includeToken ? magicLink.token : "***"
        self.accessLevel = magicLink.accessLevel
        self.requiresPIN = magicLink.requiresPIN
        self.expiresAt = magicLink.expiresAt
        self.revokedAt = magicLink.revokedAt
        self.openCount = magicLink.openCount
        self.lastOpenedAt = magicLink.lastOpenedAt
        self.snagIds = magicLink.snagIds
        self.projectId = magicLink.projectId
        self.contractorId = magicLink.contractorId
        self.createdAt = magicLink.createdAt
    }
}

struct MagicLinkValidationResponse: Content {
    let valid: Bool
    let accessLevel: String?
    let requiresPIN: Bool
    let expiresAt: Date?
    let snagIds: [UUID]?
    let projectId: UUID?
    let message: String?

    static func valid(magicLink: MagicLink) -> MagicLinkValidationResponse {
        return MagicLinkValidationResponse(
            valid: true,
            accessLevel: magicLink.accessLevel,
            requiresPIN: magicLink.requiresPIN,
            expiresAt: magicLink.expiresAt,
            snagIds: magicLink.snagIds,
            projectId: magicLink.projectId,
            message: nil
        )
    }

    static func invalid(reason: String) -> MagicLinkValidationResponse {
        return MagicLinkValidationResponse(
            valid: false,
            accessLevel: nil,
            requiresPIN: false,
            expiresAt: nil,
            snagIds: nil,
            projectId: nil,
            message: reason
        )
    }
}

struct PINVerificationResponse: Content {
    let verified: Bool
    let accessLevel: String?
    let snagIds: [UUID]?
    let projectId: UUID?
    let message: String?

    static func success(magicLink: MagicLink) -> PINVerificationResponse {
        return PINVerificationResponse(
            verified: true,
            accessLevel: magicLink.accessLevel,
            snagIds: magicLink.snagIds,
            projectId: magicLink.projectId,
            message: nil
        )
    }

    static func failure(reason: String) -> PINVerificationResponse {
        return PINVerificationResponse(
            verified: false,
            accessLevel: nil,
            snagIds: nil,
            projectId: nil,
            message: reason
        )
    }
}

struct MagicLinkAnalyticsResponse: Content {
    let id: UUID
    let totalAccesses: Int
    let uniqueIPs: Int
    let lastAccessedAt: Date?
    let accesses: [AccessRecord]

    struct AccessRecord: Content {
        let ipAddress: String
        let userAgent: String?
        let country: String?
        let city: String?
        let pinVerified: Bool
        let accessedAt: Date?

        init(from access: MagicLinkAccess) {
            self.ipAddress = access.ipAddress
            self.userAgent = access.userAgent
            self.country = access.country
            self.city = access.city
            self.pinVerified = access.pinVerified
            self.accessedAt = access.accessedAt
        }
    }
}
