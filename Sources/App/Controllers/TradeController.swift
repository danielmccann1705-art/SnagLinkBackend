import Vapor
import Fluent

struct TradeController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let trades = routes.grouped("api", "v1", "trades")
            .grouped(JWTAuthMiddleware())

        trades.get(use: list)
        trades.post(use: create)
        trades.patch(":tradeId", use: update)
        trades.delete(":tradeId", use: delete)
    }

    @Sendable
    func list(req: Request) async throws -> [TradeResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let trades = try await Trade.query(on: req.db)
            .filter(\.$ownerId == userId)
            .sort(\.$sortOrder)
            .all()

        return trades.map { TradeResponse(from: $0) }
    }

    @Sendable
    func create(req: Request) async throws -> TradeResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateTradeRequest.self)
        try createReq.validate()

        let trade = Trade(
            id: createReq.id,
            name: createReq.name,
            colorHex: createReq.colorHex,
            sortOrder: createReq.sortOrder ?? 0,
            isDefault: createReq.isDefault ?? false,
            ownerId: userId
        )

        try await trade.save(on: req.db)
        return TradeResponse(from: trade)
    }

    @Sendable
    func update(req: Request) async throws -> TradeResponse {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("tradeId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid trade ID")
        }

        guard let trade = try await Trade.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Trade not found")
        }

        let updateReq = try req.content.decode(UpdateTradeRequest.self)

        if let name = updateReq.name { trade.name = name }
        if let colorHex = updateReq.colorHex { trade.colorHex = colorHex }
        if let sortOrder = updateReq.sortOrder { trade.sortOrder = sortOrder }
        if let isArchived = updateReq.isArchived { trade.isArchived = isArchived }

        try await trade.save(on: req.db)
        return TradeResponse(from: trade)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()

        guard let idString = req.parameters.get("tradeId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid trade ID")
        }

        guard let trade = try await Trade.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Trade not found")
        }

        try await trade.delete(on: req.db)
        return .noContent
    }
}
