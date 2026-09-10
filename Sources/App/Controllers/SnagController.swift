import Vapor
import Fluent

struct SnagController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let snags = routes.grouped("api", "v1", "snags")
            .grouped(JWTAuthMiddleware())

        snags.get(use: list)
        snags.post(use: create)
        snags.get(":snagId", use: get)
        snags.patch(":snagId", use: update)
        snags.delete(":snagId", use: delete)
        snags.post(":snagId", "deletion", use: deleteEverywhere)
        snags.post("batch", use: batchCreate)
    }

    // MARK: - GET /api/v1/snags
    @Sendable
    func list(req: Request) async throws -> SnagListSyncResponse {
        let userId = try req.requireAuthenticatedUserId()

        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        let perPage = min((try? req.query.get(Int.self, at: "perPage")) ?? 50, 100)
        let projectId = try? req.query.get(UUID.self, at: "projectId")
        let status = try? req.query.get(String.self, at: "status")
        let priority = try? req.query.get(String.self, at: "priority")
        let updatedSince = try? req.query.get(Date.self, at: "updatedSince")

        var query = Snag.query(on: req.db)
            .filter(\.$ownerId == userId).filter(LegacyProjectAccess.personalRecords(.snags))
            .sort(\.$updatedAt, .descending)

        for receipt in try await SnagDeletionService.receipts(ownerId: userId, on: req.db) {
            query = query.group(.or) {
                $0.filter(\.$id != receipt.snagId).filter(\.$projectId != receipt.projectId)
            }
        }
        if let projectId = projectId {
            query = query.filter(\.$projectId == projectId)
        }
        if let status = status {
            query = query.filter(\.$status == status)
        }
        if let priority = priority {
            query = query.filter(\.$priority == priority)
        }
        if let updatedSince = updatedSince {
            query = query.filter(\.$updatedAt > updatedSince)
        }

        let totalCount = try await query.count()

        let offset = (page - 1) * perPage
        let snags = try await query
            .offset(offset)
            .limit(perPage)
            .all()

        return SnagListSyncResponse(
            snags: snags.map { SnagResponse(from: $0) },
            totalCount: totalCount,
            page: page,
            perPage: perPage
        )
    }

    // MARK: - POST /api/v1/snags
    @Sendable
    func create(req: Request) async throws -> SnagResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateSnagRequest.self)
        return try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(createReq.projectId, on: db)
            return try await createRecord(createReq, userId: userId, on: db)
        }
    }

    @Sendable
    func batchCreate(req: Request) async throws -> [SnagResponse] {
        let userId = try req.requireAuthenticatedUserId()
        let requests = try req.content.decode([CreateSnagRequest].self)
        guard !requests.isEmpty, requests.count <= 100 else { throw Abort(.badRequest, reason: "Submit between one and 100 snags") }
        return try await req.db.transaction { db in
            for id in Set(requests.map(\.projectId)).sorted(by: { $0.uuidString < $1.uuidString }) {
                try await SnagWorkflowService.lockProject(id, on: db)
            }
            var responses: [SnagResponse] = []
            for request in requests { responses.append(try await createRecord(request, userId: userId, on: db)) }
            return responses
        }
    }

    private func createRecord(_ createReq: CreateSnagRequest, userId: UUID, on db: Database) async throws -> SnagResponse {
        try createReq.validate()
        try await LegacyProjectAccess.requireAvailable(projectID: createReq.projectId, ownerID: userId, on: db)
        guard let project = try await Project.find(createReq.projectId, on: db), project.ownerId == userId else { throw Abort(.notFound, reason: "Project unavailable") }
        if let id = createReq.id {
            try await SnagDeletionService.requireActive(id, ownerId: userId, projectId: createReq.projectId, on: db)
            guard try await Snag.find(id, on: db) == nil else { throw Abort(.conflict, reason: "This snag already exists. Refresh before retrying") }
        }
        if let contractorID = createReq.contractorId {
            guard let contractor = try await Contractor.find(contractorID, on: db), contractor.ownerId == userId, !contractor.isArchived else { throw Abort(.badRequest, reason: "Contractor unavailable") }
        }
        if let tradeID = createReq.tradeId {
            guard let trade = try await Trade.find(tradeID, on: db), trade.ownerId == userId, !trade.isArchived else { throw Abort(.badRequest, reason: "Trade unavailable") }
        }
        if let drawingID = createReq.drawingId {
            let links = try await MagicLink.query(on: db).filter(\.$createdById == userId).filter(\.$projectId == createReq.projectId).all().map(\.token)
            guard !links.isEmpty, try await SyncedDrawing.query(on: db).filter(\.$drawingId == drawingID).filter(\.$magicLinkToken ~~ links).first() != nil else { throw Abort(.badRequest, reason: "Upload the project's drawing before attaching a snag to it") }
        }
        let snag = Snag(
            id: createReq.id,
            reference: createReq.reference,
            title: createReq.title,
            snagDescription: createReq.description,
            status: SnagStatus.normalize(createReq.status ?? "open"),
            priority: createReq.priority ?? "medium",
            location: createReq.location,
            dueDate: createReq.dueDate,
            costEstimate: createReq.costEstimate,
            actualCost: createReq.actualCost,
            currency: createReq.currency ?? "GBP",
            drawingPinX: createReq.drawingPinX,
            drawingPinY: createReq.drawingPinY,
            projectId: createReq.projectId,
            contractorId: createReq.contractorId,
            tradeId: createReq.tradeId,
            drawingId: createReq.drawingId,
            ownerId: userId,
            tags: createReq.tags ?? []
        )

        try await snag.save(on: db)
        return SnagResponse(from: snag)
    }

    // MARK: - GET /api/v1/snags/:snagId
    @Sendable
    func get(req: Request) async throws -> SnagResponse {
        let userId = try req.requireAuthenticatedUserId()
        let snag = try await findSnag(req: req, userId: userId)
        return SnagResponse(from: snag)
    }

    // MARK: - PATCH /api/v1/snags/:snagId
    @Sendable
    func update(req: Request) async throws -> SnagResponse {
        let userId = try req.requireAuthenticatedUserId()
        let original = try await findSnag(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateSnagRequest.self)

        return try await req.db.transaction { db in
            try await SnagWorkflowService.lockProject(original.projectId, on: db)
            guard let snag = try await Snag.query(on: db).filter(\.$id == original.id!)
                .filter(\.$ownerId == userId).filter(LegacyProjectAccess.personalRecords(.snags)).first() else { throw Abort(.notFound) }
            try await SnagDeletionService.requireActive(snag.id!, ownerId: userId, projectId: snag.projectId, on: db)
            if let id = updateReq.contractorId {
                guard let item = try await Contractor.find(id, on: db), item.ownerId == userId, !item.isArchived else { throw Abort(.badRequest, reason: "Contractor unavailable") }
            }
            if let id = updateReq.tradeId {
                guard let item = try await Trade.find(id, on: db), item.ownerId == userId, !item.isArchived else { throw Abort(.badRequest, reason: "Trade unavailable") }
            }
            if let id = updateReq.drawingId, id != snag.drawingId {
                let links = try await MagicLink.query(on: db).filter(\.$createdById == userId).filter(\.$projectId == snag.projectId).all().map(\.token)
                guard !links.isEmpty, try await SyncedDrawing.query(on: db).filter(\.$drawingId == id).filter(\.$magicLinkToken ~~ links).first() != nil else { throw Abort(.badRequest, reason: "Drawing unavailable for this project") }
            }
            let current = SnagStatus.normalize(snag.status)
            let reviewStates = ["submitted", "awaitingApproval", "approved", "sentBack", "complete", "completed"]
            if let status = updateReq.status, SnagStatus.normalize(status) != current,
               reviewStates.contains(current) || reviewStates.contains(SnagStatus.normalize(status)) {
                throw Abort(.conflict, reason: "The review status cannot be replaced by an edit. Refresh and use the review actions.")
            }
            if let reference = updateReq.reference { snag.reference = reference }
            if let title = updateReq.title { snag.title = title }
            if let description = updateReq.description { snag.snagDescription = description }
            if let status = updateReq.status { snag.status = SnagStatus.normalize(status) }
            if let priority = updateReq.priority { snag.priority = priority }
            if let location = updateReq.location { snag.location = location }
            if let dueDate = updateReq.dueDate { snag.dueDate = dueDate }
            if let closedAt = updateReq.closedAt, !reviewStates.contains(current) { snag.closedAt = closedAt }
            if let costEstimate = updateReq.costEstimate { snag.costEstimate = costEstimate }
            if let actualCost = updateReq.actualCost { snag.actualCost = actualCost }
            if let currency = updateReq.currency { snag.currency = currency }
            if let drawingPinX = updateReq.drawingPinX { snag.drawingPinX = drawingPinX }
            if let drawingPinY = updateReq.drawingPinY { snag.drawingPinY = drawingPinY }
            if let contractorId = updateReq.contractorId {
                snag.contractorId = contractorId
                if snag.assignedAt == nil { snag.assignedAt = Date() }
            }
            if let tradeId = updateReq.tradeId { snag.tradeId = tradeId }
            if let drawingId = updateReq.drawingId { snag.drawingId = drawingId }
            if let assignedAt = updateReq.assignedAt { snag.assignedAt = assignedAt }
            if let tags = updateReq.tags { snag.tags = tags }

            try await snag.save(on: db)
            return SnagResponse(from: snag)
        }
    }

    // MARK: - DELETE /api/v1/snags/:snagId
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        let snag = try await findSnag(req: req, userId: userId)
        try await SnagDeletionService.delete(id: try snag.requireID(), projectId: snag.projectId, ownerId: userId, on: req.db)
        try await SnagDeletionService.cleanupFiles(app: req.application)
        return .noContent
    }

    struct DeletionRequest: Content { let projectId: UUID }

    /// Explicit report-aware deletion. Old servers return 404, so the iOS queue
    /// cannot mistake a legacy row-only DELETE for completed shared-report removal.
    @Sendable
    func deleteEverywhere(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        guard let value = req.parameters.get("snagId"), let id = UUID(uuidString: value) else {
            throw Abort(.badRequest, reason: "Invalid snag ID")
        }
        let body = try req.content.decode(DeletionRequest.self)
        try await SnagDeletionService.delete(id: id, projectId: body.projectId, ownerId: userId, on: req.db)
        // DB removal is durable even if storage is temporarily unavailable.
        do { try await SnagDeletionService.cleanupFiles(app: req.application) }
        catch { req.logger.warning("Deleted snag file cleanup will retry") }
        return .noContent
    }

    // MARK: - Helpers

    private func findSnag(req: Request, userId: UUID) async throws -> Snag {
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

        try await SnagDeletionService.requireActive(id, ownerId: userId, projectId: snag.projectId, on: req.db)
        return snag
    }
}
