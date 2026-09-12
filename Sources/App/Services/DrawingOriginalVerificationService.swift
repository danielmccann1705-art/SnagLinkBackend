import Vapor
import Fluent
import FluentSQL
import Crypto

/// Trusted internal context. Actor comes from verified server authentication;
/// this is not a client-decoded receipt, storage key or renderer credential.
struct DrawingUploadBinding: Sendable {
    let workspaceId: UUID
    let projectId: UUID
    let assetId: UUID
    let actorId: UUID
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let processorProfile: String
}

struct DrawingOriginalReadTarget: Sendable {
    let binding: DrawingUploadBinding
    let deadline: Date
    /// Internal only. Never expose this target through HTTP or accept a caller key.
    var originalKey: String {
        "drawings/\(binding.workspaceId)/\(binding.projectId)/\(binding.assetId)/original"
    }
}

/// Pull-based, bounded object read. Implementations must read the persisted
/// private original, never substitute the request body or a claimed checksum.
/// They must enforce the target deadline and cancel blocked reads/owned IO.
struct DrawingOriginalObjectRead: Sendable {
    let mimeType: String
    let nextChunk: @Sendable () async throws -> Data?
    let cancel: @Sendable () async -> Void
}
protocol DrawingOriginalObjectReading: Sendable {
    func openOriginal(_ target: DrawingOriginalReadTarget) async throws -> DrawingOriginalObjectRead
}

/// Historical measured-byte fact. It does not attest parser success, current
/// object availability, publication, or an observed processor image execution.
struct DrawingOriginalReceipt: Encodable, Sendable {
    let assetId: UUID
    let workspaceId: UUID
    let projectId: UUID
    let uploaderId: UUID
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let processorProfile: String
    let verificationMethod: String
    let verifiedAt: Date
    let assetRevision: Int64
    init(_ row: SQLRow) throws {
        assetId = try row.decode(column: "asset_id", as: UUID.self)
        workspaceId = try row.decode(column: "workspace_id", as: UUID.self)
        projectId = try row.decode(column: "project_id", as: UUID.self)
        uploaderId = try row.decode(column: "uploader_id", as: UUID.self)
        sha256 = try row.decode(column: "measured_sha256", as: String.self)
        byteCount = try row.decode(column: "measured_size", as: Int.self)
        mimeType = try row.decode(column: "measured_mime", as: String.self)
        processorProfile = try row.decode(column: "processor_profile", as: String.self)
        verificationMethod = try row.decode(column: "verification_method", as: String.self)
        verifiedAt = try row.decode(column: "verified_at", as: Date.self)
        assetRevision = try row.decode(column: "asset_revision", as: Int64.self)
    }
}

enum DrawingOriginalVerificationService {
    static let verificationMethod = "drawing-original-readback-v1"
    static let maximumChunkBytes = 65536
    private struct Context { let asset: DrawingAssetRecord; let receipt: DrawingOriginalReceipt? }
    // Only measure() in this file can construct a receipt input. There is no
    // endpoint/Decodable form accepting client-declared "verified" metadata.
    private struct Measured { let sha256: String; let byteCount: Int; let mimeType: String }

    static func requireCurrentUpload(_ expected: DrawingUploadBinding, runtime: DrawingProcessorRuntimeIdentity,
                                     on database: Database) async throws -> DrawingOriginalReadTarget {
        try await database.transaction { db in
            let context = try await checked(expected, runtime: runtime, allowReceiptReplay: false, on: db)
            return .init(binding: expected, deadline: min(context.asset.expiresAt, Date().addingTimeInterval(120)))
        }
    }

    /// Bytes must already be stored using immutable private-object writes.
    /// No transaction spans storage IO. Fresh readback is required even on retry;
    /// successful retries return the same historical receipt/revision/time.
    /// Allocation expiry also blocks re-verification of an existing receipt.
    /// It does not expire/delete that durable fact or change the source state.
    static func verifyStoredOriginal(_ expected: DrawingUploadBinding, runtime: DrawingProcessorRuntimeIdentity,
                                     reader: any DrawingOriginalObjectReading,
                                     on database: Database) async throws -> DrawingOriginalReceipt {
        try Task.checkCancellation()
        let first = try await database.transaction { db in
            try await checked(expected, runtime: runtime, allowReceiptReplay: true, on: db)
        }
        let target = DrawingOriginalReadTarget(binding: expected,
            deadline: min(first.asset.expiresAt, Date().addingTimeInterval(120)))
        let measured = try await measure(target, reader: reader)
        return try await database.transaction { db in
            let context = try await checked(expected, runtime: runtime, allowReceiptReplay: true, on: db)
            try Task.checkCancellation()
            if let old = context.receipt {
                guard old.sha256 == measured.sha256, old.byteCount == measured.byteCount,
                      old.mimeType == measured.mimeType, old.processorProfile == expected.processorProfile,
                      old.verificationMethod == verificationMethod else { throw conflict() }
                return old
            }
            guard context.asset.state == "allocated", context.asset.revision < Int64.max else { throw conflict() }
            let revision = context.asset.revision + 1, sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                INSERT INTO drawing_original_receipts(asset_id,workspace_id,project_id,uploader_id,
                    measured_sha256,measured_size,measured_mime,processor_profile,verification_method,verified_at,asset_revision)
                VALUES(\(bind: expected.assetId),\(bind: expected.workspaceId),\(bind: expected.projectId),\(bind: expected.actorId),
                    \(bind: measured.sha256),\(bind: measured.byteCount),\(bind: measured.mimeType),\(bind: expected.processorProfile),
                    \(bind: verificationMethod),\(bind: Date()),\(bind: revision))
                """).run()
            try await sql.raw("UPDATE drawing_assets SET revision = \(bind: revision) WHERE id = \(bind: expected.assetId)").run()
            try Task.checkCancellation()
            guard let receipt = try await receipt(expected.assetId, on: db) else { throw conflict() }
            return receipt
        }
    }

    private static func checked(_ expected: DrawingUploadBinding, runtime: DrawingProcessorRuntimeIdentity,
                                allowReceiptReplay: Bool, on db: Database) async throws -> Context {
        guard expected.processorProfile == runtime.processorProfile,
              CanonicalDrawingService.hashValid(expected.sha256),
              ["application/pdf", "image/jpeg", "image/png"].contains(expected.mimeType), expected.byteCount > 0,
              expected.byteCount <= (expected.mimeType == "application/pdf" ? 52428800 : 10485760) else { throw conflict() }
        try await WorkspaceAccessService.lock(expected.workspaceId, on: db)
        guard let candidate = try await Project.find(expected.projectId, on: db),
              candidate.workspaceId == expected.workspaceId, candidate.platformManaged else { throw unavailable() }
        let sql = try VerifiedIdentityService.sql(db)
        // Establish the immutable source/FK before entering the older access
        // helper; it cannot silently assign an unscoped source project.
        guard let row = try await sql.raw("SELECT * FROM drawing_assets WHERE id = \(bind: expected.assetId) AND project_id = \(bind: expected.projectId) AND workspace_id = \(bind: expected.workspaceId)").first() else { throw unavailable() }
        let project = try await ProjectAccessService.require(.edit, projectID: expected.projectId, actorID: expected.actorId, on: db).0
        try PlatformMutationService.requireManaged(project)
        guard project.workspaceId == expected.workspaceId else { throw unavailable() }
        let asset = try DrawingAssetRecord(row)
        guard asset.uploaderId == expected.actorId else { throw unavailable() }
        guard try row.decode(column: "purpose", as: String.self) == "drawing_source", asset.expiresAt > Date(),
              asset.sha256 == expected.sha256, asset.byteCount == expected.byteCount, asset.mimeType == expected.mimeType,
              asset.processorProfile == runtime.processorProfile else { throw conflict() }
        let old = try await receipt(asset.id, on: db)
        guard asset.state == "allocated" || (allowReceiptReplay && old != nil && ["processing", "ready"].contains(asset.state)) else { throw conflict() }
        if old == nil {
            guard try await sql.raw("SELECT 1 FROM drawing_processing_jobs WHERE asset_id = \(bind: asset.id)").first() == nil else { throw conflict() }
        }
        return .init(asset: asset, receipt: old)
    }
    private static func receipt(_ assetID: UUID, on db: Database) async throws -> DrawingOriginalReceipt? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM drawing_original_receipts WHERE asset_id = \(bind: assetID)").first() else { return nil }
        return try .init(row)
    }
    private static func measure(_ target: DrawingOriginalReadTarget, reader: any DrawingOriginalObjectReading) async throws -> Measured {
        try Task.checkCancellation()
        guard Date() < target.deadline else { throw Abort(.requestTimeout, reason: "Drawing verification timed out", identifier: "drawing_verification_timeout") }
        let body: DrawingOriginalObjectRead
        do { body = try await reader.openOriginal(target) }
        catch {
            if error is CancellationError { throw error }
            throw Abort(.serviceUnavailable, reason: "Private drawing original unavailable", identifier: "drawing_storage_unavailable")
        }
        do {
            guard body.mimeType == target.binding.mimeType else { throw identityMismatch() }
            var digest = SHA256(), count = 0, prefix = Data(), tail = Data()
            while true {
                try Task.checkCancellation()
                guard Date() < target.deadline else { throw Abort(.requestTimeout, reason: "Drawing verification timed out", identifier: "drawing_verification_timeout") }
                let next: Data?
                do { next = try await body.nextChunk() }
                catch {
                    if error is CancellationError { throw error }
                    throw Abort(.serviceUnavailable, reason: "Private drawing original read failed", identifier: "drawing_storage_read_failed")
                }
                guard let chunk = next else { break }
                guard !chunk.isEmpty, chunk.count <= maximumChunkBytes,
                      chunk.count <= target.binding.byteCount - count else { throw identityMismatch() }
                count += chunk.count; digest.update(data: chunk)
                if prefix.count < 16 { prefix.append(chunk.prefix(16 - prefix.count)) }
                tail.append(chunk); if tail.count > 1024 { tail = Data(tail.suffix(1024)) }
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == target.binding.byteCount, hash == target.binding.sha256 else { throw identityMismatch() }
            guard signature(prefix: prefix, tail: tail, mime: body.mimeType) else {
                throw Abort(.unsupportedMediaType, reason: "Drawing source signature does not match its type", identifier: "drawing_source_signature_invalid")
            }
            try Task.checkCancellation()
            guard Date() < target.deadline else { throw Abort(.requestTimeout, reason: "Drawing verification timed out", identifier: "drawing_verification_timeout") }
            await body.cancel()
            return .init(sha256: hash, byteCount: count, mimeType: body.mimeType)
        } catch {
            await body.cancel()
            if let abort = error as? Abort { throw abort }
            if error is CancellationError { throw error }
            throw Abort(.serviceUnavailable, reason: "Private drawing original read failed", identifier: "drawing_storage_read_failed")
        }
    }
    /// Framing parity with DRA-02 verify_source, not image/PDF decoding. The
    /// isolated parser must still validate structure/geometry and seal input.
    private static func signature(prefix: Data, tail: Data, mime: String) -> Bool {
        if mime == "image/png" { return prefix.starts(with: [137,80,78,71,13,10,26,10]) }
        if mime == "image/jpeg" { return prefix.starts(with: [255,216,255]) && tail.suffix(2).elementsEqual([255,217]) }
        let p = [UInt8](prefix)
        guard mime == "application/pdf", p.count >= 9, p.prefix(5).elementsEqual(Array("%PDF-".utf8)),
              ((p[5] == 49 && p[6] == 46 && (48...55).contains(p[7])) || (p[5] == 50 && p[6] == 46 && p[7] == 48)),
              [10,13,32].contains(p[8]) else { return false }
        let trimmed = tail.reversed().drop(while: { [0,9,10,13,32].contains($0) }).reversed()
        return trimmed.suffix(5).elementsEqual(Array("%%EOF".utf8))
    }
    private static func unavailable() -> Abort { .init(.notFound, reason: "Drawing original unavailable", identifier: "drawing_original_unavailable") }
    private static func conflict() -> Abort { .init(.conflict, reason: "Drawing upload authority changed", identifier: "drawing_upload_authority_changed") }
    private static func identityMismatch() -> Abort { .init(.unprocessableEntity, reason: "Stored drawing bytes do not match their allocation", identifier: "drawing_original_identity_mismatch") }
}
