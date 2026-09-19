import Vapor
import Fluent
import FluentSQL
import SotoS3

enum StagedImportOriginalService {
    private struct Prepared: Sendable {
        let address: StagedImportOriginalAddress
        let declaration: StagedImportOriginalDeclaration
        let receipt: StagedImportOriginalReceipt?
    }

    /// Caller is an authenticated server boundary. No network transaction is held:
    /// reserve under CURRENT authority, stream/readback, then recheck before receipt.
    /// Cancellation near COMMIT is uncertain; recover with the SAME command/IDs.
    static func retain(_ command: StagedImportOriginalCommand, actor: StagedLegacyImportActor,
                       binding: ImportServerBinding, body: AWSHTTPBody, store: any StagedImportOriginalStore,
                       on database: Database, admission: StagedImportOriginalAdmission? = nil,
                       receiptAuthentication: (@Sendable (Database) async throws -> Void)? = nil, budget: StagedImportIOBudget = try! .init()) async throws -> StagedImportOriginalReceipt {
        let prepared = try await StagedLegacyImportService.withActiveSession(command.scope, actor: actor, binding: binding, on: database) { session, db in
            try await prepare(command, actor: actor, session: session, admission: admission, on: db)
        }
        do {
            try await budget.run {
                if prepared.receipt == nil {
                    let verifiedBody = try await StagedImportOriginalBytes.uploadBody(body, declaration: prepared.declaration, budget: budget)
                    try budget.check()
                    // Validate transport preflight before creating external-write
                    // evidence, then re-enter current source/account authority.
                    let ticket = try await StagedLegacyImportService.withActiveSession(command.scope, actor: actor, binding: binding, on: database) { session, db in
                        try budget.check()
                        let current = try await prepare(command, actor: actor, session: session, admission: admission, on: db)
                        guard current.address == prepared.address, current.declaration == prepared.declaration else { throw conflict() }
                        return try await ObjectWriteIntentService.begin(
                            .init(storageKind: "private_import", key: ImportedObjectKey.original(prepared.address).value,
                                  sha256: prepared.declaration.sha256, byteCount: prepared.declaration.bytes, contentType: "application/octet-stream"),
                            source: .init(kind: "staged_original", id: command.declarationId, sessionID: session.sessionId),
                            scope: .init(userID: actor.id, workspaceID: command.scope.workspaceId), on: db)
                    }
                    _ = try await ObjectWriteIntentService.execute(ticket, on: database, beforeIssuing: { try budget.check() }) {
                        try await store.putIfAbsent(prepared.address, body: verifiedBody, bytes: prepared.declaration.bytes, budget: budget)
                    }
                }
                // Both successful PUT and 412/retry require persisted-byte GET.
                // A missing/corrupt object is a repair failure, never permission to overwrite.
                let persisted = try await store.read(prepared.address, budget: budget)
                try await StagedImportOriginalBytes.measure(persisted, declaration: prepared.declaration, budget: budget)
                try budget.check()
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as StagedImportOriginalError {
            switch error {
            case .invalidDeclaration, .byteCountMismatch, .checksumMismatch, .oversizedChunk:
                throw Abort(.unprocessableEntity, reason: "Original bytes do not match the retained declaration or transport bounds", identifier: "staged_original_bytes_mismatch")
            case .deadlineExceeded:
                throw Abort(.requestTimeout, reason: "Original transfer timed out; retry the same retained operation", identifier: "staged_original_timeout")
            case .objectUnavailable, .storageUnavailable:
                throw unavailable()
            }
        } catch { throw unavailable() } // Never return SDK/body errors or source paths.
        try budget.check()
        return try await StagedLegacyImportService.withActiveSession(command.scope, actor: actor, binding: binding, on: database) { session, db in
            try budget.check()
            try await receiptAuthentication?(db)
            let current = try await prepare(command, actor: actor, session: session, admission: admission, on: db)
            guard current.address == prepared.address, current.declaration == prepared.declaration else { throw conflict() }
            if let old = current.receipt { return old }
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                INSERT INTO staged_import_original_receipts (session_id,declaration_id,receipt_id,actor_id,first_operation_id,device_id,
                    session_revision,measured_sha256,measured_bytes,measured_at,verification,content_validation)
                VALUES (\(bind: session.sessionId),\(bind: command.declarationId),\(bind: UUID()),\(bind: actor.id),\(bind: command.operationId),
                    \(bind: command.scope.deviceId),\(bind: session.revision),\(bind: current.declaration.sha256),\(bind: current.declaration.bytes),
                    CURRENT_TIMESTAMP,'persisted_original_bytes_v1','opaque_not_decoded')
                """).run()
            // Read server timestamp/values, so initial return and replay are exact.
            guard let receipt = try await loadReceipt(command, actor: actor, declaration: current.declaration, on: db) else { throw conflict() }
            try budget.check()
            return receipt
        }
    }

    /// Runs only inside withActiveSession's current workspace/user/actor scope lock.
    /// This intentionally separate operation namespace does not invert the global
    /// operation→workspace lock order or alias global mutation_receipts.
    private static func prepare(_ command: StagedImportOriginalCommand, actor: StagedLegacyImportActor,
                                session: StagedLegacyImportReceipt, admission: StagedImportOriginalAdmission? = nil, on db: Database) async throws -> Prepared {
        guard command.expectedSessionRevision > 0, session.revision == command.expectedSessionRevision,
              command.scope.deviceId == session.deviceId else { throw conflict() }
        try await VerifiedIdentityService.lock("staged-original-file-v1:\(actor.id):\(command.operationId)", on: db)
        let sql = try VerifiedIdentityService.sql(db)
        guard let file = try await sql.raw("SELECT declared_sha256,declared_bytes FROM staged_legacy_import_files WHERE session_id = \(bind: session.sessionId) AND declaration_id = \(bind: command.declarationId)").first() else {
            throw Abort(.notFound, reason: "Declared original is unavailable", identifier: "staged_original_not_found")
        }
        let declaration = try StagedImportOriginalDeclaration(sha256: file.decode(column: "declared_sha256", as: String.self), bytes: file.decode(column: "declared_bytes", as: Int64.self))
        try StagedImportOriginalBytes.validate(declaration)
        if let admission {
            guard admission.maximumBytes > 0, admission.maximumBytes <= StagedImportOriginalBytes.maximumBytes else { throw conflict() }
            guard declaration.bytes <= admission.maximumBytes else {
                throw Abort(.payloadTooLarge, reason: "This original exceeds the current single-request transfer limit. Keep it in the source archive", identifier: "staged_original_transport_limit")
            }
            guard admission.expectedInputBytes == declaration.bytes else {
                throw Abort(.badRequest, reason: "Content-Length must match this retained original declaration", identifier: "staged_original_length_mismatch")
            }
        }

        let hash = try PlatformMutationService.requestHash(command, route: "PRIVATE:staged-original-file-v1:\(declaration.sha256):\(declaration.bytes)")
        if let old = try await sql.raw("SELECT actor_id,operation_id,request_hash FROM staged_import_file_operations WHERE (actor_id = \(bind: actor.id) AND operation_id = \(bind: command.operationId)) OR (session_id = \(bind: session.sessionId) AND declaration_id = \(bind: command.declarationId)) LIMIT 1").first() {
            guard try old.decode(column: "actor_id", as: UUID.self) == actor.id,
                  try old.decode(column: "operation_id", as: UUID.self) == command.operationId,
                  try old.decode(column: "request_hash", as: String.self) == hash else { throw conflict() }
        } else {
            try await sql.raw("""
                INSERT INTO staged_import_file_operations(actor_id,operation_id,session_id,declaration_id,device_id,session_revision,request_hash,created_at)
                VALUES (\(bind: actor.id),\(bind: command.operationId),\(bind: session.sessionId),\(bind: command.declarationId),
                    \(bind: session.deviceId),\(bind: session.revision),\(bind: hash),CURRENT_TIMESTAMP)
                """).run()
        }
        return try await .init(address: .init(workspaceId: session.workspaceId, sessionId: session.sessionId, declarationId: command.declarationId),
            declaration: declaration, receipt: loadReceipt(command, actor: actor, declaration: declaration, on: db))
    }

    private static func loadReceipt(_ command: StagedImportOriginalCommand, actor: StagedLegacyImportActor,
                                    declaration: StagedImportOriginalDeclaration, on db: Database) async throws -> StagedImportOriginalReceipt? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM staged_import_original_receipts WHERE session_id = \(bind: command.scope.sessionId) AND declaration_id = \(bind: command.declarationId)").first() else { return nil }
        let receipt = try StagedImportOriginalReceipt(formatVersion: 1, receiptId: row.decode(column: "receipt_id", as: UUID.self),
            sessionId: row.decode(column: "session_id", as: UUID.self), declarationId: row.decode(column: "declaration_id", as: UUID.self),
            actorId: row.decode(column: "actor_id", as: UUID.self), deviceId: row.decode(column: "device_id", as: UUID.self),
            firstOperationId: row.decode(column: "first_operation_id", as: UUID.self), sessionRevision: row.decode(column: "session_revision", as: Int64.self),
            measuredSHA256: row.decode(column: "measured_sha256", as: String.self), measuredBytes: row.decode(column: "measured_bytes", as: Int64.self),
            measuredAt: row.decode(column: "measured_at", as: Date.self), verification: row.decode(column: "verification", as: String.self),
            contentValidation: row.decode(column: "content_validation", as: String.self), canonicalReady: false)
        guard receipt.actorId == actor.id, receipt.deviceId == command.scope.deviceId, receipt.firstOperationId == command.operationId,
              receipt.sessionRevision == command.expectedSessionRevision, receipt.measuredSHA256 == declaration.sha256,
              receipt.measuredBytes == declaration.bytes, receipt.verification == "persisted_original_bytes_v1", receipt.contentValidation == "opaque_not_decoded" else { throw conflict() }
        return receipt
    }
    private static func conflict() -> Abort {
        Abort(.conflict, reason: "This original operation or preparation changed; retain the original command and identifiers", identifier: "staged_original_operation_conflict")
    }
    private static func unavailable() -> Abort {
        Abort(.serviceUnavailable, reason: "Private original storage could not be verified; retry the same retained operation", identifier: "staged_original_storage_unavailable")
    }
}

/// HTTP transport admission only; never substitutes declared or measured bytes.
struct StagedImportOriginalAdmission: Sendable {
    let maximumBytes: Int64
    let expectedInputBytes: Int64
}

extension StagedImportOriginalService {
    /// Stable, actor-private manifest of declared originals. Does not reserve a
    /// file operation, read object storage, expose source paths or grant access.
    static func manifest(_ request: StagedImportFileManifestRequest, actor: StagedLegacyImportActor,
                         binding: ImportServerBinding, on database: Database) async throws -> StagedImportFileManifest {
        guard request.formatVersion == 1, request.expectedSessionRevision > 0,
              (0...20_000).contains(request.offset), (1...100).contains(request.limit) else { throw StagedImportFileHTTP.invalid() }
        return try await StagedLegacyImportService.withActiveSession(request.scope, actor: actor, binding: binding, on: database) { session, db in
            guard session.revision == request.expectedSessionRevision, request.offset <= session.declaredFileCount else { throw conflict() }
            let sql = try VerifiedIdentityService.sql(db)
            let rows = try await sql.raw("""
                SELECT f.declaration_id,f.archive_path,f.declared_sha256,f.declared_bytes,o.operation_id,o.actor_id,o.device_id,o.session_revision
                FROM staged_legacy_import_files f
                LEFT JOIN staged_import_file_operations o ON o.session_id=f.session_id AND o.declaration_id=f.declaration_id
                WHERE f.session_id = \(bind: session.sessionId)
                ORDER BY f.archive_path COLLATE "C" LIMIT \(bind: request.limit) OFFSET \(bind: request.offset)
                """).all()
            guard rows.count == min(request.limit, session.declaredFileCount - request.offset) else { throw conflict() }
            var entries: [StagedImportFileManifest.Entry] = []
            for (index, row) in rows.enumerated() {
                try Task.checkCancellation()
                let id = try row.decode(column: "declaration_id", as: UUID.self)
                let declaration = try StagedImportOriginalDeclaration(sha256: row.decode(column: "declared_sha256", as: String.self), bytes: row.decode(column: "declared_bytes", as: Int64.self))
                let operation = try row.decode(column: "operation_id", as: UUID?.self)
                let receipt: StagedImportOriginalReceipt?
                if let operation {
                    guard try row.decode(column: "actor_id", as: UUID.self) == actor.id,
                          try row.decode(column: "device_id", as: UUID.self) == session.deviceId,
                          try row.decode(column: "session_revision", as: Int64.self) == session.revision else { throw conflict() }
                    receipt = try await loadReceipt(.init(scope: request.scope, declarationId: id, operationId: operation, expectedSessionRevision: session.revision), actor: actor, declaration: declaration, on: db)
                } else { receipt = nil }
                entries.append(.init(declarationId: id, ordinal: request.offset + index, handleDigestVersion: 1,
                    sourceHandleSHA256: StagedImportFileHTTP.sourceHandleDigest(try row.decode(column: "archive_path", as: String.self)),
                    declaredSHA256: declaration.sha256, declaredBytes: declaration.bytes, operationId: operation, originalReceipt: receipt,
                    storageState: receipt != nil ? "persisted_original_verified" : (operation != nil ? "operation_reserved" : "declared_only"),
                    uploadSupported: declaration.bytes <= StagedImportFileHTTP.maximumUploadBytes))
            }
            let next = request.offset + entries.count
            return .init(formatVersion: 1, scope: request.scope, sessionRevision: session.revision, totalCount: session.declaredFileCount,
                offset: request.offset, nextOffset: next < session.declaredFileCount ? next : nil,
                descriptorMaximumBytes: LegacyProjectImportDecoder.maximumBytes, totalDeclaredFileMaximumBytes: StagedImportOriginalBytes.maximumBytes,
                singleRequestMaximumBytes: StagedImportFileHTTP.maximumUploadBytes, supportedContentType: "application/octet-stream",
                supportedOriginalRoles: ["projectCover", "photoOriginal", "photoThumbnail", "photoAnnotation", "drawingFile", "drawingThumbnail", "commentAttachment", "deletedPhoto"],
                canonicalReady: false, entries: entries)
        }
    }
}
