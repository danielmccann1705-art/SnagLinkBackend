import Vapor

// MARK: - Snag DTOs

/// DTO representing a snag item accessible via magic link
struct SnagDTO: Content {
    let id: UUID
    let title: String
    let description: String?
    let status: String
    let priority: String
    let photos: [SnagPhotoDTO]
    let location: String?           // Human-readable location string
    let floorPlanName: String?      // Name of floor plan if associated
    let floorPlanId: UUID?          // UUID of the associated floor plan
    let floorPlanImageURL: String?  // URL to the floor plan image
    let pinX: Double?               // 0-1 normalized X coordinate on floor plan
    let pinY: Double?               // 0-1 normalized Y coordinate on floor plan
    let dueDate: String?            // ISO8601 date string
    let assignedTo: String?         // Contractor/assignee name
    let createdAt: String?          // ISO8601 date string
    let createdByName: String?      // Name of person who created the snag
    let projectId: UUID
}

struct SnagPhotoDTO: Content {
    let id: UUID
    let url: String
    let thumbnailUrl: String?
}

// Note: SnagLocationDTO removed - location is now a human-readable string in SnagDTO

/// Response for listing snags via magic link
struct SnagListResponse: Content {
    let snags: [SnagDTO]
    let totalCount: Int
    let projectId: UUID
    let projectName: String         // Name of the project
    let projectAddress: String?     // Project address/location
    let contractorName: String      // Contractor who received the magic link
    let accessLevel: String
    // Summary stats for quick display
    let openCount: Int
    let inProgressCount: Int
    let completedCount: Int
}

// MARK: - Request DTOs

struct CreateMagicLinkRequest: Content {
    let accessLevel: String
    let pin: String?
    let expiresAt: Date
    let snagIds: [UUID]
    let projectId: UUID
    let contractorId: UUID?
    // Optional fields for email notification
    let contractorEmail: String?
    let contractorName: String?
    let projectName: String?
    let projectAddress: String?
    let createdByName: String?
    let createdByEmail: String?

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

        // Validate email format if provided
        if let email = contractorEmail, !email.isEmpty {
            let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
            guard email.range(of: emailRegex, options: .regularExpression) != nil else {
                throw Abort(.badRequest, reason: "Invalid contractor email format")
            }
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
    let slug: String?
    let shortUrl: String
    let qrCodeUrl: String

    init(from magicLink: MagicLink, includeToken: Bool = false, baseURL: String? = nil) {
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
        self.slug = magicLink.slug

        let base = baseURL ?? Environment.get("BASE_URL") ?? "https://snaglist.app"
        let slugOrToken = magicLink.slug ?? magicLink.token
        self.shortUrl = "\(base)/m/\(slugOrToken)"
        self.qrCodeUrl = "\(base)/api/v1/magic-links/\(magicLink.id!)/qr"
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
    let contractorName: String?     // Contractor who received the link
    let projectName: String?        // Project name for display
    let projectAddress: String?     // Project address for display

    static func valid(magicLink: MagicLink, contractorName: String? = nil, projectName: String? = nil, projectAddress: String? = nil) -> MagicLinkValidationResponse {
        return MagicLinkValidationResponse(
            valid: true,
            accessLevel: magicLink.accessLevel,
            requiresPIN: magicLink.requiresPIN,
            expiresAt: magicLink.expiresAt,
            snagIds: magicLink.snagIds,
            projectId: magicLink.projectId,
            message: nil,
            contractorName: contractorName,
            projectName: projectName,
            projectAddress: projectAddress
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
            message: reason,
            contractorName: nil,
            projectName: nil,
            projectAddress: nil
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
