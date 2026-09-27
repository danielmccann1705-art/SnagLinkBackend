import Vapor
import Fluent
import FluentSQL

/// Report contract v1 (F07/F12): preview, issue, history and download of a project
/// report built from the authorised register. Contract: `LANE-D-BACKEND.md` §0.
///
/// An issued report is a record of what was issued. Its snapshot is built once, from
/// the same filters and the same overdue rule as the register, encoded canonically
/// (sorted keys, ISO-8601 seconds), hashed and stored; it is never rebuilt. No
/// person's name is written into it: people are ids, resolved to names on read.
struct ReportScope: Content, Equatable {
    var archived: Bool? = nil
    var q: String? = nil
    var status: String? = nil
    var priority: String? = nil
    var contractorId: String? = nil
    var location: String? = nil
    var due: String? = nil

    /// Trimmed, empty values dropped, `archived:false` dropped (it is the default), and
    /// validated with the register's own rules.
    func normalised() throws -> ReportScope {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let result = ReportScope(archived: archived == true ? true : nil, q: clean(q), status: clean(status), priority: clean(priority),
                                 contractorId: clean(contractorId)?.lowercased(), location: clean(location), due: clean(due))
        try result.registerQuery.validate()
        return result
    }
    var registerQuery: SnagRegisterQuery {
        SnagRegisterQuery(page: nil, archived: archived, q: q, status: status, priority: priority,
                          contractorId: contractorId, location: location, due: due, sort: nil, direction: nil)
    }
}

struct ReportPreviewCommand: Content { let title: String?; let scope: ReportScope? }
struct ReportIssueCommand: Content { let mutation: MutationMetadata; let title: String?; let scope: ReportScope? }

struct ReportPerson: Content, Equatable { let userId: UUID; let name: String?; let former: Bool }

struct ReportSummary: Content, Equatable {
    let total: Int; let open: Int; let overdue: Int; let awaitingReview: Int; let closed: Int; let legacyUnverified: Int
}

struct ReportSnapshot: Content, Equatable {
    struct ProjectInfo: Content, Equatable {
        let id: UUID; let name: String; let reference: String?; let address: String?; let timezone: String
    }
    struct ContractorInfo: Content, Equatable { let id: UUID; let companyName: String; let contactName: String? }
    struct Acceptance: Content, Equatable { let kind: String; let decidedAt: Date; let reviewerUserId: UUID }
    struct Evidence: Content, Equatable { let captureAssetIds: [UUID]; let completionAssetIds: [UUID] }
    struct Item: Content, Equatable {
        let snagId: UUID; let reference: String; let title: String; let description: String?; let location: String?
        let priority: String; let status: String; let statusLabel: String; let legacyUnverified: Bool
        let dueOn: String?; let overdue: Bool; let closedAt: Date?
        let contractor: ContractorInfo?; let acceptance: Acceptance?; let evidence: Evidence
    }
    let formatVersion: Int
    let title: String
    let project: ProjectInfo
    let generatedAt: Date
    let asOfDate: String
    let scope: ReportScope
    let summary: ReportSummary
    let items: [Item]
}

struct IssuedReportResponse: Content, Equatable {
    let id: UUID; let projectId: UUID; let workspaceId: UUID
    let number: Int; let reference: String; let title: String
    let issuedAt: Date; let issuedBy: ReportPerson
    let scope: ReportScope; let summary: ReportSummary
    let snagCount: Int; let snapshotSha256: String; let formatVersion: Int
}
struct IssuedReportPage: Content { let items: [IssuedReportResponse]; let page: Int; let hasMore: Bool }
struct IssuedReportDetail: Content {
    let report: IssuedReportResponse?
    let snapshot: ReportSnapshot
    let people: [ReportPerson]
}

enum IssuedReportService {
    static let formatVersion = 1
    static let maximumItems = 2_000
    static let pageSize = 50
    static let defaultTitle = "Snag report"

    static func title(_ raw: String?) throws -> String {
        let collapsed = (raw ?? "").components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return defaultTitle }
        guard collapsed.count <= 120 else { throw Abort(.badRequest, reason: "Keep the report title to 120 characters", identifier: "report_title_invalid") }
        return collapsed
    }
    static func reference(_ number: Int) -> String { "RPT-" + (number < 1000 ? String(format: "%03d", number) : String(number)) }

    /// Canonical, deterministic bytes: sorted keys, whole-second ISO-8601 dates.
    static func encode(_ snapshot: ReportSnapshot) throws -> String { try PlatformMutationService.encode(snapshot) }

    static func statusLabel(status: String, legacy: Bool, acceptance: ReportSnapshot.Acceptance?) -> String {
        if legacy { return status == "closed" ? "Legacy closure — unverified" : "Legacy status — unverified" }
        switch status {
        case "open": return "Open"
        case "in_progress": return "In progress"
        case "awaiting_review": return "Awaiting review"
        case "changes_requested": return "Changes requested"
        case "closed":
            switch acceptance?.kind {
            case "accept": return "Closed — accepted"
            case "internal_fix": return "Closed — fixed by the manager"
            case "waiver": return "Closed — waived"
            default: return "Closed"
            }
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Builds the snapshot under the caller's access check. Never stores anything.
    static func build(title rawTitle: String?, scope rawScope: ReportScope?, project: Project, on db: Database, now: Date = Date()) async throws -> ReportSnapshot {
        try PlatformMutationService.requireManaged(project)
        let scope = try (rawScope ?? ReportScope()).normalised()
        let title = try title(rawTitle)
        let projectID = try project.requireID()
        let timezone = try await CanonicalValueService.timezone(project, on: db)
        let (today, nextWeek) = try await SnagRegisterService.calendarWindow(project, on: db, now: now)
        let filters = scope.registerQuery
        let base = Snag.query(on: db).filter(\.$projectId == projectID)
        _ = filters.archived == true ? base.filter(\.$archivedAt != nil) : base.filter(\.$archivedAt == nil)
        let query = SnagRegisterService.matching(filters, base: base, today: today, nextWeek: nextWeek)
        let count = try await query.count()
        guard count <= maximumItems else {
            throw Abort(.unprocessableEntity, reason: "A report holds up to 2,000 snags. Narrow the filters and try again", identifier: "report_scope_too_large")
        }
        let snags = try await query.sort(\.$displayNumber).sort(\.$id).all()
        let ids = try snags.map { try $0.requireID() }
        let sql = try VerifiedIdentityService.sql(db)

        let contractorIDs = Array(Set(snags.compactMap(\.contractorId)))
        let contractors = contractorIDs.isEmpty ? [] : try await Contractor.query(on: db).filter(\.$id ~~ contractorIDs)
            .filter(\.$workspaceId == project.workspaceId).filter(\.$platformManaged == true).all()
        var contractorByID: [UUID: ReportSnapshot.ContractorInfo] = [:]
        for contractor in contractors {
            let id = try contractor.requireID()
            contractorByID[id] = .init(id: id, companyName: contractor.companyName, contactName: contractor.contactName)
        }

        var decisions: [UUID: ReportSnapshot.Acceptance] = [:]
        if !ids.isEmpty {
            let rows = try await sql.raw("""
                SELECT DISTINCT ON (snag_id) snag_id, kind, actor_id, created_at FROM review_decisions
                WHERE project_id = \(bind: projectID) AND snag_id = ANY(\(bind: ids)) AND kind IN ('accept', 'internal_fix', 'waiver')
                ORDER BY snag_id, created_at DESC, id DESC
                """).all()
            for row in rows {
                decisions[try row.decode(column: "snag_id", as: UUID.self)] = .init(
                    kind: try row.decode(column: "kind", as: String.self),
                    decidedAt: try row.decode(column: "created_at", as: Date.self),
                    reviewerUserId: try row.decode(column: "actor_id", as: UUID.self))
            }
        }
        var capture: [UUID: [UUID]] = [:], completion: [UUID: [UUID]] = [:]
        if !ids.isEmpty {
            let rows = try await sql.raw("""
                SELECT id, snag_id, purpose FROM media_assets
                WHERE project_id = \(bind: projectID) AND snag_id = ANY(\(bind: ids)) AND state = 'ready' AND attached_at IS NOT NULL
                ORDER BY snag_id, created_at, id
                """).all()
            for row in rows {
                let snagID = try row.decode(column: "snag_id", as: UUID.self), assetID = try row.decode(column: "id", as: UUID.self)
                if try row.decode(column: "purpose", as: String.self) == "capture" { capture[snagID, default: []].append(assetID) }
                else { completion[snagID, default: []].append(assetID) }
            }
        }

        var items: [ReportSnapshot.Item] = []
        var open = 0, overdue = 0, awaiting = 0, closed = 0, legacyCount = 0
        for snag in snags {
            let id = try snag.requireID()
            let legacy = snag.workflowQualification != nil
            let owed = !legacy && SnagRegisterService.contractorOwedStatuses.contains(snag.status)
            let late = owed && (snag.dueOn.map { $0 < today } ?? false)
            let acceptance = (!legacy && snag.status == "closed") ? decisions[id] : nil
            if legacy { legacyCount += 1 }
            else if owed { open += 1; if late { overdue += 1 } }
            else if snag.status == "awaiting_review" { awaiting += 1 }
            else if snag.status == "closed" { closed += 1 }
            items.append(.init(snagId: id, reference: snag.reference, title: snag.title, description: snag.snagDescription,
                               location: snag.location, priority: snag.priority, status: snag.status,
                               statusLabel: statusLabel(status: snag.status, legacy: legacy, acceptance: acceptance),
                               legacyUnverified: legacy, dueOn: snag.dueOn, overdue: late, closedAt: snag.closedAt,
                               contractor: snag.contractorId.flatMap { contractorByID[$0] }, acceptance: acceptance,
                               evidence: .init(captureAssetIds: capture[id] ?? [], completionAssetIds: completion[id] ?? [])))
        }
        let generatedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return ReportSnapshot(formatVersion: formatVersion, title: title,
            project: .init(id: projectID, name: project.name, reference: project.reference.isEmpty ? nil : project.reference,
                           address: project.address, timezone: timezone.identifier),
            generatedAt: generatedAt, asOfDate: today, scope: scope,
            summary: .init(total: items.count, open: open, overdue: overdue, awaitingReview: awaiting, closed: closed, legacyUnverified: legacyCount),
            items: items)
    }

    /// Names are resolved now, never stored: a deleted member reads "Former member".
    static func people(_ ids: [UUID], on db: Database) async throws -> [ReportPerson] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT id, name, lifecycle_state FROM users WHERE id = ANY(\(bind: unique))").all()
        var byID: [UUID: ReportPerson] = [:]
        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self)
            let former = try row.decode(column: "lifecycle_state", as: String.self) == "deleted"
            let stored = try row.decode(column: "name", as: String?.self)
            byID[id] = .init(userId: id, name: former ? "Former member" : stored, former: former)
        }
        return unique.sorted { $0.uuidString < $1.uuidString }.map { byID[$0] ?? .init(userId: $0, name: "Former member", former: true) }
    }
    static func peopleIn(_ snapshot: ReportSnapshot, issuer: UUID?) -> [UUID] {
        snapshot.items.compactMap(\.acceptance?.reviewerUserId) + (issuer.map { [$0] } ?? [])
    }

    /// Stores a new issued report. The caller holds the operation lock and has checked
    /// `.review`. The number is allocated under a per-project transaction lock.
    static func issue(_ command: ReportIssueCommand, project: Project, actorID: UUID, on db: Database, now: Date = Date()) async throws -> IssuedReportResponse {
        let snapshot = try await build(title: command.title, scope: command.scope, project: project, on: db, now: now)
        let projectID = try project.requireID()
        guard let workspaceID = project.workspaceId else { throw Abort(.conflict, reason: "Project access changed. Refresh to continue") }
        try await VerifiedIdentityService.lock("issued-report:\(projectID)", on: db)
        let sql = try VerifiedIdentityService.sql(db)
        let next = try await sql.raw("SELECT COALESCE(max(number), 0) + 1 AS next FROM issued_reports WHERE project_id = \(bind: projectID)")
            .first()!.decode(column: "next", as: Int.self)
        let bytes = try encode(snapshot)
        let digest = PrivateImageProcessor.digest(Data(bytes.utf8))
        let scopeJSON = try PlatformMutationService.encode(snapshot.scope)
        let summaryJSON = try PlatformMutationService.encode(snapshot.summary)
        let id = UUID()
        try await sql.raw("""
            INSERT INTO issued_reports (id, workspace_id, project_id, number, title, issued_by_user_id, issued_at, scope_json, summary_json,
                                        snag_count, format_version, snapshot_json, snapshot_sha256)
            VALUES (\(bind: id), \(bind: workspaceID), \(bind: projectID), \(bind: next), \(bind: snapshot.title), \(bind: actorID), \(bind: snapshot.generatedAt),
                    \(bind: scopeJSON), \(bind: summaryJSON),
                    \(bind: snapshot.items.count), \(bind: formatVersion), \(bind: bytes), \(bind: digest))
            """).run()
        let issuer = try await people([actorID], on: db).first!
        return .init(id: id, projectId: projectID, workspaceId: workspaceID, number: next, reference: reference(next), title: snapshot.title,
                     issuedAt: snapshot.generatedAt, issuedBy: issuer, scope: snapshot.scope, summary: snapshot.summary,
                     snagCount: snapshot.items.count, snapshotSha256: digest, formatVersion: formatVersion)
    }

    private static func response(_ row: SQLRow, people: [UUID: ReportPerson]) throws -> IssuedReportResponse {
        let number = try row.decode(column: "number", as: Int.self)
        let issuer = try row.decode(column: "issued_by_user_id", as: UUID.self)
        return .init(id: try row.decode(column: "id", as: UUID.self), projectId: try row.decode(column: "project_id", as: UUID.self),
                     workspaceId: try row.decode(column: "workspace_id", as: UUID.self), number: number, reference: reference(number),
                     title: try row.decode(column: "title", as: String.self), issuedAt: try row.decode(column: "issued_at", as: Date.self),
                     issuedBy: people[issuer] ?? .init(userId: issuer, name: "Former member", former: true),
                     scope: try PlatformMutationService.decode(ReportScope.self, row.decode(column: "scope_json", as: String.self)),
                     summary: try PlatformMutationService.decode(ReportSummary.self, row.decode(column: "summary_json", as: String.self)),
                     snagCount: try row.decode(column: "snag_count", as: Int.self),
                     snapshotSha256: try row.decode(column: "snapshot_sha256", as: String.self),
                     formatVersion: try row.decode(column: "format_version", as: Int.self))
    }

    static func list(projectID: UUID, page: Int, on db: Database) async throws -> IssuedReportPage {
        guard (1...10_000).contains(page) else { throw Abort(.badRequest, reason: "Check the page") }
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            SELECT id, workspace_id, project_id, number, title, issued_by_user_id, issued_at, scope_json, summary_json, snag_count, format_version, snapshot_sha256
            FROM issued_reports WHERE project_id = \(bind: projectID)
            ORDER BY issued_at DESC, number DESC LIMIT \(bind: pageSize + 1) OFFSET \(bind: (page - 1) * pageSize)
            """).all()
        let visible = Array(rows.prefix(pageSize))
        let resolved = try await people(visible.map { try $0.decode(column: "issued_by_user_id", as: UUID.self) }, on: db)
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.userId, $0) })
        return .init(items: try visible.map { try response($0, people: byID) }, page: page, hasMore: rows.count > pageSize)
    }

    /// One issued report with its stored snapshot. The stored bytes are re-hashed on
    /// every read; a mismatch is refused rather than served as the record.
    static func find(_ reportID: UUID, projectID: UUID, on db: Database) async throws -> IssuedReportDetail {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT id, workspace_id, project_id, number, title, issued_by_user_id, issued_at, scope_json, summary_json, snag_count, format_version,
                   snapshot_sha256, snapshot_json
            FROM issued_reports WHERE id = \(bind: reportID) AND project_id = \(bind: projectID)
            """).first() else { throw Abort(.notFound, reason: "Report unavailable") }
        let bytes = try row.decode(column: "snapshot_json", as: String.self)
        guard PrivateImageProcessor.digest(Data(bytes.utf8)) == (try row.decode(column: "snapshot_sha256", as: String.self)) else {
            throw Abort(.internalServerError, reason: "This report could not be verified", identifier: "report_integrity_failed")
        }
        let snapshot = try PlatformMutationService.decode(ReportSnapshot.self, bytes)
        let issuer = try row.decode(column: "issued_by_user_id", as: UUID.self)
        let resolved = try await people(peopleIn(snapshot, issuer: issuer), on: db)
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.userId, $0) })
        return .init(report: try response(row, people: byID), snapshot: snapshot, people: resolved)
    }
}
