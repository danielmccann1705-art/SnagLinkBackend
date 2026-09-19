import Fluent
import FluentSQL
import Vapor

enum SnagDeletionService {
    static func receipt(id: UUID, ownerId: UUID, projectId: UUID, on db: Database) async throws -> SnagDeletion? {
        try await SnagDeletion.query(on: db).filter(\.$snagId == id)
            .filter(\.$ownerId == ownerId).filter(\.$projectId == projectId).first()
    }

    static func requireActive(_ id: UUID, ownerId: UUID, projectId: UUID? = nil, on db: Database) async throws {
        if let projectId { try await LegacyProjectAccess.requireAvailable(projectID: projectId, ownerID: ownerId, on: db) }
        let query = SnagDeletion.query(on: db).filter(\.$snagId == id).filter(\.$ownerId == ownerId)
        if let projectId { query.filter(\.$projectId == projectId) }
        guard try await query.first() == nil else { throw Abort(.gone, reason: "This snag has been deleted.") }
    }

    static func receipts(ownerId: UUID, on db: Database) async throws -> [SnagDeletion] {
        try await SnagDeletion.query(on: db).filter(\.$ownerId == ownerId).filter(LegacyProjectAccess.personalRecords(.deletions)).all()
    }

    /// Filters every read as well as writes. An in-flight, old report upload cannot
    /// make a deleted snag visible again, even if it completes after deletion.
    static func visibleReportJSON(_ json: String, ownerId: UUID, projectId: UUID, on db: Database) async throws -> String {
        try await LegacyProjectAccess.requireAvailable(projectID: projectId, ownerID: ownerId, on: db)
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snags = object["snags"] as? [[String: Any]] else { return json }
        let ids = snags.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty else { return json }
        let deleted = try await SnagDeletion.query(on: db).filter(\.$snagId ~~ ids)
            .filter(\.$ownerId == ownerId).filter(\.$projectId == projectId).all().map(\.snagId)
        let visible = try removing(Set(deleted), from: json)
        return try await SnagWorkflowService.overlayCanonicalStatuses(visible, ids: ids, ownerId: ownerId, projectId: projectId, on: db)
    }

    /// Preserve unknown fields; do not round-trip through the narrower legacy DTO.
    static func removing(_ deleted: Set<UUID>, from json: String) throws -> String {
        guard !deleted.isEmpty else { return json }
        guard let data = json.data(using: .utf8),
              var report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snags = report["snags"] as? [[String: Any]] else { return json }
        let removed = snags.filter { snag in
            (snag["id"] as? String).flatMap(UUID.init(uuidString:)).map(deleted.contains) ?? false
        }
        guard !removed.isEmpty else { return json }
        let remaining = snags.filter { snag in
            !((snag["id"] as? String).flatMap(UUID.init(uuidString:)).map(deleted.contains) ?? false)
        }
        report["snags"] = remaining
        if var project = report["project"] as? [String: Any] {
            func subtract(_ key: String, _ count: Int) {
                if let old = project[key] as? Int { project[key] = max(0, old - count) }
            }
            subtract("snagCount", removed.count)
            subtract("openSnagCount", removed.filter { ($0["status"] as? String) == "open" }.count)
            subtract("inProgressSnagCount", removed.filter { SnagStatus.normalize($0["status"] as? String ?? "") == "sent" }.count)
            subtract("closedSnagCount", removed.filter { SnagStatus.normalize($0["status"] as? String ?? "") == "approved" }.count)
            if let count = project["snagCount"] as? Int, let closed = project["closedSnagCount"] as? Int {
                project["completionPercentage"] = count == 0 ? 0 : Double(closed) / Double(count) * 100
            }
            report["project"] = project
        }
        if let drawings = report["drawings"] as? [[String: Any]] {
            report["drawings"] = drawings.map { drawing in
                var copy = drawing
                if let id = drawing["id"] as? String, let count = drawing["snagPinCount"] as? Int {
                    copy["snagPinCount"] = max(0, count - removed.filter { ($0["drawingId"] as? String) == id }.count)
                }
                return copy
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
    }

    static func delete(id: UUID, projectId: UUID, ownerId: UUID, on db: Database) async throws {
        try await db.transaction { tx in
            try await SnagWorkflowService.lockProject(projectId, on: tx)
            try await LegacyProjectAccess.requireAvailable(projectID: projectId, ownerID: ownerId, on: tx)
            if let sql = tx as? SQLDatabase {
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: id.uuidString), 0))").run()
            }
            if try await receipt(id: id, ownerId: ownerId, projectId: projectId, on: tx) != nil {
                return // Lost acknowledgement / repeated delete: success, no widened access.
            }
            let project = try await Project.query(on: tx).filter(\.$id == projectId).filter(\.$ownerId == ownerId).first()
            let links = try await MagicLink.query(on: tx).filter(\.$projectId == projectId).filter(\.$createdById == ownerId).all()
            let snag = try await Snag.query(on: tx).filter(\.$id == id)
                .filter(\.$ownerId == ownerId).filter(\.$projectId == projectId).first()
            // iOS report sharing does not necessarily create a Project/Snag CRUD row.
            // Owned project links establish ownership for that legacy path.
            guard project != nil || !links.isEmpty else { throw Abort(.notFound, reason: "Project not found") }
            let receipt = SnagDeletion(snagId: id, ownerId: ownerId, projectId: projectId)
            try await receipt.save(on: tx)
            let tokens = links.map(\.token)
            let linkIds = links.compactMap(\.id)
            if !tokens.isEmpty {
                let reports = try await SyncedReport.query(on: tx).filter(\.$magicLinkToken ~~ tokens).all()
                for report in reports {
                    report.reportJSON = try removing([id], from: report.reportJSON)
                    try await report.save(on: tx)
                }
                let photos = try await SyncedPhoto.query(on: tx).filter(\.$magicLinkToken ~~ tokens).filter(\.$snagId == id).all()
                receipt.filePaths = Array(Set(photos.flatMap { [$0.filePath, $0.thumbnailFilePath].compactMap { $0 } }))
                for photo in photos { try await photo.delete(on: tx) }
                // Cascade removes completion-photo metadata. Do not delete arbitrary
                // externally supplied photo URLs: their ownership is not established.
                try await Completion.query(on: tx).filter(\.$magicLinkId ~~ linkIds).filter(\.$snagId == id).delete()
            }
            if let snag { try await snag.delete(on: tx) }
            try await receipt.save(on: tx)
            // Keep link selections intact. An empty selection can mean the whole project.
        }
    }

    /// Called after the DB transaction, and by scheduled cleanup for transient storage errors.
    static func cleanupFiles(app: Application, on database: Database? = nil) async throws {
        let db = database ?? app.db
        for receipt in try await SnagDeletion.query(on: db).all() where !receipt.filePaths.isEmpty {
            var failed: [String] = []
            for path in receipt.filePaths {
                let referenced = try await SyncedPhoto.query(on: db).group(.or) {
                    $0.filter(\.$filePath == path).filter(\.$thumbnailFilePath == path)
                }.count() > 0
                guard !referenced else { continue }
                do { try await StorageService.deleteOwnedSyncedPhoto(key: path, app: app) }
                catch { failed.append(path); app.logger.warning("Deleted snag photo cleanup will retry") }
            }
            receipt.filePaths = failed
            try await receipt.save(on: db)
        }
    }
}
