import Vapor
import Fluent
import FluentSQL

/// Typed readback of published import records under CURRENT project read authority.
/// Callers hold the project access transaction. Bytes are resolved internally from
/// server-owned keys and verified against their recorded digests before return.
enum LegacyImportReadService {
    struct Graph: Content {
        let projectId: UUID
        let files: [ImportedFileResponse]; let fileUses: [ImportedFileUseResponse]; let photos: [ImportedPhotoResponse]
        let drawings: [DrawingSheetResponse]; let opaqueDrawings: [OpaqueImportedDrawingResponse]; let pins: [DrawingPinResponse]
        let comments: [ImportedCommentResponse]; let statusChanges: [ImportedStatusChangeResponse]; let deletions: [ImportedDeletionResponse]
        let organisation: ProjectOrganisationResponse; let folders: [WorkspaceFolderResponse]; let tags: [WorkspaceTagResponse]
        let receipt: LegacyImportCommitReceipt?
    }
    static func graph(projectID: UUID, workspaceID: UUID, on db: Database) async throws -> Graph {
        let sql = try VerifiedIdentityService.sql(db)
        let files = try await sql.raw("SELECT * FROM imported_file_objects WHERE project_id = \(bind: projectID) ORDER BY id").all().map(ImportedFileResponse.init)
        let uses = try await sql.raw("SELECT * FROM imported_file_uses WHERE project_id = \(bind: projectID) ORDER BY kind, source_id, role, position").all().map(ImportedFileUseResponse.init)
        let photos = try await sql.raw("SELECT * FROM imported_photos WHERE project_id = \(bind: projectID) ORDER BY snag_id, sort_order, id").all().map(ImportedPhotoResponse.init)
        let sheets = try await sheets(projectID: projectID, on: db)
        let opaque = try await sql.raw("SELECT * FROM imported_drawing_provenance WHERE project_id = \(bind: projectID) AND rendering = 'opaque_unrendered' ORDER BY sort_order, drawing_id").all().map { row in
            try OpaqueImportedDrawingResponse(id: row.decode(column: "drawing_id", as: UUID.self), projectId: projectID, name: row.decode(column: "name", as: String.self), sortOrder: row.decode(column: "sort_order", as: Int.self), imported: ImportedDrawingProvenance(row))
        }
        let pins = try await sql.raw("SELECT * FROM snag_drawing_pins WHERE project_id = \(bind: projectID) ORDER BY snag_id").all().map(DrawingPinResponse.init)
        let comments = try await sql.raw("SELECT * FROM imported_snag_comments WHERE project_id = \(bind: projectID) ORDER BY snag_id, created_at, id").all().map(ImportedCommentResponse.init)
        let statuses = try await sql.raw("SELECT * FROM imported_status_changes WHERE project_id = \(bind: projectID) ORDER BY snag_id, created_at, id").all().map(ImportedStatusChangeResponse.init)
        let deletions = try await sql.raw("SELECT * FROM imported_snag_deletions WHERE project_id = \(bind: projectID) ORDER BY deleted_snag_id").all().map(ImportedDeletionResponse.init)
        let organisation = try await organisation(projectID: projectID, on: db)
        let folders = try await sql.raw("SELECT * FROM workspace_folders WHERE workspace_id = \(bind: workspaceID) ORDER BY sort_order, id").all().map(WorkspaceFolderResponse.init)
        let tags = try await sql.raw("SELECT * FROM workspace_tags WHERE workspace_id = \(bind: workspaceID) ORDER BY name, id").all().map(WorkspaceTagResponse.init)
        let receipt = try await sql.raw("SELECT receipt_json FROM legacy_import_commits WHERE project_id = \(bind: projectID)").first().map { try PlatformMutationService.decode(LegacyImportCommitReceipt.self, $0.decode(column: "receipt_json", as: String.self)) }
        return .init(projectId: projectID, files: files, fileUses: uses, photos: photos, drawings: sheets, opaqueDrawings: opaque, pins: pins,
            comments: comments, statusChanges: statuses, deletions: deletions, organisation: organisation, folders: folders, tags: tags, receipt: receipt)
    }
    static func organisation(projectID: UUID, on db: Database) async throws -> ProjectOrganisationResponse {
        let sql = try VerifiedIdentityService.sql(db)
        let folder = try await sql.raw("SELECT folder_id FROM project_folder_links WHERE project_id = \(bind: projectID)").first()?.decode(column: "folder_id", as: UUID.self)
        let tags = try await sql.raw("SELECT tag_id FROM project_tag_links WHERE project_id = \(bind: projectID) ORDER BY tag_id").all().map { try $0.decode(column: "tag_id", as: UUID.self) }
        return .init(projectId: projectID, folderId: folder, tagIds: tags)
    }
    static func sheets(projectID: UUID, on db: Database) async throws -> [DrawingSheetResponse] {
        let ids = try await VerifiedIdentityService.sql(db).raw("SELECT id FROM drawings WHERE project_id = \(bind: projectID) ORDER BY sort_order, id").all().map { try $0.decode(column: "id", as: UUID.self) }
        var result: [DrawingSheetResponse] = []
        for id in ids { result.append(try await sheet(id, projectID: projectID, on: db)) }
        return result
    }
    static func sheet(_ id: UUID, projectID: UUID, on db: Database) async throws -> DrawingSheetResponse {
        let sql = try VerifiedIdentityService.sql(db)
        guard let d = try await sql.raw("SELECT * FROM drawings WHERE id = \(bind: id) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "Drawing unavailable") }
        let pages = try await sql.raw("""
            SELECT vp.id, vp.version_id, vp.asset_id, vp.asset_page_id, vp.page_index, ap.source_page_label, ap.geometry_json,
                ap.rendition_sha256, ap.rendition_size, ap.thumbnail_sha256, ap.thumbnail_size
            FROM drawing_version_pages vp JOIN drawing_asset_pages ap ON ap.id = vp.asset_page_id AND ap.project_id = vp.project_id
            WHERE vp.drawing_id = \(bind: id) AND vp.project_id = \(bind: projectID) AND vp.version_id = \(bind: try d.decode(column: "current_version_id", as: UUID.self)) ORDER BY vp.page_index
            """).all().map { row -> DrawingSheetResponse.Page in
            let pageID = try row.decode(column: "id", as: UUID.self)
            return try .init(id: pageID, versionId: row.decode(column: "version_id", as: UUID.self), assetId: row.decode(column: "asset_id", as: UUID.self), assetPageId: row.decode(column: "asset_page_id", as: UUID.self),
                pageIndex: row.decode(column: "page_index", as: Int.self), sourcePageLabel: row.decode(column: "source_page_label", as: String.self),
                geometry: PlatformMutationService.decode(DrawingPageGeometry.self, row.decode(column: "geometry_json", as: String.self)),
                rendition: .init(sha256: row.decode(column: "rendition_sha256", as: String.self), byteCount: row.decode(column: "rendition_size", as: Int.self), mimeType: "image/jpeg", contentPath: "/api/v2/projects/\(projectID)/drawings/pages/\(pageID)/rendition"),
                thumbnail: .init(sha256: row.decode(column: "thumbnail_sha256", as: String.self), byteCount: row.decode(column: "thumbnail_size", as: Int.self), mimeType: "image/jpeg", contentPath: "/api/v2/projects/\(projectID)/drawings/pages/\(pageID)/thumbnail"))
        }
        let imported = try await sql.raw("SELECT * FROM imported_drawing_provenance WHERE drawing_id = \(bind: id) AND project_id = \(bind: projectID)").first().map(ImportedDrawingProvenance.init)
        return try .init(id: id, projectId: projectID, name: d.decode(column: "name", as: String.self), sortOrder: d.decode(column: "sort_order", as: Int.self), revision: d.decode(column: "revision", as: Int64.self),
            currentVersionId: d.decode(column: "current_version_id", as: UUID.self), createdBy: d.decode(column: "created_by", as: UUID.self), createdAt: d.decode(column: "created_at", as: Date.self),
            updatedAt: d.decode(column: "updated_at", as: Date.self), archivedAt: d.decode(column: "archived_at", as: Date?.self), pages: pages, imported: imported)
    }

    struct Bytes: Sendable { let data: Data; let sha256: String; let mime: String }
    /// Resolves and verifies an imported file object's original or rendition bytes.
    static func fileBytes(_ fileID: UUID, projectID: UUID, rendition: Bool, store: any StagedImportOriginalStore, on db: Database) async throws -> (key: ImportedObjectKey, sha256: String, size: Int64, mime: String) {
        let sql = try VerifiedIdentityService.sql(db)
        guard let row = try await sql.raw("SELECT * FROM imported_file_objects WHERE id = \(bind: fileID) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "File unavailable") }
        if rendition {
            guard let key = try row.decode(column: "rendition_key", as: String?.self), let sha = try row.decode(column: "rendition_sha256", as: String?.self), let size = try row.decode(column: "rendition_size", as: Int?.self) else {
                throw Abort(.notFound, reason: "This original was retained but could not be decoded; download the original instead", identifier: "imported_file_rendition_unavailable")
            }
            return (try ImportedObjectKey.stored(key), sha, Int64(size), "image/jpeg")
        }
        let address = try StagedImportOriginalAddress(workspaceId: row.decode(column: "workspace_id", as: UUID.self), sessionId: row.decode(column: "session_id", as: UUID.self), declarationId: row.decode(column: "declaration_id", as: UUID.self))
        return try (ImportedObjectKey.original(address), row.decode(column: "sha256", as: String.self), row.decode(column: "bytes", as: Int64.self), row.decode(column: "decoded_mime", as: String?.self) ?? "application/octet-stream")
    }
    static func drawingPageBytes(_ pageID: UUID, projectID: UUID, thumbnail: Bool, on db: Database) async throws -> (key: ImportedObjectKey, sha256: String, size: Int64, mime: String) {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT ap.rendition_key, ap.rendition_sha256, ap.rendition_size, ap.thumbnail_key, ap.thumbnail_sha256, ap.thumbnail_size
            FROM drawing_version_pages vp JOIN drawing_asset_pages ap ON ap.id = vp.asset_page_id AND ap.project_id = vp.project_id
            JOIN drawings d ON d.id = vp.drawing_id AND d.project_id = vp.project_id JOIN drawing_assets a ON a.id = vp.asset_id AND a.project_id = vp.project_id
            WHERE vp.id = \(bind: pageID) AND vp.project_id = \(bind: projectID) AND a.state = 'ready' AND a.published_at IS NOT NULL
            """).first() else { throw Abort(.notFound, reason: "Drawing page unavailable") }
        let prefix = thumbnail ? "thumbnail" : "rendition"
        return try (ImportedObjectKey.stored(row.decode(column: prefix + "_key", as: String.self)), row.decode(column: prefix + "_sha256", as: String.self), Int64(row.decode(column: prefix + "_size", as: Int.self)), "image/jpeg")
    }
    /// Reads bounded bytes and verifies the recorded digest/length before returning them.
    static func verifiedBytes(_ target: (key: ImportedObjectKey, sha256: String, size: Int64, mime: String), store: any StagedImportOriginalStore) async throws -> Bytes {
        guard target.size <= Int64(StagedImportFileHTTP.maximumUploadBytes) else {
            throw Abort(.payloadTooLarge, reason: "This original exceeds the current download limit; it remains retained", identifier: "imported_file_too_large")
        }
        let budget = try StagedImportIOBudget()
        let data: Data
        do { data = try await store.readDerived(target.key, limit: Int(target.size) + 1, budget: budget) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.serviceUnavailable, reason: "Private storage could not be read; retry", identifier: "imported_file_storage_unavailable") }
        guard Int64(data.count) == target.size, LegacyProjectImportDecoder.digest(data) == target.sha256 else {
            throw Abort(.serviceUnavailable, reason: "Stored bytes no longer match their verified record", identifier: "imported_file_integrity")
        }
        return .init(data: data, sha256: target.sha256, mime: target.mime)
    }
}
