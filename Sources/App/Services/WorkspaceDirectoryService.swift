import Vapor
import Fluent
import FluentSQL

struct DirectoryCommand: Content {
    let mutation: MutationMetadata
    let id: UUID
    let expectedRevision: Int64 // 0 creates; existing records require their current revision.
    let projectId: UUID? // Permission context only; cannot choose another workspace owner.
    let fields: [String: PlatformJSON]
}
struct DirectoryResponse: Content {
    let id: UUID; let workspaceId: UUID; let revision: Int64; let type: String; let data: PlatformJSON
}
struct DirectoryConflict: Error {
    struct Body: Content {
        let error = true; let identifier = "revision_conflict"
        let reason = "This directory entry changed. Compare the latest version before saving."
        let current: DirectoryResponse
    }
    let body: Body
}

struct WorkspaceDirectoryService {
    enum Kind: String, Sendable { case contractor, trade }
    /// Owner/Admin have workspace directory authority. Assigned managers can edit
    /// the directory from a project; assigned contributors have read-only access.
    static func require(workspaceID: UUID, projectID: UUID?, actorID: UUID, write: Bool, on db: Database) async throws {
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        guard let workspace = try await Team.find(workspaceID, on: db) else { throw Abort(.notFound) }
        let role = try await WorkspaceAccessService.role(actorID: actorID, workspace: workspace, on: db)
        if let projectID {
            guard let context = try await Project.find(projectID, on: db), context.workspaceId == workspaceID else { throw Abort(.notFound, reason: "Directory unavailable") }
            let (project, _) = try await ProjectAccessService.require(write ? .assign : .read, projectID: projectID, actorID: actorID, on: db)
            guard project.workspaceId == workspaceID else { throw Abort(.notFound, reason: "Directory unavailable") }
        } else {
            guard ["owner", "admin"].contains(role) else { throw Abort(.forbidden, reason: "Choose one of your assigned projects to use its contractor directory") }
        }
    }
    static func response(_ value: Contractor) throws -> DirectoryResponse {
        .init(id: try value.requireID(), workspaceId: value.workspaceId!, revision: value.revision, type: "contractor", data: try PlatformMutationService.decode(PlatformJSON.self, PlatformMutationService.encode(ContractorResponse(from: value))))
    }
    static func response(_ value: Trade) throws -> DirectoryResponse {
        .init(id: try value.requireID(), workspaceId: value.workspaceId!, revision: value.revision, type: "trade", data: try PlatformMutationService.decode(PlatformJSON.self, PlatformMutationService.encode(TradeResponse(from: value))))
    }
    static func change(kind: Kind, command: DirectoryCommand, workspaceID: UUID, actorID: UUID, on db: Database) async throws -> DirectoryResponse {
        try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
        try await require(workspaceID: workspaceID, projectID: command.projectId, actorID: actorID, write: true, on: db)
        let hash = try PlatformMutationService.requestHash(command, route: "directory:\(workspaceID):\(kind.rawValue)")
        if let replay = try await PlatformMutationService.replay(DirectoryResponse.self, actorID: actorID, mutation: command.mutation, hash: hash, on: db) { return replay }
        guard command.expectedRevision >= 0, !command.fields.isEmpty, command.fields.count <= 8 else { throw Abort(.badRequest, reason: "Provide changed fields and a valid base revision") }
        try await VerifiedIdentityService.lock("entity:\(kind.rawValue):\(command.id)", on: db)
        let result: DirectoryResponse
        switch kind {
        case .contractor: result = try await contractor(command, workspaceID: workspaceID, actorID: actorID, on: db)
        case .trade: result = try await trade(command, workspaceID: workspaceID, actorID: actorID, on: db)
        }
        try await PlatformMutationService.change(workspaceID: workspaceID, projectID: nil, type: kind.rawValue, entityID: command.id, revision: result.revision, kind: command.expectedRevision == 0 ? "created" : "updated", fields: Array(command.fields.keys), payload: result, actorID: actorID, on: db)
        try await PlatformMutationService.record(result, actorID: actorID, workspaceID: workspaceID, mutation: command.mutation, hash: hash, on: db)
        return result
    }
    private static func text(_ value: PlatformJSON, key: String, optional: Bool = false, maximum: Int = 200) throws -> String? {
        if value == .null && optional { return nil }
        guard case .string(let text) = value, text.count <= maximum, optional || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Abort(.badRequest, reason: "Check \(key)") }
        return text
    }
    private static func flag(_ value: PlatformJSON) throws -> Bool {
        guard case .bool(let result) = value else { throw Abort(.badRequest, reason: "Expected true or false") }
        return result
    }
    private static func contractor(_ command: DirectoryCommand, workspaceID: UUID, actorID: UUID, on db: Database) async throws -> DirectoryResponse {
        let allowed: Set<String> = ["companyName", "contactName", "email", "phone", "notes", "isArchived", "tradeIds"]
        guard Set(command.fields.keys).isSubset(of: allowed) else { throw Abort(.badRequest, reason: "Unsupported contractor field") }
        let existing = try await Contractor.find(command.id, on: db)
        if let existing {
            guard existing.workspaceId == workspaceID, existing.platformManaged else { throw Abort(.notFound, reason: "Contractor unavailable") }
            guard command.expectedRevision == existing.revision else { throw DirectoryConflict(body: .init(current: try response(existing))) }
        } else { guard command.expectedRevision == 0, command.fields["companyName"] != nil else { throw Abort(.conflict, reason: "Create this contractor with a stable ID, name and revision zero") } }
        let value = existing ?? Contractor(id: command.id, companyName: "", ownerId: actorID)
        value.workspaceId = workspaceID; value.platformManaged = true
        for (key, field) in command.fields {
            switch key {
            case "companyName": value.companyName = try text(field, key: key)!
            case "contactName": value.contactName = try text(field, key: key, optional: true)
            case "phone": value.phone = try text(field, key: key, optional: true, maximum: 80)
            case "notes": value.notes = try text(field, key: key, optional: true, maximum: 5000)
            case "email":
                let email = try text(field, key: key, optional: true, maximum: 254)
                guard email == nil || EmailValidator.isValidFormat(email!) else { throw Abort(.badRequest, reason: "Enter a valid contractor email") }
                value.email = email.map(EmailValidator.normalize)
            case "isArchived": value.isArchived = try flag(field)
            case "tradeIds":
                guard case .array(let fields) = field, fields.count <= 50 else { throw Abort(.badRequest, reason: "Choose up to 50 trades") }
                let ids = try fields.map { field -> UUID in
                    guard case .string(let raw) = field, let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid trade ID") }
                    return id
                }
                guard Set(ids).count == ids.count else { throw Abort(.badRequest, reason: "Trades must be unique") }
                let matches = try await Trade.query(on: db).filter(\.$id ~~ ids).filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).filter(\.$isArchived == false).count()
                guard matches == ids.count else { throw Abort(.badRequest, reason: "Choose active trades from this workspace") }
                value.tradeIds = ids
            default: throw Abort(.badRequest)
            }
        }
        if existing != nil { value.revision += 1 }
        try await value.save(on: db)
        let sql = try VerifiedIdentityService.sql(db)
        try await sql.raw("DELETE FROM contractor_trades WHERE contractor_id = \(bind: command.id)").run()
        for id in value.tradeIds { try await sql.raw("INSERT INTO contractor_trades (contractor_id, trade_id, workspace_id) VALUES (\(bind: command.id), \(bind: id), \(bind: workspaceID))").run() }
        return try response(value)
    }
    private static func trade(_ command: DirectoryCommand, workspaceID: UUID, actorID: UUID, on db: Database) async throws -> DirectoryResponse {
        let allowed: Set<String> = ["name", "colorHex", "sortOrder", "isArchived", "isDefault"]
        guard Set(command.fields.keys).isSubset(of: allowed) else { throw Abort(.badRequest, reason: "Unsupported trade field") }
        let existing = try await Trade.find(command.id, on: db)
        if let existing {
            guard existing.workspaceId == workspaceID, existing.platformManaged else { throw Abort(.notFound, reason: "Trade unavailable") }
            guard command.expectedRevision == existing.revision else { throw DirectoryConflict(body: .init(current: try response(existing))) }
        } else { guard command.expectedRevision == 0, command.fields["name"] != nil else { throw Abort(.conflict, reason: "Create this trade with a stable ID, name and revision zero") } }
        let value = existing ?? Trade(id: command.id, name: "", colorHex: "6B7280", ownerId: actorID)
        value.workspaceId = workspaceID; value.platformManaged = true
        for (key, field) in command.fields {
            switch key {
            case "name": value.name = try text(field, key: key)!
            case "colorHex":
                guard let hex = try text(field, key: key, maximum: 6), hex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "Use a six-digit colour") }
                value.colorHex = hex.uppercased()
            case "sortOrder":
                guard case .number(let number) = field, number >= 0, number <= 100000, number.rounded() == number else { throw Abort(.badRequest, reason: "Invalid sort order") }
                value.sortOrder = Int(number)
            case "isArchived": value.isArchived = try flag(field)
            case "isDefault": value.isDefault = try flag(field)
            default: throw Abort(.badRequest)
            }
        }
        if existing != nil { value.revision += 1 }; try await value.save(on: db)
        return try response(value)
    }
}
