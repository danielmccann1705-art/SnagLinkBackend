import Fluent
import Vapor

// MARK: - Completion Controller
struct CompletionController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let completions = routes.grouped("api", "v1")

        // Public routes (magic link authenticated)
        let magicLinks = completions.grouped("magic-links")
        magicLinks.post(":linkId", "snags", ":snagId", "complete", use: submitCompletion)
        magicLinks.patch(":linkId", "snags", ":snagId", "status", use: updateSnagStatus)

        // Authenticated routes
        let authenticated = completions.grouped(JWTAuthMiddleware())
        let completionsGroup = authenticated.grouped("completions")

        completionsGroup.get("pending", use: getPendingCompletions)
        completionsGroup.get(":completionId", use: getCompletion)
        completionsGroup.post(":completionId", "approve", use: approveCompletion)
        completionsGroup.post(":completionId", "reject", use: rejectCompletion)

        // Snag-scoped routes
        authenticated.grouped("snags").get(":snagId", "completions", use: getCompletionsForSnag)
    }

    // MARK: - Submit Completion (Magic Link)

    /// POST /api/v1/magic-links/:linkId/snags/:snagId/complete
    /// Allows a contractor to submit a completion via magic link
    @Sendable
    func submitCompletion(req: Request) async throws -> CompletionActionResponse {
        // Get token and snag ID from path
        guard let token = req.parameters.get("linkId"),
              let snagIdString = req.parameters.get("snagId"),
              let snagId = UUID(uuidString: snagIdString) else {
            throw Abort(.badRequest, reason: "Invalid token or snag ID")
        }

        req.logger.info("Completion submitted for snag: \(snagId)")

        // Validate magic link
        let magicLink = try await TokenValidationService.validateMagicLink(token: token, on: req.db)
        try PINSessionService.requireVerified(req, link: magicLink)

        // B2: preview links are read-only — never write contractor-side data.
        guard !magicLink.previewMode else {
            throw Abort(.forbidden, reason: "This is a preview link — submissions are disabled.")
        }

        try await SnagDeletionService.requireActive(snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)

        // Verify snag ID is in the magic link's allowed snags
        guard magicLink.snagIds.contains(snagId) else {
            throw Abort(.forbidden, reason: "This magic link does not have access to this snag")
        }

        // Verify magic link has update or full access
        guard magicLink.accessLevel != AccessLevel.view.rawValue else {
            throw Abort(.forbidden, reason: "This magic link does not allow submissions")
        }

        // Validate request
        try SubmitCompletionRequest.validate(content: req)
        let request = try req.content.decode(SubmitCompletionRequest.self)

        // Create completion
        let completion = Completion(
            snagId: snagId,
            magicLinkId: magicLink.id!,
            contractorName: request.contractorName,
            notes: request.notes
        )

        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(magicLink.projectId, on: db)
            let status = try await SnagWorkflowService.currentStatus(snagId: snagId, link: magicLink, on: db)
            guard !["approved", "submitted", "awaitingApproval", "complete", "completed"].contains(status) else {
                throw Abort(.conflict, reason: "This snag is already submitted or approved. Refresh the report before continuing.")
            }
            let ownedLinkIds = try await MagicLink.query(on: db).filter(\.$createdById == magicLink.createdById)
                .filter(\.$projectId == magicLink.projectId).all().compactMap(\.id)
            guard try await Completion.query(on: db).filter(\.$snagId == snagId)
                .filter(\.$magicLinkId ~~ ownedLinkIds).filter(\.$status == .pending).count() == 0 else {
                throw Abort(.conflict, reason: "A pending completion already exists for this snag")
            }
            try await completion.save(on: db)

            // Save photos if provided
            if let photoUrls = request.photoUrls {
                for url in photoUrls {
                    let photo = CompletionPhoto(
                        completionId: completion.id!,
                        url: url
                    )
                    try await photo.save(on: db)
                }
            }

            try await SnagWorkflowService.setStatus("submitted", snagId: snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: db)
        }

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        // Log audit event
        try await AuditService.log(
            eventType: .magicLinkValidated,
            resourceType: .magicLink,
            resourceId: magicLink.id!,
            userId: nil,
            request: req,
            success: true,
            details: "Completion submitted for snag \(snagId)",
            on: req.db
        )

        // Keep best-effort notification attempts within the request lifetime.
        // An untracked Task could access req.db after application shutdown.
        // Failures are logged after the completion transaction has committed.
        // Resolve snag title from synced report data
        var snagTitle = "Snag #\(snagId.uuidString.prefix(8).uppercased())"
        do {
            if let syncedReport = try await SyncedReport.query(on: req.db)
                .filter(\.$magicLinkToken == token)
                .first(),
               let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let report = try? decoder.decode(SyncedReportJSON.self, from: jsonData),
                   let matchingSnag = report.snags?.first(where: { $0.id == snagId }) {
                    let ref = matchingSnag.reference
                    let title = matchingSnag.title
                    if let ref = ref, !ref.isEmpty, let title = title, !title.isEmpty {
                        snagTitle = "\(ref) — \(title)"
                    } else if let ref = ref, !ref.isEmpty {
                        snagTitle = ref
                    } else if let title = title, !title.isEmpty {
                        snagTitle = title
                    }
                }
            }
        } catch {
            req.logger.warning("Failed to resolve snag title from report: \(error)")
        }

        do {
            if let pmEmail = Environment.get("DEFAULT_PM_EMAIL") {
                try await NotificationService.sendCompletionEmail(
                    to: pmEmail,
                    pmName: "Project Manager",
                    contractorName: request.contractorName,
                    snagTitle: snagTitle,
                    projectName: "Project",
                    completionNotes: request.notes,
                    hasPhotos: request.photoUrls?.isEmpty == false,
                    reviewURL: nil,
                    client: req.client
                )
            }
        } catch {
            req.logger.error("Failed to send completion notification email: \(error)")
        }

        // Push notification
        do {
            req.logger.info("Looking up device tokens for magic link creator")
            try await APNsService.sendCompletionNotification(
                toUserId: magicLink.createdById,
                contractorName: request.contractorName,
                snagTitle: snagTitle,
                completionId: completion.id!,
                snagId: snagId,
                client: req.client,
                logger: req.logger,
                db: req.db
            )
            req.logger.info("Push notification sent successfully")
        } catch {
            req.logger.error("APNs send failed: \(error)")
        }

        return .submitted(id: completion.id!)
    }

    // MARK: - Get Pending Completions

    /// GET /api/v1/completions/pending
    /// Lists all pending completions for the authenticated user's projects
    @Sendable
    func getPendingCompletions(req: Request) async throws -> PendingCompletionsResponse {
        let userId = try req.requireAuthenticatedUserId()

        // Get magic links created by this user
        let userMagicLinks = try await MagicLink.query(on: req.db)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks))
            .all()

        let magicLinkIds = userMagicLinks.compactMap { $0.id }

        guard !magicLinkIds.isEmpty else {
            return PendingCompletionsResponse(completions: [], totalCount: 0)
        }

        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        let perPage = min((try? req.query.get(Int.self, at: "perPage")) ?? 50, 100)
        let offset = (page - 1) * perPage

        let query = Completion.query(on: req.db)
            .filter(\.$magicLinkId ~~ magicLinkIds)
            .filter(\.$status == .pending)
        for receipt in try await SnagDeletionService.receipts(ownerId: userId, on: req.db) {
            let affectedLinks = userMagicLinks.filter { $0.projectId == receipt.projectId }.compactMap(\.id)
            if !affectedLinks.isEmpty {
                query.group(.or) {
                    $0.filter(\.$snagId != receipt.snagId).filter(\.$magicLinkId !~ affectedLinks)
                }
            }
        }
        let totalCount = try await query.count()
        let completions = try await query.with(\.$photos).sort(\.$submittedAt, .descending)
            .offset(offset).limit(perPage).all()

        let summaries = completions.map { PendingCompletionSummary(from: $0) }

        return PendingCompletionsResponse(
            completions: summaries,
            totalCount: totalCount
        )
    }

    // MARK: - Get Single Completion

    /// GET /api/v1/completions/:completionId
    /// Gets a single completion with full details
    @Sendable
    func getCompletion(req: Request) async throws -> CompletionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let completionId = req.parameters.get("completionId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid completion ID")
        }

        // Find completion
        guard let completion = try await Completion.query(on: req.db)
            .filter(\.$id == completionId)
            .with(\.$photos)
            .first() else {
            throw Abort(.notFound, reason: "Completion not found")
        }

        // Verify ownership via magic link
        guard let magicLink = try await MagicLink.find(completion.magicLinkId, on: req.db),
              magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You don't have access to this completion")
        }

        try await SnagDeletionService.requireActive(completion.snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)
        return CompletionResponse(from: completion)
    }

    // MARK: - Approve Completion

    /// POST /api/v1/completions/:completionId/approve
    /// Approves a pending completion
    @Sendable
    func approveCompletion(req: Request) async throws -> CompletionActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let completionId = req.parameters.get("completionId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid completion ID")
        }

        // Find completion
        guard let completion = try await Completion.find(completionId, on: req.db) else {
            throw Abort(.notFound, reason: "Completion not found")
        }

        // Verify ownership via magic link
        guard let magicLink = try await MagicLink.find(completion.magicLinkId, on: req.db),
              magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You don't have access to this completion")
        }

        try await SnagDeletionService.requireActive(completion.snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)
        // Verify pending status
        guard completion.status == .pending else {
            throw Abort(.conflict, reason: "Completion has already been reviewed")
        }

        // Get reviewer name from request or use default
        let request = try? req.content.decode(ApproveCompletionRequest.self)
        let reviewerName = request?.reviewerName ?? "Project Manager"

        // Approve
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(magicLink.projectId, on: db)
            try await SnagWorkflowService.requireScope(snagId: completion.snagId, link: magicLink, on: db)
            guard let current = try await Completion.find(completionId, on: db), current.status == .pending else {
                throw Abort(.conflict, reason: "Completion has already been reviewed")
            }
            current.approve(by: userId, userName: reviewerName)
            try await current.save(on: db)
            try await SnagWorkflowService.setStatus("approved", snagId: current.snagId, ownerId: userId, projectId: magicLink.projectId, on: db)
        }

        // Log audit event
        try await AuditService.log(
            eventType: .magicLinkValidated,
            resourceType: .magicLink,
            resourceId: completion.magicLinkId,
            userId: userId,
            request: req,
            success: true,
            details: "Completion \(completionId) approved",
            on: req.db
        )

        return .approved(id: completionId)
    }

    // MARK: - Reject Completion

    /// POST /api/v1/completions/:completionId/reject
    /// Rejects a pending completion with a reason
    @Sendable
    func rejectCompletion(req: Request) async throws -> CompletionActionResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let completionId = req.parameters.get("completionId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid completion ID")
        }

        // Validate request
        try RejectCompletionRequest.validate(content: req)
        let request = try req.content.decode(RejectCompletionRequest.self)

        // Find completion
        guard let completion = try await Completion.find(completionId, on: req.db) else {
            throw Abort(.notFound, reason: "Completion not found")
        }

        // Verify ownership via magic link
        guard let magicLink = try await MagicLink.find(completion.magicLinkId, on: req.db),
              magicLink.createdById == userId else {
            throw Abort(.forbidden, reason: "You don't have access to this completion")
        }

        try await SnagDeletionService.requireActive(completion.snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)
        // Verify pending status
        guard completion.status == .pending else {
            throw Abort(.conflict, reason: "Completion has already been reviewed")
        }

        // Get reviewer name
        let reviewerName = request.reviewerName ?? "Project Manager"

        // Reject
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(magicLink.projectId, on: db)
            try await SnagWorkflowService.requireScope(snagId: completion.snagId, link: magicLink, on: db)
            guard let current = try await Completion.find(completionId, on: db), current.status == .pending else {
                throw Abort(.conflict, reason: "Completion has already been reviewed")
            }
            current.reject(by: userId, userName: reviewerName, reason: request.reason)
            try await current.save(on: db)
            try await SnagWorkflowService.setStatus("sentBack", snagId: current.snagId, ownerId: userId, projectId: magicLink.projectId, on: db)
        }

        // Log audit event
        try await AuditService.log(
            eventType: .magicLinkValidated,
            resourceType: .magicLink,
            resourceId: completion.magicLinkId,
            userId: userId,
            request: req,
            success: true,
            details: "Completion \(completionId) rejected: \(request.reason)",
            on: req.db
        )

        return .rejected(id: completionId)
    }

    // MARK: - Get Completions for Snag

    /// GET /api/v1/snags/:snagId/completions
    /// Lists all completions for a specific snag (pending, approved, rejected)
    @Sendable
    func getCompletionsForSnag(req: Request) async throws -> SnagCompletionsResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let snagId = req.parameters.get("snagId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid snag ID")
        }

        let ownedLinks = try await MagicLink.query(on: req.db)
            .filter(\.$createdById == userId).filter(LegacyProjectAccess.personalRecords(.magicLinks)).all().filter { $0.snagIds.contains(snagId) }
        guard !ownedLinks.isEmpty else {
            throw Abort(.forbidden, reason: "You don't have access to this snag")
        }
        let deletedProjects = try await SnagDeletion.query(on: req.db)
            .filter(\.$ownerId == userId).filter(\.$snagId == snagId).all().map(\.projectId)
        let activeLinkIds = ownedLinks.filter { !deletedProjects.contains($0.projectId) }.compactMap(\.id)
        guard !activeLinkIds.isEmpty else { throw Abort(.gone, reason: "This snag has been deleted.") }
        let completions = try await Completion.query(on: req.db)
            .filter(\.$snagId == snagId).filter(\.$magicLinkId ~~ activeLinkIds)
            .with(\.$photos).sort(\.$submittedAt, .descending).all()

        let entries = completions.map { completion in
            SnagCompletionEntry(
                id: completion.id!,
                snagId: completion.snagId,
                contractorName: completion.contractorName,
                notes: completion.notes,
                photoUrls: completion.photos.map { $0.url },
                status: completion.status.rawValue,
                createdAt: completion.submittedAt
            )
        }

        return SnagCompletionsResponse(completions: entries)
    }

    // MARK: - Update Snag Status (Magic Link)

    /// PATCH /api/v1/magic-links/:linkId/snags/:snagId/status
    /// Allows a contractor to change a snag's status via magic link (e.g. open → in_progress)
    @Sendable
    func updateSnagStatus(req: Request) async throws -> StatusUpdateResponse {
        guard let token = req.parameters.get("linkId"),
              let snagIdString = req.parameters.get("snagId"),
              let snagId = UUID(uuidString: snagIdString) else {
            throw Abort(.badRequest, reason: "Invalid token or snag ID")
        }

        // Validate magic link
        let magicLink = try await TokenValidationService.validateMagicLink(token: token, on: req.db)
        try PINSessionService.requireVerified(req, link: magicLink)

        // B2: preview links are read-only — never write contractor-side data.
        guard !magicLink.previewMode else {
            throw Abort(.forbidden, reason: "This is a preview link — status updates are disabled.")
        }

        try await SnagDeletionService.requireActive(snagId, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)

        // Verify snag ID is in the magic link's allowed snags
        guard magicLink.snagIds.contains(snagId) else {
            throw Abort(.forbidden, reason: "This magic link does not have access to this snag")
        }

        // Verify magic link has update or full access
        guard magicLink.accessLevel != AccessLevel.view.rawValue else {
            throw Abort(.forbidden, reason: "This magic link does not allow status updates")
        }

        // Decode request
        struct StatusRequest: Content {
            let status: String
        }
        let request = try req.content.decode(StatusRequest.self)

        guard request.status == "in_progress" else {
            throw Abort(.forbidden, reason: "Contractors must submit completion evidence for manager review; only a manager can close a snag.")
        }
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(magicLink.projectId, on: db)
            let status = try await SnagWorkflowService.currentStatus(snagId: snagId, link: magicLink, on: db)
            guard ["open", "sent", "opened", "cold", "overdue", "in_progress"].contains(status) else {
                throw Abort(.conflict, reason: "This snag is awaiting review or has been reviewed. Refresh the report before continuing.")
            }
            try await SnagWorkflowService.setStatus("in_progress", snagId: snagId,
                ownerId: magicLink.createdById, projectId: magicLink.projectId, on: db)
        }

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: false,
            on: req.db
        )

        return StatusUpdateResponse(success: true, snagId: snagId, newStatus: request.status)
    }
}

// MARK: - Status Update DTOs

struct StatusUpdateResponse: Content {
    let success: Bool
    let snagId: UUID
    let newStatus: String
}
