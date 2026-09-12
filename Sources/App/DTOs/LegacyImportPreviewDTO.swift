import Vapor

/// An identity/requirement inventory, not an uploaded project graph or ownership claim.
struct LegacyImportPreviewCommand: Content {
    struct Source: Content {
        let archiveId: UUID
        let sourceFingerprint: String
        let databaseSHA256: String
        let inventorySHA256: String
        let selectedProjectId: UUID
        let exportSHA256: String
        let exportByteCount: Int
        let exportFormatVersion: Int
    }
    struct Destination: Content, Equatable {
        let environment: String
        let apiOrigin: String
    }
    static let maximumBodyBytes = 2 * 1024 * 1024
    static let kinds: Set<String> = ["projects", "snags", "photos", "drawings", "contractors", "trades", "folders", "tags", "comments", "statusHistory", "deletionReceipts"]
    static let requirementNames: Set<String> = ["originalPhotoCount", "thumbnailCount", "annotationCount", "coverCount", "drawingFileCount", "drawingThumbnailCount", "attachmentCount", "deletionMediaCount", "pinCount", "localClosureCount", "legacyReferenceCount", "sourceFindingCount", "relationshipFindingCount", "missingMediaReferenceCount", "unsafeMediaReferenceCount", "unresolvedDrawingAssociationCount"]
    let formatVersion: Int
    let mutation: MutationMetadata
    // Native operationID is also the plan ID; no invented second identity.
    let expectedActorId: UUID
    let expectedWorkspaceKind: String
    let source: Source
    let destination: Destination
    let recordIds: [String: [UUID]]
    let requirements: [String: Int]

    /// Reject extra fields before Codable can ignore them: raw contacts, paths,
    /// credentials, consent flags and future executable fields are not accepted.
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBodyBytes else { throw oversized() }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
        func keys(_ value: Any?, _ allowed: Set<String>) throws {
            guard let value = value as? [String: Any], Set(value.keys) == allowed else { throw invalid() }
        }
        try keys(object, ["formatVersion", "mutation", "expectedActorId", "expectedWorkspaceKind", "source", "destination", "recordIds", "requirements"])
        try keys(object["mutation"], ["operationId", "deviceId"])
        try keys(object["source"], ["archiveId", "sourceFingerprint", "databaseSHA256", "inventorySHA256", "selectedProjectId", "exportSHA256", "exportByteCount", "exportFormatVersion"])
        try keys(object["destination"], ["environment", "apiOrigin"])
        try keys(object["recordIds"], kinds)
        try keys(object["requirements"], requirementNames)
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw invalid() }
        try result.validate()
        return result
    }

    func validate() throws {
        guard formatVersion == 1, source.exportFormatVersion == 1,
              ["personal", "company"].contains(expectedWorkspaceKind),
              Set(recordIds.keys) == Self.kinds, Set(requirements.keys) == Self.requirementNames,
              recordIds["projects"] == [source.selectedProjectId] else { throw Self.invalid() }
        guard (1...(8 * 1024 * 1024)).contains(source.exportByteCount) else { throw Self.oversized() }
        for digest in [source.sourceFingerprint, source.databaseSHA256, source.inventorySHA256, source.exportSHA256] {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Self.invalid() }
        }
        var count = 0
        for ids in recordIds.values {
            guard ids.count <= 10_000 else { throw Self.oversized() }
            count += ids.count
            guard count <= 10_000 else { throw Self.oversized() }
            guard Set(ids).count == ids.count, ids == ids.sorted(by: { $0.uuidString < $1.uuidString }) else { throw Self.invalid() }
        }
        guard requirements.values.allSatisfy({ (0...100_000).contains($0) }),
              requirements["coverCount"]! <= 1,
              requirements["originalPhotoCount"]! <= recordIds["photos"]!.count,
              requirements["thumbnailCount"]! <= recordIds["photos"]!.count,
              requirements["annotationCount"]! <= recordIds["photos"]!.count,
              requirements["drawingFileCount"]! <= recordIds["drawings"]!.count,
              requirements["drawingThumbnailCount"]! <= recordIds["drawings"]!.count,
              requirements["pinCount"]! <= recordIds["snags"]!.count,
              requirements["localClosureCount"]! <= recordIds["snags"]!.count else { throw Self.invalid() }
        let media = ["originalPhotoCount", "thumbnailCount", "annotationCount", "coverCount", "drawingFileCount", "drawingThumbnailCount", "attachmentCount", "deletionMediaCount"].reduce(0) { $0 + requirements[$1]! }
        guard media <= 50_000 else { throw Self.oversized() }
        let canonical: ImportServerBinding
        do { canonical = try ImportServerBinding(environment: destination.environment, apiOrigin: destination.apiOrigin) }
        catch { throw Self.invalid() }
        guard canonical.destination == destination else { throw Self.invalid() }
    }
    static func invalid() -> Abort { Abort(.badRequest, reason: "Send the complete supported identity manifest with valid counts and unique sorted IDs", identifier: "invalid_import_preview_manifest") }
    static func oversized() -> Abort { Abort(.payloadTooLarge, reason: "The selected project exceeds this preview's bounded manifest limit. Nothing was imported", identifier: "import_preview_too_large") }
}

struct LegacyImportPreviewResponse: Content {
    struct IdentityCheck: Content {
        let kind: String
        let sourceIds: [UUID]
        let count: Int
        let namespacesChecked: [String]
        let scope: String
    }
    struct Collision: Content {
        let kind: String
        let sourceId: UUID
        let code: String
    }
    let formatVersion: Int
    let state: String
    let importExecutable: Bool
    let sourceBytesVerified: Bool
    let graphContentValidation: String
    let ownershipConsent: String
    let operationId: UUID
    let deviceId: UUID
    let actorId: UUID
    let workspaceId: UUID
    let workspaceKind: String
    let workspaceRevision: Int64
    let actorRole: String
    let destination: LegacyImportPreviewCommand.Destination
    let source: LegacyImportPreviewCommand.Source
    let requestHash: String
    let previewFingerprint: String
    let checks: [String]
    let identities: [IdentityCheck]
    let collisions: [Collision]
    let blockers: [String]
    let createdAt: Date
    let expiresAt: Date
}
