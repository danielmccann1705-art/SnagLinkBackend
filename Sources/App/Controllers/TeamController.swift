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
            .sort(\.$name)
            .all()

        return teams.map { TeamResponse(from: $0) }
    }

    @Sendable
    func create(req: Request) async throws -> TeamResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateTeamRequest.self)
        try createReq.validate()

        let team = Team(
            id: createReq.id,
            name: createReq.name,
            ownerUserId: userId
        )

        try await team.save(on: req.db)
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
        let team = try await findTeam(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateTeamRequest.self)

        if let name = updateReq.name { team.name = name }

        try await team.save(on: req.db)
        return TeamResponse(from: team)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        let team = try await findTeam(req: req, userId: userId)
        try await team.delete(on: req.db)
        return .noContent
    }

    private func findTeam(req: Request, userId: UUID) async throws -> Team {
        guard let idString = req.parameters.get("teamId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid team ID")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerUserId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Team not found")
        }

        return team
    }
}
