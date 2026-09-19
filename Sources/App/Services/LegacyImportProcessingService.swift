import Vapor
import Fluent
import FluentSQL
import SotoS3

/// Private, role-specific processing of retained originals for one prepared projection.
/// Object IO never runs inside a SQL transaction; results are recorded under the
/// current source/account fence and are immutable once written. Nothing here
/// publishes a project, grants access or changes the source receipt.
enum LegacyImportProcessingService {
    static let renditionMaximumBytes = PrivateImageProcessor.maximumBytes
    static let drawingThumbnailPixels = 512
    static let drawingProcessorProfile = "legacy-raster-import-v1"

    struct Summary: Codable, Sendable {
        let declaredFileCount: Int, receivedFileCount: Int, processedFileCount: Int
        let decodedImageCount: Int, opaqueFileCount: Int, renderedDrawingCount: Int, unsupportedDrawingCount: Int
        let missingRequiredFileCount: Int
        /// Attempts that failed, across every pass. Zero on a preparation that went
        /// through first time; a rising number on one that is stuck.
        let failedAttemptCount: Int
        /// Files that have failed three times or more and have still not succeeded.
        /// Re-running keeps what is already done, so this is the number that says
        /// whether running it again is worth anything.
        let repeatedlyFailingFileCount: Int
    }
    private struct Pending: Sendable {
        let declarationId: UUID; let receiptId: UUID; let sha256: String; let bytes: Int64
        let roles: Set<LegacyImportFileRole>; let drawingSourceIds: [UUID]
    }
    private struct Decoded: Sendable {
        let mime: String; let width: Int; let height: Int; let rendition: Data; let renditionSHA256: String
    }
    private struct Rendered: Sendable {
        let drawingSourceId: UUID; let assetId: UUID; let geometry: DrawingPageGeometry
        let page: Data; let pageSHA256: String; let thumbnail: Data; let thumbnailSHA256: String; let resultHash: String
    }
    /// Why a file produced no rendition.
    ///
    /// `notAnImage` is a settled fact about the file — a PDF, a document, an oversized
    /// original. `processorFailed` is a fact about *us*: the bytes carried an image
    /// signature we claim to handle and the processor threw anyway. Collapsing the two
    /// into one `opaque` outcome made a transient failure, or a processor bug since
    /// fixed, permanent and invisible: the row excluded the file from every later pass,
    /// and the attempt was recorded as a success.
    enum OpaqueReason: String, Sendable { case notAnImage = "not_an_image", processorFailed = "image_processing_failed" }

    private struct Outcome: Sendable {
        let pending: Pending; let decoded: Decoded?; let rendered: [Rendered]; let unsupportedDrawings: [(UUID, UUID)]
        let renditionKey: ImportedObjectKey?; let pageKeys: [UUID: (ImportedObjectKey, ImportedObjectKey)]
        var opaqueReason: OpaqueReason? = nil
    }

    /// Processes every retained original that has no processing row yet, then reports
    /// the projection's current readiness. Safe to repeat; identical results are reused.
    /// `reprocessFailures` additionally retries files that our own image processor
    /// failed on. Off by default, because an ordinary pass should never revisit a
    /// settled outcome; on, it is the way a processor fix reaches files that were
    /// recorded opaque before it.
    static func process(projectionID: UUID, scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                        store: any StagedImportOriginalStore, on database: Database, budget: StagedImportIOBudget = try! .init(),
                        reprocessFailures: Bool = false) async throws -> Summary {
        let projection = try await LegacyCanonicalProjectionService.read(projectionID: projectionID, scope: scope, actor: actor, binding: binding, on: database)
        let pending = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
            try await pendingDeclarations(projection, session: session, reprocessFailures: reprocessFailures, on: db)
        }
        for item in pending {
            try budget.check()
            let address = StagedImportOriginalAddress(workspaceId: projection.binding.workspaceId, sessionId: projection.binding.sessionId, declarationId: item.declarationId)
            do {
                let writeDerived: @Sendable (ImportedObjectKey, Data, String) async throws -> Void = { key, data, mime in
                    let ticket = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
                        guard session.sessionId == projection.binding.sessionId,
                              try await VerifiedIdentityService.sql(db).raw("SELECT id FROM legacy_canonical_projections WHERE id=\(bind: projection.projectionId) AND session_id=\(bind: session.sessionId)").first() != nil else {
                            throw Abort(.conflict, reason: "Import processing source changed")
                        }
                        return try await ObjectWriteIntentService.begin(
                            .init(storageKind: "private_import", key: key.value, data: data, contentType: mime),
                            source: .init(kind: "import_derived", id: item.declarationId, sessionID: session.sessionId),
                            scope: .init(userID: actor.id, workspaceID: scope.workspaceId), on: db)
                    }
                    try await ObjectWriteIntentService.execute(ticket, on: database) {
                        try await store.putDerived(key, data: data, mime: mime, budget: budget)
                    }
                }
                let outcome = try await decode(item, address: address, projection: projection, store: store, budget: budget, writeDerived: writeDerived)
                _ = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
                    try await record(outcome, projection: projection, on: db)
                    // A processor failure is a failure even though it produced a row:
                    // the row exists so publication is not blocked, and the attempt says
                    // what actually happened so it can be reprocessed later.
                    try await recordAttempt(projection: projection, declarationID: item.declarationId,
                                            failure: outcome.opaqueReason == .processorFailed ? OpaqueReason.processorFailed.rawValue : nil,
                                            on: db)
                }
            } catch is CancellationError {
                // Not this file's failure — the whole run stopped. Recording it as one
                // would make an operator hunt a file that is probably fine.
                throw CancellationError()
            } catch {
                _ = try? await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
                    try await recordAttempt(projection: projection, declarationID: item.declarationId, failure: failureKind(error), on: db)
                }
                throw error
            }
        }
        return try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database, allowPublished: true) { session, db in
            try await summary(projection, session: session, on: db)
        }
    }

    static func requireUnpublished(_ sessionID: UUID, on db: Database) async throws {
        guard try await VerifiedIdentityService.sql(db).raw("SELECT id FROM legacy_import_commits WHERE session_id = \(bind: sessionID)").first() == nil else {
            throw Abort(.conflict, reason: "This preparation was already published. Read its commit receipt instead of changing it", identifier: "import_preparation_published")
        }
    }

    private static func pendingDeclarations(_ projection: LegacyCanonicalProjection, session: StagedLegacyImportReceipt,
                                            reprocessFailures: Bool = false, on db: Database) async throws -> [Pending] {
        let sql = try VerifiedIdentityService.sql(db)
        // Never processed, plus — when asked — the ones our own processor failed on.
        // A file that is simply not an image is never revisited: that outcome is settled
        // and revisiting it would churn every import for nothing.
        let receipts = try await sql.raw("""
            SELECT r.declaration_id, r.receipt_id, r.measured_sha256, r.measured_bytes FROM staged_import_original_receipts r
            LEFT JOIN legacy_import_file_processing p ON p.projection_id = \(bind: projection.projectionId) AND p.declaration_id = r.declaration_id
            WHERE r.session_id = \(bind: session.sessionId)
              AND (p.declaration_id IS NULL
                   OR (\(bind: reprocessFailures) AND p.state = 'opaque' AND EXISTS (
                         SELECT 1 FROM legacy_import_processing_attempts a
                         WHERE a.projection_id = p.projection_id AND a.declaration_id = p.declaration_id
                           AND a.outcome = 'failed' AND a.failure_kind = 'image_processing_failed')))
            ORDER BY r.declaration_id
            """).all()
        let filesByDeclaration = Dictionary(uniqueKeysWithValues: projection.files.map { ($0.declarationId, $0) })
        let usesByFile = Dictionary(grouping: projection.fileUses.filter { $0.fileObjectId != nil }, by: { $0.fileObjectId! })
        return try receipts.map { row in
            let id = try row.decode(column: "declaration_id", as: UUID.self)
            guard let file = filesByDeclaration[id] else { throw Abort(.conflict, reason: "Projection and retained files diverged", identifier: "import_projection_files_diverged") }
            let uses = usesByFile[file.id] ?? []
            return try .init(declarationId: id, receiptId: row.decode(column: "receipt_id", as: UUID.self), sha256: row.decode(column: "measured_sha256", as: String.self),
                bytes: row.decode(column: "measured_bytes", as: Int64.self), roles: Set(uses.map(\.role)),
                drawingSourceIds: uses.filter { $0.role == .drawingFile && $0.kind == .drawings }.map(\.sourceId).sorted { $0.uuidString < $1.uuidString })
        }
    }

    private static func decode(_ item: Pending, address: StagedImportOriginalAddress, projection: LegacyCanonicalProjection,
                               store: any StagedImportOriginalStore, budget: StagedImportIOBudget,
                               writeDerived: @escaping @Sendable (ImportedObjectKey, Data, String) async throws -> Void) async throws -> Outcome {
        let opaque = Outcome(pending: item, decoded: nil, rendered: [], unsupportedDrawings: drawingAssets(item, projection),
                             renditionKey: nil, pageKeys: [:], opaqueReason: .notAnImage)
        // Oversized originals stay retained and readable; only bounded images decode.
        guard item.bytes > 0, item.bytes <= Int64(renditionMaximumBytes) else { return opaque }
        let data: Data
        do {
            let body = try await store.read(address, budget: budget)
            let buffer = try await body.collect(upTo: renditionMaximumBytes)
            data = Data(buffer: buffer)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.serviceUnavailable, reason: "Private original storage could not be read. Run the preparation again — files already processed are kept", identifier: "staged_original_storage_unavailable") }
        guard data.count == Int(item.bytes), LegacyProjectImportDecoder.digest(data) == item.sha256 else {
            throw Abort(.conflict, reason: "Retained original bytes no longer match their receipt", identifier: "staged_original_bytes_mismatch")
        }
        guard let mime = PrivateImageProcessor.detectMime(data) else { return opaque }
        let result: PrivateImageProcessor.Result
        do { result = try PrivateImageProcessor.process(data, mime: mime) }
        catch {
            // The bytes carry a signature we claim to handle, so this is our failure,
            // not the file's. Kept opaque so publication is not blocked by it, but
            // marked so it can be attempted again once the processor is fixed.
            var failed = opaque; failed.opaqueReason = .processorFailed; return failed
        }
        let renditionSHA = PrivateImageProcessor.digest(result.jpeg)
        let renditionKey = try ImportedObjectKey.derived(address, purpose: "rendition", sha256: renditionSHA)
        try await writeDerived(renditionKey, result.jpeg, "image/jpeg")
        let decoded = Decoded(mime: mime, width: result.width, height: result.height, rendition: result.jpeg, renditionSHA256: renditionSHA)
        var rendered: [Rendered] = [], pageKeys: [UUID: (ImportedObjectKey, ImportedObjectKey)] = [:], unsupported: [(UUID, UUID)] = []
        for (drawingID, assetID) in drawingAssets(item, projection) {
            // One raster page: the coordinate surface is the upright decoded source pixel box.
            guard let thumb = try? PrivateImageProcessor.process(data, mime: mime, maximumPixelSize: drawingThumbnailPixels),
                  result.sourceWidth > 0, result.sourceHeight > 0 else { unsupported.append((drawingID, assetID)); continue }
            let w = Double(result.sourceWidth), h = Double(result.sourceHeight)
            let box = DrawingPageGeometry.Box(x: 0, y: 0, width: w, height: h)
            let geometry = DrawingPageGeometry(mediaBox: box, cropBox: box, displayBox: box, rotation: 0, userUnit: 1, width: result.width, height: result.height,
                sourceToDisplay: [1 / w, 0, 0, 1 / h, 0, 0], coordinateSystem: "display_top_left_v1")
            let thumbSHA = PrivateImageProcessor.digest(thumb.jpeg)
            let page = DrawingProcessedPage(sourcePageIndex: 0, sourcePageLabel: "1", geometry: geometry, renditionSHA256: renditionSHA, renditionBytes: result.jpeg.count, thumbnailSHA256: thumbSHA, thumbnailBytes: thumb.jpeg.count)
            let manifest = DrawingProcessingManifest(sourceSHA256: item.sha256, sourceBytes: Int(item.bytes), sourceMIME: mime, processorProfile: drawingProcessorProfile, pages: [page])
            do { try DrawingGeometryValidation.validate(geometry, mime: mime) } catch { unsupported.append((drawingID, assetID)); continue }
            let pageKey = try ImportedObjectKey.derived(address, purpose: "drawing-page", sha256: renditionSHA)
            let thumbKey = try ImportedObjectKey.derived(address, purpose: "drawing-thumb", sha256: thumbSHA)
            try await writeDerived(pageKey, result.jpeg, "image/jpeg")
            try await writeDerived(thumbKey, thumb.jpeg, "image/jpeg")
            pageKeys[drawingID] = (pageKey, thumbKey)
            rendered.append(.init(drawingSourceId: drawingID, assetId: assetID, geometry: geometry, page: result.jpeg, pageSHA256: renditionSHA,
                thumbnail: thumb.jpeg, thumbnailSHA256: thumbSHA, resultHash: try CanonicalDrawingService.manifestHash(manifest)))
        }
        return .init(pending: item, decoded: decoded, rendered: rendered, unsupportedDrawings: unsupported, renditionKey: renditionKey, pageKeys: pageKeys)
    }
    private static func drawingAssets(_ item: Pending, _ projection: LegacyCanonicalProjection) -> [(UUID, UUID)] {
        let assets = Dictionary(uniqueKeysWithValues: projection.drawings.map { ($0.id, $0.assetId) })
        return item.drawingSourceIds.compactMap { id in assets[id].map { (id, $0) } }
    }

    private static func record(_ outcome: Outcome, projection: LegacyCanonicalProjection, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db), item = outcome.pending, now = Date()
        let existing = try await sql.raw("SELECT state FROM legacy_import_file_processing WHERE projection_id = \(bind: projection.projectionId) AND declaration_id = \(bind: item.declarationId)").first()
        if let existing {
            // The only change the database permits: an opaque row that has now decoded.
            guard try existing.decode(column: "state", as: String.self) == "opaque",
                  let decoded = outcome.decoded, let key = outcome.renditionKey else { return }
            try await sql.raw("""
                UPDATE legacy_import_file_processing
                SET state = 'decoded_image', decoded_mime = \(bind: decoded.mime), width = \(bind: decoded.width), height = \(bind: decoded.height),
                    rendition_key = \(bind: key.value), rendition_sha256 = \(bind: decoded.renditionSHA256), rendition_size = \(bind: decoded.rendition.count),
                    processed_at = \(bind: now)
                WHERE projection_id = \(bind: projection.projectionId) AND declaration_id = \(bind: item.declarationId)
                """).run()
            return
        }
        if let decoded = outcome.decoded, let key = outcome.renditionKey {
            try await sql.raw("""
                INSERT INTO legacy_import_file_processing (projection_id,session_id,declaration_id,receipt_id,state,decoded_mime,width,height,rendition_key,rendition_sha256,rendition_size,processed_at)
                VALUES (\(bind: projection.projectionId),\(bind: projection.binding.sessionId),\(bind: item.declarationId),\(bind: item.receiptId),'decoded_image',\(bind: decoded.mime),\(bind: decoded.width),\(bind: decoded.height),\(bind: key.value),\(bind: decoded.renditionSHA256),\(bind: decoded.rendition.count),\(bind: now))
                """).run()
        } else {
            try await sql.raw("""
                INSERT INTO legacy_import_file_processing (projection_id,session_id,declaration_id,receipt_id,state,processed_at)
                VALUES (\(bind: projection.projectionId),\(bind: projection.binding.sessionId),\(bind: item.declarationId),\(bind: item.receiptId),'opaque',\(bind: now))
                """).run()
        }
        for rendered in outcome.rendered {
            let keys = outcome.pageKeys[rendered.drawingSourceId]!
            try await sql.raw("""
                INSERT INTO legacy_import_drawing_processing (projection_id,drawing_source_id,asset_id,declaration_id,state,source_mime,source_sha256,source_bytes,geometry_json,rendition_key,rendition_sha256,rendition_size,thumbnail_key,thumbnail_sha256,thumbnail_size,result_hash,processed_at)
                VALUES (\(bind: projection.projectionId),\(bind: rendered.drawingSourceId),\(bind: rendered.assetId),\(bind: item.declarationId),'rendered',\(bind: outcome.decoded!.mime),\(bind: item.sha256),\(bind: item.bytes),\(bind: PlatformMutationService.encode(rendered.geometry)),\(bind: keys.0.value),\(bind: rendered.pageSHA256),\(bind: rendered.page.count),\(bind: keys.1.value),\(bind: rendered.thumbnailSHA256),\(bind: rendered.thumbnail.count),\(bind: rendered.resultHash),\(bind: now))
                """).run()
        }
        for (drawingID, assetID) in outcome.unsupportedDrawings {
            try await sql.raw("""
                INSERT INTO legacy_import_drawing_processing (projection_id,drawing_source_id,asset_id,declaration_id,state,source_sha256,source_bytes,processed_at)
                VALUES (\(bind: projection.projectionId),\(bind: drawingID),\(bind: assetID),\(bind: item.declarationId),'unsupported',\(bind: item.sha256),\(bind: item.bytes),\(bind: now))
                """).run()
        }
    }

    /// Appends one attempt. `attempt_number` is derived inside the same session the
    /// caller already holds, so two passes cannot claim the same number.
    static func recordAttempt(projection: LegacyCanonicalProjection, declarationID: UUID, failure: String?, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        let previous = try await sql.raw("""
            SELECT coalesce(max(attempt_number), 0) AS n FROM legacy_import_processing_attempts
            WHERE projection_id = \(bind: projection.projectionId) AND declaration_id = \(bind: declarationID)
            """).first()!.decode(column: "n", as: Int.self)
        try await sql.raw("""
            INSERT INTO legacy_import_processing_attempts
                (id, projection_id, session_id, declaration_id, attempt_number, outcome, failure_kind, attempted_at)
            VALUES (\(bind: UUID()), \(bind: projection.projectionId), \(bind: projection.binding.sessionId), \(bind: declarationID),
                    \(bind: previous + 1), \(bind: failure == nil ? "succeeded" : "failed"), \(bind: failure), \(bind: Date()))
            """).run()
    }

    /// A classification, never the message. Anything unrecognised is `unknown` rather
    /// than the error's text, which is where a storage path or a signed URL would leak.
    static func failureKind(_ error: Error) -> String {
        guard let abort = error as? Abort, !abort.identifier.isEmpty,
              abort.identifier.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil else { return "unknown" }
        return abort.identifier
    }

    static func summary(_ projection: LegacyCanonicalProjection, session: StagedLegacyImportReceipt, on db: Database) async throws -> Summary {
        let sql = try VerifiedIdentityService.sql(db)
        let received = try await sql.raw("SELECT count(*) AS n FROM staged_import_original_receipts WHERE session_id = \(bind: session.sessionId)").first()!.decode(column: "n", as: Int.self)
        let files = try await sql.raw("SELECT state, count(*) AS n FROM legacy_import_file_processing WHERE projection_id = \(bind: projection.projectionId) GROUP BY state").all()
        var decoded = 0, opaque = 0
        for row in files { if try row.decode(column: "state", as: String.self) == "decoded_image" { decoded = try row.decode(column: "n", as: Int.self) } else { opaque = try row.decode(column: "n", as: Int.self) } }
        let drawings = try await sql.raw("SELECT state, count(*) AS n FROM legacy_import_drawing_processing WHERE projection_id = \(bind: projection.projectionId) GROUP BY state").all()
        var rendered = 0, unsupported = 0
        for row in drawings { if try row.decode(column: "state", as: String.self) == "rendered" { rendered = try row.decode(column: "n", as: Int.self) } else { unsupported = try row.decode(column: "n", as: Int.self) } }
        let processedDeclarations = Set(try await sql.raw("SELECT declaration_id FROM legacy_import_file_processing WHERE projection_id = \(bind: projection.projectionId)").all().map { try $0.decode(column: "declaration_id", as: UUID.self) })
        let failedAttempts = try await sql.raw("SELECT count(*) AS n FROM legacy_import_processing_attempts WHERE projection_id = \(bind: projection.projectionId) AND outcome = 'failed'").first()!.decode(column: "n", as: Int.self)
        // Three failures with no success is the point at which running it again stops
        // being optimism. The row still stands; this only makes it visible.
        let stuck = try await sql.raw("""
            SELECT count(*) AS n FROM (
                SELECT a.declaration_id FROM legacy_import_processing_attempts a
                WHERE a.projection_id = \(bind: projection.projectionId) AND a.outcome = 'failed'
                    AND NOT EXISTS (SELECT 1 FROM legacy_import_processing_attempts s
                                    WHERE s.projection_id = a.projection_id AND s.declaration_id = a.declaration_id AND s.outcome = 'succeeded')
                GROUP BY a.declaration_id HAVING count(*) >= 3
            ) repeated
            """).first()!.decode(column: "n", as: Int.self)
        let fileByID = Dictionary(uniqueKeysWithValues: projection.files.map { ($0.id, $0) })
        let missing = projection.fileUses.filter { use in
            guard use.required else { return false }
            guard let objectID = use.fileObjectId, let file = fileByID[objectID] else { return true }
            return !processedDeclarations.contains(file.declarationId)
        }.count
        return .init(declaredFileCount: projection.files.count, receivedFileCount: received, processedFileCount: decoded + opaque,
            decodedImageCount: decoded, opaqueFileCount: opaque, renderedDrawingCount: rendered, unsupportedDrawingCount: unsupported, missingRequiredFileCount: missing,
            failedAttemptCount: failedAttempts, repeatedlyFailingFileCount: stuck)
    }
}
