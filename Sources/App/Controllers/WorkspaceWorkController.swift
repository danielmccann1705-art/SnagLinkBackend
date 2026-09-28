import Vapor
import Fluent
import FluentSQL

/// Workspace-wide reads for the manager portal (Lane 2, 28 Sep 2026): one bounded request where the
/// portal used to read every project's register up to six times (124 requests for 20 projects).
///
/// Nothing here is a second permission model or a second filter model:
/// - the projects in scope are `WorkspaceReadScope`'s — the project list's candidates, each decided by
///   `ProjectAccessPolicy.allowedActions` under the workspace's shared lock, exactly as the per-project
///   register decides them; a project the actor may not read is simply not in scope;
/// - rows are filtered by `SnagRegisterService.matching` (the register's own filters, due dates in the
///   workspace calendar) and summarised by `SnagRegisterService.summaries` (the register's own summary);
/// - a project the register would refuse (`project_import_required`) is reported in `unavailable`,
///   never silently left out of a total.
struct WorkspaceWorkController: RouteCollection {
    static let pageSize = 50
    static let summaryPageSize = 500

    struct ProjectWork: Content {
        let projectId: UUID
        let capabilities: [String]
        /// The per-project register's `summary` (active snags). Absent when `unavailable` is set.
        let summary: SnagRegisterService.Summary?
        /// Register total of {contractorId: unassigned, status: open}.
        let unassignedOpen: Int?
        /// Register total of {status: changes_requested}.
        let changesRequested: Int?
        /// Register total of {due: next7} (today to before day 7, workspace calendar), and how many are closed.
        let dueNext7: Int?
        let dueNext7Closed: Int?
        /// Contractor links prepared (not yet activated) and not expired. Present only where this person
        /// may share (the project's Contractor links list is theirs to read).
        let preparedLinks: Int?
        /// Why the register refuses this project ("project_import_required"); nothing is counted for it.
        let unavailable: String?
    }
    struct Totals: Content {
        let total: Int; let overdue: Int; let legacyUnverified: Int; let reviewPastDue: Int
        /// Awaiting review in projects this person may review (the Reviews queue), and in all projects.
        let awaitingReview: Int; let awaitingReviewAllProjects: Int
        let unassignedOpen: Int; let changesRequested: Int; let dueNext7: Int; let dueNext7Closed: Int
        let preparedLinks: Int
        let oldestAwaitingReviewSince: Date?
    }
    struct Summary: Content {
        let workspaceId: UUID
        /// Today in the workspace calendar: the overdue and next-7-days boundary used for every count.
        let asOfDate: String
        let projects: [ProjectWork]
        let totals: Totals
        let page: Int
        let hasMore: Bool
    }
    struct Row: Content { let projectId: UUID; let item: PlatformSnagResponse }
    struct Unavailable: Content { let projectId: UUID; let reason: String }
    struct Page: Content {
        let items: [Row]; let page: Int; let hasMore: Bool
        /// Exact number of matching rows across every project in scope.
        let total: Int
        let contractors: [SnagRegisterService.ContractorLabel]
        let evidence: [SnagRegisterService.EvidencePreview]
        /// Projects whose rows this view covers, in the order rows are grouped (name, then id).
        let projectIds: [UUID]
        let unavailable: [Unavailable]
        let asOfDate: String
    }

    func boot(routes: RoutesBuilder) throws {
        let workspaces = routes.grouped("api", "v2", "workspaces").grouped(PlatformAuthMiddleware())
        workspaces.get(":workspaceId", "work-summary", use: summary)
        workspaces.get(":workspaceId", "snags", use: register)
    }
    private func workspaceID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("workspaceId"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }

    @Sendable func summary(req: Request) async throws -> Summary {
        let workspaceID = try workspaceID(req), actorID = try req.requireAuthenticatedUserId()
        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        guard (1...100).contains(page) else { throw Abort(.badRequest, reason: "Invalid page") }
        return try await req.db.transaction { db in
            let scope = try await WorkspaceReadScope.load(workspaceID: workspaceID, actorID: actorID, offset: (page - 1) * Self.summaryPageSize,
                                                          candidateLimit: Self.summaryPageSize + 1, on: db)
            let window = try SnagRegisterService.calendarWindow(identifier: scope.team.timezone, now: Date())
            let readable = Array(scope.readable.prefix(Self.summaryPageSize))
            let managed = try readable.filter { $0.project.platformManaged }.map { try $0.project.requireID() }
            let rows = try await SnagRegisterService.summaries(projectIDs: managed, archived: false, today: window.today, nextWeek: window.nextWeek, on: db)
            let sharing = try readable.filter { $0.project.platformManaged && $0.actions.contains(.share) }.map { try $0.project.requireID() }
            var prepared: [UUID: Int] = [:]
            if !sharing.isEmpty {
                for row in try await VerifiedIdentityService.sql(db).raw("""
                    SELECT project_id, count(*) AS n FROM link_grants
                    WHERE project_id = ANY(\(bind: sharing)) AND state = 'prepared' AND expires_at > now() GROUP BY project_id
                    """).all() {
                    prepared[try row.decode(column: "project_id", as: UUID.self)] = try row.decode(column: "n", as: Int.self)
                }
            }
            var preparedTotal = 0
            var projects: [ProjectWork] = []
            var total = 0, overdue = 0, legacy = 0, pastDue = 0, awaiting = 0, awaitingAll = 0, unassigned = 0, changes = 0, due7 = 0, due7Closed = 0
            var oldest: Date? = nil
            for (project, actions) in readable {
                let id = try project.requireID(), capabilities = actions.map(\.rawValue).sorted()
                guard project.platformManaged, let row = rows[id] else {
                    projects.append(.init(projectId: id, capabilities: capabilities, summary: nil, unassignedOpen: nil, changesRequested: nil,
                                          dueNext7: nil, dueNext7Closed: nil, preparedLinks: nil, unavailable: "project_import_required"))
                    continue
                }
                let links = actions.contains(.share) ? (prepared[id] ?? 0) : nil
                preparedTotal += links ?? 0
                projects.append(.init(projectId: id, capabilities: capabilities, summary: row.summary, unassignedOpen: row.unassignedOpen,
                                      changesRequested: row.changesRequested, dueNext7: row.dueNext7, dueNext7Closed: row.dueNext7Closed, preparedLinks: links, unavailable: nil))
                total += row.summary.total; overdue += row.summary.overdue; legacy += row.summary.legacyUnverified
                pastDue += row.summary.reviewPastDue ?? 0; awaitingAll += row.summary.awaitingReview
                unassigned += row.unassignedOpen; changes += row.changesRequested; due7 += row.dueNext7; due7Closed += row.dueNext7Closed
                if actions.contains(.review) {
                    awaiting += row.summary.awaitingReview
                    if let since = row.summary.oldestAwaitingReviewSince, oldest.map({ since < $0 }) ?? true { oldest = since }
                }
            }
            return Summary(workspaceId: workspaceID, asOfDate: window.today, projects: projects,
                           totals: .init(total: total, overdue: overdue, legacyUnverified: legacy, reviewPastDue: pastDue, awaitingReview: awaiting,
                                         awaitingReviewAllProjects: awaitingAll, unassignedOpen: unassigned, changesRequested: changes,
                                         dueNext7: due7, dueNext7Closed: due7Closed, preparedLinks: preparedTotal, oldestAwaitingReviewSince: oldest),
                           page: page, hasMore: scope.projects.count > Self.summaryPageSize)
        }
    }

    @Sendable func register(req: Request) async throws -> Page {
        let workspaceID = try workspaceID(req), actorID = try req.requireAuthenticatedUserId()
        var filters = try req.query.decode(SnagRegisterQuery.self)
        let only = try req.query.get(String?.self, at: "projectId")
        let queue = try req.query.get(String?.self, at: "queue")
        guard only == nil || UUID(uuidString: only!) != nil else { throw Abort(.badRequest, reason: "Choose a project") }
        guard queue == nil || queue == "review" else { throw Abort(.badRequest, reason: "Choose a valid queue") }
        // The review queue: canonical submissions awaiting a decision, in projects this person may review,
        // oldest change first unless another order is asked for.
        if queue == "review" {
            guard filters.status == nil || filters.status == "awaiting_review" else { throw Abort(.badRequest, reason: "The review queue lists snags awaiting review") }
            guard filters.archived != true else { throw Abort(.badRequest, reason: "The review queue lists active snags") }
            filters.status = "awaiting_review"
            if filters.sort == nil { filters.sort = "updated"; filters.direction = filters.direction ?? "asc" }
        }
        try filters.validate()
        let page = filters.page ?? 1
        return try await req.db.transaction { db in
            let scope = try await WorkspaceReadScope.load(workspaceID: workspaceID, actorID: actorID, on: db)
            let window = try SnagRegisterService.calendarWindow(identifier: scope.team.timezone, now: Date())
            var candidates = scope.readable
            if let only, let id = UUID(uuidString: only) {
                candidates = candidates.filter { $0.project.id == id }
                // Exactly the per-project register's answers for a project outside scope or not yet managed.
                guard let one = candidates.first else { throw Abort(.notFound, reason: "Project unavailable") }
                try PlatformMutationService.requireManaged(one.project)
            }
            if queue == "review" { candidates = candidates.filter { $0.actions.contains(.review) } }
            let unavailable = try candidates.filter { !$0.project.platformManaged }.map { Unavailable(projectId: try $0.project.requireID(), reason: "project_import_required") }
            let inScope = candidates.filter { $0.project.platformManaged }
                .sorted { ($0.project.name.lowercased(), $0.project.id!.uuidString) < ($1.project.name.lowercased(), $1.project.id!.uuidString) }
            let order = try inScope.map { try $0.project.requireID() }
            guard !order.isEmpty else {
                return Page(items: [], page: page, hasMore: false, total: 0, contractors: [], evidence: [], projectIds: [], unavailable: unavailable, asOfDate: window.today)
            }
            let base = Snag.query(on: db).filter(\.$projectId ~~ order)
            if filters.archived == true { base.filter(\.$archivedAt != nil) } else { base.filter(\.$archivedAt == nil) }
            if queue == "review" { base.filter(\.$workflowQualification == nil) }
            let query = SnagRegisterService.matching(filters, base: base, today: window.today, nextWeek: window.nextWeek)
            let total = try await query.count()
            let descending = filters.direction == "desc"
            let projectOrder = DatabaseQuery.Sort.sql(embed: "array_position(\(bind: order), project_id)")
            switch filters.sort ?? "reference" {
            case "due": query.sort(.sql(raw: descending ? "due_on DESC NULLS LAST" : "due_on ASC NULLS LAST")).sort(projectOrder).sort(\.$displayNumber)
            case "updated": query.sort(.sql(raw: descending ? "updated_at DESC NULLS LAST" : "updated_at ASC NULLS LAST")).sort(projectOrder).sort(\.$displayNumber)
            case "priority": query.sort(.sql(raw: descending
                ? "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC"
                : "CASE priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END ASC")).sort(projectOrder).sort(\.$displayNumber)
            default: query.sort(projectOrder).sort(\.$displayNumber, descending ? .descending : .ascending)
            }
            let values = try await query.sort(\.$id).range(((page - 1) * Self.pageSize)..<(page * Self.pageSize)).all()
            let contractorIDs = Set(values.compactMap(\.contractorId))
            let contractors = contractorIDs.isEmpty ? [] : try await Contractor.query(on: db).filter(\.$id ~~ Array(contractorIDs))
                .filter(\.$workspaceId == workspaceID).filter(\.$platformManaged == true).all()
            let ids = try values.map { try $0.requireID() }
            let projectsOnPage = Array(Set(values.map(\.projectId)))
            let photos = ids.isEmpty ? [] : try await VerifiedIdentityService.sql(db).raw("""
                SELECT DISTINCT ON (snag_id) media_assets.*, count(*) OVER (PARTITION BY snag_id) AS photo_count
                FROM media_assets WHERE project_id = ANY(\(bind: projectsOnPage)) AND snag_id = ANY(\(bind: ids)) AND state = 'ready' AND attached_at IS NOT NULL
                ORDER BY snag_id, CASE purpose WHEN 'capture' THEN 0 ELSE 1 END, created_at, id
                """).all()
            let evidence = try photos.map { row in
                SnagRegisterService.EvidencePreview(snagId: try row.decode(column: "snag_id", as: UUID.self), asset: try MediaAssetResponse(row), count: try row.decode(column: "photo_count", as: Int.self))
            }
            return Page(items: values.map { Row(projectId: $0.projectId, item: PlatformSnagResponse($0)) }, page: page, hasMore: page * Self.pageSize < total,
                        total: total, contractors: try contractors.map {
                            SnagRegisterService.ContractorLabel(id: try $0.requireID(), companyName: $0.companyName, contactName: $0.contactName, isArchived: $0.isArchived)
                        }, evidence: evidence, projectIds: order, unavailable: unavailable, asOfDate: window.today)
        }
    }
}
