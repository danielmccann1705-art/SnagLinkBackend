import Vapor
import Fluent

struct StagedLegacyImportController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let routes = routes.grouped("api", "v2", "workspaces", ":workspaceId", "import-sessions").grouped(PlatformAuthMiddleware())
        routes.on(.POST, body: .collect(maxSize: "12mb"), use: create)
        // Read through a small POST so source fingerprints/device bindings never
        // enter query strings, access-log URLs or browser navigation history.
        routes.on(.POST, ":sessionId", "receipt", body: .collect(maxSize: "16kb"), use: receipt)
        routes.on(.POST, ":sessionId", "abort", body: .collect(maxSize: "16kb"), use: abort)
    }
    @Sendable func create(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let workspaceID = try id("workspaceId", req)
        let value = try StagedLegacyImportHTTP.create(body(req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        do {
            let receipt = try await StagedLegacyImportService.create(value.command.bound(to: actor), descriptor: value.descriptor,
                workspaceID: workspaceID, actor: actor, binding: binding, on: req.db)
            return try response(receipt)
        } catch let error as LegacyProjectImportError { throw StagedLegacyImportHTTP.sourceError(error) }
    }
    @Sendable func receipt(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let value = try StagedLegacyImportHTTP.read(body(req), workspaceID: id("workspaceId", req), sessionID: id("sessionId", req))
        return try await response(StagedLegacyImportService.read(value.scope, actor: StagedImportRequestBoundary.actor(req), binding: binding, on: req.db))
    }
    @Sendable func abort(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let command = try StagedLegacyImportHTTP.abort(body(req), workspaceID: id("workspaceId", req), sessionID: id("sessionId", req))
        return try await response(StagedLegacyImportService.abort(command, actor: StagedImportRequestBoundary.actor(req), binding: binding, on: req.db))
    }
    private func body(_ req: Request) throws -> Data {
        guard req.headers.contentType == .json, req.headers.first(name: .contentEncoding) == nil,
              req.url.query == nil, let bytes = req.body.data else { throw StagedLegacyImportHTTP.invalid() }
        return Data(bytes.readableBytesView)
    }
    private func id(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; return id
    }
    private func response(_ value: StagedLegacyImportReceipt) throws -> Response {
        Response(status: .ok, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                 body: .init(string: try PlatformMutationService.encode(value)))
    }
}
