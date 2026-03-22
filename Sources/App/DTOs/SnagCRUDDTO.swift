import Vapor

// MARK: - Request DTOs

struct CreateSnagRequest: Content {
    let id: UUID?
    let reference: String
    let title: String
    let description: String?
    let status: String?
    let priority: String?
    let location: String?
    let dueDate: Date?
    let costEstimate: Double?
    let actualCost: Double?
    let currency: String?
    let drawingPinX: Double?
    let drawingPinY: Double?
    let projectId: UUID
    let contractorId: UUID?
    let tradeId: UUID?
    let drawingId: UUID?
    let tags: [String]?

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Snag title is required")
        }
        guard title.count <= 500 else {
            throw Abort(.badRequest, reason: "Snag title must be 500 characters or less")
        }
    }
}

struct UpdateSnagRequest: Content {
    let reference: String?
    let title: String?
    let description: String?
    let status: String?
    let priority: String?
    let location: String?
    let dueDate: Date?
    let closedAt: Date?
    let costEstimate: Double?
    let actualCost: Double?
    let currency: String?
    let drawingPinX: Double?
    let drawingPinY: Double?
    let contractorId: UUID?
    let tradeId: UUID?
    let drawingId: UUID?
    let assignedAt: Date?
    let tags: [String]?
}

// MARK: - Response DTOs

struct SnagResponse: Content {
    let id: UUID
    let reference: String
    let title: String
    let description: String?
    let status: String
    let priority: String
    let location: String?
    let dueDate: Date?
    let closedAt: Date?
    let costEstimate: Double?
    let actualCost: Double?
    let currency: String
    let drawingPinX: Double?
    let drawingPinY: Double?
    let projectId: UUID
    let contractorId: UUID?
    let tradeId: UUID?
    let drawingId: UUID?
    let assignedAt: Date?
    let ownerId: UUID
    let tags: [String]
    let createdAt: Date?
    let updatedAt: Date?

    init(from snag: Snag) {
        self.id = snag.id!
        self.reference = snag.reference
        self.title = snag.title
        self.description = snag.snagDescription
        self.status = snag.status
        self.priority = snag.priority
        self.location = snag.location
        self.dueDate = snag.dueDate
        self.closedAt = snag.closedAt
        self.costEstimate = snag.costEstimate
        self.actualCost = snag.actualCost
        self.currency = snag.currency
        self.drawingPinX = snag.drawingPinX
        self.drawingPinY = snag.drawingPinY
        self.projectId = snag.projectId
        self.contractorId = snag.contractorId
        self.tradeId = snag.tradeId
        self.drawingId = snag.drawingId
        self.assignedAt = snag.assignedAt
        self.ownerId = snag.ownerId
        self.tags = snag.tags
        self.createdAt = snag.createdAt
        self.updatedAt = snag.updatedAt
    }
}

struct SnagListSyncResponse: Content {
    let snags: [SnagResponse]
    let totalCount: Int
    let page: Int
    let perPage: Int
}
