import Vapor
import Fluent
import FluentSQL

/// All reads, writes and media requests use the same live grant and item checks.
/// The original creator is checked as issuer authority, never used as the actor
/// for work performed by the recipient.
enum LinkGrantService {
    static func row(_ id: UUID, projectID: UUID, on db: Database) async throws -> SQLRow {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM link_grants WHERE id = \(bind: id) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "Contractor link unavailable") }
        return row
    }
    static func response(_ row: SQLRow, on db: Database) async throws -> LinkGrantResponse {
        let id = try row.decode(column: "id", as: UUID.self), sql = try VerifiedIdentityService.sql(db)
        let items = try await sql.raw("SELECT i.snag_id, i.revoked_at, s.archived_at, s.contractor_id, i.assignment_id FROM link_items i JOIN snags s ON s.id = i.snag_id WHERE i.grant_id = \(bind: id) ORDER BY i.position").all()
        let selected = try items.map { try $0.decode(column: "snag_id", as: UUID.self) }
        let active = try items.filter {
            try $0.decode(column: "revoked_at", as: Date?.self) == nil && $0.decode(column: "archived_at", as: Date?.self) == nil && $0.decode(column: "contractor_id", as: UUID?.self) == $0.decode(column: "assignment_id", as: UUID?.self)
        }.map { try $0.decode(column: "snag_id", as: UUID.self) }
        let assets = try await sql.raw("SELECT asset_id FROM link_media WHERE grant_id = \(bind: id) ORDER BY asset_id").all().map { try $0.decode(column: "asset_id", as: UUID.self) }
        return try .init(row, selected: selected, active: active, assets: assets)
    }
    static func validate(_ command: LinkPrepareCommand) throws {
        guard ["completion", "read_only", "preview"].contains(command.mode), command.mode != "completion" || command.contractorId != nil,
              command.snagIds.count <= 100, Set(command.snagIds).count == command.snagIds.count,
              command.assetIds.count <= 500, Set(command.assetIds).count == command.assetIds.count,
              (1...90).contains(command.durationDays ?? 30) else { throw Abort(.badRequest, reason: "Choose up to 100 distinct snags, a contractor for completion access, and an expiry between 1 and 90 days") }
        if let pin = command.pin { guard pin.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "Use a PIN of 4 to 8 digits") } }
    }
    static func prepare(_ command: LinkPrepareCommand, pinHash: String?, project: Project, actorID: UUID, on db: Database) async throws -> LinkGrantResponse {
        try validate(command); try PlatformMutationService.requireManaged(project)
        let projectID = try project.requireID(), workspaceID = project.workspaceId!, sql = try VerifiedIdentityService.sql(db)
        try await VerifiedIdentityService.lock("entity:grant:\(command.id)", on: db)
        guard try await sql.raw("SELECT id FROM link_grants WHERE id = \(bind: command.id)").first() == nil else { throw Abort(.conflict, reason: "This link request already exists. Retry the original operation") }
        if let id = command.contractorId {
            guard let contractor = try await Contractor.find(id, on: db), contractor.workspaceId == workspaceID, contractor.platformManaged, !contractor.isArchived else { throw Abort(.badRequest, reason: "Choose an active contractor from this company") }
        }
        var snags: [Snag] = []
        for id in command.snagIds {
            let snag = try await PlatformSnagService.find(id, projectID: projectID, on: db)
            guard snag.publishedAt != nil, snag.archivedAt == nil, command.contractorId == nil || snag.contractorId == command.contractorId else { throw Abort(.unprocessableEntity, reason: "Share only logged, active snags assigned to the selected contractor") }
            snags.append(snag)
        }
        var assets: [SQLRow] = []
        for id in command.assetIds {
            guard let row = try await sql.raw("SELECT * FROM media_assets WHERE id = \(bind: id) AND project_id = \(bind: projectID)").first(),
                  command.snagIds.contains(try row.decode(column: "snag_id", as: UUID.self)),
                  try row.decode(column: "purpose", as: String.self) == "capture",
                  try row.decode(column: "state", as: String.self) != "retired" else { throw Abort(.unprocessableEntity, reason: "Each shared before photo must belong to a selected snag") }
            assets.append(row)
        }
        let now = Date()
        try await sql.raw("""
            INSERT INTO link_grants (id, workspace_id, project_id, creator_id, contractor_id, mode, pin_hash, duration_days, created_at, expires_at)
            VALUES (\(bind: command.id), \(bind: workspaceID), \(bind: projectID), \(bind: actorID), \(bind: command.contractorId), \(bind: command.mode), \(bind: pinHash), \(bind: command.durationDays ?? 30), \(bind: now), \(bind: now.addingTimeInterval(86400)))
            """).run()
        for (position, snag) in snags.enumerated() {
            try await sql.raw("INSERT INTO link_items (grant_id, snag_id, project_id, position, assignment_id) VALUES (\(bind: command.id), \(bind: snag.requireID()), \(bind: projectID), \(bind: position), \(bind: snag.contractorId))").run()
        }
        for asset in assets {
            try await sql.raw("INSERT INTO link_media (grant_id, snag_id, project_id, asset_id) VALUES (\(bind: command.id), \(bind: asset.decode(column: "snag_id", as: UUID.self)), \(bind: projectID), \(bind: asset.decode(column: "id", as: UUID.self)))").run()
        }
        try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID, action: "contractor_link_prepared", targetID: command.id, on: db)
        return try await response(row(command.id, projectID: projectID, on: db), on: db)
    }
    static func activate(_ row: SQLRow, expectedRevision: Int64, project: Project, app: Application, actorID: UUID, on db: Database) async throws -> LinkGrantResponse {
        let current = try await response(row, on: db), sql = try VerifiedIdentityService.sql(db)
        guard current.state == "prepared", current.expiresAt > Date(), current.revision == expectedRevision else { throw Abort(.conflict, reason: "This link request changed or expired. Prepare a new Contractor link") }
        guard Set(current.selectedSnagIds) == Set(current.activeSnagIds) else { throw Abort(.conflict, reason: "The selected snags changed. Prepare a new Contractor link before sharing") }
        let assets = try await sql.raw("SELECT a.* FROM link_media m JOIN media_assets a ON a.id = m.asset_id WHERE m.grant_id = \(bind: current.id)").all()
        for asset in assets {
            guard try asset.decode(column: "state", as: String.self) == "ready", try asset.decode(column: "attached_at", as: Date?.self) != nil else { throw Abort(.unprocessableEntity, reason: "Finish processing and attaching every selected photo before sharing", identifier: "link_media_not_ready") }
        }
        // Store only approved contractor fields in the issuance snapshot. The live
        // projection remains authoritative for status and never reads this JSON.
        let snapshot = try await page(row, project: project, page: 1, limit: 100, on: db)
        let token = "c2_" + (try SecureTokenGenerator.generate(byteCount: 32)), now = Date()
        let expiry = now.addingTimeInterval(TimeInterval(try row.decode(column: "duration_days", as: Int.self)) * 86400)
        try await sql.raw("""
            UPDATE link_grants SET state = 'active', revision = revision + 1, token_hash = \(bind: SHA256Hasher.hash(token: token)),
                token_ciphertext = \(bind: LinkGrantTokenService.seal(token, id: current.id, app: app)), activated_at = \(bind: now), expires_at = \(bind: expiry), issuance_json = \(bind: PlatformMutationService.encode(snapshot))
            WHERE id = \(bind: current.id)
            """).run()
        try await WorkspaceAccessService.activity(workspaceID: project.workspaceId!, actorID: actorID, action: "contractor_link_activated", targetID: current.id, on: db)
        return try await response(self.row(current.id, projectID: project.requireID(), on: db), on: db)
    }
    static func load(_ token: String, req: Request, verifySession: Bool = true, on db: Database) async throws -> (SQLRow, Project) {
        guard token.hasPrefix("c2_"), token.count <= 100,
              let found = try await VerifiedIdentityService.sql(db).raw("SELECT id, project_id, workspace_id FROM link_grants WHERE token_hash = \(bind: SHA256Hasher.hash(token: token))").first() else { throw Abort(.notFound, reason: "Contractor link unavailable") }
        try await WorkspaceAccessService.lock(found.decode(column: "workspace_id", as: UUID.self), on: db)
        let row = try await self.row(found.decode(column: "id", as: UUID.self), projectID: found.decode(column: "project_id", as: UUID.self), on: db)
        guard try row.decode(column: "state", as: String.self) == "active", try row.decode(column: "expires_at", as: Date.self) > Date() else { throw Abort(.gone, reason: "This Contractor link expired or was revoked. Ask the project manager for a new link") }
        // Revoked issuer membership/access also invalidates an old capability.
        let (project, _) = try await ProjectAccessService.require(.share, projectID: row.decode(column: "project_id", as: UUID.self), actorID: row.decode(column: "creator_id", as: UUID.self), on: db)
        try PlatformMutationService.requireManaged(project)
        if let contractorID = try row.decode(column: "contractor_id", as: UUID?.self) {
            guard let contractor = try await Contractor.find(contractorID, on: db), !contractor.isArchived else { throw Abort(.gone, reason: "This contractor assignment is no longer active") }
        }
        if verifySession, try row.decode(column: "pin_hash", as: String?.self) != nil {
            let id = try row.decode(column: "id", as: UUID.self)
            guard let token = RequestCredentialCookie.value(cookieName(id), on: req), token.count <= 128,
                  try await VerifiedIdentityService.sql(db).raw("SELECT token_hash FROM link_sessions WHERE token_hash = \(bind: SHA256Hasher.hash(token: token)) AND grant_id = \(bind: id) AND expires_at > \(bind: Date())").first() != nil else { throw Abort(.forbidden, reason: "Enter the PIN provided by the project manager", identifier: "pin_required") }
        }
        return (row, project)
    }
    static func item(_ snagID: UUID, grant: SQLRow, project: Project, write: Bool, on db: Database) async throws -> Snag {
        let id = try grant.decode(column: "id", as: UUID.self)
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT assignment_id FROM link_items WHERE grant_id = \(bind: id) AND snag_id = \(bind: snagID) AND revoked_at IS NULL").first() else { throw Abort(.notFound, reason: "This snag is not available through this Contractor link") }
        let snag = try await PlatformSnagService.find(snagID, projectID: project.requireID(), on: db)
        guard snag.archivedAt == nil, snag.publishedAt != nil, try row.decode(column: "assignment_id", as: UUID?.self) == snag.contractorId else { throw Abort(.notFound, reason: "This snag is no longer available through this Contractor link") }
        if write { guard try grant.decode(column: "mode", as: String.self) == "completion" else { throw Abort(.forbidden, reason: "This Contractor link is read only") } }
        return snag
    }
    static func cookieName(_ id: UUID) -> String { "__Host-snaglist_link_" + id.uuidString.lowercased() }
    static func requireWrite(_ req: Request) throws {
        // Custom header prevents cross-origin forms; no CORS permission is issued
        // for this header. Native requests may omit Origin; browser requests must
        // match the configured public API/renderer origin exactly.
        guard req.headers["X-Snaglist-Contractor"] == ["1"], !["cross-site", "none"].contains(req.headers.first(name: "Sec-Fetch-Site") ?? "") else { throw Abort(.forbidden, reason: "Open this action from your Contractor link") }
        if let origin = req.headers.first(name: "Origin") {
            guard let configured = Environment.get("BASE_URL"), req.headers["Origin"] == [configured], origin != "null" else { throw Abort(.forbidden, reason: "Open this action from your Contractor link") }
        }
    }
    static func replay<T: Decodable>(_ type: T.Type, grantID: UUID, mutation: MutationMetadata, hash: String, on db: Database) async throws -> T? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT request_hash, result_json FROM link_mutation_receipts WHERE grant_id = \(bind: grantID) AND operation_id = \(bind: mutation.operationId)").first() else { return nil }
        guard try row.decode(column: "request_hash", as: String.self) == hash else { throw Abort(.conflict, reason: "Keep the original request when retrying this action", identifier: "operation_reused") }
        return try PlatformMutationService.decode(type, row.decode(column: "result_json", as: String.self))
    }
    static func record<T: Encodable>(_ result: T, grantID: UUID, mutation: MutationMetadata, hash: String, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO link_mutation_receipts (grant_id, operation_id, device_id, request_hash, result_json, created_at) VALUES (\(bind: grantID), \(bind: mutation.operationId), \(bind: mutation.deviceId), \(bind: hash), \(bind: PlatformMutationService.encode(result)), \(bind: Date()))").run()
    }
}

extension LinkGrantService {
    static func page(_ grant: SQLRow, project: Project, page: Int, limit: Int = 25, on db: Database) async throws -> ContractorPage {
        let grantID = try grant.decode(column: "id", as: UUID.self), sql = try VerifiedIdentityService.sql(db)
        let current = try await response(grant, on: db)
        let ids = Array(current.activeSnagIds.dropFirst((page - 1) * limit).prefix(limit))
        var result: [ContractorItem] = []
        if !ids.isEmpty {
            let snags = try await Snag.query(on: db).filter(\.$id ~~ ids).all()
            let attempts = try await sql.raw("SELECT * FROM (SELECT a.*, row_number() OVER (PARTITION BY snag_id ORDER BY attempt_number DESC) AS recent FROM completion_attempts a WHERE actor_grant_id = \(bind: grantID) AND snag_id = ANY(\(bind: ids)::UUID[])) bounded WHERE recent <= 5 ORDER BY snag_id, attempt_number DESC").all()
            let values = try await CanonicalWorkflowService.attempts(attempts, on: db)
            let evidenceIDs = values.flatMap(\.evidenceIds)
            let media = try await sql.raw("""
                SELECT DISTINCT a.* FROM media_assets a
                LEFT JOIN link_media m ON m.asset_id = a.id AND m.grant_id = \(bind: grantID)
                WHERE a.snag_id = ANY(\(bind: ids)::UUID[]) AND a.state = 'ready' AND a.attached_at IS NOT NULL
                    AND (m.asset_id IS NOT NULL OR a.id = ANY(\(bind: evidenceIDs)::UUID[]))
                ORDER BY a.created_at, a.id
                """).all()
            let decisions = try await sql.raw("SELECT d.attempt_id, d.reason FROM review_decisions d JOIN completion_attempts a ON a.id = d.attempt_id WHERE a.actor_grant_id = \(bind: grantID) AND a.id = ANY(\(bind: values.map(\.id))::UUID[]) AND d.kind = 'send_back'").all()
            var feedback: [UUID: String] = [:]
            for decision in decisions { feedback[try decision.decode(column: "attempt_id", as: UUID.self)] = try decision.decode(column: "reason", as: String.self) }
            let date = ISO8601DateFormatter()
            for id in ids {
                guard let snag = snags.first(where: { $0.id == id }) else { continue }
                let photos: [ContractorItem.Photo] = try media.filter { try $0.decode(column: "snag_id", as: UUID.self) == id }.map {
                    try .init(id: $0.decode(column: "id", as: UUID.self), label: $0.decode(column: "purpose", as: String.self) == "capture" ? "Before" : "After", width: $0.decode(column: "width", as: Int?.self), height: $0.decode(column: "height", as: Int?.self))
                }
                // Only this grant's submissions and their send-back reasons are
                // disclosed. Internal notes and other contractors' history stay private.
                let submissions = values.filter { $0.snagId == id }.prefix(25).map {
                    ContractorItem.Submission(id: $0.id, number: $0.number, notes: $0.notes, state: $0.state, submittedAt: $0.submittedAt, evidenceIds: $0.evidenceIds, feedback: feedback[$0.id])
                }
                result.append(.init(id: id, reference: snag.reference, title: snag.title, description: snag.snagDescription, location: snag.location, priority: snag.priority, dueDate: snag.dueOn ?? snag.dueDate.map(date.string), status: snag.status, revision: snag.revision, workflowRevision: snag.workflowRevision, photos: photos, submissions: submissions))
            }
        }
        let contractor: String?
        if let id = current.contractorId { contractor = try await Contractor.find(id, on: db)?.companyName } else { contractor = nil }
        return .init(projectName: project.name, projectAddress: project.address, contractorName: contractor, mode: current.mode, expiresAt: current.expiresAt, issuedAt: current.activatedAt ?? current.createdAt, items: result, total: current.activeSnagIds.count, page: page, hasMore: page * limit < current.activeSnagIds.count)
    }
    static func visibleMedia(_ id: UUID, snagID: UUID, grant: SQLRow, project: Project, on db: Database) async throws -> SQLRow {
        _ = try await item(snagID, grant: grant, project: project, write: false, on: db)
        let row = try await PrivateMediaService.row(id, snagID: snagID, projectID: project.requireID(), on: db)
        guard try row.decode(column: "state", as: String.self) == "ready" else { throw Abort(.notFound) }
        let grantID = try grant.decode(column: "id", as: UUID.self)
        if try row.decode(column: "creator_grant_id", as: UUID?.self) == grantID {
            try PrivateMediaService.requireUploader(row, actorID: nil, grantID: grantID)
        } else {
            guard try row.decode(column: "attached_at", as: Date?.self) != nil,
                  try await VerifiedIdentityService.sql(db).raw("SELECT asset_id FROM link_media WHERE grant_id = \(bind: grantID) AND asset_id = \(bind: id)").first() != nil else { throw Abort(.notFound) }
        }
        return row
    }
}
