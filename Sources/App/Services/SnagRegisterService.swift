import Vapor
import Fluent
import FluentSQL

/// A register page is a current authorised view, never a sync snapshot or a
/// deletion list. Filter counts and rows are read under the project access lock.
struct SnagRegisterQuery: Content {
    var page: Int?
    var archived: Bool?
    var q: String?
    var status: String?
    var priority: String?
    var contractorId: String?
    var location: String?
    var due: String?
    var sort: String?
    var direction: String?

    func validate() throws {
        guard (1...10000).contains(page ?? 1), (q?.count ?? 0) <= 200,
              (location?.count ?? 0) <= 500 else { throw Abort(.badRequest, reason: "Check the search text and page") }
        for (value, allowed) in [(status, ["open", "in_progress", "awaiting_review", "changes_requested", "closed"]),
                                  (priority, ["low", "medium", "high", "critical"]),
                                  (due, ["overdue", "today", "next7", "none"]),
                                  (sort, ["reference", "due", "updated", "priority"]),
                                  (direction, ["asc", "desc"])] {
            guard value == nil || allowed.contains(value!) else { throw Abort(.badRequest, reason: "Choose a valid register filter") }
        }
        guard contractorId == nil || contractorId == "unassigned" || UUID(uuidString: contractorId!) != nil else {
            throw Abort(.badRequest, reason: "Choose a contractor or Unassigned")
        }
    }
}

enum SnagRegisterService {
    struct ContractorLabel: Content {
        let id: UUID; let companyName: String; let contactName: String?; let isArchived: Bool
    }
    /// `awaitingReview` counts only actionable canonical submissions; imported legacy
    /// states are reported separately and never enter the review queue count.
    ///
    /// `overdue` is trade overdue: contractor-owed canonical work (`contractorOwedStatuses`)
    /// whose `dueOn` is before today in the workspace calendar. Work awaiting the
    /// manager's decision is never overdue for the trade; how long it has waited is
    /// the manager's review ageing, reported separately as `reviewPastDue` (its
    /// deadline passed while it waits for review) and `oldestAwaitingReviewSince`
    /// (when the oldest pending submission arrived). Both are optional so older
    /// clients and stored receipts still decode.
    struct Summary: Content {
        let total: Int; let awaitingReview: Int; let overdue: Int; var legacyUnverified: Int = 0
        var reviewPastDue: Int? = nil
        var oldestAwaitingReviewSince: Date? = nil
    }
    /// The canonical states in which the contractor still owes work. The single
    /// definition used by the overdue count, the `due=overdue` filter and reports.
    /// `awaiting_review` (the manager's decision is outstanding) and `closed` are
    /// excluded, and so is any imported state still carrying a legacy qualification,
    /// which needs a reviewer's reconciliation before anyone owes work on it.
    static let contractorOwedStatuses = ["open", "in_progress", "changes_requested"]
    static func contractorOverdue(_ query: QueryBuilder<Snag>, today: String) -> QueryBuilder<Snag> {
        query.filter(\.$dueOn < today).filter(\.$status ~~ contractorOwedStatuses).filter(\.$workflowQualification == nil)
    }
    /// The register's filter set applied to `base` (a project + archived scope). Shared
    /// by the paged register and issued reports so both mean exactly the same thing.
    static func matching(_ filters: SnagRegisterQuery, base query: QueryBuilder<Snag>, today: String, nextWeek: String) -> QueryBuilder<Snag> {
        if let text = filters.q?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // POSITION treats %, _ and backslashes literally. Every user value
            // is bound, including punctuation; no user-built SQL expressions.
            query.filter(.sql(embed: "POSITION(LOWER(\(bind: text)) IN LOWER(CONCAT_WS(' ', reference, title, description, location))) > 0"))
        }
        if let location = filters.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            query.filter(.sql(embed: "POSITION(LOWER(\(bind: location)) IN LOWER(COALESCE(location, ''))) > 0"))
        }
        if let status = filters.status { query.filter(\.$status == status) }
        if let priority = filters.priority { query.filter(\.$priority == priority) }
        if filters.contractorId == "unassigned" { query.filter(\.$contractorId == nil) }
        else if let raw = filters.contractorId, let id = UUID(uuidString: raw) { query.filter(\.$contractorId == id) }
        switch filters.due {
        case "overdue": _ = contractorOverdue(query, today: today)
        case "today": query.filter(\.$dueOn == today)
        case "next7": query.filter(\.$dueOn >= today).filter(\.$dueOn < nextWeek)
        case "none": query.filter(\.$dueOn == nil)
        default: break
        }
        return query
    }
    /// Today and today + 7 in the workspace calendar.
    static func calendarWindow(_ project: Project, on db: Database, now: Date) async throws -> (today: String, nextWeek: String) {
        let timezone = try await CanonicalValueService.timezone(project, on: db)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let formatter = CanonicalValueService.dateFormatter(timezone: timezone)
        return (formatter.string(from: now), formatter.string(from: calendar.date(byAdding: .day, value: 7, to: now)!))
    }
    struct EvidencePreview: Content { let snagId: UUID; let asset: MediaAssetResponse; let count: Int }
    struct Page: Content {
        let items: [PlatformSnagResponse]; let page: Int; let hasMore: Bool
        let total: Int; let summary: Summary; let contractors: [ContractorLabel]
        let evidence: [EvidencePreview]
    }
    static func list(_ filters: SnagRegisterQuery, project: Project, on db: Database, now: Date = Date()) async throws -> Page {
        try filters.validate()
        try PlatformMutationService.requireManaged(project)
        let projectID = try project.requireID(), page = filters.page ?? 1
        let (today, nextWeek) = try await calendarWindow(project, on: db, now: now)
        func base() -> QueryBuilder<Snag> {
            let result = Snag.query(on: db).filter(\.$projectId == projectID)
            return filters.archived == true ? result.filter(\.$archivedAt != nil) : result.filter(\.$archivedAt == nil)
        }
        func overdue(_ query: QueryBuilder<Snag>) -> QueryBuilder<Snag> { contractorOverdue(query, today: today) }
        func awaitingReview(_ query: QueryBuilder<Snag>) -> QueryBuilder<Snag> {
            query.filter(\.$status == "awaiting_review").filter(\.$workflowQualification == nil)
        }
        let oldestPending = try await VerifiedIdentityService.sql(db).raw("""
            SELECT min(a.submitted_at) AS oldest FROM completion_attempts a JOIN snags s ON s.id = a.snag_id AND s.project_id = a.project_id
            WHERE a.project_id = \(bind: projectID) AND a.state = 'pending' AND s.status = 'awaiting_review' AND s.workflow_qualification IS NULL
              AND \(unsafeRaw: filters.archived == true ? "s.archived_at IS NOT NULL" : "s.archived_at IS NULL")
            """).first()?.decode(column: "oldest", as: Date?.self)
        let summary = try await Summary(total: base().count(),
            awaitingReview: awaitingReview(base()).count(), overdue: overdue(base()).count(),
            legacyUnverified: base().filter(\.$workflowQualification != nil).count(),
            reviewPastDue: awaitingReview(base()).filter(\.$dueOn < today).count(),
            oldestAwaitingReviewSince: oldestPending)
        let query = matching(filters, base: base(), today: today, nextWeek: nextWeek)
        let total = try await query.count()
        let descending = filters.direction == "desc"
        switch filters.sort ?? "reference" {
        case "due": query.sort(.sql(raw: descending ? "due_on DESC NULLS LAST" : "due_on ASC NULLS LAST"))
        case "updated": query.sort(.sql(raw: descending ? "updated_at DESC NULLS LAST" : "updated_at ASC NULLS LAST"))
        case "priority": query.sort(.sql(raw: descending
            ? "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC"
            : "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END ASC"))
        default: query.sort(\.$displayNumber, descending ? .descending : .ascending)
        }
        let values = try await query.sort(\.$displayNumber).sort(\.$id).range(((page - 1) * 50)..<(page * 50)).all()
        let contractorIDs = Set(values.compactMap(\.contractorId))
        let contractors = try await Contractor.query(on: db).filter(\.$id ~~ Array(contractorIDs))
            .filter(\.$workspaceId == project.workspaceId).filter(\.$platformManaged == true).all()
        let ids = try values.map { try $0.requireID() }
        let photos = ids.isEmpty ? [] : try await VerifiedIdentityService.sql(db).raw("""
            SELECT DISTINCT ON (snag_id) media_assets.*, count(*) OVER (PARTITION BY snag_id) AS photo_count
            FROM media_assets WHERE project_id = \(bind: projectID) AND snag_id = ANY(\(bind: ids)) AND state = 'ready' AND attached_at IS NOT NULL
            ORDER BY snag_id, CASE purpose WHEN 'capture' THEN 0 ELSE 1 END, created_at, id
            """).all()
        let evidence = try photos.map { row in
            EvidencePreview(snagId: try row.decode(column: "snag_id", as: UUID.self), asset: try MediaAssetResponse(row), count: try row.decode(column: "photo_count", as: Int.self))
        }
        return try Page(items: values.map(PlatformSnagResponse.init), page: page, hasMore: page * 50 < total,
            total: total, summary: summary, contractors: contractors.map {
                ContractorLabel(id: try $0.requireID(), companyName: $0.companyName, contactName: $0.contactName, isArchived: $0.isArchived)
            }, evidence: evidence)
    }
}
