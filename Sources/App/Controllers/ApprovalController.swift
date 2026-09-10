import Vapor
import Fluent

/// B5: PM approval workflow — the queue of submitted snags, plus approve / send-back actions.
/// The snag-status source of truth is the `snags` table (synced from iOS, per B3). Additive to
/// the existing implicit Completion-based flow, which continues to work for legacy clients.
struct ApprovalController: RouteCollection {

    /// Snag statuses that sit in the PM's approval queue.
    static let pendingStatuses = ["submitted", "awaitingApproval"]

    func boot(routes: RoutesBuilder) throws {
        let approvals = routes.grouped("api", "v1", "approvals")
            .grouped(JWTAuthMiddleware())

        approvals.get("pending", use: pending)
        approvals.post(":snagId", "approve", use: approve)
        approvals.post(":snagId", "send-back", use: sendBack)
    }

    // MARK: - GET /api/v1/approvals/pending

    @Sendable
    func pending(req: Request) async throws -> PendingApprovalsResponse {
        let userId = try req.requireAuthenticatedUserId()

        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        let perPage = min((try? req.query.get(Int.self, at: "perPage")) ?? 20, 100)
        let offset = (page - 1) * perPage

        let base = Snag.query(on: req.db)
            .filter(\.$ownerId == userId).filter(LegacyProjectAccess.personalRecords(.snags))
            .filter(\.$status ~~ Self.pendingStatuses)

        let totalCount = try await base.count()

        // Oldest first by default (longest-waiting submissions surface at the top).
        let snags = try await Snag.query(on: req.db)
            .filter(\.$ownerId == userId).filter(LegacyProjectAccess.personalRecords(.snags))
            .filter(\.$status ~~ Self.pendingStatuses)
            .sort(\.$updatedAt, .ascending)
            .offset(offset)
            .limit(perPage)
            .all()

        // Batch-load before/after photos for the page's snags.
        let snagIds = snags.compactMap { $0.id }
        var beforeBySnag: [UUID: [String]] = [:]
        var afterBySnag: [UUID: [String]] = [:]
        if !snagIds.isEmpty {
            let photos = try await SyncedPhoto.query(on: req.db)
                .filter(\.$snagId ~~ snagIds)
                .sort(\.$sortOrder)
                .all()
            let storageBase = StorageService.publicBaseURL
            for photo in photos {
                let url = "\(storageBase)\(photo.filePath)"
                if photo.label == "after" {
                    afterBySnag[photo.snagId, default: []].append(url)
                } else {
                    beforeBySnag[photo.snagId, default: []].append(url)
                }
            }
        }

        let approvals = snags.map { snag -> SnagApprovalDTO in
            let sid = snag.id!
            return SnagApprovalDTO(
                snagId: sid,
                projectId: snag.projectId,
                contractorId: snag.contractorId,
                title: snag.title,
                reference: snag.reference,
                status: snag.status,
                submittedAt: snag.updatedAt,
                beforePhotoUrls: beforeBySnag[sid] ?? [],
                afterPhotoUrls: afterBySnag[sid] ?? []
            )
        }

        return PendingApprovalsResponse(approvals: approvals, totalCount: totalCount, page: page, perPage: perPage)
    }

    // MARK: - POST /api/v1/approvals/:snagId/approve

    @Sendable
    func approve(req: Request) async throws -> SnagResponse {
        let userId = try req.requireAuthenticatedUserId()
        let snag = try await ownedSnag(req: req, userId: userId)

        snag.status = "approved"
        snag.closedAt = Date()
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(snag.projectId, on: db)
            guard let current = try await Snag.find(snag.id!, on: db),
                  ["submitted", "awaitingApproval"].contains(SnagStatus.normalize(current.status)) else {
                throw Abort(.conflict, reason: "This snag is no longer awaiting review. Refresh before continuing.")
            }
            try await SnagWorkflowService.setStatus("approved", snagId: snag.id!, ownerId: userId, projectId: snag.projectId, on: db)
            let links = try await MagicLink.query(on: db).filter(\.$createdById == userId)
                .filter(\.$projectId == snag.projectId).all().compactMap(\.id)
            if !links.isEmpty {
                for completion in try await Completion.query(on: db).filter(\.$snagId == snag.id!)
                    .filter(\.$magicLinkId ~~ links).filter(\.$status == .pending).all() {
                    completion.approve(by: userId, userName: "Project Manager")
                    try await completion.save(on: db)
                }
            }
        }

        notifyContractor(snag: snag, approved: true, note: nil, req: req)

        return SnagResponse(from: snag)
    }

    // MARK: - POST /api/v1/approvals/:snagId/send-back

    @Sendable
    func sendBack(req: Request) async throws -> SnagResponse {
        let userId = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(SendBackRequest.self)
        try body.validate()

        let snag = try await ownedSnag(req: req, userId: userId)

        snag.status = "sentBack"
        try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(snag.projectId, on: db)
            guard let current = try await Snag.find(snag.id!, on: db),
                  ["submitted", "awaitingApproval"].contains(SnagStatus.normalize(current.status)) else {
                throw Abort(.conflict, reason: "This snag is no longer awaiting review. Refresh before continuing.")
            }
            try await SnagWorkflowService.setStatus("sentBack", snagId: snag.id!, ownerId: userId, projectId: snag.projectId, on: db)
            let links = try await MagicLink.query(on: db).filter(\.$createdById == userId)
                .filter(\.$projectId == snag.projectId).all().compactMap(\.id)
            if !links.isEmpty {
                for completion in try await Completion.query(on: db).filter(\.$snagId == snag.id!)
                    .filter(\.$magicLinkId ~~ links).filter(\.$status == .pending).all() {
                    completion.reject(by: userId, userName: "Project Manager", reason: body.reason.rawValue)
                    try await completion.save(on: db)
                }
            }
            let record = SnagSendBack(snagId: snag.id!, reason: body.reason, note: body.note, sentBackBy: userId)
            try await record.save(on: db)
        }


        notifyContractor(snag: snag, approved: false, note: body.note, req: req)

        return SnagResponse(from: snag)
    }

    // MARK: - Helpers

    /// Finds a snag owned by the authenticated user, or throws 404.
    private func ownedSnag(req: Request, userId: UUID) async throws -> Snag {
        guard let idString = req.parameters.get("snagId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid snag ID")
        }
        guard let snag = try await Snag.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerId == userId).filter(LegacyProjectAccess.personalRecords(.snags))
            .first() else {
            throw Abort(.notFound, reason: "Snag not found")
        }
        return snag
    }

    /// Best-effort contractor notification (email if we have one; no-ops otherwise). Push/SMS to
    /// contractors is not yet wired — contractors don't necessarily have the app or a device token.
    private func notifyContractor(snag: Snag, approved: Bool, note: String?, req: Request) {
        let db = req.db
        let client = req.client
        let logger = req.logger
        let contractorId = snag.contractorId
        let snagTitle = snag.title

        Task {
            guard let contractorId = contractorId,
                  let contractor = try? await Contractor.find(contractorId, on: db),
                  let email = contractor.email, !email.isEmpty else {
                logger.info("Approval notification skipped: no contractor email for snag \(snag.id?.uuidString ?? "?")")
                return
            }
            do {
                try await NotificationService.sendApprovalDecisionEmail(
                    to: email,
                    contractorName: contractor.contactName ?? contractor.companyName,
                    snagTitle: snagTitle,
                    approved: approved,
                    note: note,
                    client: client
                )
            } catch {
                logger.error("Failed to send approval decision email: \(error)")
            }
        }
    }
}
