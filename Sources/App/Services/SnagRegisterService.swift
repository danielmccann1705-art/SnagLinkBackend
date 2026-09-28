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
        calendarWindow(try await CanonicalValueService.timezone(project, on: db), now: now)
    }
    /// The same window from a workspace calendar already read (`teams.timezone`), with
    /// `CanonicalValueService.timezone`'s refusal when it is not a valid identifier.
    static func calendarWindow(identifier: String, now: Date) throws -> (today: String, nextWeek: String) {
        guard let timezone = TimeZone(identifier: identifier) else {
            throw Abort(.conflict, reason: "Confirm the workspace timezone before setting deadlines", identifier: "timezone_required")
        }
        return calendarWindow(timezone, now: now)
    }
    static func calendarWindow(_ timezone: TimeZone, now: Date) -> (today: String, nextWeek: String) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let formatter = CanonicalValueService.dateFormatter(timezone: timezone)
        return (formatter.string(from: now), formatter.string(from: calendar.date(byAdding: .day, value: 7, to: now)!))
    }
    /// True when `matching` would add no condition: blank text, no status, priority, contractor or
    /// due filter. The filtered total then equals the unfiltered summary total by construction.
    static func isUnfiltered(_ filters: SnagRegisterQuery) -> Bool {
        (filters.q?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (filters.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && filters.status == nil && filters.priority == nil
            && (filters.contractorId == nil || (filters.contractorId != "unassigned" && UUID(uuidString: filters.contractorId!) == nil))
            && !["overdue", "today", "next7", "none"].contains(filters.due ?? "")
    }
    /// The unfiltered summary of one project (or several: `projectIDs`) in one statement, counting
    /// exactly what the five Fluent counts and the oldest-pending query used to (Lane 2, 28 Sep 2026):
    /// awaitingReview = canonical awaiting_review; overdue = `contractorOverdue`; legacyUnverified =
    /// any qualification; reviewPastDue = canonical awaiting_review with dueOn before today;
    /// oldestAwaitingReviewSince = the oldest pending attempt of a canonical awaiting_review snag.
    /// Extra per-project figures for the workspace summary ride along (register totals of fixed filters).
    struct SummaryRow {
        let summary: Summary
        /// Register total of {contractorId: unassigned, status: open}.
        let unassignedOpen: Int
        /// Register total of {status: changes_requested}.
        let changesRequested: Int
        /// Register total of {due: next7}, and how many of those are closed.
        let dueNext7: Int
        let dueNext7Closed: Int
    }
    static func summaries(projectIDs: [UUID], archived: Bool, today: String, nextWeek: String, on db: Database) async throws -> [UUID: SummaryRow] {
        guard !projectIDs.isEmpty else { return [:] }
        let owed = contractorOwedStatuses
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            SELECT s.project_id,
                count(*) AS total,
                count(*) FILTER (WHERE s.status = 'awaiting_review' AND s.workflow_qualification IS NULL) AS awaiting,
                count(*) FILTER (WHERE s.due_on < \(bind: today) AND s.status = ANY(\(bind: owed)) AND s.workflow_qualification IS NULL) AS overdue,
                count(*) FILTER (WHERE s.workflow_qualification IS NOT NULL) AS legacy,
                count(*) FILTER (WHERE s.status = 'awaiting_review' AND s.workflow_qualification IS NULL AND s.due_on < \(bind: today)) AS review_past_due,
                count(*) FILTER (WHERE s.contractor_id IS NULL AND s.status = 'open') AS unassigned_open,
                count(*) FILTER (WHERE s.status = 'changes_requested') AS changes_requested,
                count(*) FILTER (WHERE s.due_on >= \(bind: today) AND s.due_on < \(bind: nextWeek)) AS due_next7,
                count(*) FILTER (WHERE s.due_on >= \(bind: today) AND s.due_on < \(bind: nextWeek) AND s.status = 'closed') AS due_next7_closed,
                (SELECT min(a.submitted_at) FROM completion_attempts a JOIN snags s2 ON s2.id = a.snag_id AND s2.project_id = a.project_id
                  WHERE a.project_id = s.project_id AND a.state = 'pending' AND s2.status = 'awaiting_review' AND s2.workflow_qualification IS NULL
                    AND \(unsafeRaw: archived ? "s2.archived_at IS NOT NULL" : "s2.archived_at IS NULL")) AS oldest
            FROM snags s
            WHERE s.project_id = ANY(\(bind: projectIDs)) AND \(unsafeRaw: archived ? "s.archived_at IS NOT NULL" : "s.archived_at IS NULL")
            GROUP BY s.project_id
            """).all()
        var result: [UUID: SummaryRow] = [:]
        for row in rows {
            let id = try row.decode(column: "project_id", as: UUID.self)
            result[id] = SummaryRow(summary: Summary(total: try row.decode(column: "total", as: Int.self),
                    awaitingReview: try row.decode(column: "awaiting", as: Int.self), overdue: try row.decode(column: "overdue", as: Int.self),
                    legacyUnverified: try row.decode(column: "legacy", as: Int.self), reviewPastDue: try row.decode(column: "review_past_due", as: Int.self),
                    oldestAwaitingReviewSince: try row.decode(column: "oldest", as: Date?.self)),
                unassignedOpen: try row.decode(column: "unassigned_open", as: Int.self), changesRequested: try row.decode(column: "changes_requested", as: Int.self),
                dueNext7: try row.decode(column: "due_next7", as: Int.self), dueNext7Closed: try row.decode(column: "due_next7_closed", as: Int.self))
        }
        // A project with no rows in this scope has an all-zero summary, exactly as the counts gave.
        for id in projectIDs where result[id] == nil {
            result[id] = SummaryRow(summary: Summary(total: 0, awaitingReview: 0, overdue: 0, legacyUnverified: 0, reviewPastDue: 0, oldestAwaitingReviewSince: nil),
                                    unassignedOpen: 0, changesRequested: 0, dueNext7: 0, dueNext7Closed: 0)
        }
        return result
    }
    /// `summaries` and, in the same statement, the prepared, unexpired Contractor links of `sharing` (the work summary's
    /// separate count query, Lane 2 28 Sep evening): the same two queries' rows, UNION ALL-ed and told apart by `row_kind`.
    static func summariesAndPreparedLinks(projectIDs: [UUID], sharing: [UUID], today: String, nextWeek: String, on db: Database) async throws -> (summaries: [UUID: SummaryRow], prepared: [UUID: Int]) {
        guard !sharing.isEmpty else { return (try await summaries(projectIDs: projectIDs, archived: false, today: today, nextWeek: nextWeek, on: db), [:]) }
        guard !projectIDs.isEmpty else { return ([:], [:]) }
        let owed = contractorOwedStatuses
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            SELECT 'summary' AS row_kind, s.project_id,
                count(*) AS total,
                count(*) FILTER (WHERE s.status = 'awaiting_review' AND s.workflow_qualification IS NULL) AS awaiting,
                count(*) FILTER (WHERE s.due_on < \(bind: today) AND s.status = ANY(\(bind: owed)) AND s.workflow_qualification IS NULL) AS overdue,
                count(*) FILTER (WHERE s.workflow_qualification IS NOT NULL) AS legacy,
                count(*) FILTER (WHERE s.status = 'awaiting_review' AND s.workflow_qualification IS NULL AND s.due_on < \(bind: today)) AS review_past_due,
                count(*) FILTER (WHERE s.contractor_id IS NULL AND s.status = 'open') AS unassigned_open,
                count(*) FILTER (WHERE s.status = 'changes_requested') AS changes_requested,
                count(*) FILTER (WHERE s.due_on >= \(bind: today) AND s.due_on < \(bind: nextWeek)) AS due_next7,
                count(*) FILTER (WHERE s.due_on >= \(bind: today) AND s.due_on < \(bind: nextWeek) AND s.status = 'closed') AS due_next7_closed,
                (SELECT min(a.submitted_at) FROM completion_attempts a JOIN snags s2 ON s2.id = a.snag_id AND s2.project_id = a.project_id
                  WHERE a.project_id = s.project_id AND a.state = 'pending' AND s2.status = 'awaiting_review' AND s2.workflow_qualification IS NULL
                    AND s2.archived_at IS NULL) AS oldest
            FROM snags s
            WHERE s.project_id = ANY(\(bind: projectIDs)) AND s.archived_at IS NULL
            GROUP BY s.project_id
            UNION ALL
            SELECT 'links' AS row_kind, project_id, count(*) AS total, 0, 0, 0, 0, 0, 0, 0, 0, NULL::timestamptz
            FROM link_grants
            WHERE project_id = ANY(\(bind: sharing)) AND state = 'prepared' AND expires_at > now() GROUP BY project_id
            """).all()
        var result: [UUID: SummaryRow] = [:], prepared: [UUID: Int] = [:]
        for row in rows {
            let id = try row.decode(column: "project_id", as: UUID.self)
            if try row.decode(column: "row_kind", as: String.self) == "links" { prepared[id] = try row.decode(column: "total", as: Int.self); continue }
            result[id] = SummaryRow(summary: Summary(total: try row.decode(column: "total", as: Int.self),
                    awaitingReview: try row.decode(column: "awaiting", as: Int.self), overdue: try row.decode(column: "overdue", as: Int.self),
                    legacyUnverified: try row.decode(column: "legacy", as: Int.self), reviewPastDue: try row.decode(column: "review_past_due", as: Int.self),
                    oldestAwaitingReviewSince: try row.decode(column: "oldest", as: Date?.self)),
                unassignedOpen: try row.decode(column: "unassigned_open", as: Int.self), changesRequested: try row.decode(column: "changes_requested", as: Int.self),
                dueNext7: try row.decode(column: "due_next7", as: Int.self), dueNext7Closed: try row.decode(column: "due_next7_closed", as: Int.self))
        }
        for id in projectIDs where result[id] == nil {
            result[id] = SummaryRow(summary: Summary(total: 0, awaitingReview: 0, overdue: 0, legacyUnverified: 0, reviewPastDue: 0, oldestAwaitingReviewSince: nil),
                                    unassignedOpen: 0, changesRequested: 0, dueNext7: 0, dueNext7Closed: 0)
        }
        return (result, prepared)
    }
    struct EvidencePreview: Content { let snagId: UUID; let asset: MediaAssetResponse; let count: Int }
    struct Page: Content {
        let items: [PlatformSnagResponse]; let page: Int; let hasMore: Bool
        let total: Int; let summary: Summary; let contractors: [ContractorLabel]
        let evidence: [EvidencePreview]
    }
    /// `timezone` is the workspace calendar when the caller already read it (`ProjectAccessService.readContext`);
    /// nil reads it here as before.
    static func list(_ filters: SnagRegisterQuery, project: Project, timezone: String? = nil, on db: Database, now: Date = Date()) async throws -> Page {
        try filters.validate()
        try PlatformMutationService.requireManaged(project)
        let projectID = try project.requireID(), page = filters.page ?? 1
        let window: (today: String, nextWeek: String)
        if let timezone { window = try calendarWindow(identifier: timezone, now: now) }
        else { window = try await calendarWindow(project, on: db, now: now) }
        let (today, nextWeek) = window
        func base() -> QueryBuilder<Snag> {
            let result = Snag.query(on: db).filter(\.$projectId == projectID)
            return filters.archived == true ? result.filter(\.$archivedAt != nil) : result.filter(\.$archivedAt == nil)
        }
        // One statement for the whole unfiltered summary (was six), and no second count when the
        // view has no filter: its total is the summary's total (Lane 2, 28 Sep 2026).
        let summary = try await summaries(projectIDs: [projectID], archived: filters.archived == true, today: today, nextWeek: nextWeek, on: db)[projectID]!.summary
        let query = matching(filters, base: base(), today: today, nextWeek: nextWeek)
        let total = isUnfiltered(filters) ? summary.total : try await query.count()
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
        let contractors = contractorIDs.isEmpty ? [] : try await Contractor.query(on: db).filter(\.$id ~~ Array(contractorIDs))
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

/// Columns of one joined table carried under a prefix in a combined statement (Lane 2, 28 Sep 2026): a decoder
/// that reads a whole row (`MediaAssetResponse(row)`, `decode(fluentModel:)`) reads the prefixed columns as if
/// they were the only ones.
struct PrefixedSQLRow: SQLRow {
    let base: any SQLRow
    let prefix: String
    var allColumns: [String] { base.allColumns.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
    func contains(column: String) -> Bool { base.contains(column: prefix + column) }
    func decodeNil(column: String) throws -> Bool { try base.decodeNil(column: prefix + column) }
    func decode<D: Decodable>(column: String, as type: D.Type) throws -> D { try base.decode(column: prefix + column, as: type) }
}

/// The register's filters, orders and page as SQL for one statement (Lane 2, 28 Sep 2026, evening). Staging's
/// container is about 45 ms from its database per statement, so a register read of nine sequential statements
/// cost about 0.5 s before anything else. These are exactly `SnagRegisterService.matching`'s conditions (same
/// expressions, same bound values), `list`'s and the workspace register's orders and tie-breaks, and `range`'s
/// LIMIT/OFFSET. `ReadPathEquivalenceTests` compares every page with the previous statements.
enum RegisterSQL {
    /// `matching(filters, …)` as conditions on unqualified `snags` columns (AND-ed; empty = no condition).
    static func conditions(_ filters: SnagRegisterQuery, today: String, nextWeek: String) -> [SQLQueryString] {
        var result: [SQLQueryString] = []
        if let text = filters.q?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            result.append("POSITION(LOWER(\(bind: text)) IN LOWER(CONCAT_WS(' ', reference, title, description, location))) > 0")
        }
        if let location = filters.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            result.append("POSITION(LOWER(\(bind: location)) IN LOWER(COALESCE(location, ''))) > 0")
        }
        if let status = filters.status { result.append("status = \(bind: status)") }
        if let priority = filters.priority { result.append("priority = \(bind: priority)") }
        if filters.contractorId == "unassigned" { result.append("contractor_id IS NULL") }
        else if let raw = filters.contractorId, let id = UUID(uuidString: raw) { result.append("contractor_id = \(bind: id)") }
        switch filters.due {
        case "overdue":
            result.append("due_on < \(bind: today)")
            result.append("status = ANY(\(bind: SnagRegisterService.contractorOwedStatuses))")
            result.append("workflow_qualification IS NULL")
        case "today": result.append("due_on = \(bind: today)")
        case "next7": result.append("due_on >= \(bind: today)"); result.append("due_on < \(bind: nextWeek)")
        case "none": result.append("due_on IS NULL")
        default: break
        }
        return result
    }
    static func whereClause(_ conditions: [SQLQueryString]) -> SQLQueryString {
        guard !conditions.isEmpty else { return "TRUE" }
        return conditions.map { (condition: SQLQueryString) -> SQLQueryString in "(\(condition))" }.joined(separator: " AND ")
    }
    /// `list`'s order (project register) or the workspace register's (`projects` = the project order), then the
    /// same tie-breaks: display number ascending and id ascending, exactly as Fluent's appended sorts.
    static func order(_ filters: SnagRegisterQuery, projects: [UUID]? = nil) -> SQLQueryString {
        let descending = filters.direction == "desc"
        var project: SQLQueryString? = nil
        if let projects { project = "array_position(\(bind: projects), project_id)" }
        func then(_ first: SQLQueryString) -> SQLQueryString {
            if let project { return "\(first), \(project), display_number ASC, id ASC" }
            return "\(first), display_number ASC, id ASC"
        }
        switch filters.sort ?? "reference" {
        case "due": return then(descending ? "due_on DESC NULLS LAST" : "due_on ASC NULLS LAST")
        case "updated": return then(descending ? "updated_at DESC NULLS LAST" : "updated_at ASC NULLS LAST")
        case "priority": return then(descending
            ? "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC"
            : "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END ASC")
        default:
            let number: SQLQueryString = descending ? "display_number DESC" : "display_number ASC"
            // Project register: display number, then (Fluent's appended sorts) display number ascending, id.
            // Workspace register: project, display number in the asked direction, id.
            if let project { return "\(project), \(number), id ASC" }
            return "\(number), display_number ASC, id ASC"
        }
    }
    /// The page as two CTEs after `filtered`: the order is decided on the sort keys and ids alone (a narrow sort: a deep page of
    /// a 5,000-snag project no longer sorts whole rows), then the page's 50 rows are read by id. Same rows, same order.
    static func pageCTE(order: SQLQueryString, limit: Int, offset: Int) -> SQLQueryString {
        """
        page_keys AS (
            SELECT id AS page_id, row_number() OVER (ORDER BY \(order)) AS register_position
            FROM filtered ORDER BY \(order) LIMIT \(bind: limit) OFFSET \(bind: offset)
        ), page AS (
            SELECT snags.*, page_keys.register_position FROM page_keys JOIN snags ON snags.id = page_keys.page_id
        )
        """
    }
    /// Page rows (`page.*` = the snag columns and `register_position`) with the page's contractor label (`ct_…`,
    /// only a platform-managed contractor of `workspace`) and evidence preview (`ph_…`: the first ready, attached
    /// photo in `list`'s order, and `ph_evidence_count`) joined on. `page` must be a CTE of snag rows.
    static var pageJoins: SQLQueryString { """
        LEFT JOIN contractors ct ON ct.id = page.contractor_id AND ct.workspace_id = scope_workspace.id AND ct.platform_managed = TRUE
        LEFT JOIN LATERAL (
            SELECT m.id, m.project_id, m.snag_id, m.purpose, m.intent_id, m.state, m.revision, m.original_sha256, m.original_size,
                   m.original_mime, m.width, m.height, m.created_at, m.expires_at, m.attached_at, m.rendition_sha256, m.rendition_size,
                   count(*) OVER () AS evidence_count
            FROM media_assets m
            WHERE m.project_id = page.project_id AND m.snag_id = page.id AND m.state = 'ready' AND m.attached_at IS NOT NULL
            ORDER BY CASE m.purpose WHEN 'capture' THEN 0 ELSE 1 END, m.created_at, m.id
            LIMIT 1
        ) ph ON page.id IS NOT NULL
        """ }
    static var pageColumns: SQLQueryString { """
        page.*, ct.id AS ct_id, ct.company_name AS ct_company_name, ct.contact_name AS ct_contact_name, ct.is_archived AS ct_is_archived,
        ph.id AS ph_id, ph.project_id AS ph_project_id, ph.snag_id AS ph_snag_id, ph.purpose AS ph_purpose, ph.intent_id AS ph_intent_id,
        ph.state AS ph_state, ph.revision AS ph_revision, ph.original_sha256 AS ph_original_sha256, ph.original_size AS ph_original_size,
        ph.original_mime AS ph_original_mime, ph.width AS ph_width, ph.height AS ph_height, ph.created_at AS ph_created_at,
        ph.expires_at AS ph_expires_at, ph.attached_at AS ph_attached_at, ph.rendition_sha256 AS ph_rendition_sha256,
        ph.rendition_size AS ph_rendition_size, ph.evidence_count AS ph_evidence_count
        """ }
    /// The rows of one page, its contractor labels (sorted by id: the previous separate query returned them in no
    /// specified order) and its evidence previews (by snag id, as `DISTINCT ON (snag_id) … ORDER BY snag_id` did).
    static func decodePage(_ rows: [any SQLRow]) throws -> (snags: [Snag], contractors: [SnagRegisterService.ContractorLabel], evidence: [SnagRegisterService.EvidencePreview]) {
        var snags: [Snag] = [], labels: [UUID: SnagRegisterService.ContractorLabel] = [:], evidence: [SnagRegisterService.EvidencePreview] = []
        for row in rows {
            guard !(try row.decodeNil(column: "register_position")) else { continue }
            snags.append(try row.decode(fluentModel: Snag.self))
            if !(try row.decodeNil(column: "ct_id")) {
                let id = try row.decode(column: "ct_id", as: UUID.self)
                labels[id] = .init(id: id, companyName: try row.decode(column: "ct_company_name", as: String.self),
                                   contactName: try row.decode(column: "ct_contact_name", as: String?.self), isArchived: try row.decode(column: "ct_is_archived", as: Bool.self))
            }
            if !(try row.decodeNil(column: "ph_id")) {
                evidence.append(.init(snagId: try row.decode(column: "ph_snag_id", as: UUID.self), asset: try MediaAssetResponse(PrefixedSQLRow(base: row, prefix: "ph_")),
                                      count: try row.decode(column: "ph_evidence_count", as: Int.self)))
            }
        }
        return (snags, labels.values.sorted { $0.id.uuidString < $1.id.uuidString }, evidence.sorted { $0.snagId.uuidString < $1.snagId.uuidString })
    }
}

extension SnagRegisterService {
    /// One project's register page in five statements instead of nine or ten (Lane 2, 28 Sep 2026, evening):
    /// session, BEGIN, the workspace's shared lock (the statement that finds the project's workspace, as
    /// `ProjectAccessService.readContext`), ONE statement for everything else, COMMIT.
    ///
    /// The one statement re-reads every access fact under the lock (exactly readContext's second statement) and,
    /// from the same snapshot, the summary, the filtered total, the 50-row page, its contractor labels and its
    /// evidence previews. The decision is then made in Swift by the same code as readContext; nothing read is
    /// returned unless it allows reading, and the errors and their order are readContext's, then `list`'s.
    /// The page is computed with the workspace calendar read (as a hint) in the lock statement; if the calendar
    /// changed in between, or is not a valid time zone, or the filters are invalid, or the project predates
    /// workspaces, the previous statements run instead (same answers, as before).
    static func read(_ filters: SnagRegisterQuery, projectID: UUID, actorID: UUID, on db: Database, now: Date = Date()) async throws -> Page {
        let located = try await ProjectAccessService.locateForRead(projectID: projectID, on: db)
        guard let located, let hint = located.timezoneHint, let zone = TimeZone(identifier: hint), (try? filters.validate()) != nil else {
            let context = try await ProjectAccessService.readContext(projectID: projectID, actorID: actorID, located: located, on: db)
            return try await list(filters, project: context.project, timezone: context.workspaceTimezone, on: db, now: now)
        }
        let window = calendarWindow(zone, now: now)
        let page = filters.page ?? 1
        let archived: SQLQueryString = filters.archived == true ? "archived_at IS NOT NULL" : "archived_at IS NULL"
        let archivedS2: SQLQueryString = filters.archived == true ? "s2.archived_at IS NOT NULL" : "s2.archived_at IS NULL"
        let unfiltered = isUnfiltered(filters)
        let filteredTotal: SQLQueryString = unfiltered ? "NULL::bigint" : "(SELECT count(*) FROM filtered)"
        let owed = contractorOwedStatuses
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            WITH scope_workspace AS (
                SELECT p.workspace_id AS id, p.owner_id AS hd_owner_id, p.platform_managed AS hd_platform_managed, p.archived_at AS hd_archived_at,
                       t.kind AS access_workspace_kind, t.owner_user_id AS access_workspace_owner,
                       t.lifecycle_state AS access_workspace_state, t.timezone AS access_workspace_timezone,
                       (SELECT u.lifecycle_state FROM users u WHERE u.id = \(bind: actorID)) AS access_user_state,
                       (SELECT m.role FROM workspace_memberships m WHERE m.workspace_id = p.workspace_id AND m.user_id = \(bind: actorID)) AS access_member_role,
                       (SELECT m.state FROM workspace_memberships m WHERE m.workspace_id = p.workspace_id AND m.user_id = \(bind: actorID)) AS access_member_state,
                       (SELECT g.role FROM project_access g WHERE g.state = 'active' AND g.workspace_id = p.workspace_id AND g.project_id = p.id AND g.user_id = \(bind: actorID) LIMIT 1) AS access_grant_role
                FROM projects p JOIN teams t ON t.id = p.workspace_id
                WHERE p.id = \(bind: projectID)
            ), scoped AS NOT MATERIALIZED (
                SELECT * FROM snags WHERE project_id = \(bind: projectID) AND \(archived)
            ), summary AS (
                SELECT count(*) AS hd_total,
                    count(*) FILTER (WHERE status = 'awaiting_review' AND workflow_qualification IS NULL) AS hd_awaiting,
                    count(*) FILTER (WHERE due_on < \(bind: window.today) AND status = ANY(\(bind: owed)) AND workflow_qualification IS NULL) AS hd_overdue,
                    count(*) FILTER (WHERE workflow_qualification IS NOT NULL) AS hd_legacy,
                    count(*) FILTER (WHERE status = 'awaiting_review' AND workflow_qualification IS NULL AND due_on < \(bind: window.today)) AS hd_review_past_due,
                    (SELECT min(a.submitted_at) FROM completion_attempts a JOIN snags s2 ON s2.id = a.snag_id AND s2.project_id = a.project_id
                      WHERE a.project_id = \(bind: projectID) AND a.state = 'pending' AND s2.status = 'awaiting_review' AND s2.workflow_qualification IS NULL
                        AND \(archivedS2)) AS hd_oldest
                FROM scoped
            ), filtered AS NOT MATERIALIZED (
                SELECT * FROM scoped WHERE \(RegisterSQL.whereClause(RegisterSQL.conditions(filters, today: window.today, nextWeek: window.nextWeek)))
            ), \(RegisterSQL.pageCTE(order: RegisterSQL.order(filters), limit: 50, offset: (page - 1) * 50))
            SELECT scope_workspace.id AS hd_workspace_id, scope_workspace.hd_owner_id, scope_workspace.hd_platform_managed, scope_workspace.hd_archived_at,
                   scope_workspace.access_workspace_kind, scope_workspace.access_workspace_owner, scope_workspace.access_workspace_state,
                   scope_workspace.access_workspace_timezone, scope_workspace.access_user_state, scope_workspace.access_member_role,
                   scope_workspace.access_member_state, scope_workspace.access_grant_role,
                   summary.*, \(filteredTotal) AS hd_filtered_total, \(RegisterSQL.pageColumns)
            FROM scope_workspace CROSS JOIN summary
            LEFT JOIN page ON TRUE
            \(RegisterSQL.pageJoins)
            ORDER BY page.register_position
            """).all()
        // Everything the decision reads, re-read under the lock: readContext's checks, in readContext's order.
        guard let head = rows.first, try head.decode(column: "hd_workspace_id", as: UUID?.self) == located.workspaceID else {
            throw Abort(.conflict, reason: "Project access changed. Refresh to continue")
        }
        _ = try ProjectAccessService.readDecision(head, projectID: projectID, workspaceID: located.workspaceID, actorID: actorID,
                                                  ownerID: try head.decode(column: "hd_owner_id", as: UUID.self))
        let timezone = try head.decode(column: "access_workspace_timezone", as: String.self)
        guard timezone == hint else {
            // The calendar changed between the two statements: the page above used the old one. Read it again as before.
            guard let project = try await Project.find(projectID, on: db) else { throw Abort(.conflict, reason: "Project access changed. Refresh to continue") }
            return try await list(filters, project: project, timezone: timezone, on: db, now: now)
        }
        // `list`'s checks, in `list`'s order (the filters were validated above; the calendar is valid).
        try PlatformMutationService.requireManaged(platformManaged: try head.decode(column: "hd_platform_managed", as: Bool.self),
                                                   archivedAt: try head.decode(column: "hd_archived_at", as: Date?.self))
        let summary = Summary(total: try head.decode(column: "hd_total", as: Int.self),
                              awaitingReview: try head.decode(column: "hd_awaiting", as: Int.self), overdue: try head.decode(column: "hd_overdue", as: Int.self),
                              legacyUnverified: try head.decode(column: "hd_legacy", as: Int.self), reviewPastDue: try head.decode(column: "hd_review_past_due", as: Int.self),
                              oldestAwaitingReviewSince: try head.decode(column: "hd_oldest", as: Date?.self))
        let total = unfiltered ? summary.total : try head.decode(column: "hd_filtered_total", as: Int.self)
        let decoded = try RegisterSQL.decodePage(rows)
        return try Page(items: decoded.snags.map(PlatformSnagResponse.init), page: page, hasMore: page * 50 < total,
                        total: total, summary: summary, contractors: decoded.contractors, evidence: decoded.evidence)
    }
}
