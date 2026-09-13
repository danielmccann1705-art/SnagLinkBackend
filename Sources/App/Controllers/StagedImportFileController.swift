import Vapor
import SotoS3

/// Tests supply an isolated typed store; no route or request can set this value.
struct StagedImportOriginalStoreKey: StorageKey { typealias Value = any StagedImportOriginalStore }

struct StagedImportFileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let routes = routes.grouped("api", "v2", "workspaces", ":workspaceId", "import-sessions", ":sessionId", "files").grouped(PlatformAuthMiddleware())
        routes.on(.POST, "manifest", body: .collect(maxSize: "16kb"), use: manifest)
        routes.on(.POST, ":declarationId", "original", body: .stream, use: upload)
    }
    @Sendable func manifest(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        guard req.headers.contentType == .json, req.headers[.contentType].count == 1,
              req.headers[.contentEncoding].isEmpty, req.url.query == nil, let data = req.body.data else { throw StagedImportFileHTTP.invalid() }
        let command = try StagedImportFileHTTP.manifest(Data(data.readableBytesView), workspace: id("workspaceId", req), session: id("sessionId", req))
        let result = try await StagedImportOriginalService.manifest(command, actor: StagedImportRequestBoundary.actor(req), binding: binding, on: req.db)
        return try response(result)
    }
    @Sendable func upload(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        guard req.url.query == nil else { throw StagedImportFileHTTP.invalid() }
        let (command, byteCount) = try StagedImportFileHTTP.upload(req.headers, workspace: id("workspaceId", req), session: id("sessionId", req), declaration: id("declarationId", req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        let store: any StagedImportOriginalStore = try req.application.storage[StagedImportOriginalStoreKey.self] ?? StorageService.stagedImportOriginalStore(app: req.application)
        let body: AWSHTTPBody
        if byteCount == 0 {
            // Request.Body.AsyncSequence can trap for .none. This bounded empty
            // path checks actual body input; it does not trust the header as EOF.
            let bytes = try await req.body.collect(max: 0).get()
            guard (bytes?.readableBytes ?? 0) == 0 else { throw StagedImportFileHTTP.invalid() }
            body = .init(buffer: ByteBuffer())
        } else {
            // Pinned Vapor Request.Body is a back-pressured AsyncSequence. Soto
            // retains this sequence lazily: declaration admission precedes reads.
            body = .init(asyncSequence: req.body, length: Int(byteCount))
        }
        let result = try await StagedImportOriginalService.retain(command, actor: actor, binding: binding, body: body, store: store, on: req.db,
            admission: .init(maximumBytes: StagedImportFileHTTP.maximumUploadBytes, expectedInputBytes: byteCount),
            receiptAuthentication: { db in try await StagedImportRequestBoundary.receiptAuthentication(req, actor: actor, on: db) })
        return try response(result)
    }
    private func id(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw StagedImportFileHTTP.invalid() }; return id
    }
    private func response<T: Encodable>(_ value: T) throws -> Response {
        Response(status: .ok, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "Vary": "Cookie, Authorization"],
            body: .init(string: try PlatformMutationService.encode(value)))
    }
}
