import Vapor
import Fluent
import FluentSQL

struct OwnershipTransferResponse: Content, Sendable {
    let id: UUID
    let workspaceId: UUID
    let ownerUserId: UUID
    let targetUserId: UUID
    let state: String
    let createdAt: Date
    let resolvedAt: Date?
    // Present on the permission-scoped pending-list readout; no contact emails.
    var workspaceName: String? = nil
    var ownerDisplayName: String? = nil
    var targetDisplayName: String? = nil
}

enum OwnershipTransferService {
    static func propose(workspaceID: UUID, targetID: UUID, expectedRevision: Int64, actorID: UUID, on db: Database) async throws -> OwnershipTransferResponse {
        let team = try await WorkspaceAccessService.requireCompany(workspaceID, actorID: actorID, admin: true, on: db)
        guard team.ownerUserId == actorID else { throw Abort(.forbidden, reason: "Only the owner can offer ownership") }
        guard team.revision == expectedRevision else { throw changed() }
        guard actorID != targetID else { throw Abort(.badRequest, reason: "Choose another active company member") }
        let sql = try VerifiedIdentityService.sql(db)
        // Match account deletion's workspace-before-user order. Keep both users
        // active until the offer is durable, including a recipient deleting now.
        try await lockParties(actorID, targetID, on: db)
        guard let member = try await sql.raw("SELECT revision FROM workspace_memberships WHERE workspace_id=\(bind: workspaceID) AND user_id=\(bind: targetID) AND state='active'").first() else {
            throw Abort(.badRequest, reason: "Choose an existing active company member")
        }
        let targetRevision = try member.decode(column: "revision", as: Int64.self)
        if let existing = try await sql.raw("SELECT * FROM ownership_transfer_offers WHERE workspace_id=\(bind: workspaceID) AND state='pending'").first() {
            if try existing.decode(column: "owner_user_id", as: UUID.self) == actorID,
               try existing.decode(column: "target_user_id", as: UUID.self) == targetID,
               try existing.decode(column: "workspace_revision", as: Int64.self) == expectedRevision,
               try existing.decode(column: "target_membership_revision", as: Int64.self) == targetRevision { return try response(existing) }
            try await sql.raw("UPDATE ownership_transfer_offers SET state='superseded',resolved_at=NOW() WHERE id=\(bind: existing.decode(column: "id", as: UUID.self))").run()
        }
        let id = UUID()
        let row = try await sql.raw("""
            INSERT INTO ownership_transfer_offers(id,workspace_id,owner_user_id,target_user_id,workspace_revision,target_membership_revision,state,created_at)
            VALUES(\(bind: id),\(bind: workspaceID),\(bind: actorID),\(bind: targetID),\(bind: expectedRevision),\(bind: targetRevision),'pending',NOW()) RETURNING *
            """).first()
        guard let row else { throw Abort(.internalServerError) }
        return try response(row)
    }
    static func accept(id: UUID, actorID: UUID, on db: Database) async throws -> OwnershipTransferResponse {
        let row = try await locked(id: id, actorID: actorID, on: db)
        guard try row.decode(column: "target_user_id", as: UUID.self) == actorID else { throw Abort(.notFound) }
        let state = try row.decode(column: "state", as: String.self)
        // A replay reports the recorded result; it never changes ownership again.
        if state == "accepted" { return try response(row) }
        guard state == "pending" else { throw changed() }
        let workspaceID = try row.decode(column: "workspace_id", as: UUID.self)
        let ownerID = try row.decode(column: "owner_user_id", as: UUID.self)
        try await lockParties(ownerID, actorID, on: db)
        let team = try await WorkspaceAccessService.requireCompany(workspaceID, actorID: ownerID, admin: true, on: db)
        guard team.ownerUserId == ownerID,
              try team.revision == row.decode(column: "workspace_revision", as: Int64.self) else { throw changed() }
        let sql = try VerifiedIdentityService.sql(db)
        guard let member = try await sql.raw("SELECT revision FROM workspace_memberships WHERE workspace_id=\(bind: workspaceID) AND user_id=\(bind: actorID) AND state='active'").first(),
              try member.decode(column: "revision", as: Int64.self) == row.decode(column: "target_membership_revision", as: Int64.self) else { throw changed() }
        try await WorkspaceAccessService.transferOwnership(workspaceID: workspaceID, targetID: actorID, expectedRevision: team.revision, actorID: ownerID, on: db)
        try await sql.raw("UPDATE ownership_transfer_offers SET state='accepted',resolved_at=NOW() WHERE id=\(bind: id)").run()
        return try await get(id: id, on: db)
    }
    static func resolve(id: UUID, actorID: UUID, cancel: Bool, on db: Database) async throws -> OwnershipTransferResponse {
        let row = try await locked(id: id, actorID: actorID, on: db)
        let required = try row.decode(column: cancel ? "owner_user_id" : "target_user_id", as: UUID.self)
        guard actorID == required else { throw Abort(.notFound) }
        let next = cancel ? "cancelled" : "declined"
        let current = try row.decode(column: "state", as: String.self)
        if current == next { return try response(row) }
        guard current == "pending" else { throw changed() }
        try await VerifiedIdentityService.sql(db).raw("UPDATE ownership_transfer_offers SET state=\(bind: next),resolved_at=NOW() WHERE id=\(bind: id)").run()
        return try await get(id: id, on: db)
    }
    static func pendingForActor(actorID: UUID, on db: Database) async throws -> [OwnershipTransferResponse] {
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        return try await VerifiedIdentityService.sql(db).raw("""
            SELECT o.*,t.name AS workspace_name,source.name AS owner_display_name,target.name AS target_display_name
            FROM ownership_transfer_offers o JOIN teams t ON t.id=o.workspace_id
            JOIN users source ON source.id=o.owner_user_id JOIN users target ON target.id=o.target_user_id
            JOIN workspace_memberships m ON m.workspace_id=o.workspace_id AND m.user_id=o.target_user_id
            WHERE (o.target_user_id=\(bind: actorID) OR o.owner_user_id=\(bind: actorID)) AND o.state='pending' AND t.lifecycle_state='active'
              AND t.owner_user_id=o.owner_user_id AND t.revision=o.workspace_revision
              AND m.state='active' AND m.revision=o.target_membership_revision
            ORDER BY o.created_at,o.id LIMIT 100
            """).all().map(response)
    }
    private static func locked(id: UUID, actorID: UUID, on db: Database) async throws -> SQLRow {
        _ = try await VerifiedIdentityService.activeUser(actorID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        guard let scope = try await sql.raw("SELECT workspace_id FROM ownership_transfer_offers WHERE id=\(bind: id) AND (owner_user_id=\(bind: actorID) OR target_user_id=\(bind: actorID))").first() else { throw Abort(.notFound) }
        try await WorkspaceAccessService.lock(scope.decode(column: "workspace_id", as: UUID.self), on: db)
        guard let row = try await sql.raw("SELECT * FROM ownership_transfer_offers WHERE id=\(bind: id) FOR UPDATE").first() else { throw Abort(.notFound) }
        return row
    }
    private static func lockParties(_ first: UUID, _ second: UUID, on db: Database) async throws {
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT id,lifecycle_state FROM users WHERE id IN (\(bind: first),\(bind: second)) ORDER BY id FOR SHARE").all()
        guard rows.count == 2, try rows.allSatisfy({ try $0.decode(column: "lifecycle_state", as: String.self) == "active" }) else { throw changed() }
    }
    private static func get(id: UUID, on db: Database) async throws -> OwnershipTransferResponse {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM ownership_transfer_offers WHERE id=\(bind: id)").first() else { throw Abort(.notFound) }
        return try response(row)
    }
    private static func response(_ row: SQLRow) throws -> OwnershipTransferResponse {
        var result = try OwnershipTransferResponse(id: row.decode(column: "id", as: UUID.self), workspaceId: row.decode(column: "workspace_id", as: UUID.self),
                  ownerUserId: row.decode(column: "owner_user_id", as: UUID.self), targetUserId: row.decode(column: "target_user_id", as: UUID.self),
                  state: row.decode(column: "state", as: String.self), createdAt: row.decode(column: "created_at", as: Date.self), resolvedAt: row.decode(column: "resolved_at", as: Date?.self))
        result.workspaceName = try? row.decode(column: "workspace_name", as: String.self)
        result.ownerDisplayName = try? row.decode(column: "owner_display_name", as: String.self)
        result.targetDisplayName = try? row.decode(column: "target_display_name", as: String.self)
        return result
    }
    private static func changed() -> Abort { Abort(.conflict, reason: "This ownership offer changed. Refresh and try again", identifier: "ownership_transfer_changed") }
}
