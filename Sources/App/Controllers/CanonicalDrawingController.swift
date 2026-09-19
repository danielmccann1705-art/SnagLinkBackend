import Vapor
import Fluent

struct CanonicalDrawingController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let drawings = routes.grouped("api", "v2", "projects", ":projectId", "drawings")
            .grouped(PlatformAuthMiddleware())
        drawings.on(.POST, "sources", body: .collect(maxSize: "16kb"), use: allocate)
        drawings.get("sources", ":assetId", use: source)
        drawings.on(.PUT, "sources", ":assetId", "content", body: .collect(maxSize: "50mb"), use: upload)
        drawings.on(.POST, "sources", ":assetId", "process", body: .collect(maxSize: "16kb"), use: process)
        drawings.on(.POST, "publish", body: .collect(maxSize: "64kb"), use: publish)
        drawings.on(.POST, "snags", ":snagId", "pin", body: .collect(maxSize: "16kb"), use: pin)
    }

    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid drawing route")
        }
        return value
    }

    private func editableProject(_ projectID: UUID, actorID: UUID, on db: Database) async throws -> Project {
        let project = try await ProjectAccessService.require(.edit, projectID: projectID, actorID: actorID, on: db).0
        try PlatformMutationService.requireManaged(project)
        return project
    }

    @Sendable func allocate(req: Request) async throws -> DrawingAssetRecord {
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let command = try req.content.decode(DrawingAllocateCommand.self)
        let runtime = try CanonicalDrawingRuntimeAccess.require(req.application)
        let workspaceID = try await req.db.transaction { db in
            try await editableProject(projectID, actorID: actorID, on: db).workspaceId!
        }
        return try await CanonicalDrawingService.allocateWithExpectedRuntime(command,
            workspaceID: workspaceID, projectID: projectID, actorID: actorID,
            runtime: runtime.identity, on: req.db)
    }

    @Sendable func source(req: Request) async throws -> DrawingAssetRecord {
        try await CanonicalDrawingService.readAsset(id("assetId", req), projectID: id("projectId", req),
            actorID: req.requireAuthenticatedUserId(), on: req.db)
    }

    @Sendable func upload(req: Request) async throws -> DrawingAssetRecord {
        let projectID = try id("projectId", req), assetID = try id("assetId", req)
        let actorID = try req.requireAuthenticatedUserId()
        guard req.url.query == nil, req.headers[.contentType].count == 1,
              req.headers[.contentEncoding].isEmpty, let buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Drawing bytes are missing")
        }
        let bytes = Data(buffer: buffer), runtime = try CanonicalDrawingRuntimeAccess.require(req.application)
        let binding: DrawingUploadBinding = try await req.db.transaction { db in
            let project = try await editableProject(projectID, actorID: actorID, on: db)
            let asset = try await CanonicalDrawingService.asset(assetID, projectID: projectID, on: db)
            try CanonicalDrawingService.owned(asset, actorID: actorID)
            guard asset.state == "allocated", asset.processorProfile == runtime.identity.processorProfile,
                  asset.byteCount == bytes.count,
                  req.headers.contentType?.description == asset.mimeType,
                  PrivateImageProcessor.digest(bytes) == asset.sha256 else {
                throw Abort(.unprocessableEntity, reason: "Drawing bytes differ from the allocated source",
                            identifier: "drawing_source_mismatch")
            }
            return .init(workspaceId: project.workspaceId!, projectId: projectID, assetId: assetID,
                actorId: actorID, sha256: asset.sha256, byteCount: asset.byteCount,
                mimeType: asset.mimeType, processorProfile: asset.processorProfile)
        }
        _ = try await DrawingOriginalVerificationService.requireCurrentUpload(binding,
            runtime: runtime.identity, on: req.db)
        try await runtime.putOriginal(binding, bytes: bytes)
        _ = try await DrawingOriginalVerificationService.verifyStoredOriginal(binding,
            runtime: runtime.identity, reader: runtime, on: req.db)
        return try await CanonicalDrawingService.readAsset(assetID, projectID: projectID,
            actorID: actorID, on: req.db)
    }

    @Sendable func process(req: Request) async throws -> DrawingAssetRecord {
        let projectID = try id("projectId", req), assetID = try id("assetId", req)
        let actorID = try req.requireAuthenticatedUserId()
        let command = try req.content.decode(DrawingProcessCommand.self)
        let runtime = try CanonicalDrawingRuntimeAccess.require(req.application)
        let prepared: (Project, DrawingAssetRecord) = try await req.db.transaction { db in
            let project = try await editableProject(projectID, actorID: actorID, on: db)
            let asset = try await CanonicalDrawingService.asset(assetID, projectID: projectID, on: db)
            try CanonicalDrawingService.owned(asset, actorID: actorID)
            guard asset.processorProfile == runtime.identity.processorProfile else {
                throw Abort(.conflict, reason: "Drawing processor profile changed",
                            identifier: "drawing_processing_authority_changed")
            }
            if asset.state != "ready", asset.revision != command.expectedAssetRevision {
                throw Abort(.conflict, reason: "Drawing source changed; refresh before processing",
                            identifier: "drawing_source_changed")
            }
            return (project, asset)
        }
        if prepared.1.state == "ready" { return prepared.1 }
        let lease = try await CanonicalDrawingService.beginVerifiedProcessing(assetID: assetID,
            projectID: projectID, actorID: actorID, expectedRevision: command.expectedAssetRevision,
            on: req.db)
        let identity = DrawingProcessingIdentity(workspaceId: prepared.0.workspaceId!,
            projectId: projectID, assetId: assetID, actorId: actorID, leaseToken: lease.token,
            sourceSHA256: prepared.1.sha256, sourceBytes: prepared.1.byteCount,
            sourceMIME: prepared.1.mimeType, processorProfile: prepared.1.processorProfile)
        _ = try await DrawingProcessingAuthority.requireCurrent(identity, runtime: runtime.identity, on: req.db)
        let manifest = try await runtime.process(identity)
        _ = try await DrawingProcessingAuthority.requireCurrent(identity, runtime: runtime.identity, on: req.db)
        return try await CanonicalDrawingService.finishProcessing(lease, manifest: manifest, on: req.db)
    }

    @Sendable func publish(req: Request) async throws -> DrawingPublicationRecord {
        try await CanonicalDrawingService.publish(req.content.decode(DrawingPublishCommand.self),
            projectID: id("projectId", req), actorID: req.requireAuthenticatedUserId(), on: req.db)
    }

    @Sendable func pin(req: Request) async throws -> DrawingPinRecord {
        try await CanonicalDrawingService.setPin(req.content.decode(DrawingPinCommand.self),
            snagID: id("snagId", req), projectID: id("projectId", req),
            actorID: req.requireAuthenticatedUserId(), on: req.db)
    }
}
