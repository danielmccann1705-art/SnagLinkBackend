import Vapor
import Fluent
import FluentSQL

/// Durable PRIVATE preparation. These methods own their transaction so source,
/// mappings, present-day action and small retry pointer commit or roll back together.
/// No ProjectAccessService, canonical writes, media verification or executable commit.
struct StagedLegacyImportService {
    /// Fluent bridges this closure through makeFutureWithTask, so Swift's
    /// task-local cancellation flag does not propagate into that new task.
    /// Keep an explicit, thread-safe flag across the bridge instead.
    private final class CancellationFence: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
            try Task.checkCancellation()
        }
    }
    private static func transaction<T>(_ database: Database,
        body: @escaping (Database, CancellationFence) async throws -> T) async throws -> T {
        let fence = CancellationFence()
        return try await withTaskCancellationHandler(operation: {
            try fence.check()
            let result = try await database.transaction { db in
                try fence.check()
                let result = try await body(db, fence)
                // This is the final application boundary before Fluent issues
                // COMMIT. Cancellation after it may be an uncertain committed
                // outcome; replay the same immutable operation to resolve it.
                try fence.check()
                return result
            }
            try fence.check()
            return result
        }, onCancel: { fence.cancel() })
    }
    private struct Pointer: Codable { let sessionId: UUID }
    private struct Authority { let fingerprint: String; let kind: String; let directoryRows: Int }
    private struct Record { let kind: LegacyImportRecordKind; let id: UUID; let json: String }
    static let maximumRetainedSessions = 32
    static let maximumRetainedDescriptorBytes = 64 * 1024 * 1024

    static func create(_ command: StagedLegacyImportCommand, descriptor: Data, workspaceID: UUID,
                       actor: StagedLegacyImportActor, binding: ImportServerBinding, on database: Database,
                       now: Date = Date()) async throws -> StagedLegacyImportReceipt {
        try command.validate(actor: actor, binding: binding)
        let decoded = try LegacyProjectImportDecoder.decode(descriptor, expected: .init(exportSHA256: command.exportSHA256,
            exportByteCount: command.exportByteCount, selectedProjectID: command.selectedProjectId, sourceFingerprint: command.sourceFingerprint))
        let hash = try PlatformMutationService.requestHash(command, route: "PRIVATE:stage-legacy-source:\(workspaceID)")
        return try await transaction(database) { db, cancellation in
            try await PlatformMutationService.lock(actorID: actor.id, mutation: command.mutation, on: db)
            try await VerifiedIdentityService.lock("staged-import-session:\(command.sessionId)", on: db)
            try await VerifiedIdentityService.lock("staged-import-source:\(actor.id):\(binding.environment):\(binding.apiOrigin):\(command.sourceFingerprint):\(command.selectedProjectId)", on: db)
            let authority = try await authority(workspaceID: workspaceID, actor: actor, on: db)
            guard authority.kind == command.expectedWorkspaceKind else { throw bindingChanged() }
            let graph = try LegacyProjectImportGraphValidator.validate(decoded, capacity: .init(existingWorkspaceDirectoryRows: authority.directoryRows))
            if let old = try await PlatformMutationService.replay(Pointer.self, actorID: actor.id, mutation: command.mutation, hash: hash, on: db) {
                guard old.sessionId == command.sessionId else { throw bindingChanged() }
                let receipt = try await readLocked(scope(command, workspaceID: workspaceID), actor: actor, authority: authority, binding: binding, on: db)
                try await verifyDescriptor(receipt, expectedBytes: descriptor, on: db)
                return receipt // An aborted first write stays aborted, never reactivated.
            }
            let sql = try VerifiedIdentityService.sql(db)
            guard try await sql.raw("SELECT id FROM staged_legacy_imports WHERE id = \(bind: command.sessionId) OR (actor_id = \(bind: actor.id) AND environment = \(bind: binding.environment) AND api_origin = \(bind: binding.apiOrigin) AND source_fingerprint = \(bind: command.sourceFingerprint) AND source_project_id = \(bind: command.selectedProjectId)) LIMIT 1").first() == nil else { throw conflict() }
            // Serialize quota across different source/workspace preparations by one actor.
            try await VerifiedIdentityService.lock("staged-import-actor-quota:\(actor.id)", on: db)
            let quota = try await sql.raw("SELECT count(*) AS n, coalesce(sum(export_byte_count),0) AS bytes FROM staged_legacy_imports WHERE actor_id = \(bind: actor.id)").first()!
            guard try quota.decode(column: "n", as: Int.self) < maximumRetainedSessions,
                  try quota.decode(column: "bytes", as: Int64.self) + Int64(descriptor.count) <= maximumRetainedDescriptorBytes else {
                throw Abort(.payloadTooLarge, reason: "Retained preparation capacity is reached; keep the local archive", identifier: "import_retention_capacity")
            }
            let receipt = StagedLegacyImportReceipt(formatVersion: 1, sessionId: command.sessionId, createOperationId: command.mutation.operationId,
                deviceId: command.mutation.deviceId, actorId: actor.id, workspaceId: workspaceID, workspaceKind: authority.kind,
                destination: binding.destination, selectedProjectId: command.selectedProjectId, sourceFingerprint: command.sourceFingerprint,
                exportSHA256: command.exportSHA256, exportByteCount: descriptor.count, requestHash: hash, state: "staged_incomplete", revision: 1,
                recordCounts: Dictionary(uniqueKeysWithValues: graph.sourceRecordIDs.map { ($0.key.rawValue, $0.value.count) }), edgeCount: graph.edges.count,
                fileRoleCounts: Dictionary(uniqueKeysWithValues: graph.fileRoleCounts.map { ($0.key.rawValue, $0.value) }),
                declaredFileCount: graph.declaredFiles.count, declaredFileBytes: graph.totalDeclaredFileBytes,
                sourceIssueCounts: Dictionary(grouping: graph.issues, by: \.code).mapValues(\.count),
                journalEventUpperBound: graph.publicationBudget.journalEventUpperBound, snapshotRowUpperBound: graph.publicationBudget.snapshotRowUpperBound,
                acknowledgementVersion: command.acknowledgement.version, acknowledgedAt: now, createdAt: now, updatedAt: now,
                importExecutable: false, mediaVerification: graph.mediaVerification, historicalAcceptance: graph.historicalAcceptance)
            try await sql.raw("""
                INSERT INTO staged_legacy_imports (id,actor_id,workspace_id,workspace_kind,environment,api_origin,device_id,operation_id,auth_version,
                    authority_fingerprint,source_project_id,source_fingerprint,export_sha256,export_byte_count,request_hash,state,revision,
                    acknowledgement_version,acknowledgement_wording,acknowledged_at,created_at,updated_at,summary_json)
                VALUES (\(bind: command.sessionId),\(bind: actor.id),\(bind: workspaceID),\(bind: authority.kind),\(bind: binding.environment),\(bind: binding.apiOrigin),
                    \(bind: command.mutation.deviceId),\(bind: command.mutation.operationId),\(bind: actor.authVersion),\(bind: authority.fingerprint),
                    \(bind: command.selectedProjectId),\(bind: command.sourceFingerprint),\(bind: command.exportSHA256),\(bind: descriptor.count),\(bind: hash),
                    'staged_incomplete',1,\(bind: command.acknowledgement.version),\(bind: command.acknowledgement.wording),\(bind: now),\(bind: now),\(bind: now),\(bind: PlatformMutationService.encode(receipt)))
                """).run()
            try await sql.raw("INSERT INTO staged_legacy_import_sources (session_id,descriptor) VALUES (\(bind: command.sessionId),decode(\(bind: descriptor.base64EncodedString()),'base64'))").run()
            try await retain(graph, sessionID: command.sessionId, cancellation: cancellation, on: db)
            try await action(sessionID: command.sessionId, revision: 1, name: "source_staged", actor: actor, mutation: command.mutation, now: now, on: db)
            try cancellation.check()
            try await PlatformMutationService.record(Pointer(sessionId: command.sessionId), actorID: actor.id, workspaceID: workspaceID, mutation: command.mutation, hash: hash, on: db)
            return receipt
        }
    }

    static func read(_ scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                     on database: Database) async throws -> StagedLegacyImportReceipt {
        try await transaction(database) { db, cancellation in
            let authority = try await authority(workspaceID: scope.workspaceId, actor: actor, on: db)
            return try await readLocked(scope, actor: actor, authority: authority, binding: binding, on: db)
        }
    }

    /// Runs the next storage step under the same CURRENT account/workspace lock.
    /// The callback must keep DB work inside this transaction. Never hold this
    /// lease across a network upload; re-enter after IO before retaining a receipt.
    /// No auth token, database or authority value may be cached as future permission.
    /// Once a session is published, its preparation is frozen: file uploads, projection
    /// changes and abort are refused (`allowPublished: false`). Readers of the commit
    /// receipt and processing status pass `allowPublished: true`.
    static func withActiveSession<T>(_ scope: StagedLegacyImportScope, actor: StagedLegacyImportActor,
                                     binding: ImportServerBinding, on database: Database, allowPublished: Bool = false,
                                     body: @escaping (StagedLegacyImportReceipt, Database) async throws -> T) async throws -> T {
        try await transaction(database) { db, cancellation in
            let authority = try await authority(workspaceID: scope.workspaceId, actor: actor, on: db)
            let receipt = try await readLocked(scope, actor: actor, authority: authority, binding: binding, on: db)
            guard receipt.state == "staged_incomplete" else { throw Abort(.gone, reason: "This preparation was aborted", identifier: "import_preparation_aborted") }
            if !allowPublished { try await LegacyImportProcessingService.requireUnpublished(receipt.sessionId, on: db) }
            try cancellation.check()
            return try await body(receipt, db)
        }
    }

    /// Internal consumer only, deliberately not Content and with no HTTP route.
    /// Aborted sources cannot be loaded for processing. Future redaction must deny
    /// this whole retained source before exposing any derived historical projection.
    static func loadVerifiedGraph(_ scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                                  on database: Database) async throws -> LegacyProjectImportGraph {
        try await transaction(database) { db, cancellation in
            let authority = try await authority(workspaceID: scope.workspaceId, actor: actor, on: db)
            let receipt = try await readLocked(scope, actor: actor, authority: authority, binding: binding, on: db)
            guard receipt.state == "staged_incomplete" else { throw Abort(.gone, reason: "This preparation was aborted", identifier: "import_preparation_aborted") }
            let bytes = try await sourceBytes(receipt.sessionId, on: db)
            let decoded = try LegacyProjectImportDecoder.decode(bytes, expected: .init(exportSHA256: receipt.exportSHA256, exportByteCount: receipt.exportByteCount,
                selectedProjectID: receipt.selectedProjectId, sourceFingerprint: receipt.sourceFingerprint))
            return try LegacyProjectImportGraphValidator.validate(decoded, capacity: .init(existingWorkspaceDirectoryRows: authority.directoryRows))
        }
    }

    static func abort(_ command: AbortStagedLegacyImportCommand, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                      on database: Database, now: Date = Date()) async throws -> StagedLegacyImportReceipt {
        guard command.mutation.deviceId == command.scope.deviceId, command.expectedRevision > 0 else { throw bindingChanged() }
        let hash = try PlatformMutationService.requestHash(command, route: "PRIVATE:abort-legacy-source:\(command.scope.workspaceId)")
        return try await transaction(database) { db, cancellation in
            try await PlatformMutationService.lock(actorID: actor.id, mutation: command.mutation, on: db)
            let authority = try await authority(workspaceID: command.scope.workspaceId, actor: actor, on: db)
            let current = try await readLocked(command.scope, actor: actor, authority: authority, binding: binding, on: db)
            if let replay = try await PlatformMutationService.replay(Pointer.self, actorID: actor.id, mutation: command.mutation, hash: hash, on: db) {
                guard replay.sessionId == current.sessionId, current.state == "aborted" else { throw bindingChanged() }
                return current
            }
            guard current.state == "staged_incomplete", current.revision == command.expectedRevision else { throw conflict() }
            try await LegacyImportProcessingService.requireUnpublished(current.sessionId, on: db)
            // Change only state/revision/present-day action. Source and mappings remain immutable.
            let updated = current.aborted(at: now)
            try await VerifiedIdentityService.sql(db).raw("UPDATE staged_legacy_imports SET state = 'aborted', revision = \(bind: updated.revision), updated_at = \(bind: now), summary_json = \(bind: PlatformMutationService.encode(updated)) WHERE id = \(bind: current.sessionId)").run()
            try await action(sessionID: current.sessionId, revision: updated.revision, name: "preparation_aborted", actor: actor, mutation: command.mutation, now: now, on: db)
            try await PlatformMutationService.record(Pointer(sessionId: current.sessionId), actorID: actor.id, workspaceID: current.workspaceId, mutation: command.mutation, hash: hash, on: db)
            return updated
        }
    }

    static func scope(_ command: StagedLegacyImportCommand, workspaceID: UUID) -> StagedLegacyImportScope {
        .init(sessionId: command.sessionId, workspaceId: workspaceID, deviceId: command.mutation.deviceId, destination: command.destination,
              exportSHA256: command.exportSHA256, sourceFingerprint: command.sourceFingerprint, selectedProjectId: command.selectedProjectId)
    }

    private static func authority(workspaceID: UUID, actor: StagedLegacyImportActor, on db: Database) async throws -> Authority {
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        // Row lock serializes logout-all/auth-version/lifecycle updates with this
        // transaction, while workspace lock serializes membership/owner changes.
        guard let user = try await sql.raw("SELECT auth_version,lifecycle_state FROM users WHERE id = \(bind: actor.id) FOR SHARE").first(),
              try user.decode(column: "lifecycle_state", as: String.self) == "active",
              try user.decode(column: "auth_version", as: Int.self) == actor.authVersion else { throw Abort(.unauthorized) }
        guard let workspace = try await Team.find(workspaceID, on: db) else { throw Abort(.notFound) }
        let role = try await WorkspaceAccessService.role(actorID: actor.id, workspace: workspace, on: db)
        guard ["owner", "admin"].contains(role) else { throw Abort(.forbidden, reason: "A current workspace owner or admin must prepare this import") }
        let membership = try await sql.raw("SELECT role,state,revision FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: actor.id)").first()
        var facts = [actor.id.uuidString, String(actor.authVersion), workspaceID.uuidString, workspace.kind, workspace.ownerUserId.uuidString,
                     workspace.lifecycleState, String(workspace.revision), role]
        if let membership { facts += [try membership.decode(column: "role", as: String.self), try membership.decode(column: "state", as: String.self), String(try membership.decode(column: "revision", as: Int64.self))] }
        else { facts.append("no-membership-row") }
        let count = try await sql.raw("SELECT (SELECT count(*) FROM contractors WHERE workspace_id = \(bind: workspaceID) AND platform_managed) + (SELECT count(*) FROM trades WHERE workspace_id = \(bind: workspaceID) AND platform_managed) AS n").first()!.decode(column: "n", as: Int.self)
        return .init(fingerprint: SHA256Hasher.hash(token: facts.joined(separator: "\n")), kind: workspace.kind, directoryRows: count)
    }

    private static func readLocked(_ scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, authority: Authority,
                                   binding: ImportServerBinding, on db: Database) async throws -> StagedLegacyImportReceipt {
        guard scope.destination == binding.destination else { throw bindingChanged() }
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM staged_legacy_imports WHERE id = \(bind: scope.sessionId) AND actor_id = \(bind: actor.id) AND workspace_id = \(bind: scope.workspaceId)").first() else { throw Abort(.notFound) }
        guard try row.decode(column: "auth_version", as: Int.self) == actor.authVersion,
              try row.decode(column: "authority_fingerprint", as: String.self) == authority.fingerprint,
              try row.decode(column: "device_id", as: UUID.self) == scope.deviceId,
              try row.decode(column: "environment", as: String.self) == binding.environment,
              try row.decode(column: "api_origin", as: String.self) == binding.apiOrigin,
              try row.decode(column: "export_sha256", as: String.self) == scope.exportSHA256,
              try row.decode(column: "source_fingerprint", as: String.self) == scope.sourceFingerprint,
              try row.decode(column: "source_project_id", as: UUID.self) == scope.selectedProjectId else { throw bindingChanged() }
        let receipt = try PlatformMutationService.decode(StagedLegacyImportReceipt.self, row.decode(column: "summary_json", as: String.self))
        guard receipt.sessionId == scope.sessionId, receipt.actorId == actor.id, receipt.workspaceId == scope.workspaceId,
              receipt.deviceId == scope.deviceId, receipt.destination == binding.destination, receipt.workspaceKind == authority.kind,
              receipt.exportSHA256 == scope.exportSHA256, receipt.sourceFingerprint == scope.sourceFingerprint, receipt.selectedProjectId == scope.selectedProjectId,
              receipt.exportByteCount == (try row.decode(column: "export_byte_count", as: Int.self)),
              receipt.createOperationId == (try row.decode(column: "operation_id", as: UUID.self)),
              receipt.requestHash == (try row.decode(column: "request_hash", as: String.self)),
              receipt.acknowledgementVersion == (try row.decode(column: "acknowledgement_version", as: String.self)),
              receipt.state == (try row.decode(column: "state", as: String.self)), receipt.revision == (try row.decode(column: "revision", as: Int64.self)),
              !receipt.importExecutable, receipt.mediaVerification == "source_declarations_only",
              receipt.historicalAcceptance == "unverified_no_canonical_decisions_created" else { throw bindingChanged() }
        return receipt
    }
    private static func sourceBytes(_ sessionID: UUID, on db: Database) async throws -> Data {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT encode(descriptor,'base64') AS bytes FROM staged_legacy_import_sources WHERE session_id = \(bind: sessionID)").first(),
              let bytes = try Data(base64Encoded: row.decode(column: "bytes", as: String.self), options: .ignoreUnknownCharacters),
              bytes.count <= LegacyProjectImportDecoder.maximumBytes else { throw bindingChanged() }
        return bytes
    }
    private static func verifyDescriptor(_ receipt: StagedLegacyImportReceipt, expectedBytes: Data, on db: Database) async throws {
        let retained = try await sourceBytes(receipt.sessionId, on: db)
        guard retained == expectedBytes, retained.count == receipt.exportByteCount, LegacyProjectImportDecoder.digest(retained) == receipt.exportSHA256 else { throw bindingChanged() }
    }
    private static func action(sessionID: UUID, revision: Int64, name: String, actor: StagedLegacyImportActor,
                               mutation: MutationMetadata, now: Date, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO staged_legacy_import_actions (session_id,revision,actor_id,operation_id,device_id,action,happened_at) VALUES (\(bind: sessionID),\(bind: revision),\(bind: actor.id),\(bind: mutation.operationId),\(bind: mutation.deviceId),\(bind: name),\(bind: now))").run()
    }
    private static func retain(_ graph: LegacyProjectImportGraph, sessionID: UUID, cancellation: CancellationFence, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        for record in try records(graph.decoded.source) {
            try cancellation.check()
            try await sql.raw("INSERT INTO staged_legacy_import_records (session_id,kind,source_id,mapping_id,proposed_target_id,mapping_state,source_json,source_sha256) VALUES (\(bind: sessionID),\(bind: record.kind.rawValue),\(bind: record.id),\(bind: UUID()),\(bind: record.id),'unreserved_source_id',\(bind: record.json),\(bind: SHA256Hasher.hash(token: record.json)))").run()
        }
        for (position, edge) in graph.edges.enumerated() {
            try cancellation.check()
            try await sql.raw("INSERT INTO staged_legacy_import_edges (session_id,position,kind,source_id,field,target_kind,target_source_id,target_present) VALUES (\(bind: sessionID),\(bind: position),\(bind: edge.kind.rawValue),\(bind: edge.recordID),\(bind: edge.field),\(bind: edge.targetKind.rawValue),\(bind: edge.targetID),\(bind: edge.targetPresent))").run()
        }
        for file in graph.declaredFiles {
            try cancellation.check()
            try await sql.raw("INSERT INTO staged_legacy_import_files (session_id,declaration_id,archive_path,declared_sha256,declared_bytes,verification_state) VALUES (\(bind: sessionID),\(bind: UUID()),\(bind: file.archivePath),\(bind: file.sha256),\(bind: file.bytes),'unverified_declaration')").run()
        }
        for use in graph.fileUses {
            try cancellation.check()
            try await sql.raw("INSERT INTO staged_legacy_import_file_uses (session_id,use_id,kind,source_id,role,position,required,source_json) VALUES (\(bind: sessionID),\(bind: UUID()),\(bind: use.kind.rawValue),\(bind: use.recordID),\(bind: use.role.rawValue),\(bind: use.position),\(bind: use.required),\(bind: sourceJSON(use.source)))").run()
        }
    }
    /// Native dates keep reference-date seconds and fractional values. These are
    /// typed projections, never the exact descriptor hash or verified authorship.
    private static func sourceJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func records(_ source: LegacyProjectImportSource) throws -> [Record] {
        var output: [Record] = []
        func add<T: Encodable>(_ kind: LegacyImportRecordKind, _ id: UUID, _ value: T) throws {
            output.append(.init(kind: kind, id: id, json: try sourceJSON(value)))
        }
        try add(.projects, source.project.id, source.project)
        for value in source.snags { try add(.snags, value.id, value) }
        for value in source.photos { try add(.photos, value.id, value) }
        for value in source.drawings { try add(.drawings, value.id, value) }
        for value in source.contractors { try add(.contractors, value.id, value) }
        for value in source.trades { try add(.trades, value.id, value) }
        for value in source.folders { try add(.folders, value.id, value) }
        for value in source.tags { try add(.tags, value.id, value) }
        for value in source.comments { try add(.comments, value.id, value) }
        for value in source.statusHistory { try add(.statusHistory, value.id, value) }
        for value in source.deletionReceipts { try add(.deletionReceipts, value.deletedSnagID, value) }
        return output
    }
    static func bindingChanged() -> Abort { Abort(.conflict, reason: "The preparation's account, authority, device, source or destination changed. Keep the original archive", identifier: "import_preparation_binding_changed") }
    static func conflict() -> Abort { Abort(.conflict, reason: "This source or operation already has a preparation. Resume its original binding", identifier: "import_preparation_conflict") }
}
