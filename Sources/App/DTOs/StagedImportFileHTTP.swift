import Vapor

struct StagedImportFileManifestRequest: Codable, Sendable {
    let formatVersion: Int
    let scope: StagedLegacyImportScope
    let expectedSessionRevision: Int64
    let offset: Int
    let limit: Int
}
struct StagedImportFileManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let declarationId: UUID
        let ordinal: Int
        let handleDigestVersion: Int
        let sourceHandleSHA256: String
        let declaredSHA256: String
        let declaredBytes: Int64
        let operationId: UUID?
        let originalReceipt: StagedImportOriginalReceipt?
        let storageState: String
        let uploadSupported: Bool
    }
    let formatVersion: Int
    let scope: StagedLegacyImportScope
    let sessionRevision: Int64
    let totalCount: Int
    let offset: Int
    let nextOffset: Int?
    let descriptorMaximumBytes: Int
    let totalDeclaredFileMaximumBytes: Int64
    let singleRequestMaximumBytes: Int64
    let supportedContentType: String
    let supportedOriginalRoles: [String]
    let canonicalReady: Bool
    let entries: [Entry]
}

enum StagedImportFileHTTP {
    static let maximumUploadBytes: Int64 = 50 * 1024 * 1024
    static let maximumCommandBytes = 4 * 1024
    static let commandHeader = "X-Snaglist-Import-Command"
    struct UploadEnvelope: Codable { let formatVersion: Int; let command: StagedImportOriginalCommand }

    static func manifest(_ data: Data, workspace: UUID, session: UUID) throws -> StagedImportFileManifestRequest {
        let object = try StagedLegacyImportHTTP.object(data, limit: StagedLegacyImportHTTP.maximumSmallBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "scope", "expectedSessionRevision", "offset", "limit"])
        try StagedLegacyImportHTTP.scope(object["scope"])
        let result: StagedImportFileManifestRequest = try StagedLegacyImportHTTP.decode(data)
        guard result.formatVersion == 1, result.expectedSessionRevision > 0,
              (0...20_000).contains(result.offset), (1...100).contains(result.limit) else { throw invalid() }
        try StagedLegacyImportHTTP.match(result.scope, workspace, session)
        return result
    }
    static func upload(_ headers: HTTPHeaders, workspace: UUID, session: UUID, declaration: UUID) throws -> (StagedImportOriginalCommand, Int64) {
        let values = headers[commandHeader]
        guard values.count == 1, let encoded = values.first,
              encoded.utf8.count <= ((maximumCommandBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), data.count <= maximumCommandBytes,
              data.base64EncodedString() == encoded else { throw invalid() }
        let object = try StagedLegacyImportHTTP.object(data, limit: maximumCommandBytes)
        try StagedLegacyImportHTTP.keys(object, ["formatVersion", "command"])
        let command = try StagedLegacyImportHTTP.keys(object["command"], ["scope", "declarationId", "operationId", "expectedSessionRevision"])
        try StagedLegacyImportHTTP.scope(command["scope"])
        let result: UploadEnvelope = try StagedLegacyImportHTTP.decode(data)
        guard result.formatVersion == 1, result.command.expectedSessionRevision > 0,
              result.command.declarationId == declaration else { throw invalid() }
        try StagedLegacyImportHTTP.match(result.command.scope, workspace, session)
        let lengths = headers[.contentLength]
        guard lengths.count == 1, let length = lengths.first else {
            throw Abort(.lengthRequired, reason: "An exact Content-Length is required for this original")
        }
        guard !length.isEmpty, length.utf8.count <= 10, length == "0" || length.first != "0",
              length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(length) else { throw invalid() }
        guard count <= maximumUploadBytes else { throw oversized() }
        guard headers[.contentEncoding].isEmpty, headers[.transferEncoding].isEmpty,
              headers[.contentType].count == 1, headers.first(name: .contentType)?.lowercased() == "application/octet-stream" else { throw invalid() }
        return (result.command, count)
    }
    static func sourceHandleDigest(_ archiveHandle: String) -> String {
        SHA256Hasher.hash(token: "snaglist-staged-source-handle-v1\n" + archiveHandle)
    }
    static func invalid() -> Abort { .init(.badRequest, reason: "Send the complete supported original-file envelope", identifier: "invalid_staged_file_envelope") }
    static func oversized() -> Abort { .init(.payloadTooLarge, reason: "This original exceeds the current transfer limit. Keep the complete source archive", identifier: "staged_original_transport_limit") }
}
