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
    private struct Outcome: Sendable {
        let pending: Pending; let decoded: Decoded?; let rendered: [Rendered]; let unsupportedDrawings: [(UUID, UUID)]
        let renditionKey: ImportedObjectKey?; let pageKeys: [UUID: (ImportedObjectKey, ImportedObjectKey)]
    }

    /// Processes every retained original that has no processing row yet, then reports
    /// the projection's current readiness. Safe to repeat; identical results are reused.
    static func process(projectionID: UUID, scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                        store: any StagedImportOriginalStore, on database: Database, budget: StagedImportIOBudget = try! .init()) async throws -> Summary {
        let projection = try await LegacyCanonicalProjectionService.read(projectionID: projectionID, scope: scope, actor: actor, binding: binding, on: database)
        let pending = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
            try await pendingDeclarations(projection, session: session, on: db)
        }
        for item in pending {
            try budget.check()
            let address = StagedImportOriginalAddress(workspaceId: projection.binding.workspaceId, sessionId: projection.binding.sessionId, declarationId: item.declarationId)
            let outcome = try await decode(item, address: address, projection: projection, store: store, budget: budget)
            _ = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database) { session, db in
                try await record(outcome, projection: projection, on: db)
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

    private static func pendingDeclarations(_ projection: LegacyCanonicalProjection, session: StagedLegacyImportReceipt, on db: Database) async throws -> [Pending] {
        let sql = try VerifiedIdentityService.sql(db)
        let receipts = try await sql.raw("""
            SELECT r.declaration_id, r.receipt_id, r.measured_sha256, r.measured_bytes FROM staged_import_original_receipts r
            LEFT JOIN legacy_import_file_processing p ON p.projection_id = \(bind: projection.projectionId) AND p.declaration_id = r.declaration_id
            WHERE r.session_id = \(bind: session.sessionId) AND p.declaration_id IS NULL ORDER BY r.declaration_id
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
                               store: any StagedImportOriginalStore, budget: StagedImportIOBudget) async throws -> Outcome {
        let opaque = Outcome(pending: item, decoded: nil, rendered: [], unsupportedDrawings: drawingAssets(item, projection), renditionKey: nil, pageKeys: [:])
        // Oversized originals stay retained and readable; only bounded images decode.
        guard item.bytes > 0, item.bytes <= Int64(renditionMaximumBytes) else { return opaque }
        let data: Data
        do {
            let body = try await store.read(address, budget: budget)
            let buffer = try await body.collect(upTo: renditionMaximumBytes)
            data = Data(buffer: buffer)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.serviceUnavailable, reason: "Private original storage could not be read; retry preparation", identifier: "staged_original_storage_unavailable") }
        guard data.count == Int(item.bytes), LegacyProjectImportDecoder.digest(data) == item.sha256 else {
            throw Abort(.conflict, reason: "Retained original bytes no longer match their receipt", identifier: "staged_original_bytes_mismatch")
        }
        guard let mime = PrivateImageProcessor.detectMime(data), let result = try? PrivateImageProcessor.process(data, mime: mime) else { return opaque }
        let renditionSHA = PrivateImageProcessor.digest(result.jpeg)
        let renditionKey = try ImportedObjectKey.derived(address, purpose: "rendition", sha256: renditionSHA)
        try await store.putDerived(renditionKey, data: result.jpeg, mime: "image/jpeg", budget: budget)
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
            try await store.putDerived(pageKey, data: result.jpeg, mime: "image/jpeg", budget: budget)
            try await store.putDerived(thumbKey, data: thumb.jpeg, mime: "image/jpeg", budget: budget)
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
        if try await sql.raw("SELECT 1 FROM legacy_import_file_processing WHERE projection_id = \(bind: projection.projectionId) AND declaration_id = \(bind: item.declarationId)").first() != nil { return }
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
        let fileByID = Dictionary(uniqueKeysWithValues: projection.files.map { ($0.id, $0) })
        let missing = projection.fileUses.filter { use in
            guard use.required else { return false }
            guard let objectID = use.fileObjectId, let file = fileByID[objectID] else { return true }
            return !processedDeclarations.contains(file.declarationId)
        }.count
        return .init(declaredFileCount: projection.files.count, receivedFileCount: received, processedFileCount: decoded + opaque,
            decodedImageCount: decoded, opaqueFileCount: opaque, renderedDrawingCount: rendered, unsupportedDrawingCount: unsupported, missingRequiredFileCount: missing)
    }
}
