import Vapor
import Fluent

/// Private preparation → processing → acknowledged publication routes. Same gate,
/// authentication boundary and small-body discipline as source preparation.
struct LegacyImportCommitController: RouteCollection {
    struct ProjectionEnvelope: Decodable { let formatVersion: Int; let command: LegacyCanonicalProjectionCommand }
    struct StatusEnvelope: Decodable { let formatVersion: Int; let scope: StagedLegacyImportScope; let projectionId: UUID }
    struct CommitEnvelope: Decodable { let formatVersion: Int; let command: LegacyImportCommitCommand }
    struct ReceiptEnvelope: Decodable { let formatVersion: Int; let scope: StagedLegacyImportScope; let commitId: UUID }

    func boot(routes: RoutesBuilder) throws {
        let routes = routes.grouped("api", "v2", "workspaces", ":workspaceId", "import-sessions", ":sessionId").grouped(PlatformAuthMiddleware())
        routes.on(.POST, "projection", body: .collect(maxSize: "16kb"), use: projection)
        routes.on(.POST, "projection", "status", body: .collect(maxSize: "16kb"), use: status)
        routes.on(.POST, "commit", body: .collect(maxSize: "16kb"), use: commit)
        routes.on(.POST, "commit", "receipt", body: .collect(maxSize: "16kb"), use: receipt)
    }
    static func projectionCommand(_ data: Data, workspace: UUID, session: UUID) throws -> LegacyCanonicalProjectionCommand {
        let object = try StagedLegacyImportHTTP.object(data, limit: StagedLegacyImportHTTP.maximumSmallBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "command"])
        let command = try StagedLegacyImportHTTP.keys(object["command"], ["projectionId", "scope", "operationId", "expectedSourceRevision", "policy"])
        try StagedLegacyImportHTTP.scope(command["scope"])
        let value: ProjectionEnvelope = try StagedLegacyImportHTTP.decode(data)
        guard value.formatVersion == 1, value.command.expectedSourceRevision > 0, value.command.policy == LegacyCanonicalProjection.policy else { throw StagedLegacyImportHTTP.invalid() }
        try StagedLegacyImportHTTP.match(value.command.scope, workspace, session)
        return value.command
    }
    static func statusRequest(_ data: Data, workspace: UUID, session: UUID) throws -> StatusEnvelope {
        let object = try StagedLegacyImportHTTP.object(data, limit: StagedLegacyImportHTTP.maximumSmallBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "scope", "projectionId"]); try StagedLegacyImportHTTP.scope(object["scope"])
        let value: StatusEnvelope = try StagedLegacyImportHTTP.decode(data)
        guard value.formatVersion == 1 else { throw StagedLegacyImportHTTP.invalid() }
        try StagedLegacyImportHTTP.match(value.scope, workspace, session)
        return value
    }
    static func commitCommand(_ data: Data, workspace: UUID, session: UUID) throws -> LegacyImportCommitCommand {
        let object = try StagedLegacyImportHTTP.object(data, limit: StagedLegacyImportHTTP.maximumSmallBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "command"])
        let command = try StagedLegacyImportHTTP.keys(object["command"], ["commitId", "scope", "projectionId", "operationId", "expectedSourceRevision", "expectedGraphSHA256", "acknowledgement"])
        try StagedLegacyImportHTTP.scope(command["scope"]); try StagedLegacyImportHTTP.keys(command["acknowledgement"], ["version", "wording", "accepted"])
        let value: CommitEnvelope = try StagedLegacyImportHTTP.decode(data)
        guard value.formatVersion == 1, value.command.expectedSourceRevision > 0, LegacyProjectImportDecoder.validDigest(value.command.expectedGraphSHA256) else { throw StagedLegacyImportHTTP.invalid() }
        try StagedLegacyImportHTTP.match(value.command.scope, workspace, session)
        return value.command
    }
    static func receiptRequest(_ data: Data, workspace: UUID, session: UUID) throws -> ReceiptEnvelope {
        let object = try StagedLegacyImportHTTP.object(data, limit: StagedLegacyImportHTTP.maximumSmallBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "scope", "commitId"]); try StagedLegacyImportHTTP.scope(object["scope"])
        let value: ReceiptEnvelope = try StagedLegacyImportHTTP.decode(data)
        guard value.formatVersion == 1 else { throw StagedLegacyImportHTTP.invalid() }
        try StagedLegacyImportHTTP.match(value.scope, workspace, session)
        return value
    }

    @Sendable func projection(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let command = try Self.projectionCommand(body(req), workspace: id("workspaceId", req), session: id("sessionId", req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        let store = try Self.store(req)
        do {
            _ = try await LegacyCanonicalProjectionService.prepare(command, actor: actor, binding: binding, on: req.db)
            _ = try await LegacyImportProcessingService.process(projectionID: command.projectionId, scope: command.scope, actor: actor, binding: binding, store: store, on: req.db)
            let status = try await LegacyImportCommitService.status(projectionID: command.projectionId, scope: command.scope, actor: actor, binding: binding, on: req.db)
            return try response(status)
        } catch let error as LegacyProjectImportError { throw StagedLegacyImportHTTP.sourceError(error) }
        catch let error as LegacyCanonicalProjectionError { throw Self.projectionError(error) }
    }
    @Sendable func status(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let value = try Self.statusRequest(body(req), workspace: id("workspaceId", req), session: id("sessionId", req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        do { let status = try await LegacyImportCommitService.status(projectionID: value.projectionId, scope: value.scope, actor: actor, binding: binding, on: req.db); return try response(status) }
        catch let error as LegacyProjectImportError { throw StagedLegacyImportHTTP.sourceError(error) }
        catch let error as LegacyCanonicalProjectionError { throw Self.projectionError(error) }
    }
    @Sendable func commit(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let command = try Self.commitCommand(body(req), workspace: id("workspaceId", req), session: id("sessionId", req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        do { let receipt = try await LegacyImportCommitService.commit(command, actor: actor, binding: binding, on: req.db); return try response(receipt) }
        catch let error as LegacyProjectImportError { throw StagedLegacyImportHTTP.sourceError(error) }
        catch let error as LegacyCanonicalProjectionError { throw Self.projectionError(error) }
    }
    @Sendable func receipt(req: Request) async throws -> Response {
        let binding = try StagedLegacyImportHTTPGate.require(on: req.application)
        let value = try Self.receiptRequest(body(req), workspace: id("workspaceId", req), session: id("sessionId", req))
        let actor = try await StagedImportRequestBoundary.actor(req)
        let receipt = try await LegacyImportCommitService.receipt(commitID: value.commitId, scope: value.scope, actor: actor, binding: binding, on: req.db)
        return try response(receipt)
    }
    static func store(_ req: Request) throws -> any StagedImportOriginalStore {
        try req.application.storage[StagedImportOriginalStoreKey.self] ?? StorageService.stagedImportOriginalStore(app: req.application)
    }
    static func projectionError(_ error: LegacyCanonicalProjectionError) -> Abort {
        switch error {
        case .changedDirectory: return .init(.conflict, reason: "A shared contractor, trade, folder or tag from this source changed since an earlier import. Reconcile it before continuing", identifier: "import_directory_changed")
        case .projectionChanged, .binding: return .init(.conflict, reason: "The preparation's binding or prepared graph changed. Refresh before continuing", identifier: "import_projection_changed")
        case .capacity: return .init(.payloadTooLarge, reason: "The complete selected source does not fit the supported import budget. Nothing was published", identifier: "staged_import_graph_too_large")
        case .allocation, .unsupportedPolicy: return .init(.badRequest, reason: "The prepared projection does not match the supported publication contract", identifier: "invalid_import_projection")
        }
    }
    private func body(_ req: Request) throws -> Data {
        guard req.headers.contentType == .json, req.headers[.contentType].count == 1, req.headers[.contentEncoding].isEmpty,
              req.url.query == nil, let bytes = req.body.data else { throw StagedLegacyImportHTTP.invalid() }
        return Data(bytes.readableBytesView)
    }
    private func id(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; return id
    }
    private func response<T: Encodable>(_ value: T) throws -> Response {
        Response(status: .ok, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "Vary": "Cookie, Authorization"],
            body: .init(string: try PlatformMutationService.encode(value)))
    }
}

/// Authenticated readback of published import records and bytes under current
/// project read authority (a second authorised manager reads the same graph).
struct ImportedProjectController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let project = routes.grouped("api", "v2", "projects", ":projectId").grouped(PlatformAuthMiddleware())
        project.get("imported-graph", use: graph)
        project.get("drawings", use: drawings)
        project.get("imported-files", ":fileId", "original", use: original)
        project.get("imported-files", ":fileId", "rendition", use: rendition)
        project.get("drawings", "pages", ":pageId", "rendition", use: pageRendition)
        project.get("drawings", "pages", ":pageId", "thumbnail", use: pageThumbnail)
    }
    private func id(_ name: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; return id
    }
    private func authorised(_ req: Request, _ db: Database) async throws -> Project {
        let (project, _) = try await ProjectAccessService.require(.read, projectID: id("projectId", req), actorID: req.requireAuthenticatedUserId(), on: db)
        try PlatformMutationService.requireManaged(project)
        return project
    }
    @Sendable func graph(req: Request) async throws -> LegacyImportReadService.Graph {
        try await req.db.transaction { db in
            let project = try await authorised(req, db)
            return try await LegacyImportReadService.graph(projectID: project.requireID(), workspaceID: project.workspaceId!, on: db)
        }
    }
    @Sendable func drawings(req: Request) async throws -> [DrawingSheetResponse] {
        try await req.db.transaction { db in
            let project = try await authorised(req, db)
            return try await LegacyImportReadService.sheets(projectID: project.requireID(), on: db)
        }
    }
    @Sendable func original(req: Request) async throws -> Response { try await file(req, rendition: false) }
    @Sendable func rendition(req: Request) async throws -> Response { try await file(req, rendition: true) }
    @Sendable func pageRendition(req: Request) async throws -> Response { try await page(req, thumbnail: false) }
    @Sendable func pageThumbnail(req: Request) async throws -> Response { try await page(req, thumbnail: true) }
    private func file(_ req: Request, rendition: Bool) async throws -> Response {
        let store = try LegacyImportCommitController.store(req), fileID = try id("fileId", req)
        let target = try await req.db.transaction { db in
            let project = try await authorised(req, db)
            return try await LegacyImportReadService.fileBytes(fileID, projectID: project.requireID(), rendition: rendition, store: store, on: db)
        }
        return try await bytes(req, target: target, store: store)
    }
    private func page(_ req: Request, thumbnail: Bool) async throws -> Response {
        let store = try LegacyImportCommitController.store(req), pageID = try id("pageId", req)
        let target = try await req.db.transaction { db in
            let project = try await authorised(req, db)
            return try await LegacyImportReadService.drawingPageBytes(pageID, projectID: project.requireID(), thumbnail: thumbnail, on: db)
        }
        return try await bytes(req, target: target, store: store)
    }
    private func bytes(_ req: Request, target: (key: ImportedObjectKey, sha256: String, size: Int64, mime: String), store: any StagedImportOriginalStore) async throws -> Response {
        let value = try await LegacyImportReadService.verifiedBytes(target, store: store)
        // Storage IO ran outside membership locks; recheck access before disclosure.
        _ = try await req.db.transaction { db in try await authorised(req, db) }
        return Response(status: .ok, headers: ["Content-Type": value.mime, "Content-Length": String(value.data.count), "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline", "Referrer-Policy": "no-referrer", "Vary": "Cookie, Authorization"], body: .init(data: value.data))
    }
}
