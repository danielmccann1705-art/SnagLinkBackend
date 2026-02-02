import Vapor
import Fluent
import QRCodeGenerator

struct MagicLinkController: RouteCollection {

    // MARK: - Slug Generation

    /// Generates a human-friendly slug for magic links
    /// Format: {prefix}-{random} e.g., "abc-x7k2m3"
    private func generateSlug(contractorName: String?) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let prefix = contractorName?
            .lowercased()
            .filter { $0.isLetter }
            .prefix(3)
            .description ?? "snl"

        let randomPart = String((0..<6).map { _ in
            chars.randomElement()!
        })

        return "\(prefix.isEmpty ? "snl" : prefix)-\(randomPart)"
    }

    /// Generates a unique slug, retrying if collision occurs
    private func generateUniqueSlug(contractorName: String?, on database: Database) async throws -> String {
        for _ in 0..<10 {
            let slug = generateSlug(contractorName: contractorName)
            let existing = try await MagicLink.query(on: database)
                .filter(\.$slug == slug)
                .first()
            if existing == nil {
                return slug
            }
        }
        // Fallback to longer random string if collisions persist
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let randomPart = String((0..<10).map { _ in chars.randomElement()! })
        return "snl-\(randomPart)"
    }

    func boot(routes: RoutesBuilder) throws {
        let magicLinks = routes.grouped("api", "v1", "magic-links")

        // Routes with consistent parameter name ":linkId"
        // Note: Using same param name at each route level is required by Vapor's TrieRouter
        magicLinks.get(":linkId", "validate", use: validateToken)
        magicLinks.post(":linkId", "verify-pin", use: verifyPIN)
        magicLinks.post(use: create)
        magicLinks.get(use: list)
        magicLinks.delete(":linkId", use: revoke)
        magicLinks.get(":linkId", "analytics", use: getAnalytics)
        magicLinks.get(":linkId", "snags", use: getSnags)
        magicLinks.get(":linkId", "pdf", use: downloadPDF)
        magicLinks.get(":linkId", "qr", use: generateQRCode)
    }

    // MARK: - Public Endpoints

    /// Validates a magic link token
    /// GET /api/v1/magic-links/:token/validate
    @Sendable
    func validateToken(req: Request) async throws -> MagicLinkValidationResponse {
        guard let token = req.parameters.get("linkId") else {
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

            // Return validation response with contractor/project info for demo
            // In production, these would be fetched from the database
            return MagicLinkValidationResponse.valid(
                magicLink: magicLink,
                contractorName: "ABC Plumbing",
                projectName: "Riverside Apartments",
                projectAddress: "123 River Road, London SE1 2AB"
            )
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
        guard let token = req.parameters.get("linkId") else {
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

        // Generate human-friendly slug
        let slug = try await generateUniqueSlug(contractorName: createRequest.contractorName, on: req.db)

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
            createdById: userId,
            slug: slug
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

        // Send email notification if contractor email provided
        if let contractorEmail = createRequest.contractorEmail, !contractorEmail.isEmpty {
            let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.app"
            let magicLinkURL = "\(baseURL)/link/\(token)"

            // Fire-and-forget: don't block response on email sending
            Task {
                do {
                    try await NotificationService.sendMagicLinkEmail(
                        to: contractorEmail,
                        contractorName: createRequest.contractorName ?? "Contractor",
                        projectName: createRequest.projectName ?? "Project",
                        projectAddress: createRequest.projectAddress,
                        snagCount: createRequest.snagIds.count,
                        magicLinkURL: magicLinkURL,
                        createdByName: createRequest.createdByName ?? "Project Manager",
                        client: req.client
                    )
                } catch {
                    req.logger.error("Failed to send magic link email: \(error)")
                }
            }
        }

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

        guard let idString = req.parameters.get("linkId"),
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

    /// Gets snags accessible via a magic link
    /// GET /api/v1/magic-links/:token/snags
    @Sendable
    func getSnags(req: Request) async throws -> SnagListResponse {
        guard let token = req.parameters.get("linkId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        // Validate magic link
        let magicLink = try await TokenValidationService.validateMagicLink(
            token: token,
            on: req.db
        )

        // Check PIN verification if required
        // For now, we allow fetching snags without PIN as the web frontend
        // will handle PIN verification separately via the verify-pin endpoint

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        // Get optional status filter
        let statusFilter = try? req.query.get(String.self, at: "status")

        // Build realistic test snag data for the demo
        // In production, this would fetch from the main snag database

        // Floor plan IDs for demo (Ground, First, Second floor)
        let groundFloorPlanId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstFloorPlanId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let secondFloorPlanId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        // Sample floor plan image (placeholder - in production these would be actual uploaded floor plans)
        let floorPlanImageURL = "https://images.unsplash.com/photo-1503387762-592deb58ef4e?w=1200"

        struct TestSnagData {
            let title: String
            let description: String?
            let status: String
            let priority: String
            let location: String?
            let floorPlanName: String?
            let floorPlanId: UUID?
            let pinX: Double?
            let pinY: Double?
            let dueDate: String?
            let photoUrl: String?
        }

        let testSnagData: [TestSnagData] = [
            TestSnagData(
                title: "Kitchen tap leaking",
                description: "Hot water tap in kitchen area is dripping constantly. Washer may need replacement. Water pooling under sink cabinet.",
                status: "open",
                priority: "high",
                location: "Unit 4B, Kitchen",
                floorPlanName: "Ground Floor Plan",
                floorPlanId: groundFloorPlanId,
                pinX: 0.35,
                pinY: 0.42,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60)),
                photoUrl: "https://images.unsplash.com/photo-1585704032915-c3400ca199e7?w=800"
            ),
            TestSnagData(
                title: "Shower seal incomplete",
                description: "Silicone sealant around shower tray is peeling away in corners. Potential water damage risk to floor below.",
                status: "open",
                priority: "critical",
                location: "Unit 2A, Bathroom",
                floorPlanName: "First Floor Plan",
                floorPlanId: firstFloorPlanId,
                pinX: 0.72,
                pinY: 0.28,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1 * 24 * 60 * 60)),
                photoUrl: "https://images.unsplash.com/photo-1552321554-5fefe8c9ef14?w=800"
            ),
            TestSnagData(
                title: "Radiator not heating",
                description: "Bedroom radiator stays cold even when heating is on. May need bleeding or valve replacement.",
                status: "in_progress",
                priority: "medium",
                location: "Unit 3C, Master Bedroom",
                floorPlanName: "First Floor Plan",
                floorPlanId: firstFloorPlanId,
                pinX: 0.15,
                pinY: 0.65,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 24 * 60 * 60)),
                photoUrl: "https://images.unsplash.com/photo-1558618666-fcd25c85cd64?w=800"
            ),
            TestSnagData(
                title: "Socket cover plate missing",
                description: "Electrical socket in living room missing cover plate. Currently taped over for safety but needs proper cover installed.",
                status: "open",
                priority: "high",
                location: "Unit 1A, Living Room",
                floorPlanName: "Ground Floor Plan",
                floorPlanId: groundFloorPlanId,
                pinX: 0.58,
                pinY: 0.75,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(1 * 24 * 60 * 60)),
                photoUrl: nil
            ),
            TestSnagData(
                title: "Window latch broken",
                description: "Latch mechanism on bedroom window doesn't secure properly. Window can be pushed open from outside.",
                status: "open",
                priority: "critical",
                location: "Unit 5D, Bedroom 2",
                floorPlanName: "Second Floor Plan",
                floorPlanId: secondFloorPlanId,
                pinX: 0.82,
                pinY: 0.35,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 24 * 60 * 60)),
                photoUrl: "https://images.unsplash.com/photo-1509644851169-2acc08aa25b5?w=800"
            ),
            TestSnagData(
                title: "Paint touch-up needed",
                description: "Scuff marks and minor damage to hallway walls from furniture moving. Needs repainting in matching colour.",
                status: "open",
                priority: "low",
                location: "Unit 4B, Hallway",
                floorPlanName: "Ground Floor Plan",
                floorPlanId: groundFloorPlanId,
                pinX: 0.45,
                pinY: 0.55,
                dueDate: nil,
                photoUrl: nil
            ),
            TestSnagData(
                title: "Door hinge squeaking",
                description: "Entrance door hinge making loud squeaking noise when opened. Needs lubrication.",
                status: "resolved",
                priority: "low",
                location: "Unit 2A, Front Door",
                floorPlanName: "Ground Floor Plan",
                floorPlanId: groundFloorPlanId,
                pinX: 0.25,
                pinY: 0.12,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 24 * 60 * 60)),
                photoUrl: nil
            ),
            TestSnagData(
                title: "Extractor fan noisy",
                description: "Bathroom extractor fan making rattling noise when running. May need cleaning or bearing replacement.",
                status: "open",
                priority: "medium",
                location: "Unit 3C, En-suite",
                floorPlanName: "First Floor Plan",
                floorPlanId: firstFloorPlanId,
                pinX: 0.68,
                pinY: 0.58,
                dueDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 60 * 60)),
                photoUrl: "https://images.unsplash.com/photo-1585771724684-38269d6639fd?w=800"
            )
        ]

        let contractorName = "ABC Plumbing"
        let projectName = "Riverside Apartments"
        let projectAddress = "123 River Road, London SE1 2AB"
        let createdByName = "John Smith"

        // Create snag DTOs - use actual snagIds from magic link if available, otherwise generate
        var snags: [SnagDTO] = []
        for (index, data) in testSnagData.prefix(magicLink.snagIds.count).enumerated() {
            let snagId = index < magicLink.snagIds.count ? magicLink.snagIds[index] : UUID()
            let photos: [SnagPhotoDTO] = data.photoUrl.map { url in
                [SnagPhotoDTO(id: UUID(), url: url, thumbnailUrl: url)]
            } ?? []

            snags.append(SnagDTO(
                id: snagId,
                title: data.title,
                description: data.description,
                status: data.status,
                priority: data.priority,
                photos: photos,
                location: data.location,
                floorPlanName: data.floorPlanName,
                floorPlanId: data.floorPlanId,
                floorPlanImageURL: data.floorPlanId != nil ? floorPlanImageURL : nil,
                pinX: data.pinX,
                pinY: data.pinY,
                dueDate: data.dueDate,
                assignedTo: contractorName,
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 24 * 60 * 60)), // 2 weeks ago
                createdByName: createdByName,
                projectId: magicLink.projectId
            ))
        }

        // If we have more snagIds than test data, generate simple snags for the rest
        if magicLink.snagIds.count > testSnagData.count {
            for i in testSnagData.count..<magicLink.snagIds.count {
                snags.append(SnagDTO(
                    id: magicLink.snagIds[i],
                    title: "Snag Item #\(i + 1)",
                    description: "Additional snag item requiring attention.",
                    status: "open",
                    priority: "medium",
                    photos: [],
                    location: "TBD",
                    floorPlanName: nil,
                    floorPlanId: nil,
                    floorPlanImageURL: nil,
                    pinX: nil,
                    pinY: nil,
                    dueDate: nil,
                    assignedTo: contractorName,
                    createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 24 * 60 * 60)),
                    createdByName: createdByName,
                    projectId: magicLink.projectId
                ))
            }
        }

        // Filter by status if provided
        if let status = statusFilter {
            snags = snags.filter { $0.status == status }
        }

        // Calculate status counts from unfiltered data
        let allSnags = snags
        let openCount = allSnags.filter { $0.status == "open" }.count
        let inProgressCount = allSnags.filter { $0.status == "in_progress" }.count
        let completedCount = allSnags.filter { $0.status == "resolved" || $0.status == "verified" || $0.status == "closed" }.count

        return SnagListResponse(
            snags: snags,
            totalCount: snags.count,
            projectId: magicLink.projectId,
            projectName: projectName,
            projectAddress: projectAddress,
            contractorName: contractorName,
            accessLevel: magicLink.accessLevel,
            openCount: openCount,
            inProgressCount: inProgressCount,
            completedCount: completedCount
        )
    }

    /// Gets analytics for a magic link
    /// GET /api/v1/magic-links/:id/analytics
    @Sendable
    func getAnalytics(req: Request) async throws -> MagicLinkAnalyticsResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("linkId"),
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

    /// Downloads a PDF report of snags accessible via a magic link
    /// GET /api/v1/magic-links/:token/pdf
    @Sendable
    func downloadPDF(req: Request) async throws -> Response {
        guard let token = req.parameters.get("linkId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        // Validate magic link
        let magicLink = try await TokenValidationService.validateMagicLink(
            token: token,
            on: req.db
        )

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        // Build snag data (same logic as getSnags)
        let testSnagData: [(title: String, description: String?, status: String, priority: String, location: String?, dueDate: String?)] = [
            ("Kitchen tap leaking", "Hot water tap in kitchen area is dripping constantly. Washer may need replacement.", "open", "high", "Unit 4B, Kitchen", ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))),
            ("Shower seal incomplete", "Silicone sealant around shower tray is peeling away in corners.", "open", "critical", "Unit 2A, Bathroom", ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1 * 24 * 60 * 60))),
            ("Radiator not heating", "Bedroom radiator stays cold even when heating is on.", "in_progress", "medium", "Unit 3C, Master Bedroom", ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 24 * 60 * 60))),
            ("Socket cover plate missing", "Electrical socket in living room missing cover plate.", "open", "high", "Unit 1A, Living Room", ISO8601DateFormatter().string(from: Date().addingTimeInterval(1 * 24 * 60 * 60))),
            ("Window latch broken", "Latch mechanism on bedroom window doesn't secure properly.", "open", "critical", "Unit 5D, Bedroom 2", ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 24 * 60 * 60))),
            ("Paint touch-up needed", "Scuff marks and minor damage to hallway walls.", "open", "low", "Unit 4B, Hallway", nil),
            ("Door hinge squeaking", "Entrance door hinge making loud squeaking noise when opened.", "resolved", "low", "Unit 2A, Front Door", ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 24 * 60 * 60))),
            ("Extractor fan noisy", "Bathroom extractor fan making rattling noise when running.", "open", "medium", "Unit 3C, En-suite", ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 60 * 60)))
        ]

        let contractorName = "ABC Plumbing"
        let projectName = "Riverside Apartments"
        let projectAddress = "123 River Road, London SE1 2AB"

        // Build snag list for PDF
        var snags: [(title: String, description: String?, status: String, priority: String, location: String?, dueDate: String?)] = []
        for (index, data) in testSnagData.prefix(magicLink.snagIds.count).enumerated() {
            snags.append(data)
        }

        // Generate simple HTML-based PDF content
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let generatedDate = dateFormatter.string(from: Date())

        var snagRows = ""
        for (index, snag) in snags.enumerated() {
            let statusColor = snag.status == "open" ? "#dc2626" : (snag.status == "in_progress" ? "#ca8a04" : "#16a34a")
            let priorityColor = snag.priority == "critical" ? "#dc2626" : (snag.priority == "high" ? "#ea580c" : (snag.priority == "medium" ? "#2563eb" : "#6b7280"))

            snagRows += """
            <tr style="border-bottom: 1px solid #e5e7eb;">
                <td style="padding: 12px 8px; font-weight: 500;">\(index + 1)</td>
                <td style="padding: 12px 8px;">
                    <div style="font-weight: 600; color: #111827;">\(snag.title)</div>
                    \(snag.description.map { "<div style=\"font-size: 12px; color: #6b7280; margin-top: 4px;\">\($0)</div>" } ?? "")
                </td>
                <td style="padding: 12px 8px;">\(snag.location ?? "-")</td>
                <td style="padding: 12px 8px;">
                    <span style="display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; background: \(statusColor)20; color: \(statusColor);">\(snag.status.replacingOccurrences(of: "_", with: " ").uppercased())</span>
                </td>
                <td style="padding: 12px 8px;">
                    <span style="display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; background: \(priorityColor)20; color: \(priorityColor);">\(snag.priority.uppercased())</span>
                </td>
                <td style="padding: 12px 8px; font-size: 12px;">\(snag.dueDate ?? "-")</td>
            </tr>
            """
        }

        let openCount = snags.filter { $0.status == "open" }.count
        let inProgressCount = snags.filter { $0.status == "in_progress" }.count
        let completedCount = snags.filter { $0.status == "resolved" || $0.status == "verified" || $0.status == "closed" }.count

        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Snag Report - \(projectName)</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; color: #1f2937; }
                .header { border-bottom: 2px solid #f97316; padding-bottom: 20px; margin-bottom: 30px; }
                .header h1 { color: #f97316; margin: 0 0 8px 0; font-size: 28px; }
                .header .subtitle { color: #6b7280; font-size: 14px; }
                .project-info { background: #f9fafb; padding: 20px; border-radius: 8px; margin-bottom: 30px; }
                .project-info h2 { margin: 0 0 8px 0; font-size: 18px; }
                .project-info p { margin: 0; color: #6b7280; }
                .stats { display: flex; gap: 20px; margin-bottom: 30px; }
                .stat { padding: 15px 20px; border-radius: 8px; flex: 1; text-align: center; }
                .stat-open { background: #fee2e2; color: #dc2626; }
                .stat-progress { background: #fef3c7; color: #ca8a04; }
                .stat-complete { background: #dcfce7; color: #16a34a; }
                .stat-value { font-size: 24px; font-weight: 700; }
                .stat-label { font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
                table { width: 100%; border-collapse: collapse; font-size: 13px; }
                th { text-align: left; padding: 12px 8px; background: #f3f4f6; font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: #6b7280; }
                .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 11px; color: #9ca3af; text-align: center; }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>Snaglist Report</h1>
                <div class="subtitle">Generated on \(generatedDate)</div>
            </div>

            <div class="project-info">
                <h2>\(projectName)</h2>
                <p>\(projectAddress)</p>
                <p style="margin-top: 8px;">Assigned to: <strong>\(contractorName)</strong></p>
            </div>

            <div class="stats">
                <div class="stat stat-open">
                    <div class="stat-value">\(openCount)</div>
                    <div class="stat-label">Open</div>
                </div>
                <div class="stat stat-progress">
                    <div class="stat-value">\(inProgressCount)</div>
                    <div class="stat-label">In Progress</div>
                </div>
                <div class="stat stat-complete">
                    <div class="stat-value">\(completedCount)</div>
                    <div class="stat-label">Complete</div>
                </div>
            </div>

            <table>
                <thead>
                    <tr>
                        <th style="width: 40px;">#</th>
                        <th>Description</th>
                        <th style="width: 120px;">Location</th>
                        <th style="width: 90px;">Status</th>
                        <th style="width: 80px;">Priority</th>
                        <th style="width: 100px;">Due Date</th>
                    </tr>
                </thead>
                <tbody>
                    \(snagRows)
                </tbody>
            </table>

            <div class="footer">
                <p>This report was generated by Snaglist &bull; snaglist.app</p>
            </div>
        </body>
        </html>
        """

        // Return HTML with PDF content-type hint
        // Note: For true PDF generation, you would use a library like wkhtmltopdf or PDFKit
        // For now, we return styled HTML that can be printed to PDF by the browser
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.headers.add(name: .contentDisposition, value: "attachment; filename=\"snag-report-\(projectName.replacingOccurrences(of: " ", with: "-").lowercased()).html\"")
        response.body = .init(string: htmlContent)

        return response
    }

    /// Generates a QR code image for a magic link
    /// GET /api/v1/magic-links/:linkId/qr?size=300
    @Sendable
    func generateQRCode(req: Request) async throws -> Response {
        guard let idString = req.parameters.get("linkId"),
              let linkId = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid magic link ID")
        }

        // Get optional size parameter (default 300px)
        let size = req.query[Int.self, at: "size"] ?? 300
        guard size >= 100 && size <= 1000 else {
            throw Abort(.badRequest, reason: "Size must be between 100 and 1000 pixels")
        }

        // Find the magic link
        guard let magicLink = try await MagicLink.find(linkId, on: req.db) else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Check if link is still valid (not expired or revoked)
        if magicLink.isExpired {
            throw Abort(.gone, reason: "Magic link has expired")
        }
        if magicLink.isRevoked {
            throw Abort(.gone, reason: "Magic link has been revoked")
        }

        // Build the short URL using slug if available, otherwise token
        let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.app"
        let slugOrToken = magicLink.slug ?? magicLink.token
        let shortUrl = "\(baseURL)/m/\(slugOrToken)"

        // Generate QR code
        guard let qr = try? QRCode.encode(text: shortUrl, ecl: .medium) else {
            throw Abort(.internalServerError, reason: "Failed to generate QR code")
        }

        // Generate SVG with requested size
        let svgString = qr.toSVGString(border: 2, width: size)

        // Return SVG response
        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "image", subType: "svg+xml")
        response.headers.cacheControl = .init(isPublic: true, maxAge: 3600) // Cache for 1 hour
        response.body = .init(string: svgString)

        return response
    }
}
