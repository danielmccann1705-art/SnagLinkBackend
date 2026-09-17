import Vapor
import Fluent
import FluentSQL

struct ContractorGrantController: RouteCollection {
    struct PINCommand: Content { let pin: String }
    struct PINResult: Content { let verified: Bool; let expiresAt: Date }
    struct PhotoResult: Content {
        let id: UUID; let state: String; let width: Int?; let height: Int?; let intentId: UUID?
        init(_ media: MediaAssetResponse) { id = media.id; state = media.state; width = media.width; height = media.height; intentId = media.intentId }
    }
    private struct Upload: Sendable { let media: MediaAssetResponse; let originalKey: String }
    func boot(routes: RoutesBuilder) throws {
        routes.get("assets", "contractor", "v2", ":name", use: resource)
        let grant = routes.grouped("api", "v2", "contractor", ":token").grouped(ContractorErrorBoundary())
        grant.get(use: read)
        grant.post("verify-pin", use: verifyPIN)
        let snag = grant.grouped("snags", ":snagId")
        for action in [WorkflowAction.start, .submit] {
            snag.post("workflow", PathComponent(stringLiteral: action.rawValue)) { req async throws -> ContractorWorkflowResult in try await self.workflow(req, action: action) }
        }
        snag.post("media", use: allocate)
        snag.on(.PUT, "media", ":assetId", "content", body: .collect(maxSize: "10mb"), use: upload)
        snag.get("media", ":assetId", "content", use: download)
    }
    @Sendable func resource(req: Request) async throws -> Response {
        let types = ["contractor.js": "text/javascript; charset=utf-8", "contractor.css": "text/css; charset=utf-8", "tokens.css": "text/css; charset=utf-8", "wordmark-light.svg": "image/svg+xml", "IBMPlexSans-Regular.ttf": "font/ttf", "IBMPlexSans-Medium.ttf": "font/ttf", "IBMPlexSans-Bold.ttf": "font/ttf", "IBMPlexMono-Regular.ttf": "font/ttf", "OFL.txt": "text/plain; charset=utf-8"]
        guard let name = req.parameters.get("name"), let mime = types[name], let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Contractor") else { throw Abort(.notFound) }
        return try Response(status: .ok, headers: ["Content-Type": mime, "Cache-Control": "public, max-age=3600", "X-Content-Type-Options": "nosniff"], body: .init(data: Data(contentsOf: url)))
    }
    static func token(_ req: Request) throws -> String {
        guard let token = req.parameters.get("token") ?? req.parameters.get("slug") else { throw Abort(.notFound) }; return token
    }
    @Sendable func read(req: Request) async throws -> ContractorPage {
        let token = try Self.token(req), page = try req.query.get(Int?.self, at: "page") ?? 1
        guard (1...1000).contains(page) else { throw Abort(.badRequest) }
        return try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            return try await LinkGrantService.page(grant, project: project, page: page, on: db)
        }
    }
    @Sendable func verifyPIN(req: Request) async throws -> Response {
        try LinkGrantService.requireWrite(req)
        let token = try Self.token(req), body = try req.content.decode(PINCommand.self)
        guard body.pin.count <= 8 else { throw Abort(.badRequest, reason: "Enter the supplied PIN") }
        // Failure counters must COMMIT. Throwing inside this transaction would
        // roll them back and permit unlimited guesses.
        let outcome: (UUID, String?, Date, Bool) = try await req.db.transaction { db in
            let (grant, _) = try await LinkGrantService.load(token, req: req, verifySession: false, on: db)
            let id = try grant.decode(column: "id", as: UUID.self), now = Date(), sql = try VerifiedIdentityService.sql(db)
            let expiry = min(now.addingTimeInterval(7200), try grant.decode(column: "expires_at", as: Date.self))
            if let locked = try grant.decode(column: "pin_locked_until", as: Date?.self), locked > now { return (id, nil, locked, true) }
            guard let hash = try grant.decode(column: "pin_hash", as: String?.self) else { return (id, nil, expiry, false) }
            let valid = try await req.password.async.verify(body.pin, created: hash)
            if !valid {
                let wasLocked = try grant.decode(column: "pin_locked_until", as: Date?.self) != nil
                let failures = (wasLocked ? 0 : try grant.decode(column: "pin_failures", as: Int.self)) + 1
                let lock: Date? = failures >= 5 ? now.addingTimeInterval(900) : nil
                try await sql.raw("UPDATE link_grants SET pin_failures = \(bind: failures), pin_locked_until = \(bind: lock) WHERE id = \(bind: id)").run()
                return (id, nil, lock ?? now, failures >= 5)
            }
            try await sql.raw("UPDATE link_grants SET pin_failures = 0, pin_locked_until = NULL WHERE id = \(bind: id)").run()
            // Bound retained sessions; old expired sessions carry no authority.
            try await sql.raw("DELETE FROM link_sessions WHERE grant_id = \(bind: id) AND expires_at <= \(bind: now)").run()
            let count = try await sql.raw("SELECT count(*) AS n FROM link_sessions WHERE grant_id = \(bind: id)").first()!.decode(column: "n", as: Int.self)
            guard count < 100 else { throw Abort(.tooManyRequests, reason: "This link has too many active sessions. Try again later") }
            let session = try SecureTokenGenerator.generate(byteCount: 32)
            try await sql.raw("INSERT INTO link_sessions (token_hash, grant_id, expires_at, created_at) VALUES (\(bind: SHA256Hasher.hash(token: session)), \(bind: id), \(bind: expiry), \(bind: now))").run()
            return (id, session, expiry, false)
        }
        if outcome.3 { throw Abort(.tooManyRequests, headers: ["Retry-After": "900"], reason: "Too many PIN attempts. Try again in 15 minutes") }
        guard let session = outcome.1 else { throw Abort(.forbidden, reason: "That PIN was not accepted", identifier: "pin_not_accepted") }
        let response = Response(status: .ok)
        try response.content.encode(PINResult(verified: true, expiresAt: outcome.2))
        response.cookies[LinkGrantService.cookieName(outcome.0)] = .init(string: session, expires: outcome.2, maxAge: max(0, Int(outcome.2.timeIntervalSinceNow)), path: "/", isSecure: true, isHTTPOnly: true, sameSite: .lax)
        return response
    }
    @Sendable private func workflow(_ req: Request, action: WorkflowAction) async throws -> ContractorWorkflowResult {
        try LinkGrantService.requireWrite(req)
        let token = try Self.token(req), snagID = try LinkGrantController.id("snagId", req), body = try req.content.decode(WorkflowCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "contractor:\(snagID):\(action.rawValue)")
        return try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            let snag = try await LinkGrantService.item(snagID, grant: grant, project: project, write: true, on: db), id = try grant.decode(column: "id", as: UUID.self)
            if let old = try await LinkGrantService.replay(ContractorWorkflowResult.self, grantID: id, mutation: body.mutation, hash: hash, on: db) { return old }
            let response = try await CanonicalWorkflowService.execute(body, action: action, snag: snag, project: project, actorID: nil, grantID: id, actions: [.submitCompletion], on: db)
            let result = ContractorWorkflowResult(response)
            try await LinkGrantService.record(result, grantID: id, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    @Sendable func allocate(req: Request) async throws -> PhotoResult {
        try LinkGrantService.requireWrite(req); try StorageService.requirePrivateStorage(app: req.application)
        let token = try Self.token(req), snagID = try LinkGrantController.id("snagId", req), body = try req.content.decode(MediaAllocateCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "contractor:\(snagID):media")
        return try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            let snag = try await LinkGrantService.item(snagID, grant: grant, project: project, write: true, on: db), id = try grant.decode(column: "id", as: UUID.self)
            if let old = try await LinkGrantService.replay(PhotoResult.self, grantID: id, mutation: body.mutation, hash: hash, on: db) { return old }
            let media = try await PrivateMediaService.allocate(body, snag: snag, project: project, actorID: nil, grantID: id, on: db)
            let result = PhotoResult(media)
            try await LinkGrantService.record(result, grantID: id, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    @Sendable func upload(req: Request) async throws -> PhotoResult {
        try LinkGrantService.requireWrite(req)
        let token = try Self.token(req), snagID = try LinkGrantController.id("snagId", req), assetID = try LinkGrantController.id("assetId", req)
        guard let bytes = req.body.data else { throw Abort(.badRequest, reason: "Photo bytes are missing") }; let data = Data(buffer: bytes)
        let upload: Upload = try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            let snag = try await LinkGrantService.item(snagID, grant: grant, project: project, write: true, on: db)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: project.requireID(), on: db)
            try PrivateMediaService.requireUploader(row, actorID: nil, grantID: grant.decode(column: "id", as: UUID.self))
            let media = try MediaAssetResponse(row)
            if media.state != "ready" { try PrivateMediaService.submittable(snag) }
            guard data.count == media.byteCount, PrivateImageProcessor.digest(data) == media.originalSHA256, req.headers.contentType?.description == media.mimeType else { throw Abort(.unprocessableEntity, reason: "This photo differs from the original upload. Choose it again", identifier: "media_mismatch") }
            return try .init(media: media, originalKey: row.decode(column: "original_key", as: String.self))
        }
        if upload.media.state == "ready" { return .init(upload.media) }
        let processed = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) { try PrivateImageProcessor.process(data, mime: upload.media.mimeType) }.get()
        let sha = PrivateImageProcessor.digest(processed.jpeg), key = String(upload.originalKey.dropLast("original".count)) + "view-\(sha).jpg"
        try await StorageService.uploadPrivate(data, key: upload.originalKey, mime: upload.media.mimeType, app: req.application)
        try await StorageService.uploadPrivate(processed.jpeg, key: key, mime: "image/jpeg", app: req.application)
        return try await req.db.transaction { db in
            // Recheck grant, PIN, assignment and uploader AFTER processing/storage.
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            let snag = try await LinkGrantService.item(snagID, grant: grant, project: project, write: true, on: db)
            let row = try await PrivateMediaService.row(assetID, snagID: snagID, projectID: project.requireID(), on: db)
            try PrivateMediaService.requireUploader(row, actorID: nil, grantID: grant.decode(column: "id", as: UUID.self))
            if try row.decode(column: "state", as: String.self) == "ready" { return try .init(MediaAssetResponse(row)) }
            try PrivateMediaService.submittable(snag)
            try await VerifiedIdentityService.sql(db).raw("UPDATE media_assets SET state = 'ready', revision = revision + 1, ready_at = \(bind: Date()), rendition_key = \(bind: key), rendition_sha256 = \(bind: sha), rendition_size = \(bind: processed.jpeg.count), width = \(bind: processed.width), height = \(bind: processed.height) WHERE id = \(bind: assetID)").run()
            return try await .init(MediaAssetResponse(PrivateMediaService.row(assetID, snagID: snagID, projectID: project.requireID(), on: db)))
        }
    }
    @Sendable func download(req: Request) async throws -> Response {
        let token = try Self.token(req), snagID = try LinkGrantController.id("snagId", req), assetID = try LinkGrantController.id("assetId", req)

        // A snag carried over from the old app keeps its photos in the import tables,
        // not in `media_assets`. Resolve that case explicitly rather than by letting the
        // media lookup fail and catching it: a not-found here is a real refusal, and it
        // should not become control flow.
        let store = try LegacyImportCommitController.store(req)
        if let imported = try await (req.db.transaction { db -> (key: ImportedObjectKey, sha256: String, size: Int64, mime: String)? in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            return try await LinkGrantService.visibleImportedPhoto(assetID, snagID: snagID, grant: grant, project: project, on: db)
        }) {
            let value = try await LegacyImportReadService.verifiedBytes(imported, store: store)
            // Storage IO ran outside the grant's locks; recheck before disclosure.
            try await req.db.transaction { db in
                let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
                guard try await LinkGrantService.visibleImportedPhoto(assetID, snagID: snagID, grant: grant, project: project, on: db) != nil else {
                    throw Abort(.notFound)
                }
            }
            return Response(status: .ok, headers: ["Content-Type": value.mime, "Content-Length": String(value.data.count), "Cache-Control": "private, no-store", "Vary": "Cookie", "Content-Disposition": "inline; filename=snag-photo.jpg", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"], body: .init(data: value.data))
        }

        let target: (String, String) = try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            let media = try await LinkGrantService.visibleMedia(assetID, snagID: snagID, grant: grant, project: project, on: db)
            return try (media.decode(column: "rendition_key", as: String.self), media.decode(column: "rendition_sha256", as: String.self))
        }
        let bytes: Data
        do { bytes = try await StorageService.downloadPrivate(key: target.0, app: req.application) }
        catch { throw Abort(.serviceUnavailable, reason: "This photo is temporarily unavailable. Try again", identifier: "media_unavailable") }
        guard PrivateImageProcessor.digest(bytes) == target.1 else { throw Abort(.serviceUnavailable, reason: "This photo could not be verified") }
        try await req.db.transaction { db in
            let (grant, project) = try await LinkGrantService.load(token, req: req, on: db)
            _ = try await LinkGrantService.visibleMedia(assetID, snagID: snagID, grant: grant, project: project, on: db)
        }
        return Response(status: .ok, headers: ["Content-Type": "image/jpeg", "Cache-Control": "private, no-store", "Vary": "Cookie", "Content-Disposition": "inline; filename=snag-photo.jpg", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"], body: .init(data: bytes))
    }
}

/// Conflict responses for a capability must not expose the manager-only snag DTO.
private struct ContractorErrorBoundary: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: req) }
        catch is RevisionConflict { throw Abort(.conflict, reason: "This snag changed. Your notes are retained; check the latest details before trying again", identifier: "revision_conflict") }
        catch is WorkflowConflict { throw Abort(.conflict, reason: "This submission changed. Your notes are retained; check the latest review before trying again", identifier: "workflow_conflict") }
    }
}
