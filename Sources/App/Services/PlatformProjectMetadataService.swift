import Vapor
import Fluent
import FluentSQL

struct PlatformProjectMetadataService {
    static let editableFields: Set<String> = ["name", "reference", "clientName", "clientEmail", "clientPhone", "address", "notes", "projectType", "customProjectType", "latitude", "longitude", "startDate", "expectedEndDate", "startOn", "expectedEndOn"]
    static func apply(_ fields: [String: PlatformJSON], to project: Project, timezone: TimeZone) throws {
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: editableFields) else {
            throw Abort(.badRequest, reason: "Only project metadata can be edited here. Ownership, access, status, media and archive use separate actions", identifier: "invalid_fields")
        }
        for pair in [("startDate", "startOn"), ("expectedEndDate", "expectedEndOn")] {
            guard fields[pair.0] == nil || fields[pair.1] == nil else {
                throw Abort(.badRequest, reason: "Send one representation of each project date", identifier: "duplicate_field_representation")
            }
        }
        func text(_ value: PlatformJSON, optional: Bool = true, maximum: Int) throws -> String? {
            if optional && value == .null { return nil }
            guard case .string(let raw) = value, raw.unicodeScalars.count <= maximum else { throw Abort(.badRequest, reason: "Invalid project text") }
            guard optional || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Abort(.badRequest, reason: "Enter a project name and reference") }
            return raw
        }
        func coordinate(_ value: PlatformJSON, range: ClosedRange<Double>) throws -> Double? {
            if value == .null { return nil }
            guard case .number(let number) = value, number.isFinite, range.contains(number) else { throw Abort(.badRequest, reason: "Invalid project coordinates") }
            return number
        }
        func instant(_ value: PlatformJSON) throws -> Date? {
            if value == .null { return nil }
            guard case .string(let raw) = value, raw.count <= 40 else { throw Abort(.badRequest, reason: "Invalid project timestamp") }
            let formatter = ISO8601DateFormatter(), plain = formatter.date(from: raw)
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let date = plain ?? formatter.date(from: raw) else { throw Abort(.badRequest, reason: "Use an ISO 8601 timestamp with a timezone") }
            return date
        }
        for (key, value) in fields {
            switch key {
            case "name": project.name = try text(value, optional: false, maximum: 200)!
            case "reference": project.reference = try text(value, optional: false, maximum: 200)!
            case "clientName": project.clientName = try text(value, maximum: 500)
            case "clientEmail": project.clientEmail = try text(value, maximum: 500)
            case "clientPhone": project.clientPhone = try text(value, maximum: 100)
            case "address": project.address = try text(value, maximum: 2000)
            case "notes": project.notes = try text(value, maximum: 10000)
            case "projectType": project.projectType = try text(value, maximum: 200)
            case "customProjectType": project.customProjectType = try text(value, maximum: 200)
            case "latitude": project.latitude = try coordinate(value, range: -90...90)
            case "longitude": project.longitude = try coordinate(value, range: -180...180)
            case "startDate":
                project.startDate = try instant(value); project.startOn = nil
            case "expectedEndDate":
                project.expectedEndDate = try instant(value); project.expectedEndOn = nil
            case "startOn":
                project.startOn = try CanonicalValueService.calendarDate(value)
                project.startDate = project.startOn.flatMap { CanonicalValueService.dateFormatter(timezone: timezone).date(from: $0) }
            case "expectedEndOn":
                project.expectedEndOn = try CanonicalValueService.calendarDate(value)
                project.expectedEndDate = project.expectedEndOn.flatMap { CanonicalValueService.dateFormatter(timezone: timezone).date(from: $0) }
            default: throw Abort(.badRequest)
            }
        }
        if let start = project.startOn, let end = project.expectedEndOn, end < start {
            throw Abort(.badRequest, reason: "Expected end date cannot be before the start date", identifier: "invalid_project_dates")
        }
    }
    static func applyCreate(_ input: CreateProjectRequest, to project: Project, on db: Database) async throws {
        var fields: [String: PlatformJSON] = [:]
        if let value = input.customProjectType { fields["customProjectType"] = .string(value) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        if let value = input.startDate { fields["startDate"] = .string(formatter.string(from: value)) }
        if let value = input.expectedEndDate { fields["expectedEndDate"] = .string(formatter.string(from: value)) }
        if let value = input.startOn { fields["startOn"] = .string(value) }
        if let value = input.expectedEndOn { fields["expectedEndOn"] = .string(value) }
        guard !fields.isEmpty else { return }
        try await apply(fields, to: project, timezone: CanonicalValueService.timezone(project, on: db))
    }
    static func edit(_ command: ProjectEditCommand, project: Project, actions: Set<ProjectAccessPolicy.Action>, actorID: UUID, on db: Database) async throws -> PlatformProjectResponse {
        try PlatformMutationService.requireManaged(project)
        guard command.expectedRevision > 0 else { throw Abort(.badRequest, reason: "A positive project revision is required") }
        let id = try project.requireID(), workspaceID = project.workspaceId!
        if command.expectedRevision != project.revision {
            let rows = try await VerifiedIdentityService.sql(db).raw("SELECT changed_fields FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND entity_type = 'project' AND entity_id = \(bind: id) AND revision > \(bind: command.expectedRevision)").all()
            let fields = try Set(rows.flatMap { try $0.decode(column: "changed_fields", as: [String].self) }).sorted()
            throw ProjectRevisionConflict(body: .init(current: try PlatformProjectResponse(project, actions: actions), changedFields: fields))
        }
        try await apply(command.fields, to: project, timezone: CanonicalValueService.timezone(project, on: db))
        project.revision += 1; try await project.save(on: db)
        let response = try PlatformProjectResponse(project, actions: actions)
        var changedFields = Set(command.fields.keys)
        for pair in [("startDate", "startOn"), ("expectedEndDate", "expectedEndOn")] where changedFields.contains(pair.0) || changedFields.contains(pair.1) { changedFields.formUnion([pair.0, pair.1]) }
        try await PlatformMutationService.change(workspaceID: workspaceID, projectID: id, type: "project", entityID: id, revision: project.revision, kind: "updated", fields: Array(changedFields), payload: response, actorID: actorID, on: db)
        return response
    }
}
