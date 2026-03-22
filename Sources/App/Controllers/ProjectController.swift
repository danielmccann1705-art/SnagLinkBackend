import Vapor
import Fluent

struct ProjectController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let projects = routes.grouped("api", "v1", "projects")
            .grouped(JWTAuthMiddleware())

        projects.get(use: list)
        projects.post(use: create)
        projects.get(":projectId", use: get)
        projects.patch(":projectId", use: update)
        projects.delete(":projectId", use: delete)
    }

    // MARK: - GET /api/v1/projects
    @Sendable
    func list(req: Request) async throws -> [ProjectResponse] {
        let userId = try req.requireAuthenticatedUserId()

        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        let perPage = min((try? req.query.get(Int.self, at: "perPage")) ?? 50, 100)
        let status = try? req.query.get(String.self, at: "status")

        var query = Project.query(on: req.db)
            .filter(\.$ownerId == userId)
            .sort(\.$updatedAt, .descending)

        if let status = status {
            query = query.filter(\.$status == status)
        }

        let projects = try await query
            .range(..<(page * perPage))
            .all()

        // Skip items from previous pages
        let startIndex = (page - 1) * perPage
        let pageItems = Array(projects.dropFirst(startIndex))

        return pageItems.map { ProjectResponse(from: $0) }
    }

    // MARK: - POST /api/v1/projects
    @Sendable
    func create(req: Request) async throws -> ProjectResponse {
        let userId = try req.requireAuthenticatedUserId()
        let createReq = try req.content.decode(CreateProjectRequest.self)
        try createReq.validate()

        let project = Project(
            id: createReq.id,
            name: createReq.name,
            reference: createReq.reference,
            clientName: createReq.clientName,
            clientEmail: createReq.clientEmail,
            clientPhone: createReq.clientPhone,
            address: createReq.address,
            notes: createReq.notes,
            projectType: createReq.projectType,
            status: createReq.status ?? "active",
            isFavorite: createReq.isFavorite ?? false,
            latitude: createReq.latitude,
            longitude: createReq.longitude,
            ownerId: userId,
            teamId: createReq.teamId
        )

        try await project.save(on: req.db)
        return ProjectResponse(from: project)
    }

    // MARK: - GET /api/v1/projects/:projectId
    @Sendable
    func get(req: Request) async throws -> ProjectResponse {
        let userId = try req.requireAuthenticatedUserId()
        let project = try await findProject(req: req, userId: userId)
        return ProjectResponse(from: project)
    }

    // MARK: - PATCH /api/v1/projects/:projectId
    @Sendable
    func update(req: Request) async throws -> ProjectResponse {
        let userId = try req.requireAuthenticatedUserId()
        let project = try await findProject(req: req, userId: userId)
        let updateReq = try req.content.decode(UpdateProjectRequest.self)

        if let name = updateReq.name { project.name = name }
        if let reference = updateReq.reference { project.reference = reference }
        if let clientName = updateReq.clientName { project.clientName = clientName }
        if let clientEmail = updateReq.clientEmail { project.clientEmail = clientEmail }
        if let clientPhone = updateReq.clientPhone { project.clientPhone = clientPhone }
        if let address = updateReq.address { project.address = address }
        if let notes = updateReq.notes { project.notes = notes }
        if let projectType = updateReq.projectType { project.projectType = projectType }
        if let status = updateReq.status { project.status = status }
        if let isFavorite = updateReq.isFavorite { project.isFavorite = isFavorite }
        if let coverImagePath = updateReq.coverImagePath { project.coverImagePath = coverImagePath }
        if let latitude = updateReq.latitude { project.latitude = latitude }
        if let longitude = updateReq.longitude { project.longitude = longitude }
        if let teamId = updateReq.teamId { project.teamId = teamId }

        try await project.save(on: req.db)
        return ProjectResponse(from: project)
    }

    // MARK: - DELETE /api/v1/projects/:projectId
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userId = try req.requireAuthenticatedUserId()
        let project = try await findProject(req: req, userId: userId)
        try await project.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func findProject(req: Request, userId: UUID) async throws -> Project {
        guard let idString = req.parameters.get("projectId"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        guard let project = try await Project.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$ownerId == userId)
            .first() else {
            throw Abort(.notFound, reason: "Project not found")
        }

        return project
    }
}
