import Vapor
import Fluent

struct LegacyImportPreviewController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let route = routes.grouped("api", "v2", "workspaces").grouped(PlatformAuthMiddleware())
        route.on(.POST, ":workspaceId", "import-previews", body: .collect(maxSize: "2mb"), use: preview)
    }
    @Sendable func preview(req: Request) async throws -> Response {
        let actor = try req.requireAuthenticatedUserId()
        guard let raw = req.parameters.get("workspaceId"), let workspaceID = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        let binding = try ImportServerBinding.load(on: req.application)
        guard req.headers.contentType == .json, let bytes = req.body.data else { throw LegacyImportPreviewCommand.invalid() }
        let command = try LegacyImportPreviewCommand.decode(Data(bytes.readableBytesView))
        let value = try await req.db.transaction { db in
            try await LegacyImportPreviewService.preview(command, workspaceID: workspaceID, actorID: actor, binding: binding, on: db)
        }
        let response = try await value.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
}
