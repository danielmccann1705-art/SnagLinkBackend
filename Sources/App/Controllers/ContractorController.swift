import Vapor
import Fluent

struct ContractorController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let contractors = routes.grouped("api", "v1", "contractors")
            .grouped(JWTAuthMiddleware())

        contractors.get(use: list)
        contractors.post(use: create)
        contractors.get(":contractorId", use: get)
        contractors.patch(":contractorId", use: update)
        contractors.delete(":contractorId", use: delete)
    }

    @Sendable
    func list(req: Request) async throws -> [ContractorResponse] {
        let userId = try req.requireAuthenticatedUserId()
        let includeArchived = (try? req.query.get(Bool.self, at: "includeArchived")) ?? false

        var query = Contractor.query(on: req.db)
            .filter(\.$ownerId == userId)
            .sort(\.$companyName)

        if !includeArchived {
            query = query.filter(\.$isArchived == false)
        }

        let contractors = try await query.all()
        return contractors.map { ContractorResponse(from: $0) }
    }

    @Sendable
    func create(req: Request) async throws -> ContractorResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateContractorRequest.self)
        try createReq.validate()

        let contractor = Contractor(
            id: createReq.id,
            companyName: createReq.companyName,
            contactName: createReq.contactName,
            email: createReq.email,
            phone: createReq.phone,
            notes: createReq.notes,
            tradeIds: createReq.tradeIds ?? [],
            ownerId: userId
        )

        try await contractor.save(on: req.db)
        return ContractorResponse(from: contractor)
    }

    @Sendable
    func get(req: Request) async throws -> ContractorResponse {
        let userId = try req.requireAuthenticatedUserId()
        let contractor = try await findContractor(req: req, userId: userId)
        return ContractorResponse(from: contractor)
    }

    @Sendable
    func update(req: Request) async throws -> ContractorResponse {
        let userId = try req.requireAuthenticatedUserId()
        let contractor = try await findContractor(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateContractorRequest.self)

        if let companyName = updateReq.companyName { contractor.companyName = companyName }
        if let contactName = updateReq.contactName { contractor.contactName = contactName }
        if let email = updateReq.email { contractor.email = email }
        if let phone = updateReq.phone { contractor.phone = phone }
        if let notes = updateReq.notes { contractor.notes = notes }
        if let isArchived = updateReq.isArchived { contractor.isArchived = isArchived }
        if let tradeIds = updateReq.tradeIds { contractor.tradeIds = tradeIds }

        try await contractor.save(on: req.db)
        return ContractorResponse(from: contractor)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        let contractor = try await findContractor(req: req, userId: userId)
        try await contractor.delete(on: req.db)
        return .noContent
    }

    private func findContractor(req: Request, userId: UUID) async throws -> Contractor {
        guard let idString = req.parameters.get("contractorId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid contractor ID")
        }

        guard let contractor = try await Contractor.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Contractor not found")
        }

        return contractor
    }
}
