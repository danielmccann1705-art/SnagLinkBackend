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
        let actor = try await actor(req)
        do {
            let receipt = try await StagedLegacyImportService.create(value.command.bound(to: actor), descriptor: value.descriptor,
                workspaceID: workspaceID, actor: actor, binding: binding, on: req.db)
            return try response(receipt)
        } catch let error as LegacyProjectImportError { throw StagedLegacyImportHTTP.sourceError(error) }
    }
    @Sendable func receipt(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let value = try StagedLegacyImportHTTP.read(body(req), workspaceID: id("workspaceId", req), sessionID: id("sessionId", req))
        return try await response(StagedLegacyImportService.read(value.scope, actor: actor(req), binding: binding, on: req.db))
    }
    @Sendable func abort(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let command = try StagedLegacyImportHTTP.abort(body(req), workspaceID: id("workspaceId", req), sessionID: id("sessionId", req))
        return try await response(StagedLegacyImportService.abort(command, actor: actor(req), binding: binding, on: req.db))
    }
    /// Refresh authentication after bounded body decoding; never upgrade a stale
    /// JWT/browser request into a new authVersion merely by loading today's user.
    private func actor(_ req: Request) async throws -> StagedLegacyImportActor {
        let id = try req.requireAuthenticatedUserId()
        let version: Int
        if let jwt = req.auth.get(UserJWTPayload.self) {
            let current = try await JWTAuthMiddleware.authenticate(req)
            guard current.userId == id, current.authVersion == jwt.authVersion else { throw Abort(.unauthorized) }
            version = current.authVersion ?? 0
        }
        else if let original = req.auth.get(BrowserPrincipal.self) {
            let current = try await BrowserSessionService.authenticate(req, config: PlatformConfiguration.load(on: req.application))
            guard current.userID == id, current.sessionID == original.sessionID,
                  let row = try await VerifiedIdentityService.sql(req.db).raw("SELECT auth_version FROM browser_sessions WHERE id = \(bind: current.sessionID) AND user_id = \(bind: id) AND revoked_at IS NULL AND expires_at > \(bind: Date())").first() else { throw Abort(.unauthorized) }
            version = try row.decode(column: "auth_version", as: Int.self)
        } else { throw Abort(.unauthorized) }
        let user = try await VerifiedIdentityService.activeUser(id, on: req.db)
        guard user.authVersion == version else { throw Abort(.unauthorized) }
        return .init(id: id, authVersion: version)
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
