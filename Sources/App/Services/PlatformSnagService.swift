import Vapor
import Fluent
import FluentSQL

struct PlatformSnagService {
    static let editableFields: Set<String> = ["title", "description", "priority", "location", "dueDate", "costEstimate", "actualCost", "currency", "tags"]
    static func apply(_ fields: [String: PlatformJSON], to snag: Snag) throws {
        guard !fields.isEmpty, fields.count <= editableFields.count,
              Set(fields.keys).isSubset(of: editableFields) else {
            throw Abort(.badRequest, reason: "Only description, location, priority, date, cost, currency and tags can be edited here. Workflow and assignment use their own actions", identifier: "invalid_fields")
        }
        func string(_ value: PlatformJSON, _ key: String, optional: Bool, maximum: Int) throws -> String? {
            if optional, value == .null { return nil }
            guard case .string(let text) = value, text.count <= maximum else { throw Abort(.badRequest, reason: "Invalid \(key)") }
            if !optional, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Abort(.badRequest, reason: "Enter \(key)") }
            return text
        }
        for (key, value) in fields {
            switch key {
            case "title": snag.title = try string(value, key, optional: false, maximum: 500)!.trimmingCharacters(in: .whitespacesAndNewlines)
            case "description": snag.snagDescription = try string(value, key, optional: true, maximum: 10000)
            case "location": snag.location = try string(value, key, optional: true, maximum: 500)
            case "priority":
                guard case .string(let priority) = value, ["low", "medium", "high", "critical"].contains(priority) else { throw Abort(.badRequest, reason: "Choose a valid priority") }
                snag.priority = priority
            case "currency":
                guard case .string(let currency) = value, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "Use a three-letter currency code") }
                snag.currency = currency
            case "dueDate":
                if value == .null { snag.dueDate = nil }
                else {
                    guard case .string(let raw) = value, raw.count <= 40 else { throw Abort(.badRequest, reason: "Invalid due date") }
                    let formatter = ISO8601DateFormatter()
                    let plain = formatter.date(from: raw)
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    guard let date = plain ?? formatter.date(from: raw) else { throw Abort(.badRequest, reason: "Use an ISO 8601 date with a timezone") }
                    snag.dueDate = date
                }
            case "costEstimate", "actualCost":
                let cost: Double?
                if value == .null { cost = nil }
                else if case .number(let n) = value, n.isFinite, n >= 0, n <= 1_000_000_000 { cost = n }
                else { throw Abort(.badRequest, reason: "Enter a valid non-negative cost") }
                if key == "costEstimate" { snag.costEstimate = cost } else { snag.actualCost = cost }
            case "tags":
                guard case .array(let values) = value, values.count <= 50 else { throw Abort(.badRequest, reason: "Choose up to 50 tags") }
                let tags = try values.map { try string($0, "tag", optional: false, maximum: 80)! }
                guard Set(tags).count == tags.count else { throw Abort(.badRequest, reason: "Tags must be unique") }
                snag.tags = tags
            default: throw Abort(.badRequest)
            }
        }
    }

    static func create(_ command: SnagCreateCommand, project: Project, actorID: UUID, on db: Database) async throws -> PlatformSnagResponse {
        try PlatformMutationService.requireManaged(project)
        let projectID = try project.requireID(), workspaceID = project.workspaceId!
        try await VerifiedIdentityService.lock("entity:snag:\(command.id)", on: db)
        guard try await Snag.find(command.id, on: db) == nil,
              try await SnagDeletion.query(on: db).filter(\.$snagId == command.id).first() == nil else {
            throw Abort(.conflict, reason: "This snag ID is already in use or retained in deletion history", identifier: "entity_exists")
        }
        guard command.fields["title"] != nil else { throw Abort(.badRequest, reason: "Enter a snag title") }
        let snag = Snag(id: command.id, reference: "", title: "", projectId: projectID, ownerId: actorID)
        try apply(command.fields, to: snag)
        guard let row = try await VerifiedIdentityService.sql(db).raw("UPDATE projects SET next_snag_number = next_snag_number + 1 WHERE id = \(bind: projectID) RETURNING next_snag_number - 1 AS number").first() else { throw Abort(.notFound) }
        let number = try row.decode(column: "number", as: Int64.self)
        snag.displayNumber = number; snag.reference = "SL\(number)"
        try await snag.save(on: db)
        let response = PlatformSnagResponse(snag)
        try await PlatformMutationService.change(workspaceID: workspaceID, projectID: projectID, type: "snag", entityID: command.id, revision: 1, kind: "created", fields: Array(command.fields.keys) + ["reference", "status"], payload: response, actorID: actorID, on: db)
        return response
    }
    static func find(_ snagID: UUID, projectID: UUID, on db: Database) async throws -> Snag {
        guard let snag = try await Snag.query(on: db).filter(\.$id == snagID).filter(\.$projectId == projectID).first() else { throw Abort(.notFound, reason: "Snag unavailable") }
        return snag
    }
    static func edit(_ command: SnagEditCommand, snag: Snag, project: Project, actorID: UUID, on db: Database) async throws -> PlatformSnagResponse {
        try PlatformMutationService.requireManaged(project)
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
        guard snag.archivedAt == nil else { throw Abort(.gone, reason: "This snag is archived. Restore it explicitly before editing", identifier: "snag_archived") }
        try apply(command.fields, to: snag)
        snag.revision += 1; try await snag.save(on: db)
        return try await changed(snag, project: project, actorID: actorID, kind: "updated", fields: Array(command.fields.keys), on: db)
    }
    static func publish(_ command: SnagPublishCommand, snag: Snag, project: Project, actorID: UUID, on db: Database) async throws -> PlatformSnagResponse {
        try PlatformMutationService.requireManaged(project)
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
        guard snag.archivedAt == nil else { throw Abort(.gone, reason: "This snag is archived") }
        guard snag.publishedAt == nil else { throw Abort(.conflict, reason: "This snag is already logged") }
        snag.publishedAt = Date(); snag.revision += 1; try await snag.save(on: db)
        return try await changed(snag, project: project, actorID: actorID, kind: "published", fields: ["publishedAt"], on: db)
    }
    static func archive(_ command: SnagArchiveCommand, snag: Snag, project: Project, actions: Set<ProjectAccessPolicy.Action>, actorID: UUID, restore: Bool, on db: Database) async throws -> PlatformSnagResponse {
        try PlatformMutationService.requireManaged(project)
        let canDiscard = ProjectAccessPolicy.mayDiscardDraft(actorID: actorID, draftCreatorID: snag.ownerId, isPublished: snag.publishedAt != nil, actions: actions)
        guard actions.contains(.archive) || (!restore && canDiscard) else { throw Abort(.forbidden, reason: "Ask a project manager to archive this logged snag") }
        try await PlatformMutationService.checkRevision(command.expectedRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
        let reason = command.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 2000 else { throw Abort(.badRequest, reason: "Give a reason, up to 2,000 characters") }
        guard restore == (snag.archivedAt != nil) else { throw Abort(.conflict, reason: restore ? "This snag is already active" : "This snag is already archived") }
        // Keep UUID, closedAt, status, evidence and previous events. Never recycle a reference.
        snag.archivedAt = restore ? nil : Date(); snag.archiveReason = restore ? nil : reason
        snag.revision += 1; try await snag.save(on: db)
        try await WorkspaceAccessService.activity(workspaceID: project.workspaceId!, actorID: actorID, action: restore ? "snag_restored" : "snag_archived", targetID: snag.requireID(), detail: reason, on: db)
        return try await changed(snag, project: project, actorID: actorID, kind: restore ? "restored" : "archived", fields: ["archivedAt", "archiveReason"], on: db)
    }
    static func changed(_ snag: Snag, project: Project, actorID: UUID, kind: String, fields: [String], on db: Database) async throws -> PlatformSnagResponse {
        let response = PlatformSnagResponse(snag)
        try await PlatformMutationService.change(workspaceID: project.workspaceId!, projectID: project.requireID(), type: "snag", entityID: snag.requireID(), revision: snag.revision, kind: kind, fields: fields, payload: response, actorID: actorID, on: db)
        return response
    }
}
