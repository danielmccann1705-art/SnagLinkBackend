import Vapor
import Fluent
import FluentSQL

/// Produced by the same scoped graph inventory used by company erasure. The
/// fingerprint excludes the confirmation/job control tables themselves.
struct CompanyClosureInventory: Sendable {
    let projectCount: Int64
    let snagCount: Int64
    let otherMemberCount: Int64
    let fingerprint: String
}
struct CompanyClosureConfirmationRequest: Content { let workspaceID: UUID; let receiptReference: String }
struct CompanyClosureAcknowledgement: Content, Sendable {
    let workspaceID: UUID
    let confirmationReference: String
    let confirmation: String
}
struct CompanyClosureConfirmationResponse: Content, Sendable {
    let confirmationReference: String
    let workspaceID: UUID
    let name: String
    let projectCount: Int64
    let snagCount: Int64
    let otherMemberCount: Int64
    let expiresIn: Int
}

enum CompanyClosureConfirmationService {
    static let lifetime: TimeInterval = 600
    struct Confirmed: Sendable {
        let confirmationID: UUID
        let workspaceID: UUID
        let workspaceRevision: Int64
        let inventory: CompanyClosureInventory
    }
    static func issue(userID: UUID, body: CompanyClosureConfirmationRequest, on db: Database) async throws -> CompanyClosureConfirmationResponse {
        let receiptHash = try AccountDeletionService.receiptHash(body.receiptReference)
        let team = try await WorkspaceAccessService.requireCompany(body.workspaceID, actorID: userID, admin: true, on: db)
        guard team.ownerUserId == userID else { throw Abort(.forbidden, reason: "Only the owner can close this company") }
        let inventory = try await AccountDeletionGraphService.companyInventory(workspaceID: body.workspaceID, on: db)
        let reference = try SecureTokenGenerator.generate(byteCount: 32), now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO company_closure_confirmations(id,actor_user_id,workspace_id,reference_hash,receipt_hash,workspace_revision,
                project_count,snag_count,other_member_count,inventory_hash,created_at,expires_at)
            VALUES(\(bind: UUID()),\(bind: userID),\(bind: body.workspaceID),\(bind: referenceHash(reference)),\(bind: receiptHash),\(bind: team.revision),
                \(bind: inventory.projectCount),\(bind: inventory.snagCount),\(bind: inventory.otherMemberCount),\(bind: inventory.fingerprint),\(bind: now),\(bind: now.addingTimeInterval(lifetime)))
            """).run()
        return .init(confirmationReference: reference, workspaceID: body.workspaceID, name: team.name,
                     projectCount: inventory.projectCount, snagCount: inventory.snagCount, otherMemberCount: inventory.otherMemberCount, expiresIn: Int(lifetime))
    }
    /// Final account-deletion transaction already holds sorted workspace locks
    /// and the actor row. Every context must match the same account receipt.
    static func consume(_ acknowledgements: [CompanyClosureAcknowledgement], userID: UUID, receiptHash: String, on db: Database) async throws -> [Confirmed] {
        guard Set(acknowledgements.map(\.workspaceID)).count == acknowledgements.count else { throw changed() }
        let sql = try VerifiedIdentityService.sql(db)
        var result: [Confirmed] = []
        for acknowledgement in acknowledgements.sorted(by: { $0.workspaceID.uuidString < $1.workspaceID.uuidString }) {
            guard acknowledgement.confirmation == "CLOSE COMPANY", (try? AccountDeletionService.receiptHash(acknowledgement.confirmationReference)) != nil else { throw changed() }
            guard let team = try await Team.find(acknowledgement.workspaceID, on: db),
                  team.kind == "company", team.lifecycleState == "active", team.ownerUserId == userID else { throw changed() }
            guard let row = try await sql.raw("""
                SELECT *,expires_at>clock_timestamp() AS unexpired FROM company_closure_confirmations
                WHERE reference_hash=\(bind: referenceHash(acknowledgement.confirmationReference)) FOR UPDATE
                """).first(),
                  try row.decode(column: "actor_user_id", as: UUID.self) == userID,
                  try row.decode(column: "workspace_id", as: UUID.self) == acknowledgement.workspaceID,
                  try row.decode(column: "receipt_hash", as: String.self) == receiptHash,
                  try row.decode(column: "workspace_revision", as: Int64.self) == team.revision,
                  try row.decode(column: "unexpired", as: Bool.self),
                  try row.decode(column: "consumed_at", as: Date?.self) == nil else { throw changed() }
            let inventory = try await AccountDeletionGraphService.companyInventory(workspaceID: acknowledgement.workspaceID, on: db)
            guard try row.decode(column: "inventory_hash", as: String.self) == inventory.fingerprint,
                  try row.decode(column: "project_count", as: Int64.self) == inventory.projectCount,
                  try row.decode(column: "snag_count", as: Int64.self) == inventory.snagCount,
                  try row.decode(column: "other_member_count", as: Int64.self) == inventory.otherMemberCount else { throw changed() }
            let id = try row.decode(column: "id", as: UUID.self)
            guard try await sql.raw("UPDATE company_closure_confirmations SET consumed_at=clock_timestamp() WHERE id=\(bind: id) AND expires_at>clock_timestamp() AND consumed_at IS NULL RETURNING id").first() != nil else { throw changed() }
            result.append(.init(confirmationID: id, workspaceID: acknowledgement.workspaceID, workspaceRevision: team.revision, inventory: inventory))
        }
        return result
    }
    static func referenceHash(_ reference: String) -> String { SHA256Hasher.hash(token: "company-closure-confirmation:" + reference) }
    static func changed() -> Abort {
        Abort(.conflict, reason: "The company or closure confirmation changed. Review the current counts before closing it", identifier: "company_closure_confirmation_changed")
    }
}
