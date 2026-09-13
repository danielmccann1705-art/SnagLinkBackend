import Foundation

/// Internal transport command, deliberately not Content and not an authentication claim.
/// `operationId` belongs only to staged-original-file-v1, not global mutation receipts.
struct StagedImportOriginalCommand: Codable, Sendable {
    let scope: StagedLegacyImportScope
    let declarationId: UUID
    let operationId: UUID
    let expectedSessionRevision: Int64
}

/// A present-day fact about retained bytes; never a decoded image, ready drawing,
/// canonical media attachment, historical author or accepted completion.
struct StagedImportOriginalReceipt: Codable, Sendable, Equatable {
    let formatVersion: Int
    let receiptId: UUID
    let sessionId: UUID
    let declarationId: UUID
    let actorId: UUID
    let deviceId: UUID
    let firstOperationId: UUID
    let sessionRevision: Int64
    let measuredSHA256: String
    let measuredBytes: Int64
    let measuredAt: Date
    let verification: String
    let contentValidation: String
    let canonicalReady: Bool
}

/// Constructed from current server-owned rows, never from a source path or URL.
struct StagedImportOriginalAddress: Hashable, Sendable {
    let workspaceId: UUID
    let sessionId: UUID
    let declarationId: UUID
}

struct StagedImportOriginalDeclaration: Equatable, Sendable {
    let sha256: String
    let bytes: Int64
}
