import Vapor

/// Supplied by a freshly authenticated boundary, never decoded from a request body.
/// Browser session revocation/CSRF and JWT verification remain that boundary's job.
struct StagedLegacyImportActor: Sendable {
    let id: UUID
    let authVersion: Int
}

struct StagedLegacyImportCommand: Codable, Sendable {
    struct Acknowledgement: Codable, Equatable, Sendable {
        static let supportedVersion = "selected-source-staging-v1"
        static let supportedWording = "I am authorised to transfer this selected project's data to the selected workspace. Prepare this source privately for import. Historical names, statuses and closure are unverified; this preparation does not publish a project or approve work."
        let version: String
        let wording: String
        let accepted: Bool
    }
    let formatVersion: Int
    let sessionId: UUID
    let mutation: MutationMetadata
    let expectedActorId: UUID
    let expectedAuthVersion: Int
    let expectedWorkspaceKind: String
    let destination: LegacyImportPreviewCommand.Destination
    let selectedProjectId: UUID
    let sourceFingerprint: String
    let exportSHA256: String
    let exportByteCount: Int
    let acknowledgement: Acknowledgement

    func validate(actor: StagedLegacyImportActor, binding: ImportServerBinding) throws {
        guard formatVersion == 1, expectedActorId == actor.id, expectedAuthVersion == actor.authVersion,
              expectedAuthVersion >= 0, ["personal", "company"].contains(expectedWorkspaceKind),
              destination == binding.destination else { throw StagedLegacyImportService.bindingChanged() }
        guard acknowledgement.accepted, acknowledgement.version == Acknowledgement.supportedVersion,
              acknowledgement.wording == Acknowledgement.supportedWording else {
            throw Abort(.badRequest, reason: "Explicit acknowledgement of this selected source and destination is required", identifier: "import_acknowledgement_required")
        }
        guard (1...(8 * 1024 * 1024)).contains(exportByteCount) else { throw Abort(.payloadTooLarge) }
        for value in [sourceFingerprint, exportSHA256] {
            guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Abort(.badRequest) }
        }
    }
}

/// Small actor-private metadata only: no raw descriptor, contact details, paths,
/// historical author IDs, Contractor link tokens or media access URLs.
struct StagedLegacyImportReceipt: Codable, Sendable {
    let formatVersion: Int
    let sessionId: UUID
    let createOperationId: UUID
    let deviceId: UUID
    let actorId: UUID
    let workspaceId: UUID
    let workspaceKind: String
    let destination: LegacyImportPreviewCommand.Destination
    let selectedProjectId: UUID
    let sourceFingerprint: String
    let exportSHA256: String
    let exportByteCount: Int
    let requestHash: String
    let state: String
    let revision: Int64
    let recordCounts: [String: Int]
    let edgeCount: Int
    let fileRoleCounts: [String: Int]
    let declaredFileCount: Int
    let declaredFileBytes: Int64
    let sourceIssueCounts: [String: Int]
    let journalEventUpperBound: Int
    let snapshotRowUpperBound: Int
    let acknowledgementVersion: String
    let acknowledgedAt: Date
    let createdAt: Date
    let updatedAt: Date
    let importExecutable: Bool
    let mediaVerification: String
    let historicalAcceptance: String
    func aborted(at date: Date) -> Self {
        .init(formatVersion: formatVersion, sessionId: sessionId, createOperationId: createOperationId, deviceId: deviceId,
              actorId: actorId, workspaceId: workspaceId, workspaceKind: workspaceKind, destination: destination,
              selectedProjectId: selectedProjectId, sourceFingerprint: sourceFingerprint, exportSHA256: exportSHA256,
              exportByteCount: exportByteCount, requestHash: requestHash, state: "aborted", revision: revision + 1,
              recordCounts: recordCounts, edgeCount: edgeCount, fileRoleCounts: fileRoleCounts, declaredFileCount: declaredFileCount,
              declaredFileBytes: declaredFileBytes, sourceIssueCounts: sourceIssueCounts, journalEventUpperBound: journalEventUpperBound,
              snapshotRowUpperBound: snapshotRowUpperBound, acknowledgementVersion: acknowledgementVersion,
              acknowledgedAt: acknowledgedAt, createdAt: createdAt, updatedAt: date, importExecutable: importExecutable,
              mediaVerification: mediaVerification, historicalAcceptance: historicalAcceptance)
    }

}

struct StagedLegacyImportScope: Codable, Sendable {
    let sessionId: UUID
    let workspaceId: UUID
    let deviceId: UUID
    let destination: LegacyImportPreviewCommand.Destination
    let exportSHA256: String
    let sourceFingerprint: String
    let selectedProjectId: UUID
}
struct AbortStagedLegacyImportCommand: Codable, Sendable {
    let scope: StagedLegacyImportScope
    let mutation: MutationMetadata
    let expectedRevision: Int64
}
