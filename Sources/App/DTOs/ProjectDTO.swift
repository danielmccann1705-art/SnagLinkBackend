import Vapor

// MARK: - Request DTOs

struct CreateProjectRequest: Content {
    let id: UUID?
    let name: String
    let reference: String
    let clientName: String?
    let clientEmail: String?
    let clientPhone: String?
    let address: String?
    let notes: String?
    let projectType: String?
    let status: String?
    let isFavorite: Bool?
    let latitude: Double?
    let longitude: Double?
    let teamId: UUID?

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Project name is required")
        }
        guard name.count <= 200 else {
            throw Abort(.badRequest, reason: "Project name must be 200 characters or less")
        }
    }
}

struct UpdateProjectRequest: Content {
    let name: String?
    let reference: String?
    let clientName: String?
    let clientEmail: String?
    let clientPhone: String?
    let address: String?
    let notes: String?
    let projectType: String?
    let status: String?
    let isFavorite: Bool?
    let coverImagePath: String?
    let latitude: Double?
    let longitude: Double?
    let teamId: UUID?
}

// MARK: - Response DTOs

struct ProjectResponse: Content {
    let id: UUID
    let name: String
    let reference: String
    let clientName: String?
    let clientEmail: String?
    let clientPhone: String?
    let address: String?
    let notes: String?
    let projectType: String?
    let status: String
    let isFavorite: Bool
    let coverImagePath: String?
    let latitude: Double?
    let longitude: Double?
    let ownerId: UUID
    let teamId: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from project: Project) {
        self.id = project.id!
        self.name = project.name
        self.reference = project.reference
        self.clientName = project.clientName
        self.clientEmail = project.clientEmail
        self.clientPhone = project.clientPhone
        self.address = project.address
        self.notes = project.notes
        self.projectType = project.projectType
        self.status = project.status
        self.isFavorite = project.isFavorite
        self.coverImagePath = project.coverImagePath
        self.latitude = project.latitude
        self.longitude = project.longitude
        self.ownerId = project.ownerId
        self.teamId = project.teamId
        self.createdAt = project.createdAt
        self.updatedAt = project.updatedAt
    }
}
