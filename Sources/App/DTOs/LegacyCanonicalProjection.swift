import Foundation

/// Internal, strongly typed input to the future canonical writer. Not Content and
/// never a public report/source dump. Original source bytes remain in their store.
struct LegacyCanonicalProjection: Codable, Sendable {
    static let policy = "selected-project-canonical-projection-v1"
    struct Binding: Codable, Sendable {
        let sessionId: UUID; let actorId: UUID; let workspaceId: UUID
        let deviceId: UUID; let destination: LegacyImportPreviewCommand.Destination
        let sourceFingerprint: String; let archiveId: UUID; let exportSHA256: String
        let projectId: UUID; let sourceRevision: Int64
    }
    struct Allocation: Codable, Equatable, Sendable {
        /// Closed server-defined purpose, not a key supplied by a transport caller.
        let key: String; let targetId: UUID
    }
    struct SourceRecord: Codable, Sendable {
        let kind: LegacyImportRecordKind; let sourceId: UUID
        let mappingId: UUID; let sourceSHA256: String
    }
    struct FileObject: Codable, Sendable {
        let id: UUID; let declarationId: UUID; let declaredSHA256: String; let declaredBytes: Int64
        let requiredFact: String // persisted_original_bytes_v1; never a verified claim.
    }
    struct FileUse: Codable, Sendable {
        let id: UUID; let kind: LegacyImportRecordKind; let sourceId: UUID
        let role: LegacyImportFileRole; let position: Int; let required: Bool
        let fileObjectId: UUID?; let availability: LegacyProjectImportSource.FileReference.Availability
        let usedLegacyDrawingLocation: Bool
        // Paths stay only in retained source. These bindings preserve their identity.
        let sourcePathSHA256: String?; let archiveHandleSHA256: String?
    }
    struct Edge: Codable, Sendable {
        let kind: LegacyImportRecordKind; let sourceId: UUID; let field: String
        let targetKind: LegacyImportRecordKind; let targetId: UUID; let targetPresent: Bool
    }
    struct Finding: Codable, Equatable, Sendable {
        enum Disposition: String, Codable, Sendable { case blocker, qualification }
        let code: String; let kind: LegacyImportRecordKind; let sourceId: UUID
        let field: String; let disposition: Disposition
    }
    struct Project: Codable, Sendable {
        let id: UUID; let name: String; let reference: String
        let clientName: String?; let clientEmail: String?; let clientPhone: String?
        let address: String?; let latitude: Double?; let longitude: Double?
        let projectType: String?; let customProjectType: String?; let notes: String?
        let startDate: Date?; let expectedEndDate: Date? // calendar intent stays absent.
        let localStatus: String; let isFavorite: Bool
        let sourceCreatedAt: Date; let sourceUpdatedAt: Date
        let folderId: UUID?; let tagIds: [UUID]; let snagIds: [UUID]; let drawingIds: [UUID]
        let unverifiedSourceTeamId: UUID?; let coverUseId: UUID
    }
    struct Workflow: Codable, Sendable {
        let sourceStatus: String; let displayStatus: String?
        let qualification: String; let requiresReconciliation: Bool
        let unverifiedClosedAt: Date?
        let actionableReview: Bool; let verifiedAcceptance: Bool
    }
    struct Snag: Codable, Sendable {
        // This source type has no file paths or credentials. Every ordinary field,
        // historical date and ordered source relationship remains explicitly typed.
        let values: LegacyProjectImportSource.Snag
        let reference: String; let displayNumber: Int64; let initialVisibility: String
        let costEstimateDecimal: String?; let actualCostDecimal: String?
        let workflow: Workflow
        let initialEntityRevision: Int64; let initialWorkflowRevision: Int64
    }
    struct Photo: Codable, Sendable {
        let id: UUID; let snagId: UUID; let originalUseId: UUID; let thumbnailUseId: UUID; let annotationUseId: UUID
        let sourceLabelJSON: String?; let sourceLegacyLabelJSON: String?; let labelResolution: String
        let capturedAt: Date; let latitude: Double?; let longitude: Double?; let sortOrder: Int; let sourceCreatedAt: Date
        let renditionId: UUID; let requiredFact: String
    }
    struct Drawing: Codable, Sendable {
        let id: UUID; let name: String; let projectId: UUID; let fileUseId: UUID; let thumbnailUseId: UUID
        let sourcePageNumber: Int?; let sortOrder: Int; let sourceCreatedAt: Date; let sourceUpdatedAt: Date
        let snagIds: [UUID]; let provenance: String
        let assetId: UUID; let assetPageId: UUID; let versionId: UUID; let versionPageId: UUID
        let requiredFact: String // actual supported raster/PDF processing, not inferred from a path.
    }
    struct Pin: Codable, Sendable {
        let snagId: UUID; let drawingId: UUID?; let versionId: UUID?; let versionPageId: UUID?
        let x: Double?; let y: Double?; let eventId: UUID; let sourceShape: String
        let qualification: String
    }
    struct Comment: Codable, Sendable {
        let id: UUID; let snagId: UUID; let content: String
        let unverifiedAuthorId: UUID?; let unverifiedAuthorName: String; let unverifiedAuthorType: String
        let createdAt: Date; let updatedAt: Date?; let parentCommentId: UUID?
        let mentions: LegacyProjectImportSource.StringList; let isFromContractorLink: Bool
        let attachmentListState: LegacyProjectImportSource.StringList.State
        let attachmentListSourceBytes: Int; let attachmentListSourceSHA256: String?
        let attachmentUseIds: [UUID]; let provenance: String
    }
    struct Deletion: Codable, Sendable {
        let deletedSnagId: UUID; let projectId: UUID; let reference: String; let unverifiedSourceOwnerId: UUID?
        let createdAt: Date; let historicalNeedsRemoteDeletion: Bool; let photoUseIds: [UUID]
        let execution: String
    }
    struct DirectoryIdentity: Codable, Sendable {
        let kind: LegacyImportRecordKind; let sourceId: UUID; let targetId: UUID
        let intrinsicSHA256: String; let policy: String
    }
    let formatVersion: Int; let projectionId: UUID; let binding: Binding
    let source: LegacyProjectImportSource.Source
    let project: Project; let snags: [Snag]; let photos: [Photo]; let drawings: [Drawing]; let pins: [Pin]
    let contractors: [LegacyProjectImportSource.Contractor]; let trades: [LegacyProjectImportSource.Trade]
    let folders: [LegacyProjectImportSource.Folder]; let tags: [LegacyProjectImportSource.Tag]
    let comments: [Comment]; let statusHistory: [LegacyProjectImportSource.StatusChange]; let deletions: [Deletion]
    let sourceRecords: [SourceRecord]; let edges: [Edge]; let files: [FileObject]; let fileUses: [FileUse]
    let allocations: [Allocation]; let directoryIdentities: [DirectoryIdentity]; let findings: [Finding]
    let excludedArchiveRecordCounts: [LegacyProjectImportSource.Count]
    let archiveRelationshipIssueCounts: [LegacyProjectImportSource.Count]
    let sourceFindingCounts: [LegacyProjectImportSource.Count]; let sourceFindings: [LegacyProjectImportSource.Finding]; let omittedFindingCount: Int; let limitations: [String]
    let journalEventUpperBound: Int; let snapshotRowUpperBound: Int
    let importExecutable: Bool; let publicationAcknowledgement: String
}

struct LegacyCanonicalProjectionCommand: Codable, Sendable {
    let projectionId: UUID; let scope: StagedLegacyImportScope
    let operationId: UUID; let expectedSourceRevision: Int64
    let policy: String
}

struct LegacyCanonicalProjectionReceipt: Codable, Sendable {
    let projectionId: UUID; let sessionId: UUID; let operationId: UUID
    let policy: String; let graphSHA256: String; let revision: Int64; let createdAt: Date
    let blockerCount: Int; let qualificationCount: Int; let fileCount: Int; let allocationCount: Int
    let importExecutable: Bool
}
