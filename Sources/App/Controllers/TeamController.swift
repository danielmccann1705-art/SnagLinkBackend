import Vapor
import Fluent

struct TeamController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let teams = routes.grouped("api", "v1", "teams")
            .grouped(JWTAuthMiddleware())

        teams.get(use: list)
        teams.post(use: create)
        teams.get(":teamId", use: get)
        teams.patch(":teamId", use: update)
        teams.delete(":teamId", use: delete)
    }

    @Sendable
    func list(req: Request) async throws -> [TeamResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let teams = try await Team.query(on: req.db)
            .filter(\.$ownerUserId == userId)
            .filter(\.$kind == "company")
            .filter(\.$lifecycleState == "active")
            .sort(\.$name)
            .all()

        return teams.map { TeamResponse(from: $0) }
    }

    @Sendable
    func create(req: Request) async throws -> TeamResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateTeamRequest.self)
        try createReq.validate()

        let team = try await req.db.transaction { db in
            try await WorkspaceAccessService.createCompany(id: createReq.id ?? UUID(), name: createReq.name, actorID: userId, on: db)
        }
        return TeamResponse(from: team)
    }

    @Sendable
    func get(req: Request) async throws -> TeamResponse {
        let userId = try req.requireAuthenticatedUserId()
        let team = try await findTeam(req: req, userId: userId)
        return TeamResponse(from: team)
    }

    @Sendable
    func update(req: Request) async throws -> TeamResponse {
        let userId = try req.requireAuthenticatedUserId()
        let initial = try await findTeam(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateTeamRequest.self)
        return try await req.db.transaction { db in
            let team = try await WorkspaceAccessService.requireCompany(initial.requireID(), actorID: userId, admin: true, on: db)
            if let value = updateReq.name {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 120 else { throw Abort(.badRequest, reason: "Enter a company name") }
                team.name = name
            }
            team.revision += 1
            try await team.save(on: db)
            return TeamResponse(from: team)
        }
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        _ = try await findTeam(req: req, userId: userId)
        throw Abort(.conflict, reason: "Company closure requires the current account settings flow so shared projects and members can be handled safely")
    }

    private func findTeam(req: Request, userId: UUID) async throws -> Team {
        guard let idString = req.parameters.get("teamId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid team ID")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerUserId == userId)
            .filter(\.$kind == "company")
            .filter(\.$lifecycleState == "active")
            .first() else {
            throw Abort(.notFound, reason: "Team not found")
        }

        return team
    }
}
