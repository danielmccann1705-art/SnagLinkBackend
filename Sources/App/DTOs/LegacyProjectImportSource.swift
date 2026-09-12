import Foundation

/// Exact v1 native source schema. Never decode it directly at a transport boundary: use
/// LegacyProjectImportDecoder to reject duplicate/unknown keys and enforce source binding.
/// Decoding does not establish account ownership, media verification or canonical acceptance.
struct LegacyProjectImportSource: Codable, Sendable {
    struct Source: Codable, Sendable {
        let archiveID: UUID
        let capturedAt: Date
        let appVersion: String
        let sourceFingerprint: String
        let databaseSHA256: String
        let inventorySHA256: String
        let inventoryComparison: String
    }
    struct Finding: Codable, Sendable {
        let code: String
        let recordID: UUID?
        let field: String
    }
    struct Count: Codable, Sendable {
        let category: String
        let count: Int
    }
    struct FileReference: Codable, Sendable {
        enum Availability: String, Codable, Sendable {
            case verifiedBytes, missing, unsafePath, notRecorded
        }
        /// Untrusted source text, retained only as data. Never append this to a URL.
        let sourcePath: String?
        /// Unsafe path text stays in the archive; its digest permits comparison.
        let sourcePathSHA256: String?
        /// Verified relative archive entry only; never an absolute device path.
        let archivePath: String?
        let bytes: Int64?
        let sha256: String?
        let availability: Availability
        let usedLegacyDrawingLocation: Bool
    }
    struct StringList: Codable, Sendable {
        enum State: String, Codable, Sendable { case notRecorded, decoded, decodedWithExcludedUnsafePaths, unreadable }
        let values: [String]?
        let sourceBytes: Int
        let sourceSHA256: String?
        let state: State
    }
    struct Project: Codable, Sendable {
        let id: UUID
        let name: String
        let reference: String
        let clientName: String?
        let clientEmail: String?
        let clientPhone: String?
        let address: String?
        let latitude: Double?
        let longitude: Double?
        let projectType: String?
        let customProjectType: String?
        let startDate: Date?
        let expectedEndDate: Date?
        let cover: FileReference
        let notes: String?
        let localStatus: String
        let createdAt: Date
        let updatedAt: Date
        let isFavorite: Bool
        let sourceSnagIDs: [UUID]
        let sourceDrawingIDs: [UUID]
        let folderID: UUID?
        let tagIDs: [UUID]
        /// A historical relationship, never membership or import destination.
        let unverifiedSourceTeamID: UUID?
    }
    struct Snag: Codable, Sendable {
        let id: UUID
        let reference: String
        let title: String
        let description: String?
        let localStatus: String
        let priority: String
        let location: String?
        let drawingPinX: Double?
        let drawingPinY: Double?
        let dueDate: Date?
        let costEstimate: Double?
        let actualCost: Double?
        let currency: String
        let tags: [String]
        let createdAt: Date
        let updatedAt: Date
        let unverifiedClosedAt: Date?
        let historicalContractorLinkSentAt: Date?
        let projectID: UUID?
        let tradeID: UUID?
        let contractorID: UUID?
        let drawingID: UUID?
        let sourcePhotoIDs: [UUID]
        let sourceCommentIDs: [UUID]
        let sourceStatusChangeIDs: [UUID]
    }
    struct Photo: Codable, Sendable {
        let id: UUID
        let snagID: UUID?
        let original: FileReference
        let thumbnail: FileReference
        let annotation: FileReference
        /// Exact stored JSON and Codable representation of the legacy attribute.
        /// Neither is replaced by effectiveLabel's silent default-to-before rule.
        let sourceLabelJSON: String?
        let sourceLegacyLabelJSON: String?
        let labelResolution: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        let sortOrder: Int
        let createdAt: Date
    }
    struct Drawing: Codable, Sendable {
        let id: UUID
        let name: String
        let file: FileReference
        let thumbnail: FileReference
        let pageNumber: Int?
        let sortOrder: Int
        let createdAt: Date
        let updatedAt: Date
        let projectID: UUID?
        let sourceSnagIDs: [UUID]
        let provenance: String
    }
    struct Contractor: Codable, Sendable {
        let id: UUID
        let companyName: String
        let contactName: String?
        let email: String?
        let phone: String?
        let notes: String?
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        let tradeIDs: [UUID]
        let selectedSnagIDs: [UUID]
    }
    struct Trade: Codable, Sendable {
        let id: UUID
        let name: String
        let colorHex: String
        let sortOrder: Int
        let isArchived: Bool
        let isDefault: Bool
        let createdAt: Date
        let updatedAt: Date
        let selectedContractorIDs: [UUID]
        let selectedSnagIDs: [UUID]
    }
    struct Folder: Codable, Sendable {
        let id: UUID
        let name: String
        let colorHex: String
        let sortOrder: Int
        let createdAt: Date
        let updatedAt: Date
        let parentID: UUID?
        let selectedChildIDs: [UUID]
        let selectedProjectIDs: [UUID]
    }
    struct Tag: Codable, Sendable {
        let id: UUID
        let name: String
        let colorHex: String
        let createdAt: Date
        let updatedAt: Date
        let selectedProjectIDs: [UUID]
    }
    struct Comment: Codable, Sendable {
        let id: UUID
        let snagID: UUID?
        let content: String
        let unverifiedAuthorID: UUID?
        let unverifiedAuthorName: String
        let unverifiedAuthorType: String
        let createdAt: Date
        let updatedAt: Date?
        let parentCommentID: UUID?
        let mentions: StringList
        let isFromContractorLink: Bool
        let attachmentPaths: StringList
        let attachments: [FileReference]
        let provenance: String
    }
    struct StatusChange: Codable, Sendable {
        let id: UUID
        let snagID: UUID?
        let fromLocalStatus: String
        let toLocalStatus: String
        let unverifiedChangedByID: UUID?
        let unverifiedChangedByName: String
        let unverifiedChangedByType: String
        let reason: String?
        let createdAt: Date
        let provenance: String
    }
    struct DeletionReceipt: Codable, Sendable {
        let deletedSnagID: UUID
        let projectID: UUID
        let reference: String
        let unverifiedSourceOwnerID: UUID?
        let createdAt: Date
        let historicalNeedsRemoteDeletion: Bool
        let photoFiles: [FileReference]
        let execution: String
    }

    let formatVersion: Int
    let purpose: String
    let ownership: String
    let canonicalAcceptance: String
    let mediaContentValidation: String
    let source: Source
    let project: Project
    let snags: [Snag]
    let photos: [Photo]
    let drawings: [Drawing]
    let contractors: [Contractor]
    let trades: [Trade]
    let folders: [Folder]
    let tags: [Tag]
    let comments: [Comment]
    let statusHistory: [StatusChange]
    let deletionReceipts: [DeletionReceipt]
    /// Counts describe the whole archive, without exporting excluded records/IDs.
    let excludedArchiveRecordCounts: [Count]
    let archiveRelationshipIssueCounts: [Count]
    let findings: [Finding]
    let findingCounts: [Count]
    let omittedFindingCount: Int
    let limitations: [String]

}
