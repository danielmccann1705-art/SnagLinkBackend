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

        // Public routes — rate limited to prevent brute force
        let rateLimited = magicLinks.grouped(RateLimitMiddleware(action: .tokenLookup))
        rateLimited.get(":linkId", "validate", use: validateToken)
        rateLimited.post(":linkId", "verify-pin", use: verifyPIN)
        // Compatibility paths used by the shipped iOS app and App Clip.
        rateLimited.get("token", ":linkId", "validate", use: validateToken)
        rateLimited.post("token", ":linkId", "verify-pin", use: verifyPIN)
        rateLimited.get(":linkId", "snags", use: getSnags)
        rateLimited.get(":linkId", "pdf", use: downloadPDF)
        rateLimited.get(":linkId", "qr", use: generateQRCode)

        // Authenticated management routes (JWT required)
        let authenticated = magicLinks.grouped(JWTAuthMiddleware())
        authenticated.post(use: create)
        authenticated.post("preview", use: createPreview)  // B2
        authenticated.post(":linkId", "send", use: sendLink)  // B4
        authenticated.get(use: list)
        authenticated.delete(":linkId", use: revoke)
        authenticated.post(":linkId", "revoke", use: revokeByToken)
        authenticated.get(":linkId", "analytics", use: getAnalytics)

        // Authenticated sync routes for iOS app
        authenticated.post("sync", use: syncFromiOS)
        authenticated.post(":linkId", "report", use: syncReportData)
        authenticated.on(.POST, ":linkId", "photos", body: .collect(maxSize: "10mb"), use: syncPhoto)
        authenticated.on(.POST, ":linkId", "drawings", body: .collect(maxSize: "50mb"), use: syncDrawing)
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

            // Fetch contractor/project info from synced report data
            var contractorName: String? = nil
            var projectName: String? = nil
            var projectAddress: String? = nil

            if let syncedReport = try await SyncedReport.query(on: req.db)
                .filter(\.$magicLinkToken == magicLink.token)
                .first(),
               let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let report = try? decoder.decode(SyncedReportJSON.self, from: jsonData) {
                    contractorName = report.resolvedContractorName
                    projectName = report.resolvedProjectName
                    projectAddress = report.resolvedProjectAddress
                }
            }

            return MagicLinkValidationResponse.valid(
                magicLink: magicLink,
                contractorName: contractorName,
                projectName: projectName,
                projectAddress: projectAddress
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
    func verifyPIN(req: Request) async throws -> Response {
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

                var response = try await PINVerificationResponse.success(magicLink: magicLink).encodeResponse(for: req)
                PINSessionService.attach(to: &response, link: magicLink)
                return response
            } else {
                // Log failed verification
                try await AuditService.logPINVerification(
                    magicLink: magicLink,
                    request: req,
                    success: false,
                    on: req.db
                )

                return try await PINVerificationResponse.failure(reason: "Invalid PIN").encodeResponse(for: req)
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
        try await LegacyProjectAccess.requireAvailable(projectID: createRequest.projectId, ownerID: userId, on: req.db)
        try createRequest.validate()

        // Generate secure token
        let token = try SecureTokenGenerator.generate()

        // Generate human-friendly slug
        let slug = try await generateUniqueSlug(contractorName: createRequest.contractorName, on: req.db)

        // Hash PIN if provided (using bcrypt)
        var pinHash: String? = nil
        var pinSalt: String? = nil
        if let pin = createRequest.pin {
            let hashResult = try PINVerificationService.hashPIN(pin)
            pinHash = hashResult.hash
            pinSalt = hashResult.salt  // nil for bcrypt (salt embedded in hash)
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
            let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.dev"
            let magicLinkURL = "\(baseURL)/m/\(slug)"

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

    /// Creates an unsent preview magic link (B2).
    /// POST /api/v1/magic-links/preview
    /// Returns a 1h-TTL token the PM can open at `/preview/{token}` to see the contractor view.
    /// Preview links are never counted against the monthly allowance (counting happens on send).
    @Sendable
    func createPreview(req: Request) async throws -> PreviewMagicLinkResponse {
        let userId = try req.requireAuthenticatedUserId()
        let previewRequest = try req.content.decode(PreviewMagicLinkRequest.self)
        try await LegacyProjectAccess.requireAvailable(projectID: previewRequest.projectId, ownerID: userId, on: req.db)
        try previewRequest.validate()

        let token = try SecureTokenGenerator.generate()
        // 1h TTL — set both expiresAt (so standard validation catches expiry) and
        // previewExpiresAt (drives the nightly cleanup + preview semantics).
        let expiry = Date().addingTimeInterval(60 * 60)

        let magicLink = MagicLink(
            token: token,
            accessLevel: .update,
            expiresAt: expiry,
            snagIds: previewRequest.snagIds,
            projectId: previewRequest.projectId,
            contractorId: previewRequest.contractorId,
            createdById: userId,
            slug: nil,
            previewMode: true,
            previewExpiresAt: expiry
        )

        try await magicLink.save(on: req.db)

        try await AuditService.log(
            eventType: .magicLinkCreated,
            resourceType: .magicLink,
            resourceId: magicLink.id,
            userId: userId,
            request: req,
            success: true,
            details: "Preview link created",
            on: req.db
        )

        let base = Environment.get("MAGIC_LINK_BASE_URL") ?? Environment.get("BASE_URL") ?? "https://snaglist.dev"
        return PreviewMagicLinkResponse(
            previewToken: token,
            previewURL: "\(base)/preview/\(token)"
        )
    }

    /// Records a magic-link send and enforces the tier allowance (B4).
    /// POST /api/v1/magic-links/:linkId/send
    /// - First-ever send is the exempt onboarding link: flips `onboardingLinkConsumed`, uncounted.
    /// - Free tier: 5 counted sends/month, else 403 (paywall).
    /// - Pro tier: unlimited.
    /// Returns the updated usage snapshot. Actual delivery (SMS/email) is handled by the client;
    /// this endpoint is the counting + enforcement gate.
    @Sendable
    func sendLink(req: Request) async throws -> UsageResponse {
        let userId = try req.requireAuthenticatedUserId()
        guard let idString = req.parameters.get("linkId"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid magic link ID")
        }
        guard let magicLink = try await MagicLink.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Magic link not found")
        }
        guard magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You do not have permission to send this magic link")
        }
        guard !magicLink.previewMode else {
            throw Abort(.badRequest, reason: "Preview links cannot be sent")
        }
        guard let user = try await User.find(userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        // First-ever send is the free onboarding link: exempt + uncounted.
        let tier = try await SubscriptionVerificationService.currentTier(user: user, on: req)
        if !user.onboardingLinkConsumed {
            user.onboardingLinkConsumed = true
            try await user.save(on: req.db)
            return try await UsageService.buildUsage(user: user, on: req.db)
        }

        // Free tier: enforce the monthly cap.
        if tier == .free {
            let count = try await UsageService.currentMonthSendCount(userId: userId, on: req.db)
            guard count < UsageService.freeMonthlyLimit else {
                throw Abort(
                    .forbidden,
                    headers: ["X-Snaglist-Error": "paywall_required"],
                    reason: "You've used all \(UsageService.freeMonthlyLimit) free links this month. Upgrade to Pro for unlimited."
                )
            }
        }

        // Record the counted send (both free and pro, for history).
        let send = MagicLinkSend(userId: userId, magicLinkId: id)
        try await send.save(on: req.db)

        return try await UsageService.buildUsage(user: user, on: req.db)
    }

    /// Lists magic links created by the authenticated user
    /// GET /api/v1/magic-links
    @Sendable
    func list(req: Request) async throws -> [MagicLinkResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        let perPage = min((try? req.query.get(Int.self, at: "perPage")) ?? 50, 100)
        let offset = (page - 1) * perPage

        let magicLinks = try await MagicLink.query(on: req.db)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks))
            .sort(\.$createdAt, .descending)
            .offset(offset)
            .limit(perPage)
            .all()

        return magicLinks.map { MagicLinkResponse(from: $0, includeToken: false) }
    }

    /// Revokes a magic link
    /// DELETE /api/v1/magic-links/:id
    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        if let raw = req.parameters.get("linkId"), try await req.db.transaction({ db in try await LinkGrantController.revokeLegacy(raw, actorID: userId, on: db) }) { return .noContent }

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
        if magicLink.isRevoked { return .noContent }

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

    /// Compatibility with the token-based native retry queue. Expired/revoked links
    /// remain revocable; token possession alone never authorizes this operation.
    @Sendable
    func revokeByToken(req: Request) async throws -> ReportSyncResponse {
        let userId = try req.requireAuthenticatedUserId()
        if let raw = req.parameters.get("linkId"), try await req.db.transaction({ db in try await LinkGrantController.revokeLegacy(raw, actorID: userId, on: db) }) {
            return ReportSyncResponse(success: true, message: "Link revoked", syncedAt: Date())
        }
        guard let token = req.parameters.get("linkId"),
              let link = try await MagicLink.query(on: req.db).filter(\.$token == token)
                .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks)).first() else {
            throw Abort(.notFound, reason: "Magic link not found")
        }
        if !link.isRevoked {
            link.revokedAt = Date()
            try await link.save(on: req.db)
            try await AuditService.log(eventType: .magicLinkRevoked, resourceType: .magicLink,
                resourceId: link.id, userId: userId, request: req, success: true, on: req.db)
        }
        return ReportSyncResponse(success: true, message: "Link revoked", syncedAt: Date())
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

        try PINSessionService.requireVerified(req, link: magicLink)

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        // Get optional status filter
        let statusFilter = try? req.query.get(String.self, at: "status")

        // Look up synced report data for this magic link
        guard let syncedReport = try await SyncedReport.query(on: req.db)
            .filter(\.$magicLinkToken == magicLink.token)
            .first() else {
            // No synced report yet — return empty response
            return SnagListResponse(
                snags: [],
                totalCount: 0,
                projectId: magicLink.projectId,
                projectName: "Project",
                projectAddress: nil,
                contractorName: "Contractor",
                accessLevel: magicLink.accessLevel,
                openCount: 0,
                inProgressCount: 0,
                completedCount: 0
            )
        }

        // Parse the stored report JSON
        guard let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to read report data")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report: SyncedReportJSON
        do {
            report = try decoder.decode(SyncedReportJSON.self, from: jsonData)
        } catch {
            req.logger.error("Failed to parse synced report JSON: \(error)")
            throw Abort(.internalServerError, reason: "Failed to parse report data")
        }

        // Fetch synced photos for snags in this report (query by snagId so photos
        // appear regardless of which magic link originally synced them)
        let reportSnagIds = (report.snags ?? []).compactMap { $0.id }
        let syncedPhotos = try await SyncedPhoto.query(on: req.db)
            .filter(\.$snagId ~~ reportSnagIds)
            .sort(\.$sortOrder)
            .all()

        var photosBySnagId: [UUID: [SnagPhotoDTO]] = [:]
        for photo in syncedPhotos {
            let url = "\(StorageService.publicBaseURL)\(photo.filePath)"
            let dto = SnagPhotoDTO(id: photo.id!, url: url, thumbnailUrl: url, isBefore: photo.label == "before")
            photosBySnagId[photo.snagId, default: []].append(dto)
        }

        // Build SnagDTOs from the report JSON (supports both flat and nested fields)
        let projectName = report.resolvedProjectName ?? "Project"
        let contractorName = report.resolvedContractorName ?? "Contractor"
        let projectAddress = report.resolvedProjectAddress

        var snags: [SnagDTO] = (report.snags ?? []).map { snag in
            let snagId = snag.id ?? UUID()
            let photos = photosBySnagId[snagId] ?? snag.photos?.map { p in
                SnagPhotoDTO(id: p.id ?? UUID(), url: p.url ?? "", thumbnailUrl: p.thumbnailUrl ?? p.url, isBefore: true)
            } ?? []

            return SnagDTO(
                id: snagId,
                title: snag.title ?? "Untitled",
                description: snag.description,
                status: snag.status ?? "open",
                priority: snag.priority ?? "medium",
                photos: photos,
                location: snag.location,
                floorPlanName: snag.floorPlanName,
                floorPlanId: snag.floorPlanId,
                floorPlanImageURL: snag.floorPlanImageURL,
                pinX: snag.pinX,
                pinY: snag.pinY,
                dueDate: snag.dueDate,
                assignedTo: snag.assignedTo ?? contractorName,
                createdAt: snag.createdAt,
                createdByName: snag.createdByName ?? report.createdByName,
                projectId: magicLink.projectId
            )
        }

        // Calculate status counts before filtering
        let openCount = snags.filter { SnagStatus.needsWork($0.status) }.count
        let inProgressCount = snags.filter { SnagStatus.isInProgressOrReview($0.status) }.count
        let completedCount = snags.filter { SnagStatus.isApproved($0.status) }.count

        // Filter by status if provided
        if let status = statusFilter {
            snags = snags.filter { $0.status == status }
        }

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

        try PINSessionService.requireVerified(req, link: magicLink)

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        // Fetch real snag data from synced report
        guard let syncedReport = try await SyncedReport.query(on: req.db)
            .filter(\.$magicLinkToken == magicLink.token)
            .first(),
            let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) else {
            throw Abort(.notFound, reason: "Report data not yet synced. Please sync from the app first.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report: SyncedReportJSON
        do {
            report = try decoder.decode(SyncedReportJSON.self, from: jsonData)
        } catch {
            req.logger.error("Failed to parse synced report JSON for PDF: \(error)")
            throw Abort(.internalServerError, reason: "Failed to parse report data")
        }

        let contractorName = report.resolvedContractorName ?? "Contractor"
        let projectName = report.resolvedProjectName ?? "Project"
        let projectAddress = report.resolvedProjectAddress ?? ""

        // Build snag list for PDF from real data
        let snags: [(title: String, description: String?, status: String, priority: String, location: String?, dueDate: String?)] = (report.snags ?? []).map { snag in
            (
                title: snag.title ?? "Untitled",
                description: snag.description,
                status: snag.status ?? "open",
                priority: snag.priority ?? "medium",
                location: snag.location,
                dueDate: snag.dueDate
            )
        }

        // Generate simple HTML-based PDF content
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let generatedDate = dateFormatter.string(from: Date())

        var snagRows = ""
        for (index, snag) in snags.enumerated() {
            let statusColor = SnagStatus.isApproved(snag.status) ? "#16a34a" : (SnagStatus.needsWork(snag.status) ? "#dc2626" : "#9a6700")
            let priorityColor = snag.priority == "critical" ? "#dc2626" : (snag.priority == "high" ? "#ea580c" : (snag.priority == "medium" ? "#2563eb" : "#6b7280"))

            snagRows += """
            <tr style="border-bottom: 1px solid #e5e7eb;">
                <td style="padding: 12px 8px; font-weight: 500;">\(index + 1)</td>
                <td style="padding: 12px 8px;">
                    <div style="font-weight: 600; color: #111827;">\(snag.title.htmlEscaped)</div>
                    \(snag.description.map { "<div style=\"font-size: 12px; color: #6b7280; margin-top: 4px;\">\($0.htmlEscaped)</div>" } ?? "")
                </td>
                <td style="padding: 12px 8px;">\((snag.location ?? "-").htmlEscaped)</td>
                <td style="padding: 12px 8px;">
                    <span style="display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; background: \(statusColor)20; color: \(statusColor);">\(SnagStatus.reportTitle(snag.status).htmlEscaped)</span>
                </td>
                <td style="padding: 12px 8px;">
                    <span style="display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; background: \(priorityColor)20; color: \(priorityColor);">\(snag.priority.uppercased())</span>
                </td>
                <td style="padding: 12px 8px; font-size: 12px;">\((snag.dueDate ?? "-").htmlEscaped)</td>
            </tr>
            """
        }

        let openCount = snags.filter { SnagStatus.needsWork($0.status) }.count
        let inProgressCount = snags.filter { SnagStatus.isInProgressOrReview($0.status) }.count
        let completedCount = snags.filter { SnagStatus.isApproved($0.status) }.count

        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Snag Report - \(projectName.htmlEscaped)</title>
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
                <h2>\(projectName.htmlEscaped)</h2>
                <p>\(projectAddress.htmlEscaped)</p>
                <p style="margin-top: 8px;">Assigned to: <strong>\(contractorName.htmlEscaped)</strong></p>
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
        let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.dev"
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

    // MARK: - iOS Sync

    /// Syncs a locally-created magic link from the iOS app
    /// POST /api/v1/magic-links/sync
    @Sendable
    func syncFromiOS(req: Request) async throws -> MagicLinkSyncResponse {
        let userId = try req.requireAuthenticatedUserId()
        let syncRequest = try req.content.decode(SyncMagicLinkRequest.self)
        try await LegacyProjectAccess.requireAvailable(projectID: syncRequest.projectId, ownerID: userId, on: req.db)
        guard let accessLevel = AccessLevel(rawValue: syncRequest.accessLevel) else {
            throw Abort(.badRequest, reason: "Invalid access level")
        }
        let importedHash: String?
        if let hash = syncRequest.pinHash, let salt = syncRequest.pinSalt, syncRequest.hasPIN {
            importedHash = try PINVerificationService.importIOSHash(hash, salt: salt)
        } else if syncRequest.pinHash != nil || syncRequest.pinSalt != nil {
            throw Abort(.badRequest, reason: "Incomplete PIN protection data")
        } else { importedHash = nil }

        let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.dev"

        // Check if a magic link with this token already exists (upsert)
        if let existing = try await MagicLink.query(on: req.db)
            .filter(\.$token == syncRequest.token)
            .first() {
            guard existing.createdById == userId else { throw Abort(.notFound, reason: "Magic link not found") }
            guard !existing.isRevoked else { throw Abort(.gone, reason: "This link has been revoked. Create a new link to share again.") }
            guard existing.projectId == syncRequest.projectId else { throw Abort(.conflict, reason: "A shared link cannot be moved to another project") }
            guard !existing.requiresPIN || syncRequest.hasPIN else {
                throw Abort(.conflict, reason: "PIN protection cannot be removed by synchronization")
            }
            if syncRequest.hasPIN && !existing.requiresPIN {
                guard let importedHash else {
                    throw Abort(.badRequest, reason: "Update the app to publish this PIN-protected link safely")
                }
                existing.pinHash = importedHash
                existing.pinSalt = syncRequest.pinSalt
            }
            // Never replace an existing verifier: it may already have been upgraded to bcrypt.
            // Update existing fields
            existing.accessLevel = syncRequest.accessLevel
            existing.expiresAt = syncRequest.expiresAt
            existing.snagIds = syncRequest.snagIds
            existing.projectId = syncRequest.projectId
            existing.contractorId = syncRequest.contractorId
            try await existing.save(on: req.db)

            let slugOrToken = existing.slug ?? existing.token
            return MagicLinkSyncResponse(
                success: true,
                token: existing.token,
                shortUrl: "\(baseURL)/m/\(slugOrToken)",
                pinProtectionVerified: !syncRequest.hasPIN || existing.requiresPIN
            )
        }

        // Create new magic link with iOS-provided token
        let slug = try await generateUniqueSlug(contractorName: syncRequest.contractorName, on: req.db)
        guard !syncRequest.hasPIN || importedHash != nil else {
            throw Abort(.badRequest, reason: "Update the app to publish this PIN-protected link safely")
        }

        let magicLink = MagicLink(
            token: syncRequest.token,
            accessLevel: accessLevel,
            pinHash: importedHash,
            pinSalt: syncRequest.hasPIN ? syncRequest.pinSalt : nil,
            expiresAt: syncRequest.expiresAt,
            snagIds: syncRequest.snagIds,
            projectId: syncRequest.projectId,
            contractorId: syncRequest.contractorId,
            createdById: userId,
            slug: slug
        )

        try await magicLink.save(on: req.db)

        return MagicLinkSyncResponse(
            success: true,
            token: magicLink.token,
            shortUrl: "\(baseURL)/m/\(slug)",
            pinProtectionVerified: !syncRequest.hasPIN || magicLink.requiresPIN
        )
    }

    // MARK: - Report Data Sync

    /// Receives project/snag/drawing data from the iOS app for web viewer display
    /// POST /api/v1/magic-links/:token/report
    @Sendable
    func syncReportData(req: Request) async throws -> ReportSyncResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("linkId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        // Verify magic link exists and belongs to this user
        guard let magicLink = try await MagicLink.query(on: req.db)
            .filter(\.$token == token)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks))
            .first() else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Store the raw JSON body as a string
        guard let bodyData = req.body.data,
              let jsonString = bodyData.getString(at: 0, length: bodyData.readableBytes) else {
            throw Abort(.badRequest, reason: "Invalid request body")
        }

        guard !magicLink.isRevoked else { throw Abort(.gone, reason: "This link has been revoked") }
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(magicLink.projectId, on: db)
            let filteredJSON = try await SnagDeletionService.visibleReportJSON(jsonString, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: db)

            // Upsert: update if exists, create if not
            if let existing = try await SyncedReport.query(on: db)
                .filter(\.$magicLinkToken == magicLink.token)
                .first() {
                existing.reportJSON = filteredJSON
                try await existing.save(on: db)
            } else {
                let report = SyncedReport(
                    magicLinkToken: magicLink.token,
                    reportJSON: filteredJSON
                )
                try await report.save(on: db)
            }

            // Extract snag IDs from the report and update magic link if snagIds is empty
            if magicLink.snagIds.isEmpty,
               let jsonData = filteredJSON.data(using: .utf8),
               let report = try? JSONDecoder().decode(SyncedReportJSON.self, from: jsonData),
               let snags = report.snags {
                let snagIds = snags.compactMap { $0.id }
                if !snagIds.isEmpty {
                    magicLink.snagIds = snagIds
                    try await magicLink.save(on: db)
                    req.logger.info("Updated magic link snagIds with \(snagIds.count) IDs from synced report")
                }
            }

        }

        req.logger.info("Report data synced")

        return ReportSyncResponse(
            success: true,
            message: "Report data synced",
            syncedAt: Date()
        )
    }

    // MARK: - Photo Sync

    /// Receives a photo file from the iOS app for web viewer display
    /// POST /api/v1/magic-links/:token/photos
    @Sendable
    func syncPhoto(req: Request) async throws -> PhotoSyncResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("linkId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        // Verify magic link exists and belongs to this user
        guard let magicLink = try await MagicLink.query(on: req.db)
            .filter(\.$token == token)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks))
            .first() else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Parse multipart form data
        struct PhotoUploadPayload: Content {
            var metadata: String
            var image: File
        }

        let upload = try req.content.decode(PhotoUploadPayload.self)

        // Parse the metadata JSON
        struct PhotoMetadata: Codable {
            let id: UUID
            let snagId: UUID
            let label: String
            let capturedAt: Date?
            let hasAnnotations: Bool?
            let sortOrder: Int
        }

        let photoDecoder = JSONDecoder()
        photoDecoder.dateDecodingStrategy = .iso8601
        guard let metadataData = upload.metadata.data(using: .utf8),
              let metadata = try? photoDecoder.decode(PhotoMetadata.self, from: metadataData) else {
            throw Abort(.badRequest, reason: "Invalid photo metadata")
        }

        try await SnagDeletionService.requireActive(metadata.snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)

        // Upload file via StorageService
        let fileExtension = "jpg"
        let filename = "\(metadata.id.uuidString).\(fileExtension)"
        let storageKey = "uploads/synced-photos/\(filename)"

        let linkID = try magicLink.requireID()
        let authorizeWrite: @Sendable (Database) async throws -> ObjectWriteIntentService.Scope = { db in
            let current = try await JWTAuthMiddleware.authenticate(req, on: db)
            guard current.userId == userId,
                  let link = try await MagicLink.query(on: db).filter(\.$id == linkID).filter(\.$createdById == userId)
                    .filter(LegacyProjectAccess.personalRecords(.magicLinks)).first() else { throw Abort(.notFound) }
            try await SnagDeletionService.requireActive(metadata.snagId, ownerId: link.createdById, projectId: link.projectId, on: db)
            let project = try await Project.find(link.projectId, on: db)
            if let workspaceID = project?.workspaceId { try await WorkspaceAccessService.lock(workspaceID, on: db) }
            if let existing = try await SyncedPhoto.find(metadata.id, on: db) {
                guard try await MagicLink.query(on: db).filter(\.$token == existing.magicLinkToken).filter(\.$createdById == userId)
                    .filter(LegacyProjectAccess.personalRecords(.magicLinks)).first() != nil else { throw Abort(.forbidden) }
            }
            return .init(userID: userId, workspaceID: project?.workspaceId, projectID: link.projectId, magicLinkID: linkID)
        }
        let source = ObjectWriteIntentService.Source(kind: "legacy_link", id: linkID)
        let originalData = Data(buffer: upload.image.data)
        try await ObjectWriteIntentService.write(.init(storageKind: "legacy_photo", key: storageKey, data: originalData, contentType: "image/jpeg"), source: source, on: req.db, authorize: authorizeWrite) {
            try await StorageService.upload(data: upload.image.data, key: storageKey, contentType: "image/jpeg", app: req.application)
        }

        // Generate thumbnail
        var imageBuffer = upload.image.data
        let imageRawData = imageBuffer.readData(length: imageBuffer.readableBytes) ?? Data()
        let thumbFilename = "thumb_\(filename)"
        let thumbStorageKey = "uploads/synced-photos/\(thumbFilename)"
        let thumbGenerated = await ThumbnailService.generateAndUpload(
            originalData: imageRawData,
            thumbnailKey: thumbStorageKey,
            app: req.application,
            logger: req.logger,
            upload: { data in
                try await ObjectWriteIntentService.write(.init(storageKind: "legacy_photo", key: thumbStorageKey, data: data, contentType: "image/jpeg"), source: source, on: req.db, authorize: authorizeWrite) {
                    try await StorageService.upload(data: ByteBuffer(data: data), key: thumbStorageKey, contentType: "image/jpeg", app: req.application)
                }
            }
        )
        let thumbnailFilePath = thumbGenerated ? "/uploads/synced-photos/\(thumbFilename)" : nil

        // Upsert photo record
        if let existing = try await SyncedPhoto.query(on: req.db)
            .filter(\.$id == metadata.id)
            .first() {
            existing.filePath = "/uploads/synced-photos/\(filename)"
            existing.label = metadata.label
            existing.sortOrder = metadata.sortOrder
            existing.magicLinkToken = magicLink.token
            existing.thumbnailFilePath = thumbnailFilePath
            try await existing.save(on: req.db)
        } else {
            let syncedPhoto = SyncedPhoto(
                id: metadata.id,
                magicLinkToken: magicLink.token,
                snagId: metadata.snagId,
                label: metadata.label,
                filePath: "/uploads/synced-photos/\(filename)",
                sortOrder: metadata.sortOrder,
                thumbnailFilePath: thumbnailFilePath
            )
            try await syncedPhoto.save(on: req.db)
        }

        req.logger.info("Photo synced: \(metadata.id) for magic link: \(token.prefix(8))...")

        return PhotoSyncResponse(
            success: true,
            photoId: metadata.id,
            url: "\(StorageService.publicBaseURL)/uploads/synced-photos/\(filename)"
        )
    }

    // MARK: - Drawing Sync

    /// Receives a drawing file from the iOS app for web viewer display
    /// POST /api/v1/magic-links/:token/drawings
    @Sendable
    func syncDrawing(req: Request) async throws -> DrawingSyncResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let token = req.parameters.get("linkId") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        // Verify magic link exists and belongs to this user
        guard let magicLink = try await MagicLink.query(on: req.db)
            .filter(\.$token == token)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks))
            .first() else {
            throw Abort(.notFound, reason: "Magic link not found")
        }

        // Parse multipart form data
        struct DrawingUploadPayload: Content {
            var drawingId: String
            var file: File
        }

        let upload = try req.content.decode(DrawingUploadPayload.self)

        guard let drawingId = UUID(uuidString: upload.drawingId) else {
            throw Abort(.badRequest, reason: "Invalid drawing ID")
        }

        // Determine file extension and upload
        let originalFilename = upload.file.filename
        let ext = originalFilename.split(separator: ".").last.map(String.init)?.lowercased() ?? "pdf"
        let safeExt = ["pdf", "png", "jpg", "jpeg"].contains(ext) ? ext : "pdf"
        let filename = "\(drawingId.uuidString).\(safeExt)"
        let storageKey = "uploads/synced-drawings/\(filename)"

        let contentType: String
        switch safeExt {
        case "pdf": contentType = "application/pdf"
        case "png": contentType = "image/png"
        default: contentType = "image/jpeg"
        }

        let linkID = try magicLink.requireID()
        let authorizeWrite: @Sendable (Database) async throws -> ObjectWriteIntentService.Scope = { db in
            let current = try await JWTAuthMiddleware.authenticate(req, on: db)
            guard current.userId == userId,
                  let link = try await MagicLink.query(on: db).filter(\.$id == linkID).filter(\.$createdById == userId)
                    .filter(LegacyProjectAccess.personalRecords(.magicLinks)).first() else { throw Abort(.notFound) }
            let project = try await Project.find(link.projectId, on: db)
            if let workspaceID = project?.workspaceId { try await WorkspaceAccessService.lock(workspaceID, on: db) }
            return .init(userID: userId, workspaceID: project?.workspaceId, projectID: link.projectId, magicLinkID: linkID)
        }
        try await ObjectWriteIntentService.write(.init(storageKind: "legacy_drawing", key: storageKey, data: Data(buffer: upload.file.data), contentType: contentType),
            source: .init(kind: "legacy_link", id: linkID), on: req.db, authorize: authorizeWrite) {
            try await StorageService.upload(data: upload.file.data, key: storageKey, contentType: contentType, app: req.application)
        }

        // Upsert drawing record
        if let existing = try await SyncedDrawing.query(on: req.db)
            .filter(\.$drawingId == drawingId)
            .filter(\.$magicLinkToken == magicLink.token)
            .first() {
            existing.filePath = "/uploads/synced-drawings/\(filename)"
            existing.fileName = originalFilename
            try await existing.save(on: req.db)
        } else {
            let syncedDrawing = SyncedDrawing(
                id: UUID(),
                magicLinkToken: magicLink.token,
                drawingId: drawingId,
                filePath: "/uploads/synced-drawings/\(filename)",
                fileName: originalFilename
            )
            try await syncedDrawing.save(on: req.db)
        }

        req.logger.info("Drawing synced: \(drawingId) for magic link: \(token.prefix(8))...")

        return DrawingSyncResponse(
            success: true,
            drawingId: drawingId,
            url: "\(StorageService.publicBaseURL)/uploads/synced-drawings/\(filename)"
        )
    }
}

// MARK: - Sync Response DTOs

struct ReportSyncResponse: Content {
    let success: Bool
    let message: String?
    let syncedAt: Date?
}

struct PhotoSyncResponse: Content {
    let success: Bool
    let photoId: UUID
    let url: String?
}

struct DrawingSyncResponse: Content {
    let success: Bool
    let drawingId: UUID
    let url: String?
}

// MARK: - Synced Report JSON Parsing

/// Top-level structure of the report JSON stored in SyncedReport.reportJSON
/// Supports both flat fields (projectName, projectAddress) and nested project object
struct SyncedReportJSON: Decodable {
    let project: SyncedProjectJSON?
    let projectName: String?
    let projectAddress: String?
    let contractorName: String?
    let createdByName: String?
    let snags: [SyncedSnagJSON]?

    /// Resolves project name from flat field or nested project object
    var resolvedProjectName: String? { projectName ?? project?.name }
    /// Resolves project address from flat field or nested project object
    var resolvedProjectAddress: String? { projectAddress ?? project?.address }
    /// Resolves contractor name from flat field or snags
    var resolvedContractorName: String? { contractorName ?? snags?.first?.contractorName }
}

/// Nested project object sent by iOS within ReportSyncData
struct SyncedProjectJSON: Decodable {
    let name: String?
    let address: String?
    let clientName: String?
}

/// A snag entry within the synced report JSON
struct SyncedSnagJSON: Decodable {
    let id: UUID?
    let title: String?
    let reference: String?
    let description: String?
    let status: String?
    let priority: String?
    let location: String?
    let floorPlanName: String?
    let floorPlanId: UUID?
    let floorPlanImageURL: String?
    let pinX: Double?
    let pinY: Double?
    let dueDate: String?
    let assignedTo: String?
    let contractorName: String?
    let createdAt: String?
    let createdByName: String?
    let photos: [SyncedSnagPhotoJSON]?
}

/// A photo reference within a synced snag
struct SyncedSnagPhotoJSON: Decodable {
    let id: UUID?
    let url: String?
    let thumbnailUrl: String?
}
