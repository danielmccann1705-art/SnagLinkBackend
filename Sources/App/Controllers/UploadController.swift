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
        let isJWTAuth = req.headers.bearerAuthorization != nil &&
            (try? req.jwt.verify(as: UserJWTPayload.self)) != nil
        var isTokenAuth = false
        if !isJWTAuth {
            if let token = req.query[String.self, at: "token"] {
                _ = try await TokenValidationService.validateMagicLink(token: token, on: req.db)
                isTokenAuth = true
            }
        }
        guard isJWTAuth || isTokenAuth else {
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

        // Generate unique filename
        let uuid = UUID().uuidString
        let newFilename = "\(uuid).\(fileExtension)"

        // Determine upload directory
        let uploadDir = getUploadDirectory()

        // Create directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: uploadDir) {
            try fileManager.createDirectory(
                atPath: uploadDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // Save file to disk
        let filePath = uploadDir + "/" + newFilename
        try await req.fileio.writeFile(file.data, at: filePath)

        // Generate URLs
        let baseUrl = getBaseUrl(req: req)
        let url = "\(baseUrl)/uploads/photos/\(newFilename)"
        let thumbnailUrl = "\(baseUrl)/uploads/photos/thumb_\(newFilename)"

        req.logger.info("Photo uploaded: \(newFilename)")

        return UploadPhotoResponse(
            url: url,
            thumbnailUrl: thumbnailUrl,
            filename: newFilename,
            size: file.data.readableBytes
        )
    }

    // MARK: - Helper Methods

    private func getUploadDirectory() -> String {
        if let uploadPath = Environment.get("UPLOAD_PATH") {
            return uploadPath
        }
        return "./Public/uploads/photos"
    }

    private func getBaseUrl(req: Request) -> String {
        if let baseUrl = Environment.get("BASE_URL") {
            return baseUrl
        }

        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "http"
        let host = req.headers.first(name: "Host") ?? "localhost:8080"
        return "\(scheme)://\(host)"
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
