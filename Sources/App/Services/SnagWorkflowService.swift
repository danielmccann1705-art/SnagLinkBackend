import Fluent
import FluentSQL
import Foundation
import Vapor

enum SnagWorkflowService {
    /// Serialize report publication and workflow mutations for a project, including
    /// report-only projects that have no canonical row to lock.
    static func lockProject(_ projectId: UUID, on db: Database) async throws {
        if let sql = db as? SQLDatabase {
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "workflow:" + projectId.uuidString), 0))").run()
        }
    }

    static func requireScope(snagId: UUID, link: MagicLink, on db: Database) async throws {
        try await LegacyProjectAccess.requireAvailable(projectID: link.projectId, ownerID: link.createdById, on: db)
        if let project = try await Project.find(link.projectId, on: db), project.ownerId != link.createdById {
            throw Abort(.forbidden, reason: "This link does not own the project")
        }
        if let snag = try await Snag.find(snagId, on: db),
           snag.ownerId != link.createdById || snag.projectId != link.projectId {
            throw Abort(.forbidden, reason: "This link does not own the snag")
        }
    }

    static func currentStatus(snagId: UUID, link: MagicLink, on db: Database) async throws -> String {
        try await requireScope(snagId: snagId, link: link, on: db)
        try await SnagDeletionService.requireActive(snagId, ownerId: link.createdById, projectId: link.projectId, on: db)
        if let snag = try await Snag.find(snagId, on: db) { return SnagStatus.normalize(snag.status) }
        guard let report = try await SyncedReport.query(on: db).filter(\.$magicLinkToken == link.token).first() else {
            throw Abort(.notFound, reason: "The snag report has not been published")
        }
        let visible = try await overlayCanonicalStatuses(report.reportJSON, ids: [snagId], ownerId: link.createdById, projectId: link.projectId, on: db)
        guard let data = visible.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snags = object["snags"] as? [[String: Any]],
              let snag = snags.first(where: { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == snagId }) else {
            throw Abort(.notFound, reason: "Snag not found in this report")
        }
        return SnagStatus.normalize(snag["status"] as? String ?? "open")
    }

    /// Call inside the decision transaction so its record and visible status agree.
    static func setStatus(_ status: String, snagId: UUID, ownerId: UUID, projectId: UUID, on db: Database) async throws {
        try await SnagDeletionService.requireActive(snagId, ownerId: ownerId, projectId: projectId, on: db)
        if let snag = try await Snag.query(on: db).filter(\.$id == snagId)
            .filter(\.$ownerId == ownerId).filter(\.$projectId == projectId).first() {
            snag.status = status
            snag.closedAt = status == "approved" ? Date() : nil
            try await snag.save(on: db)
        }
        let tokens = try await MagicLink.query(on: db).filter(\.$createdById == ownerId)
            .filter(\.$projectId == projectId).all().map(\.token)
        guard !tokens.isEmpty else { return }
        for report in try await SyncedReport.query(on: db).filter(\.$magicLinkToken ~~ tokens).all() {
            report.reportJSON = try applying([snagId: status], to: report.reportJSON)
            try await report.save(on: db)
        }
    }

    /// Old report snapshots must not undo a status already decided on the server.
    static func overlayCanonicalStatuses(_ json: String, ids: [UUID], ownerId: UUID, projectId: UUID, on db: Database) async throws -> String {
        let snags = try await Snag.query(on: db).filter(\.$id ~~ ids)
            .filter(\.$ownerId == ownerId).filter(\.$projectId == projectId).all()
        var statuses = Dictionary(uniqueKeysWithValues: snags.compactMap { snag in
            snag.id.map { ($0, snag.status) }
        })
        // Native sharing can publish report-only snags. Their latest completion
        // record is durable even when a stale snapshot arrives after review.
        let missing = ids.filter { statuses[$0] == nil }
        if !missing.isEmpty {
            let links = try await MagicLink.query(on: db).filter(\.$createdById == ownerId)
                .filter(\.$projectId == projectId).all().compactMap(\.id)
            if !links.isEmpty {
                let completions = try await Completion.query(on: db).filter(\.$snagId ~~ missing)
                    .filter(\.$magicLinkId ~~ links).sort(\.$submittedAt, .descending).all()
                for completion in completions where statuses[completion.snagId] == nil {
                    switch completion.status {
                    case .pending: statuses[completion.snagId] = "submitted"
                    case .approved: statuses[completion.snagId] = "approved"
                    case .rejected: statuses[completion.snagId] = "sentBack"
                    }
                }
            }
        }
        return try applying(statuses, to: json)
    }

    private static func applying(_ statuses: [UUID: String], to json: String) throws -> String {
        guard !statuses.isEmpty, let data = json.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snags = object["snags"] as? [[String: Any]] else { return json }
        object["snags"] = snags.map { snag in
            var value = snag
            if let id = (snag["id"] as? String).flatMap(UUID.init(uuidString:)), let status = statuses[id] {
                value["status"] = status
            }
            return value
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
