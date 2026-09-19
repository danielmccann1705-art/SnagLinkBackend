import Vapor
import Fluent
import FluentSQL

struct PrivateMediaController: RouteCollection {
    struct Page: Content { let items: [MediaAssetResponse]; let page: Int; let hasMore: Bool }
    private struct Upload: Sendable {
        let response: MediaAssetResponse
        let originalKey: String
    }
    func boot(routes: RoutesBuilder) throws {
        let media = routes.grouped("api", "v2", "projects", ":projectId", "snags", ":snagId", "media").grouped(PlatformAuthMiddleware())
        media.get(use: list)
        media.post(use: allocate)
        media.get(":assetId", use: get)
        media.on(.PUT, ":assetId", "content", body: .collect(maxSize: "10mb"), use: upload)
        media.get(":assetId", "content", use: download)
        media.get(":assetId", "original", use: downloadOriginal)
        media.post(":assetId", "attach", use: attach)
    }
    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func list(req: Request) async throws -> Page {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let page = try req.query.get(Int?.self, at: "page") ?? 1
        guard (1...1000).contains(page) else { throw Abort(.badRequest, reason: "Invalid media page") }
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            _ = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let rows = try await VerifiedIdentityService.sql(db).raw("""
                SELECT * FROM media_assets WHERE project_id = \(bind: projectID) AND snag_id = \(bind: snagID) AND state != 'retired'
                AND (attached_at IS NOT NULL OR (creator_id = \(bind: actorID) AND expires_at > \(bind: Date())))
                ORDER BY created_at, id LIMIT 51 OFFSET \(bind: (page - 1) * 50)
                """).all()
            return try .init(items: rows.prefix(50).map(MediaAssetResponse.init), page: page, hasMore: rows.count > 50)
        }
    }
    @Sendable func get(req: Request) async throws -> MediaAssetResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), assetID = try id("assetId", req), actorID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            if try row.decode(column: "attached_at", as: Date?.self) == nil { try PrivateMediaService.requireUploader(row, actorID: actorID) }
            return try .init(row)
        }
    }
    @Sendable func allocate(req: Request) async throws -> MediaAssetResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(MediaAllocateCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "POST:\(req.url.path)")
        try StorageService.requirePrivateStorage(app: req.application)
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: body.mutation, on: db)
            let (project, _) = try await ProjectAccessService.require(body.purpose == "completion" ? .submitCompletion : .edit, projectID: projectID, actorID: actorID, on: db)
            if let old = try await PlatformMutationService.replay(MediaAssetResponse.self, actorID: actorID, mutation: body.mutation, hash: hash, on: db) { return old }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let result = try await PrivateMediaService.allocate(body, snag: snag, project: project, actorID: actorID, on: db)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    /// The immutable allocation (asset UUID + hash + size + purpose + creator)
    /// is the retry identity for binary PUT. A different payload never overwrites it.
    @Sendable func upload(req: Request) async throws -> MediaAssetResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), assetID = try id("assetId", req), actorID = try req.requireAuthenticatedUserId()
        guard let buffer = req.body.data else { throw Abort(.badRequest, reason: "Photo bytes are missing") }
        let data = Data(buffer: buffer)
        let prepared: Upload = try await req.db.transaction { db in
            let (project, actions) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            try PrivateMediaService.requireUploader(row, actorID: actorID)
            let response = try MediaAssetResponse(row)
            guard actions.contains(response.purpose == "completion" ? .submitCompletion : .edit) else { throw Abort(.forbidden) }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            try PrivateMediaService.available(snag)
            // A repeat after attachment may retrieve the successful result even
            // after acceptance; it cannot append evidence or change workflow.
            if response.purpose == "completion", response.state != "ready" { try PrivateMediaService.submittable(snag) }
            guard response.byteCount == data.count, response.originalSHA256 == PrivateImageProcessor.digest(data),
                  req.headers.contentType?.description == response.mimeType else {
                throw Abort(.unprocessableEntity, reason: "Photo bytes differ from the allocated size, checksum or type", identifier: "media_mismatch")
            }
            return try .init(response: response, originalKey: row.decode(column: "original_key", as: String.self))
        }
        if prepared.response.state == "ready" { return prepared.response }
        let processed = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
            try PrivateImageProcessor.process(data, mime: prepared.response.mimeType)
        }.get()
        let renditionSHA = PrivateImageProcessor.digest(processed.jpeg)
        let renditionKey = String(prepared.originalKey.dropLast("original".count)) + "view-\(renditionSHA).jpg"
        let authorizeWrite: @Sendable (Database) async throws -> ObjectWriteIntentService.Scope = { db in
            let (project, actions) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            try PrivateMediaService.requireUploader(row, actorID: actorID)
            guard actions.contains(prepared.response.purpose == "completion" ? .submitCompletion : .edit),
                  try row.decode(column: "original_key", as: String.self) == prepared.originalKey else { throw Abort(.forbidden) }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            try PrivateMediaService.available(snag)
            if prepared.response.purpose == "completion" { try PrivateMediaService.submittable(snag) }
            return .init(userID: actorID, workspaceID: project.workspaceId, projectID: projectID)
        }
        let source = ObjectWriteIntentService.Source(kind: "media_asset", id: assetID)
        try await ObjectWriteIntentService.write(.init(storageKind: "private_media", key: prepared.originalKey, data: data, contentType: prepared.response.mimeType), source: source, on: req.db, authorize: authorizeWrite) {
            try await StorageService.uploadPrivate(data, key: prepared.originalKey, mime: prepared.response.mimeType, app: req.application)
        }
        try await ObjectWriteIntentService.write(.init(storageKind: "private_media", key: renditionKey, data: processed.jpeg, contentType: "image/jpeg"), source: source, on: req.db, authorize: authorizeWrite) {
            try await StorageService.uploadPrivate(processed.jpeg, key: renditionKey, mime: "image/jpeg", app: req.application)
        }
        // Processing/storage occur outside membership locks. Revalidate before
        // committing readiness; revocation cannot be bypassed by an in-flight PUT.
        return try await req.db.transaction { db in
            let (project, actions) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            try PrivateMediaService.requireUploader(row, actorID: actorID)
            guard actions.contains(prepared.response.purpose == "completion" ? .submitCompletion : .edit) else { throw Abort(.forbidden) }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            try PrivateMediaService.available(snag)
            if try row.decode(column: "state", as: String.self) == "ready" { return try .init(row) }
            if prepared.response.purpose == "completion" { try PrivateMediaService.submittable(snag) }
            try await VerifiedIdentityService.sql(db).raw("""
                UPDATE media_assets SET state = 'ready', revision = revision + 1, ready_at = \(bind: Date()),
                    rendition_key = \(bind: renditionKey), rendition_sha256 = \(bind: renditionSHA), rendition_size = \(bind: processed.jpeg.count), width = \(bind: processed.width), height = \(bind: processed.height)
                WHERE id = \(bind: assetID)
                """).run()
            return try await .init(PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db))
        }
    }
    @Sendable func attach(req: Request) async throws -> PlatformSnagResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), assetID = try id("assetId", req), actorID = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(SnagPublishCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "POST:\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: body.mutation, on: db)
            let (project, _) = try await ProjectAccessService.require(.edit, projectID: projectID, actorID: actorID, on: db)
            if let old = try await PlatformMutationService.replay(PlatformSnagResponse.self, actorID: actorID, mutation: body.mutation, hash: hash, on: db) { return old }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            let result = try await PrivateMediaService.attach(row, command: body, snag: snag, project: project, actorID: actorID, on: db)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    @Sendable func download(req: Request) async throws -> Response {
        try await download(req: req, original: false)
    }
    @Sendable func downloadOriginal(req: Request) async throws -> Response {
        try await download(req: req, original: true)
    }
    /// Originals remain behind manager authentication. Contractor routes continue
    /// to expose only their selected processed evidence through their own policy.
    @Sendable private func download(req: Request, original: Bool) async throws -> Response {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), assetID = try id("assetId", req), actorID = try req.requireAuthenticatedUserId()
        let target: (key: String, sha256: String, size: Int, mime: String) = try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db)
            try PrivateMediaService.requireVisible(row, actorID: actorID)
            let prefix = original ? "original" : "rendition"
            guard let sha = try row.decode(column: prefix + "_sha256", as: String?.self),
                  sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let size = try row.decode(column: prefix + "_size", as: Int?.self), size > 0 else {
                throw Abort(.serviceUnavailable, reason: "Photo verification details are unavailable. This photo needs repair before it can finish syncing", identifier: "media_metadata_unavailable")
            }
            return try (row.decode(column: prefix + "_key", as: String.self), sha, size,
                        original ? row.decode(column: "original_mime", as: String.self) : "image/jpeg")
        }
        let data: Data
        do { data = try await StorageService.downloadPrivate(key: target.key, app: req.application) }
        catch { throw Abort(.serviceUnavailable, reason: "This photo is temporarily unavailable. Try again", identifier: "media_unavailable") }
        guard data.count == target.size, PrivateImageProcessor.digest(data) == target.sha256 else { throw Abort(.serviceUnavailable, reason: "Photo integrity check failed", identifier: "media_unavailable") }
        // No long-lived signed URL. Check again after fetching bytes so a removed
        // member cannot complete a slow download after its access has been revoked.
        try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            try await PrivateMediaService.requireVisible(PrivateMediaService.row(assetID, snagID: snagID, projectID: projectID, on: db), actorID: actorID)
        }
        let filename = original ? "snag-photo-original." + (target.mime == "image/png" ? "png" : "jpg") : "snag-photo.jpg"
        return Response(status: .ok, headers: ["Content-Type": target.mime, "Cache-Control": "private, no-store", "Vary": "Cookie, Authorization", "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline; filename=\(filename)", "Referrer-Policy": "no-referrer"], body: .init(data: data))
    }
}
