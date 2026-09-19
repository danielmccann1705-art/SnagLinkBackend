import Fluent
import Vapor

// MARK: - Upload Controller
struct UploadController: RouteCollection {

    // Allowed image content types
    private static let allowedContentTypes: Set<String> = [
        "image/jpeg",
        "image/jpg",
        "image/png",
        "image/heic",
        "image/heif"
    ]

    // Maximum file size (10 MB)
    private static let maxFileSize = 10 * 1024 * 1024

    func boot(routes: RoutesBuilder) throws {
        let uploads = routes.grouped("api", "v1", "uploads")

        // Photo upload endpoint — requires JWT auth or magic link token
        uploads.on(.POST, "photo", body: .collect(maxSize: "10mb"), use: uploadPhoto)
    }

    // MARK: - Upload Photo

    /// POST /api/v1/uploads/photo
    /// Accepts multipart form data with a file field containing the image.
    /// Requires either JWT Bearer token or ?token= magic link token for auth.
    @Sendable
    func uploadPhoto(req: Request) async throws -> UploadPhotoResponse {
        // Authentication: require JWT or magic link token
        let principal: CompletionUploadObjectService.Principal
        var linkToken: String?
        if req.headers.bearerAuthorization != nil {
            let payload = try await JWTAuthMiddleware.authenticate(req)
            principal = .user(payload.userId)
        } else if let token = req.query[String.self, at: "token"] {
            let link = try await TokenValidationService.validateMagicLink(token: token, on: req.db)
            try PINSessionService.requireVerified(req, link: link)
            guard !link.previewMode, link.accessLevel != AccessLevel.view.rawValue else {
                throw Abort(.forbidden, reason: "This link does not allow photo uploads")
            }
            principal = .link(id: try link.requireID(), projectID: link.projectId, creatorID: link.createdById)
            linkToken = token
        } else {
            throw Abort(.unauthorized, reason: "Authentication required. Provide JWT or magic link token.")
        }

        // Parse multipart form data
        guard let file = try? req.content.decode(FileUpload.self).file else {
            throw Abort(.badRequest, reason: "No file provided. Use 'file' field in multipart form data.")
        }

        // Validate file extension
        let filename = file.filename.lowercased()
        let allowedExtensions = ["jpg", "jpeg", "png", "heic", "heif"]
        let fileExtension = filename.components(separatedBy: ".").last ?? ""

        guard allowedExtensions.contains(fileExtension) else {
            throw Abort(.badRequest, reason: "Invalid file type. Allowed types: JPEG, PNG, HEIC")
        }

        // Validate content type — only allow explicit whitelist, no wildcard fallback
        if let contentType = file.contentType?.description {
            let normalizedContentType = contentType.lowercased()
            guard Self.allowedContentTypes.contains(normalizedContentType) else {
                throw Abort(.badRequest, reason: "Invalid content type. Allowed: JPEG, PNG, HEIC")
            }
        }

        // Validate file size
        guard file.data.readableBytes <= Self.maxFileSize else {
            throw Abort(.payloadTooLarge, reason: "File too large. Maximum size is 10 MB.")
        }

        // Validate magic bytes to ensure file content matches claimed type
        let readableBytes = file.data.readableBytes
        if readableBytes >= 4 {
            let bytes = file.data.getBytes(at: file.data.readerIndex, length: 4) ?? []
            let isJPEG = bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
            let isPNG = bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
            let isHEIC = readableBytes >= 12  // HEIC/HEIF files have "ftyp" at bytes 4-7
            guard isJPEG || isPNG || isHEIC else {
                throw Abort(.badRequest, reason: "File content does not match an image format")
            }
        }

        let contentType = file.contentType?.description ?? "image/jpeg"
        let allocation = try await CompletionUploadObjectService.allocate(
            principal: principal, fileExtension: fileExtension, contentType: contentType,
            fileSize: file.data.readableBytes, on: req.db
        )
        let authenticatedLinkToken = linkToken
        let authorizeWrite: @Sendable (Database) async throws -> ObjectWriteIntentService.Scope = { db in
            // Preserve workspace→user/link lock ordering used by account closure.
            if case .link(_, let projectID, _) = principal,
               let workspaceID = try await Project.find(projectID, on: db)?.workspaceId {
                try await WorkspaceAccessService.lock(workspaceID, on: db)
            }
            if let token = authenticatedLinkToken {
                let current = try await TokenValidationService.validateMagicLink(token: token, on: db)
                try PINSessionService.requireVerified(req, link: current)
                guard CompletionUploadObjectService.Principal.link(id: try current.requireID(), projectID: current.projectId, creatorID: current.createdById) == principal else {
                    throw Abort(.forbidden, reason: "This link does not allow photo uploads")
                }
            } else {
                let current = try await JWTAuthMiddleware.authenticate(req, on: db)
                guard principal == .user(current.userId) else { throw Abort(.unauthorized) }
            }
            try await CompletionUploadObjectService.lockForWrite(allocation, on: db)
            switch principal {
            case .user(let userID): return .init(userID: userID)
            case .link(let linkID, let projectID, let creatorID):
                let project = try await Project.find(projectID, on: db)
                return .init(userID: creatorID, workspaceID: project?.workspaceId, projectID: projectID, magicLinkID: linkID)
            }
        }
        let source = ObjectWriteIntentService.Source(kind: "completion_upload", id: allocation.id)
        let rawData = Data(buffer: file.data)
        try await ObjectWriteIntentService.write(.init(storageKind: "legacy_completion_photo", key: allocation.storageKey, data: rawData, contentType: contentType), source: source, on: req.db, authorize: authorizeWrite) {
            try await StorageService.upload(data: file.data, key: allocation.storageKey, contentType: contentType, app: req.application)
        }
        let thumbnailGenerated = await ThumbnailService.generateAndUpload(originalData: rawData, thumbnailKey: allocation.thumbnailKey,
            app: req.application, logger: req.logger, upload: { data in
                try await ObjectWriteIntentService.write(.init(storageKind: "legacy_completion_photo", key: allocation.thumbnailKey, data: data, contentType: "image/jpeg"), source: source, on: req.db, authorize: authorizeWrite) {
                    try await StorageService.upload(data: ByteBuffer(data: data), key: allocation.thumbnailKey, contentType: "image/jpeg", app: req.application)
                }
            })
        try await req.db.transaction { db in
            _ = try await authorizeWrite(db)
            try await CompletionUploadObjectService.markReady(allocation, thumbnailReady: thumbnailGenerated, on: db)
        }
        let thumbnailUrl = thumbnailGenerated ? allocation.plannedThumbnailURL : allocation.issuedURL

        req.logger.info("Photo uploaded: \(allocation.filename), thumbnail: \(thumbnailGenerated ? "yes" : "fallback to original")")

        return UploadPhotoResponse(
            url: allocation.issuedURL,
            thumbnailUrl: thumbnailUrl,
            filename: allocation.filename,
            size: file.data.readableBytes
        )
    }

}

// MARK: - Request/Response DTOs

struct FileUpload: Content {
    var file: File
}

struct UploadPhotoResponse: Content {
    let url: String
    let thumbnailUrl: String
    let filename: String
    let size: Int
}
