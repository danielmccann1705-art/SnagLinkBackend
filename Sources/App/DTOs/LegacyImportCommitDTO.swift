import Vapor
import FluentSQL

/// Separately acknowledged publication of one privately prepared projection. This is
/// not the frozen source receipt and never changes `staged_legacy_imports.state`.
struct LegacyImportCommitCommand: Codable, Sendable {
    struct Acknowledgement: Codable, Equatable, Sendable {
        static let supportedVersion = "selected-project-publication-v1"
        static let supportedWording = "Publish this prepared project to the selected workspace as a shared project. Its records and transferred files become visible to everyone with access to that workspace project. Historical statuses, closure, authors and dates are imported as unverified legacy values; publishing does not approve any work."
        let version: String
        let wording: String
        let accepted: Bool
    }
    let commitId: UUID
    let scope: StagedLegacyImportScope
    let projectionId: UUID
    let operationId: UUID
    let expectedSourceRevision: Int64
    /// The exact prepared graph the actor reviewed. A different regenerated graph conflicts.
    let expectedGraphSHA256: String
    let acknowledgement: Acknowledgement
}

/// Explicit versioned projection policies applied during publication.
enum LegacyImportPublicationPolicy {
    static let version = "selected-project-publication-v1"
    static let policies = [
        "identity: source project/snag/photo/drawing/comment/history/folder/tag/contractor/trade UUIDs are retained as canonical IDs",
        "workflow: display status uses the v1.1 compatibility mapping; non-open or closed source states carry workflow_qualification=legacy_unverified with closed_at left empty",
        "dates: source instants are retained; due_on is derived from the workspace timezone (due-on-derived-from-workspace-timezone-v1); project calendar intent stays unset",
        "money: source doubles are retained beside exact decimal strings when representable",
        "files: original bytes are the retained staged originals; image renditions are freshly decoded metadata-free JPEGs; undecodable originals remain opaque",
        "drawings: only single-page raster originals are rendered as sheets (rendered_single_raster_v1); other originals remain opaque files with source pin coordinates retained on the snag",
        "history: comments, status changes and deletion receipts are typed imported history rows, never authenticated comments, attempts or decisions",
        "directory: contractor/trade/folder/tag reuse requires the same source lineage, unchanged intrinsic digest and unchanged published canonical content",
    ]
}

struct LegacyImportCommitReceipt: Codable, Sendable {
    let formatVersion: Int
    let commitId: UUID
    let sessionId: UUID
    let projectionId: UUID
    let operationId: UUID
    let deviceId: UUID
    let actorId: UUID
    let workspaceId: UUID
    let projectId: UUID
    let graphSHA256: String
    let acknowledgementVersion: String
    let policyVersion: String
    let state: String
    let transactionGroup: UUID
    let firstSequence: Int64
    let lastSequence: Int64
    let journalEventCount: Int
    let publishedCounts: [String: Int]
    let reusedDirectoryCount: Int
    let renderedDrawingCount: Int
    let opaqueDrawingCount: Int
    let decodedFileCount: Int
    let opaqueFileCount: Int
    let qualificationCounts: [String: Int]
    let coverage: [String]
    let createdAt: Date
}

/// Actor-private preparation status combining projection and file processing.
struct LegacyImportPreparationStatus: Codable, Sendable {
    let projection: LegacyCanonicalProjectionReceipt
    let declaredFileCount: Int
    let receivedFileCount: Int
    let processedFileCount: Int
    let decodedImageCount: Int
    let opaqueFileCount: Int
    let renderedDrawingCount: Int
    let unsupportedDrawingCount: Int
    let missingRequiredFileCount: Int
    let blockers: [LegacyCanonicalProjection.Finding]
    let qualifications: [LegacyCanonicalProjection.Finding]
    let readyToPublish: Bool
    let commit: LegacyImportCommitReceipt?
}

/// Typed readback of one imported file object. Content paths are authenticated
/// project gateways, never storage keys or source paths.
struct ImportedFileResponse: Content {
    let id: UUID
    let projectId: UUID
    let sha256: String
    let byteCount: Int64
    let decodedMime: String?
    let width: Int?
    let height: Int?
    let revision: Int64
    let original: MediaRenditionDescriptor
    let rendition: MediaRenditionDescriptor?
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        projectId = try row.decode(column: "project_id", as: UUID.self)
        sha256 = try row.decode(column: "sha256", as: String.self)
        byteCount = try row.decode(column: "bytes", as: Int64.self)
        decodedMime = try row.decode(column: "decoded_mime", as: String?.self)
        width = try row.decode(column: "width", as: Int?.self)
        height = try row.decode(column: "height", as: Int?.self)
        revision = try row.decode(column: "revision", as: Int64.self)
        original = .init(sha256: sha256, byteCount: Int(clamping: byteCount), mimeType: decodedMime ?? "application/octet-stream",
                         contentPath: "/api/v2/projects/\(projectId)/imported-files/\(id)/original")
        if let sha = try row.decode(column: "rendition_sha256", as: String?.self), let size = try row.decode(column: "rendition_size", as: Int?.self) {
            rendition = .init(sha256: sha, byteCount: size, mimeType: "image/jpeg", contentPath: "/api/v2/projects/\(projectId)/imported-files/\(id)/rendition")
        } else { rendition = nil }
    }
}
struct ImportedFileUseResponse: Content {
    let id: UUID; let projectId: UUID; let kind: String; let sourceId: UUID; let role: String; let position: Int
    let required: Bool; let availability: String; let fileId: UUID?; let usedLegacyDrawingLocation: Bool
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self)
        kind = try row.decode(column: "kind", as: String.self); sourceId = try row.decode(column: "source_id", as: UUID.self)
        role = try row.decode(column: "role", as: String.self); position = try row.decode(column: "position", as: Int.self)
        required = try row.decode(column: "required", as: Bool.self); availability = try row.decode(column: "availability", as: String.self)
        fileId = try row.decode(column: "file_object_id", as: UUID?.self); usedLegacyDrawingLocation = try row.decode(column: "used_legacy_drawing_location", as: Bool.self)
    }
}
struct ImportedPhotoResponse: Content {
    let id: UUID; let projectId: UUID; let snagId: UUID
    let originalUseId: UUID; let thumbnailUseId: UUID; let annotationUseId: UUID
    let sourceLabelJSON: String?; let sourceLegacyLabelJSON: String?; let labelResolution: String
    let capturedAt: Date; let latitude: Double?; let longitude: Double?; let sortOrder: Int
    let sourceCreatedAt: Date; let revision: Int64; let importedAt: Date
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self); snagId = try row.decode(column: "snag_id", as: UUID.self)
        originalUseId = try row.decode(column: "original_use_id", as: UUID.self); thumbnailUseId = try row.decode(column: "thumbnail_use_id", as: UUID.self); annotationUseId = try row.decode(column: "annotation_use_id", as: UUID.self)
        sourceLabelJSON = try row.decode(column: "source_label_json", as: String?.self); sourceLegacyLabelJSON = try row.decode(column: "source_legacy_label_json", as: String?.self)
        labelResolution = try row.decode(column: "label_resolution", as: String.self); capturedAt = try row.decode(column: "captured_at", as: Date.self)
        latitude = try row.decode(column: "latitude", as: Double?.self); longitude = try row.decode(column: "longitude", as: Double?.self)
        sortOrder = try row.decode(column: "sort_order", as: Int.self); sourceCreatedAt = try row.decode(column: "source_created_at", as: Date.self)
        revision = try row.decode(column: "revision", as: Int64.self); importedAt = try row.decode(column: "imported_at", as: Date.self)
    }
}
struct ImportedCommentResponse: Content {
    let id: UUID; let projectId: UUID; let snagId: UUID; let content: String?
    let unverifiedAuthorId: UUID?; let unverifiedAuthorName: String; let unverifiedAuthorType: String
    let createdAt: Date; let updatedAt: Date?; let parentCommentId: UUID?; let mentions: LegacyProjectImportSource.StringList
    let isFromContractorLink: Bool; let attachmentListState: String; let provenance: String; let revision: Int64; let importedAt: Date; let redactedAt: Date?
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self); snagId = try row.decode(column: "snag_id", as: UUID.self)
        redactedAt = try row.decode(column: "redacted_at", as: Date?.self)
        content = redactedAt == nil ? try row.decode(column: "content", as: String.self) : nil
        unverifiedAuthorId = try row.decode(column: "unverified_author_id", as: UUID?.self); unverifiedAuthorName = try row.decode(column: "unverified_author_name", as: String.self)
        unverifiedAuthorType = try row.decode(column: "unverified_author_type", as: String.self); createdAt = try row.decode(column: "created_at", as: Date.self)
        updatedAt = try row.decode(column: "updated_at", as: Date?.self); parentCommentId = try row.decode(column: "parent_comment_id", as: UUID?.self)
        mentions = try JSONDecoder().decode(LegacyProjectImportSource.StringList.self, from: Data(row.decode(column: "mentions_json", as: String.self).utf8))
        isFromContractorLink = try row.decode(column: "is_from_contractor_link", as: Bool.self); attachmentListState = try row.decode(column: "attachment_list_state", as: String.self)
        provenance = try row.decode(column: "provenance", as: String.self); revision = try row.decode(column: "revision", as: Int64.self); importedAt = try row.decode(column: "imported_at", as: Date.self)
    }
}
struct ImportedStatusChangeResponse: Content {
    let id: UUID; let projectId: UUID; let snagId: UUID; let fromStatus: String; let toStatus: String
    let unverifiedChangedById: UUID?; let unverifiedChangedByName: String; let unverifiedChangedByType: String; let reason: String?
    let createdAt: Date; let provenance: String; let importedAt: Date
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self); snagId = try row.decode(column: "snag_id", as: UUID.self)
        fromStatus = try row.decode(column: "from_status", as: String.self); toStatus = try row.decode(column: "to_status", as: String.self)
        unverifiedChangedById = try row.decode(column: "unverified_changed_by_id", as: UUID?.self); unverifiedChangedByName = try row.decode(column: "unverified_changed_by_name", as: String.self)
        unverifiedChangedByType = try row.decode(column: "unverified_changed_by_type", as: String.self); reason = try row.decode(column: "reason", as: String?.self)
        createdAt = try row.decode(column: "created_at", as: Date.self); provenance = try row.decode(column: "provenance", as: String.self); importedAt = try row.decode(column: "imported_at", as: Date.self)
    }
}
struct ImportedDeletionResponse: Content {
    let deletedSnagId: UUID; let projectId: UUID; let reference: String; let unverifiedSourceOwnerId: UUID?
    let createdAt: Date; let historicalNeedsRemoteDeletion: Bool; let execution: String; let importedAt: Date
    init(_ row: SQLRow) throws {
        deletedSnagId = try row.decode(column: "deleted_snag_id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self)
        reference = try row.decode(column: "reference", as: String.self); unverifiedSourceOwnerId = try row.decode(column: "unverified_source_owner_id", as: UUID?.self)
        createdAt = try row.decode(column: "created_at", as: Date.self); historicalNeedsRemoteDeletion = try row.decode(column: "historical_needs_remote_deletion", as: Bool.self)
        execution = try row.decode(column: "execution", as: String.self); importedAt = try row.decode(column: "imported_at", as: Date.self)
    }
}
struct WorkspaceFolderResponse: Content {
    let id: UUID; let workspaceId: UUID; let name: String; let colorHex: String; let sortOrder: Int; let parentId: UUID?
    let revision: Int64; let sourceCreatedAt: Date?; let sourceUpdatedAt: Date?
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); workspaceId = try row.decode(column: "workspace_id", as: UUID.self); name = try row.decode(column: "name", as: String.self)
        colorHex = try row.decode(column: "color_hex", as: String.self); sortOrder = try row.decode(column: "sort_order", as: Int.self); parentId = try row.decode(column: "parent_id", as: UUID?.self)
        revision = try row.decode(column: "revision", as: Int64.self); sourceCreatedAt = try row.decode(column: "source_created_at", as: Date?.self); sourceUpdatedAt = try row.decode(column: "source_updated_at", as: Date?.self)
    }
}
struct WorkspaceTagResponse: Content {
    let id: UUID; let workspaceId: UUID; let name: String; let colorHex: String; let revision: Int64; let sourceCreatedAt: Date?; let sourceUpdatedAt: Date?
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); workspaceId = try row.decode(column: "workspace_id", as: UUID.self); name = try row.decode(column: "name", as: String.self)
        colorHex = try row.decode(column: "color_hex", as: String.self); revision = try row.decode(column: "revision", as: Int64.self)
        sourceCreatedAt = try row.decode(column: "source_created_at", as: Date?.self); sourceUpdatedAt = try row.decode(column: "source_updated_at", as: Date?.self)
    }
}
struct ProjectOrganisationResponse: Content {
    let projectId: UUID; let folderId: UUID?; let tagIds: [UUID]
}
/// A published drawing sheet with its single rendered page. Rendition/thumbnail
/// paths are authenticated project gateways.
struct DrawingSheetResponse: Content {
    struct Page: Content {
        let id: UUID; let versionId: UUID; let assetId: UUID; let assetPageId: UUID; let pageIndex: Int; let sourcePageLabel: String
        let geometry: DrawingPageGeometry; let rendition: MediaRenditionDescriptor; let thumbnail: MediaRenditionDescriptor
    }
    let id: UUID; let projectId: UUID; let name: String; let sortOrder: Int; let revision: Int64; let currentVersionId: UUID
    let createdBy: UUID; let createdAt: Date; let updatedAt: Date; let archivedAt: Date?; let pages: [Page]
    let imported: ImportedDrawingProvenance?
}
struct ImportedDrawingProvenance: Content, Equatable {
    let fileUseId: UUID; let thumbnailUseId: UUID; let sourcePageNumber: Int?; let sourceCreatedAt: Date; let sourceUpdatedAt: Date
    let provenance: String; let rendering: String; let importedAt: Date
    init(_ row: SQLRow) throws {
        fileUseId = try row.decode(column: "file_use_id", as: UUID.self); thumbnailUseId = try row.decode(column: "thumbnail_use_id", as: UUID.self)
        sourcePageNumber = try row.decode(column: "source_page_number", as: Int?.self); sourceCreatedAt = try row.decode(column: "source_created_at", as: Date.self)
        sourceUpdatedAt = try row.decode(column: "source_updated_at", as: Date.self); provenance = try row.decode(column: "provenance", as: String.self)
        rendering = try row.decode(column: "rendering", as: String.self); importedAt = try row.decode(column: "imported_at", as: Date.self)
    }
}
/// An unrendered imported drawing: the opaque original is retained and readable,
/// but no sheet, version or page exists yet.
struct OpaqueImportedDrawingResponse: Content {
    let id: UUID; let projectId: UUID; let name: String; let sortOrder: Int; let imported: ImportedDrawingProvenance
}
struct DrawingPinResponse: Content {
    let snagId: UUID; let projectId: UUID; let drawingId: UUID?; let versionId: UUID?; let versionPageId: UUID?
    let x: Double?; let y: Double?; let revision: Int64; let snagRevision: Int64; let recordedBy: UUID; let recordedAt: Date; let deletedAt: Date?
    init(_ row: SQLRow) throws {
        snagId = try row.decode(column: "snag_id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self)
        drawingId = try row.decode(column: "drawing_id", as: UUID?.self); versionId = try row.decode(column: "version_id", as: UUID?.self); versionPageId = try row.decode(column: "version_page_id", as: UUID?.self)
        x = try row.decode(column: "x", as: Double?.self); y = try row.decode(column: "y", as: Double?.self); revision = try row.decode(column: "revision", as: Int64.self)
        snagRevision = try row.decode(column: "snag_revision", as: Int64.self); recordedBy = try row.decode(column: "recorded_by", as: UUID.self)
        recordedAt = try row.decode(column: "recorded_at", as: Date.self); deletedAt = try row.decode(column: "deleted_at", as: Date?.self)
    }
}
