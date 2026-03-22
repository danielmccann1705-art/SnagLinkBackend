import Vapor

struct CreateTeamRequest: Content {
    let id: UUID?
    let name: String

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Team name is required")
        }
    }
}

struct UpdateTeamRequest: Content {
    let name: String?
}

struct TeamResponse: Content {
    let id: UUID
    let name: String
    let ownerUserId: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(from team: Team) {
        self.id = team.id!
        self.name = team.name
        self.ownerUserId = team.ownerUserId
        self.createdAt = team.createdAt
        self.updatedAt = team.updatedAt
    }
}
