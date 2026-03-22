import Vapor

struct CreateContractorRequest: Content {
    let id: UUID?
    let companyName: String
    let contactName: String?
    let email: String?
    let phone: String?
    let notes: String?
    let tradeIds: [UUID]?

    func validate() throws {
        guard !companyName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Company name is required")
        }
        guard companyName.count <= 200 else {
            throw Abort(.badRequest, reason: "Company name must be 200 characters or less")
        }
    }
}

struct UpdateContractorRequest: Content {
    let companyName: String?
    let contactName: String?
    let email: String?
    let phone: String?
    let notes: String?
    let isArchived: Bool?
    let tradeIds: [UUID]?
}

struct ContractorResponse: Content {
    let id: UUID
    let companyName: String
    let contactName: String?
    let email: String?
    let phone: String?
    let notes: String?
    let isArchived: Bool
    let tradeIds: [UUID]
    let ownerId: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(from contractor: Contractor) {
        self.id = contractor.id!
        self.companyName = contractor.companyName
        self.contactName = contractor.contactName
        self.email = contractor.email
        self.phone = contractor.phone
        self.notes = contractor.notes
        self.isArchived = contractor.isArchived
        self.tradeIds = contractor.tradeIds
        self.ownerId = contractor.ownerId
        self.createdAt = contractor.createdAt
        self.updatedAt = contractor.updatedAt
    }
}
