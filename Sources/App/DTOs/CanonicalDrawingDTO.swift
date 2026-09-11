import Vapor
import FluentSQL

/// Internal foundation only. No HTTP route or sync coverage exposes these yet.
enum DrawingSourcePurpose: String, Codable, Sendable { case drawingSource = "drawing_source" }
struct DrawingAllocateCommand: Codable, Sendable {
    let mutation: MutationMetadata
    let id: UUID
    let purpose: DrawingSourcePurpose
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let originalFilename: String
}
struct DrawingSheetCommand: Codable, Equatable, Sendable {
    let id: UUID
    let versionId: UUID
    let versionPageId: UUID
    let name: String
    let sortOrder: Int
    let sourcePageIndex: Int
}
struct DrawingPublishCommand: Codable, Sendable {
    let mutation: MutationMetadata
    let assetId: UUID
    let expectedAssetRevision: Int64
    let acknowledgeInternalOriginalAccess: Bool
    let sheets: [DrawingSheetCommand]
}
struct DrawingPinTarget: Codable, Equatable, Sendable {
    let drawingId: UUID
    let versionId: UUID
    let versionPageId: UUID
    let x: Double
    let y: Double
}
struct DrawingPinCommand: Codable, Sendable {
    let mutation: MutationMetadata
    let expectedSnagRevision: Int64
    let expectedPinRevision: Int64
    let pin: DrawingPinTarget?
}
struct DrawingAssetRecord: Codable, Sendable {
    let id: UUID
    let projectId: UUID
    let uploaderId: UUID
    let state: String
    let revision: Int64
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let processorProfile: String
    let expiresAt: Date
    let publishedAt: Date?
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        projectId = try row.decode(column: "project_id", as: UUID.self)
        uploaderId = try row.decode(column: "uploader_id", as: UUID.self)
        state = try row.decode(column: "state", as: String.self)
        revision = try row.decode(column: "revision", as: Int64.self)
        sha256 = try row.decode(column: "original_sha256", as: String.self)
        byteCount = try row.decode(column: "original_size", as: Int.self)
        mimeType = try row.decode(column: "original_mime", as: String.self)
        processorProfile = try row.decode(column: "processor_profile", as: String.self)
        expiresAt = try row.decode(column: "expires_at", as: Date.self)
        publishedAt = try row.decode(column: "published_at", as: Date?.self)
    }
}
struct DrawingPublicationRecord: Codable, Sendable {
    let projectId: UUID
    let assetId: UUID
    let sheets: [DrawingSheetCommand]
}
struct DrawingPinRecord: Codable, Sendable {
    let snagId: UUID
    let projectId: UUID
    let revision: Int64
    let snagRevision: Int64
    let pin: DrawingPinTarget?
    let eventId: UUID
    let recordedBy: UUID
}

/// Trusted processor/storage output, not client-decoded input. This checkpoint
/// validates its manifest but does not implement byte storage or PDF processing.
struct DrawingProcessedPage: Encodable, Sendable {
    let sourcePageIndex: Int
    let sourcePageLabel: String
    let geometry: DrawingPageGeometry
    let renditionSHA256: String
    let renditionBytes: Int
    let thumbnailSHA256: String
    let thumbnailBytes: Int
}
struct DrawingPageGeometry: Codable, Equatable, Sendable {
    struct Box: Codable, Equatable, Sendable { let x: Double; let y: Double; let width: Double; let height: Double }
    let mediaBox: Box
    let cropBox: Box
    let displayBox: Box
    let rotation: Int
    let userUnit: Double
    let width: Int
    let height: Int
    let sourceToDisplay: [Double]
    let coordinateSystem: String
}
struct DrawingProcessingManifest: Encodable, Sendable {
    let sourceSHA256: String
    let sourceBytes: Int
    let sourceMIME: String
    let processorProfile: String
    let pages: [DrawingProcessedPage]
}
struct DrawingProcessingLease: Sendable {
    let assetId: UUID
    let projectId: UUID
    let actorId: UUID
    let token: UUID
    let expiresAt: Date
}
