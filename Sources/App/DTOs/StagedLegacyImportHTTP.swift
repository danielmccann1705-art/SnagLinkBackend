import Vapor

/// Private selected-source wire format. Outer metadata has no authVersion or
/// raw filename fields. The Base64 descriptor remains sensitive private source
/// data; it contains no uploaded media bytes or executable import instructions.
struct StagedLegacyImportHTTP {
    static let maximumCreateBytes = 12 * 1024 * 1024
    static let maximumSmallBytes = 16 * 1024
    struct Command: Decodable {
        let sessionId: UUID
        let mutation: MutationMetadata
        let expectedActorId: UUID
        let expectedWorkspaceKind: String
        let destination: LegacyImportPreviewCommand.Destination
        let selectedProjectId: UUID
        let sourceFingerprint: String
        let exportSHA256: String
        let exportByteCount: Int
        let acknowledgement: StagedLegacyImportCommand.Acknowledgement
        func bound(to actor: StagedLegacyImportActor) -> StagedLegacyImportCommand {
            .init(formatVersion: 1, sessionId: sessionId, mutation: mutation, expectedActorId: expectedActorId,
                  expectedAuthVersion: actor.authVersion, expectedWorkspaceKind: expectedWorkspaceKind, destination: destination,
                  selectedProjectId: selectedProjectId, sourceFingerprint: sourceFingerprint, exportSHA256: exportSHA256,
                  exportByteCount: exportByteCount, acknowledgement: acknowledgement)
        }
    }
    struct Create: Decodable { let formatVersion: Int; let command: Command; let descriptorBase64: String }
    struct Read: Decodable { let formatVersion: Int; let scope: StagedLegacyImportScope }
    struct AbortRequest: Decodable { let formatVersion: Int; let scope: StagedLegacyImportScope; let mutation: MutationMetadata; let expectedRevision: Int64 }
    struct DecodedCreate { let command: Command; let descriptor: Data }

    static func create(_ bytes: Data) throws -> DecodedCreate {
        let object = try object(bytes, limit: maximumCreateBytes)
        try keys(object, ["formatVersion", "command", "descriptorBase64"])
        let command = try keys(object["command"], ["sessionId", "mutation", "expectedActorId", "expectedWorkspaceKind", "destination", "selectedProjectId", "sourceFingerprint", "exportSHA256", "exportByteCount", "acknowledgement"])
        try mutation(command["mutation"]); try destination(command["destination"])
        try keys(command["acknowledgement"], ["version", "wording", "accepted"])
        let value: Create = try decode(bytes)
        guard value.formatVersion == 1 else { throw invalid() }
        guard (1...LegacyProjectImportDecoder.maximumBytes).contains(value.command.exportByteCount) else { throw oversized() }
        let encodedCount = ((value.command.exportByteCount + 2) / 3) * 4
        // Bound before allocation; reject whitespace, URL-safe forms, omitted
        // padding, aliases with non-zero pad bits and decoding truncation.
        guard value.descriptorBase64.utf8.count == encodedCount,
              let raw = Data(base64Encoded: value.descriptorBase64), raw.count == value.command.exportByteCount,
              raw.base64EncodedString() == value.descriptorBase64 else { throw invalid() }
        try Task.checkCancellation()
        return .init(command: value.command, descriptor: raw)
    }
    static func read(_ bytes: Data, workspaceID: UUID, sessionID: UUID) throws -> Read {
        let object = try object(bytes, limit: maximumSmallBytes)
        try keys(object, ["formatVersion", "scope"]); try scope(object["scope"])
        let value: Read = try decode(bytes)
        guard value.formatVersion == 1 else { throw invalid() }
        try match(value.scope, workspaceID, sessionID)
        return value
    }
    static func abort(_ bytes: Data, workspaceID: UUID, sessionID: UUID) throws -> AbortStagedLegacyImportCommand {
        let object = try object(bytes, limit: maximumSmallBytes)
        try keys(object, ["formatVersion", "scope", "mutation", "expectedRevision"]); try scope(object["scope"]); try mutation(object["mutation"])
        let value: AbortRequest = try decode(bytes)
        guard value.formatVersion == 1, value.expectedRevision > 0, value.mutation.deviceId == value.scope.deviceId else { throw invalid() }
        try match(value.scope, workspaceID, sessionID)
        return .init(scope: value.scope, mutation: value.mutation, expectedRevision: value.expectedRevision)
    }
    static func match(_ scope: StagedLegacyImportScope, _ workspace: UUID, _ session: UUID) throws {
        guard scope.workspaceId == workspace, scope.sessionId == session else { throw StagedLegacyImportService.bindingChanged() }
        guard LegacyProjectImportDecoder.validDigest(scope.exportSHA256), LegacyProjectImportDecoder.validDigest(scope.sourceFingerprint) else { throw invalid() }
        guard let canonical = try? ImportServerBinding(environment: scope.destination.environment, apiOrigin: scope.destination.apiOrigin),
              canonical.destination == scope.destination else { throw invalid() }
    }
    @discardableResult static func keys(_ value: Any?, _ names: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == names else { throw invalid() }
        return object
    }
    private static func destination(_ value: Any?) throws { try keys(value, ["environment", "apiOrigin"]) }
    private static func mutation(_ value: Any?) throws { try keys(value, ["operationId", "deviceId"]) }
    static func scope(_ value: Any?) throws {
        let object = try keys(value, ["sessionId", "workspaceId", "deviceId", "destination", "exportSHA256", "sourceFingerprint", "selectedProjectId"])
        try destination(object["destination"])
    }
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw invalid() }
    }
    static func object(_ data: Data, limit: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= limit else { throw oversized() }
        var scanner = EnvelopeKeys(bytes: Array(data)); try scanner.validate()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
        return object
    }
    /// Check duplicates (including escaped aliases) before Foundation can choose
    /// one value. Only the envelope is scanned here; the exact source has its own
    /// stricter schema scanner in LegacyProjectImportDecoder.
    private struct EnvelopeKeys {
        let bytes: [UInt8]
        var index = 0; var nodes = 0
        mutating func validate() throws {
            try value(depth: 0); whitespace()
            guard index == bytes.count else { throw invalid() }
        }
        mutating func value(depth: Int) throws {
            nodes += 1
            guard depth <= 6, nodes <= 128 else { throw invalid() }
            try Task.checkCancellation(); whitespace(); guard index < bytes.count else { throw invalid() }
            switch bytes[index] {
            case 123:
                index += 1; whitespace(); var names = Set<String>(); if take(125) { return }
                while true {
                    whitespace(); let range = try string()
                    guard range.count <= 256, let name = try? JSONDecoder().decode(String.self, from: Data(bytes[range])), names.insert(name).inserted else { throw invalid() }
                    whitespace(); guard take(58) else { throw invalid() }; try value(depth: depth + 1); whitespace()
                    if take(125) { return }; guard take(44) else { throw invalid() }
                }
            case 91:
                // No envelope fields accept an array. Reject before walking it.
                throw invalid()
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start, index - start <= 64 else { throw invalid() }
            }
        }
        mutating func string() throws -> Range<Int> {
            let start = index; guard take(34) else { throw invalid() }
            while index < bytes.count {
                if index % 65536 == 0 { try Task.checkCancellation() }
                let byte = bytes[index]; index += 1
                if byte == 34 { return start..<index }; if byte == 92 { index += 1 }
            }
            throw invalid()
        }
        mutating func whitespace() { while index < bytes.count, [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
    }
    static func invalid() -> Vapor.Abort { .init(.badRequest, reason: "Send the complete supported source-preparation envelope", identifier: "invalid_staged_import_envelope") }
    static func oversized() -> Vapor.Abort { .init(.payloadTooLarge, reason: "This selected source exceeds the supported preparation size. Keep the original archive", identifier: "staged_import_body_too_large") }
    static func sourceError(_ error: LegacyProjectImportError) -> Vapor.Abort {
        switch error {
        case .sizeLimit, .structureLimit, .recordLimit, .edgeLimit, .fileLimit, .byteLimit, .publicationLimit, .invalidCapacity:
            return .init(.payloadTooLarge, reason: "The complete selected source does not fit the supported import budget. Nothing was published", identifier: "staged_import_graph_too_large")
        case .sourceMismatch:
            return .init(.conflict, reason: "Source bytes do not match the retained selection. Keep the original archive", identifier: "staged_import_source_mismatch")
        default:
            return .init(.badRequest, reason: "The selected source does not match the supported complete graph contract", identifier: "invalid_staged_import_source")
        }
    }
}

/// Explicit opt-in cannot override production prohibition. No provider setting is
/// installed by adding this type/controller to the application.
struct StagedLegacyImportHTTPEnabledKey: StorageKey { typealias Value = Bool }
struct StagedLegacyImportHTTPGate {
    static func require(on app: Application) throws -> ImportServerBinding {
        let enabled = app.storage[StagedLegacyImportHTTPEnabledKey.self] ?? (Environment.get("STAGED_LEGACY_IMPORT_ENABLED") == "true")
        guard enabled else { throw disabled() }
        let binding = try ImportServerBinding.load(on: app)
        guard ["development", "staging"].contains(binding.environment) else { throw disabled() }
        return binding
    }
    static func disabled() -> Vapor.Abort { .init(.serviceUnavailable, reason: "Private source preparation is not enabled in this environment", identifier: "staged_import_disabled") }
}
