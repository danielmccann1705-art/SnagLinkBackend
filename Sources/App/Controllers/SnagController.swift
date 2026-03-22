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
            .filter(\.$ownerId == userId)
            .sort(\.$updatedAt, .descending)

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
        try createReq.validate()

        // Verify project ownership
        guard let _ = try await Project.query(on: req.db)
            .filter(\.$id == createReq.projectId)
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Project not found")
        }

        let snag = Snag(
            id: createReq.id,
            reference: createReq.reference,
            title: createReq.title,
            snagDescription: createReq.description,
            status: createReq.status ?? "open",
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

        try await snag.save(on: req.db)
        return SnagResponse(from: snag)
    }

    // MARK: - POST /api/v1/snags/batch
    @Sendable
    func batchCreate(req: Request) async throws -> [SnagResponse] {
        let userId = try req.requireAuthenticatedUserId()
        let requests = try req.content.decode([CreateSnagRequest].self)

        guard requests.count <= 100 else {
            throw Abort(.badRequest, reason: "Maximum 100 snags per batch")
        }

        var responses: [SnagResponse] = []

        for createReq in requests {
            try createReq.validate()

            let snag = Snag(
                id: createReq.id,
                reference: createReq.reference,
                title: createReq.title,
                snagDescription: createReq.description,
                status: createReq.status ?? "open",
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

            try await snag.save(on: req.db)
            responses.append(SnagResponse(from: snag))
        }

        return responses
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
        let snag = try await findSnag(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateSnagRequest.self)

        if let reference = updateReq.reference { snag.reference = reference }
        if let title = updateReq.title { snag.title = title }
        if let description = updateReq.description { snag.snagDescription = description }
        if let status = updateReq.status { snag.status = status }
        if let priority = updateReq.priority { snag.priority = priority }
        if let location = updateReq.location { snag.location = location }
        if let dueDate = updateReq.dueDate { snag.dueDate = dueDate }
        if let closedAt = updateReq.closedAt { snag.closedAt = closedAt }
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

        try await snag.save(on: req.db)
        return SnagResponse(from: snag)
    }

    // MARK: - DELETE /api/v1/snags/:snagId
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        let snag = try await findSnag(req: req, userId: userId)
        try await snag.delete(on: req.db)
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
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Snag not found")
        }

        return snag
    }
}
