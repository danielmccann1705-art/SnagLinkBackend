import Vapor
import Fluent
import FluentSQL

enum PrivateMediaService {
    static func row(_ id: UUID, snagID: UUID, projectID: UUID, on db: Database) async throws -> SQLRow {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM media_assets WHERE id = \(bind: id) AND snag_id = \(bind: snagID) AND project_id = \(bind: projectID)").first() else {
            throw Abort(.notFound, reason: "Photo unavailable")
        }
        return row
    }
    static func allocate(_ command: MediaAllocateCommand, snag: Snag, project: Project, actorID: UUID?, grantID: UUID? = nil, on db: Database) async throws -> MediaAssetResponse {
        guard (actorID == nil) != (grantID == nil), grantID == nil || command.purpose == "completion" else { throw Abort(.forbidden) }
        try PlatformMutationService.requireManaged(project)
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
        try available(snag)
        guard ["capture", "completion"].contains(command.purpose),
              (command.purpose == "completion") == (command.intentId != nil),
              ["image/jpeg", "image/png"].contains(command.mimeType),
              command.byteCount > 0, command.byteCount <= PrivateImageProcessor.maximumBytes,
              command.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Provide a JPEG or PNG, its exact size/checksum and a completion intention for after evidence")
        }
        if command.purpose == "completion" { try submittable(snag) }
        try await VerifiedIdentityService.lock("entity:media:\(command.id)", on: db)
        let sql = try VerifiedIdentityService.sql(db)
        guard try await sql.raw("SELECT id FROM media_assets WHERE id = \(bind: command.id)").first() == nil else { throw Abort(.conflict, reason: "This photo ID is already allocated", identifier: "entity_exists") }
        let now = Date()
        let pending = try await sql.raw("SELECT count(*) AS n FROM media_assets WHERE (creator_id = \(bind: actorID) OR creator_grant_id = \(bind: grantID)) AND attached_at IS NULL AND state != 'retired' AND expires_at > \(bind: now)").first()!.decode(column: "n", as: Int.self)
        guard pending < 200 else { throw Abort(.tooManyRequests, reason: "Finish or discard existing photo uploads before adding more") }
        let prefix = "platform/\(project.workspaceId!)/\(try project.requireID())/\(command.id)"
        try await sql.raw("""
            INSERT INTO media_assets (id, workspace_id, project_id, snag_id, creator_id, creator_grant_id, purpose, intent_id, state, original_sha256, original_size, original_mime, original_key, rendition_key, base_snag_revision, created_at, expires_at)
            VALUES (\(bind: command.id), \(bind: project.workspaceId!), \(bind: project.requireID()), \(bind: snag.requireID()), \(bind: actorID), \(bind: grantID), \(bind: command.purpose), \(bind: command.intentId), 'allocated', \(bind: command.sha256), \(bind: command.byteCount), \(bind: command.mimeType), \(bind: prefix + "/original"), \(bind: prefix + "/view.jpg"), \(bind: command.expectedRevision), \(bind: now), \(bind: now.addingTimeInterval(86400)))
            """).run()
        return try await MediaAssetResponse(row(command.id, snagID: snag.requireID(), projectID: project.requireID(), on: db))
    }
    static func available(_ snag: Snag) throws {
        guard snag.archivedAt == nil else { throw Abort(.gone, reason: "Restore this snag before adding evidence") }
    }
    static func submittable(_ snag: Snag) throws {
        guard ["open", "in_progress", "changes_requested"].contains(snag.status) else { throw Abort(.conflict, reason: "Review the pending submission or reopen this snag before adding completion evidence") }
    }
    static func requireUploader(_ row: SQLRow, actorID: UUID?, grantID: UUID? = nil) throws {
        guard (actorID == nil) != (grantID == nil),
              try row.decode(column: "creator_id", as: UUID?.self) == actorID,
              try row.decode(column: "creator_grant_id", as: UUID?.self) == grantID else { throw Abort(.notFound, reason: "Upload unavailable") }
        guard try row.decode(column: "state", as: String.self) != "retired" else { throw Abort(.gone, reason: "This upload was retired") }
        if try row.decode(column: "attached_at", as: Date?.self) == nil,
           try row.decode(column: "expires_at", as: Date.self) <= Date() { throw Abort(.gone, reason: "This unattached upload expired. Allocate a new photo") }
    }
    static func requireVisible(_ row: SQLRow, actorID: UUID) throws {
        guard try row.decode(column: "state", as: String.self) == "ready" else { throw Abort(.notFound, reason: "Photo is not ready") }
        if try row.decode(column: "attached_at", as: Date?.self) == nil { try requireUploader(row, actorID: actorID) }
    }
    static func attach(_ row: SQLRow, command: SnagPublishCommand, snag: Snag, project: Project, actorID: UUID, on db: Database) async throws -> PlatformSnagResponse {
        try PlatformMutationService.requireManaged(project); try available(snag)
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
        try requireUploader(row, actorID: actorID)
        guard try row.decode(column: "state", as: String.self) == "ready", try row.decode(column: "purpose", as: String.self) == "capture" else {
            throw Abort(.conflict, reason: "Process this capture photo before attaching it. After evidence is attached by the completion submission")
        }
        guard try row.decode(column: "attached_at", as: Date?.self) == nil else { throw Abort(.conflict, reason: "This photo is already attached") }
        let id = try row.decode(column: "id", as: UUID.self)
        try await VerifiedIdentityService.sql(db).raw("UPDATE media_assets SET attached_at = \(bind: Date()), revision = revision + 1 WHERE id = \(bind: id)").run()
        snag.revision += 1; try await snag.save(on: db)
        let media = try await MediaAssetResponse(self.row(id, snagID: snag.requireID(), projectID: project.requireID(), on: db))
        try await PlatformMutationService.change(workspaceID: project.workspaceId!, projectID: project.requireID(), type: "media", entityID: id, revision: media.revision, kind: "attached", fields: ["attachedAt"], payload: media, actorID: actorID, on: db)
        return try await PlatformSnagService.changed(snag, project: project, actorID: actorID, kind: "photo_attached", fields: ["media"], on: db)
    }
}
