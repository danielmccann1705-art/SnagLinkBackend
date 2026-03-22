import Vapor

struct CreateTradeRequest: Content {
    let id: UUID?
    let name: String
    let colorHex: String
    let sortOrder: Int?
    let isDefault: Bool?

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Trade name is required")
        }
    }
}

struct UpdateTradeRequest: Content {
    let name: String?
    let colorHex: String?
    let sortOrder: Int?
    let isArchived: Bool?
}

struct TradeResponse: Content {
    let id: UUID
    let name: String
    let colorHex: String
    let sortOrder: Int
    let isArchived: Bool
    let isDefault: Bool
    let ownerId: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(from trade: Trade) {
        self.id = trade.id!
        self.name = trade.name
        self.colorHex = trade.colorHex
        self.sortOrder = trade.sortOrder
        self.isArchived = trade.isArchived
        self.isDefault = trade.isDefault
        self.ownerId = trade.ownerId
        self.createdAt = trade.createdAt
        self.updatedAt = trade.updatedAt
    }
}
