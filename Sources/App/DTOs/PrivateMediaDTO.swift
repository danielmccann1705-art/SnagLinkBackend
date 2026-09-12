import Vapor
import FluentSQL

struct MediaAllocateCommand: Content {
    let mutation: MutationMetadata
    let id: UUID
    let expectedRevision: Int64
    let purpose: String
    let intentId: UUID?
    let sha256: String
    let byteCount: Int
    let mimeType: String
}

/// Exact bytes returned by one authenticated manager gateway. No storage key or
/// reusable object URL crosses this contract.
struct MediaRenditionDescriptor: Content {
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let contentPath: String
}

struct MediaAssetResponse: Content {
    let id: UUID
    let projectId: UUID
    let snagId: UUID
    let purpose: String
    let intentId: UUID?
    let state: String
    let revision: Int64
    let originalSHA256: String
    let byteCount: Int
    let mimeType: String
    let width: Int?
    let height: Int?
    let createdAt: Date
    let expiresAt: Date
    let attachedAt: Date?
    /// Relative, authenticated gateway. Never an R2 URL or token.
    let contentPath: String?
    /// Optional for old immutable receipts/snapshots and assets not yet ready.
    /// Fresh ready responses require both descriptors. Existing contentPath
    /// remains the processed JPEG route for older clients.
    let original: MediaRenditionDescriptor?
    let processed: MediaRenditionDescriptor?

    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        projectId = try row.decode(column: "project_id", as: UUID.self)
        snagId = try row.decode(column: "snag_id", as: UUID.self)
        purpose = try row.decode(column: "purpose", as: String.self)
        intentId = try row.decode(column: "intent_id", as: UUID?.self)
        state = try row.decode(column: "state", as: String.self)
        revision = try row.decode(column: "revision", as: Int64.self)
        originalSHA256 = try row.decode(column: "original_sha256", as: String.self)
        byteCount = try row.decode(column: "original_size", as: Int.self)
        mimeType = try row.decode(column: "original_mime", as: String.self)
        width = try row.decode(column: "width", as: Int?.self)
        height = try row.decode(column: "height", as: Int?.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        expiresAt = try row.decode(column: "expires_at", as: Date.self)
        attachedAt = try row.decode(column: "attached_at", as: Date?.self)
        contentPath = state == "ready" ? "/api/v2/projects/\(projectId)/snags/\(snagId)/media/\(id)/content" : nil
        if let contentPath {
            guard let sha = try row.decode(column: "rendition_sha256", as: String?.self),
                  sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let size = try row.decode(column: "rendition_size", as: Int?.self), size > 0 else {
                throw Abort(.serviceUnavailable, reason: "Photo verification details are unavailable. The original has been retained; this photo needs repair before it can finish syncing", identifier: "media_metadata_unavailable")
            }
            original = .init(sha256: originalSHA256, byteCount: byteCount, mimeType: mimeType,
                             contentPath: "/api/v2/projects/\(projectId)/snags/\(snagId)/media/\(id)/original")
            processed = .init(sha256: sha, byteCount: size, mimeType: "image/jpeg", contentPath: contentPath)
        } else {
            original = nil
            processed = nil
        }
    }
}
