import Vapor
import Fluent
import FluentSQL

enum CanonicalDrawingReadService {
    /// Returns nil for retained imported pages, whose closed staged-import key
    /// contract remains owned by LegacyImportReadService.
    static func page(_ pageID: UUID, projectID: UUID, thumbnail: Bool,
                     on db: Database) async throws -> CanonicalDrawingPageReadTarget? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT d.workspace_id, vp.asset_id, vp.asset_page_id,
                ap.rendition_key, ap.rendition_sha256, ap.rendition_size,
                ap.thumbnail_key, ap.thumbnail_sha256, ap.thumbnail_size
            FROM drawing_version_pages vp
            JOIN drawings d ON d.id = vp.drawing_id AND d.project_id = vp.project_id
            JOIN drawing_assets a ON a.id = vp.asset_id AND a.project_id = vp.project_id
            JOIN drawing_asset_pages ap ON ap.id = vp.asset_page_id AND ap.asset_id = vp.asset_id
              AND ap.project_id = vp.project_id
            WHERE vp.id = \(bind: pageID) AND vp.project_id = \(bind: projectID)
              AND a.state = 'ready' AND a.published_at IS NOT NULL
            """).first() else { throw Abort(.notFound, reason: "Drawing page unavailable") }
        let keyColumn = thumbnail ? "thumbnail_key" : "rendition_key"
        let hashColumn = thumbnail ? "thumbnail_sha256" : "rendition_sha256"
        let sizeColumn = thumbnail ? "thumbnail_size" : "rendition_size"
        let key = try row.decode(column: keyColumn, as: String.self)
        guard key.hasPrefix("drawings/") else { return nil }
        let workspaceID = try row.decode(column: "workspace_id", as: UUID.self)
        let assetID = try row.decode(column: "asset_id", as: UUID.self)
        let assetPageID = try row.decode(column: "asset_page_id", as: UUID.self)
        let hash = try row.decode(column: hashColumn, as: String.self)
        let size = try row.decode(column: sizeColumn, as: Int.self)
        let suffix = thumbnail ? "thumb-\(hash).jpg" : "\(hash).jpg"
        let expected = "drawings/\(workspaceID)/\(projectID)/\(assetID)/pages/\(assetPageID)/\(suffix)"
        guard key == expected, CanonicalDrawingService.hashValid(hash), (1...10_485_760).contains(size) else {
            throw Abort(.serviceUnavailable, reason: "Drawing page verification details are unavailable",
                        identifier: "drawing_page_metadata_unavailable")
        }
        return .init(workspaceId: workspaceID, projectId: projectID, assetId: assetID,
            assetPageId: assetPageID, kind: thumbnail ? .thumbnail : .rendition,
            sha256: hash, byteCount: size, mimeType: "image/jpeg")
    }

    static func verified(_ target: CanonicalDrawingPageReadTarget,
                         runtime: any CanonicalDrawingRuntime) async throws -> Data {
        let bytes: Data
        do { bytes = try await runtime.readPage(target) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw Abort(.serviceUnavailable, reason: "This drawing page is temporarily unavailable",
                        identifier: "drawing_page_unavailable")
        }
        guard bytes.count == target.byteCount,
              PrivateImageProcessor.digest(bytes) == target.sha256 else {
            throw Abort(.serviceUnavailable, reason: "Drawing page integrity check failed",
                        identifier: "drawing_page_unavailable")
        }
        return bytes
    }
}
