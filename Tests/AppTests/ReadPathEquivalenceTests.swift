@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Lane 2 (28 Sep 2026): the read paths now take fewer database round trips (staging sits 40 ms from its
/// database) and the portal can read a workspace in one request. None of that may change an answer. These
/// tests keep the pre-Lane-2 statements as reference implementations and require byte-identical pages and
/// identical decisions across roles, filters, sorts and pages.
final class ReadPathEquivalenceTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    // MARK: fixtures
    private func user(_ tag: String = "reader") async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("\(tag)-\(UUID())@example.test", name: "Synthetic \(tag)", on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User, body: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            if method != .GET { req.headers.contentType = .json; req.body = .init(data: bytes) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func metadata() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func project(_ owner: User, workspace: UUID, name: String) async throws -> PlatformProjectResponse {
        let body: [String: Any] = ["mutation": metadata(), "workspaceId": workspace.uuidString,
                                   "project": ["id": UUID().uuidString, "name": name, "reference": String(name.prefix(4)), "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, _ project: PlatformProjectResponse, _ fields: [String: Any]) async throws -> UUID {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
                                         body: ["mutation": metadata(), "id": UUID().uuidString, "fields": fields])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self).snag.id
    }
    private func contractor(_ owner: User, workspace: UUID, project: PlatformProjectResponse, name: String) async throws -> UUID {
        let id = UUID()
        let response = try await request(.POST, "api/v2/workspaces/\(workspace)/contractors", user: owner,
                                         body: ["mutation": metadata(), "id": id.uuidString, "expectedRevision": 0, "projectId": project.project.id.uuidString, "fields": ["companyName": name]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return id
    }
    private func sql(_ query: SQLQueryString) async throws { try await VerifiedIdentityService.sql(app.db).raw(query).run() }
    /// A register-shaped fixture: every status, legacy states, archived rows, contractors, due dates either side of
    /// the boundary and missing, text for search, and pending attempts for review ageing.
    private func populate(_ owner: User, _ envelope: PlatformProjectResponse, contractors: [UUID], count: Int, seed: Int) async throws {
        let rooms = ["Kitchen", "Bathroom", "Hall", "Landing"], priorities = ["low", "medium", "high", "critical"]
        let statuses = ["open", "open", "in_progress", "awaiting_review", "changes_requested", "closed", "open"]
        let dues: [String?] = ["2026-09-01", "2026-09-10", "2026-09-11", "2026-09-16", "2026-09-17", nil, "2026-10-20"]
        for k in 0..<count {
            var fields: [String: Any] = ["title": "Item \(seed)-\(k) \(k % 5 == 0 ? "kitchen tap" : "skirting")", "location": "Plot \(seed) · \(rooms[k % rooms.count])",
                                         "priority": priorities[(k + seed) % priorities.count]]
            if let due = dues[(k * 3 + seed) % dues.count] { fields["dueOn"] = due }
            if k % 4 == 1 { fields["description"] = "Needs a second visit; KITCHEN side" }
            let id = try await snag(owner, envelope, fields)
            let status = statuses[(k + seed) % statuses.count]
            let legacy = k % 9 == 4
            let contractorID: UUID? = k % 3 == 0 ? nil : contractors[k % contractors.count]
            try await sql("UPDATE snags SET status = \(bind: status), workflow_qualification = \(bind: legacy ? "legacy_unverified" : Optional<String>.none), contractor_id = \(bind: contractorID), updated_at = \(bind: Date(timeIntervalSince1970: 1_790_000_000 + Double((k * 7919 + seed) % 1000))) WHERE id = \(bind: id)")
            if k % 11 == 7 { try await sql("UPDATE snags SET archived_at = NOW(), archive_reason = 'fixture' WHERE id = \(bind: id)") }
            if status == "awaiting_review", !legacy {
                try await sql("""
                    INSERT INTO completion_attempts (id, workspace_id, project_id, snag_id, attempt_number, actor_id, actor_kind, notes, state, revision, submitted_at)
                    VALUES (\(bind: UUID()), \(bind: envelope.workspaceId), \(bind: envelope.project.id), \(bind: id), 1, \(bind: owner.requireID()), 'internal', NULL, 'pending', 1, \(bind: Date(timeIntervalSince1970: 1_789_000_000 + Double(k * 60))))
                    """)
            }
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: reference implementations (the statements before Lane 2)
    static func legacyList(_ filters: SnagRegisterQuery, project: Project, on db: Database, now: Date) async throws -> SnagRegisterService.Page {
        try filters.validate()
        try PlatformMutationService.requireManaged(project)
        let projectID = try project.requireID(), page = filters.page ?? 1
        let (today, nextWeek) = try await SnagRegisterService.calendarWindow(project, on: db, now: now)
        func base() -> QueryBuilder<Snag> {
            let result = Snag.query(on: db).filter(\.$projectId == projectID)
            return filters.archived == true ? result.filter(\.$archivedAt != nil) : result.filter(\.$archivedAt == nil)
        }
        func overdue(_ query: QueryBuilder<Snag>) -> QueryBuilder<Snag> { SnagRegisterService.contractorOverdue(query, today: today) }
        func awaitingReview(_ query: QueryBuilder<Snag>) -> QueryBuilder<Snag> { query.filter(\.$status == "awaiting_review").filter(\.$workflowQualification == nil) }
        let oldestPending = try await VerifiedIdentityService.sql(db).raw("""
            SELECT min(a.submitted_at) AS oldest FROM completion_attempts a JOIN snags s ON s.id = a.snag_id AND s.project_id = a.project_id
            WHERE a.project_id = \(bind: projectID) AND a.state = 'pending' AND s.status = 'awaiting_review' AND s.workflow_qualification IS NULL
              AND \(unsafeRaw: filters.archived == true ? "s.archived_at IS NOT NULL" : "s.archived_at IS NULL")
            """).first()?.decode(column: "oldest", as: Date?.self)
        let summary = try await SnagRegisterService.Summary(total: base().count(),
            awaitingReview: awaitingReview(base()).count(), overdue: overdue(base()).count(),
            legacyUnverified: base().filter(\.$workflowQualification != nil).count(),
            reviewPastDue: awaitingReview(base()).filter(\.$dueOn < today).count(),
            oldestAwaitingReviewSince: oldestPending)
        let query = SnagRegisterService.matching(filters, base: base(), today: today, nextWeek: nextWeek)
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
            SnagRegisterService.EvidencePreview(snagId: try row.decode(column: "snag_id", as: UUID.self), asset: try MediaAssetResponse(row), count: try row.decode(column: "photo_count", as: Int.self))
        }
        return try SnagRegisterService.Page(items: values.map(PlatformSnagResponse.init), page: page, hasMore: page * 50 < total,
            total: total, summary: summary, contractors: contractors.map {
                SnagRegisterService.ContractorLabel(id: try $0.requireID(), companyName: $0.companyName, contactName: $0.contactName, isArchived: $0.isArchived)
            }, evidence: evidence)
    }
    /// Outcome of an access decision, comparable across implementations.
    private func outcome(_ body: () async throws -> Set<ProjectAccessPolicy.Action>) async -> String {
        do { return "allowed " + (try await body()).map(\.rawValue).sorted().joined(separator: ",") }
        catch let abort as AbortError { return "refused \(abort.status.code) \(abort.reason)" }
        catch { return "error \(error)" }
    }

    static var filterMatrix: [SnagRegisterQuery] { [
        .init(), .init(page: 2), .init(q: "kitchen"), .init(q: "   "), .init(q: "PLOT 1"), .init(location: "hall"), .init(location: " "),
        .init(status: "open"), .init(status: "in_progress"), .init(status: "awaiting_review"), .init(status: "changes_requested"), .init(status: "closed"),
        .init(priority: "high"), .init(contractorId: "unassigned"), .init(status: "open", contractorId: "unassigned"),
        .init(due: "overdue"), .init(due: "today"), .init(due: "next7"), .init(due: "none"), .init(archived: true), .init(archived: true, status: "closed"),
        .init(sort: "due"), .init(sort: "due", direction: "desc"), .init(sort: "updated", direction: "asc"), .init(sort: "priority", direction: "desc"),
        .init(direction: "desc"), .init(page: 2, sort: "due"), .init(q: "kitchen", status: "open", due: "overdue"),
    ] }

    // MARK: tests
    func testRegisterPagesAreIdenticalToThePreviousStatements() async throws {
        let owner = try await user("owner")
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let wsID = try workspace.requireID()
        let envelope = try await project(owner, workspace: wsID, name: "Equivalence · Plot 1")
        let a = try await contractor(owner, workspace: wsID, project: envelope, name: "Aster Plastering")
        let b = try await contractor(owner, workspace: wsID, project: envelope, name: "Birch Joinery")
        try await populate(owner, envelope, contractors: [a, b], count: 64, seed: 1)
        let project = try await Project.find(envelope.project.id, on: app.db)!
        let now = ISO8601DateFormatter().date(from: "2026-09-10T12:30:00Z")!
        var filters = Self.filterMatrix
        filters.append(.init(contractorId: a.uuidString))
        for f in filters {
            let old = try await Self.legacyList(f, project: project, on: app.db, now: now)
            let new = try await SnagRegisterService.list(f, project: project, timezone: workspace.timezone, on: app.db, now: now)
            let fresh = try await SnagRegisterService.list(f, project: project, on: app.db, now: now)
            let label = try json(f)
            XCTAssertEqual(try json(new), try json(old), "filters \(label)")
            XCTAssertEqual(try json(fresh), try json(old), "filters \(label) without a pre-read timezone")
        }
        // Through HTTP (the controller reads the calendar in its access statement).
        let old = try await Self.legacyList(.init(due: "overdue"), project: project, on: app.db, now: Date())
        let response = try await request(.GET, "api/v2/projects/\(envelope.project.id)/snags?due=overdue", user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let page = try response.content.decode(SnagRegisterService.Page.self)
        XCTAssertEqual(page.total, old.total); XCTAssertEqual(page.items.map(\.snag.id), old.items.map(\.snag.id))
        XCTAssertEqual(try json(page.summary), try json(old.summary))
    }

    func testReadAccessDecidesExactlyAsTheGeneralCheckForEveryRole() async throws {
        let owner = try await user("owner"), admin = try await user("admin"), manager = try await user("manager"), member = try await user("member")
        let viewer = try await user("viewer"), bare = try await user("bare"), removed = try await user("removed"), outsider = try await user("outsider")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Equivalence Construction", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID()
        for (person, role) in [(admin, "admin"), (manager, "member"), (member, "member"), (viewer, "member"), (bare, "member"), (removed, "member")] {
            try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: person.requireID(), role: role, on: db) }
        }
        let first = try await project(owner, workspace: companyID, name: "Company · Plot 1")
        let second = try await project(owner, workspace: companyID, name: "Company · Plot 2")
        for (person, role) in [(manager, "manager"), (member, "member"), (viewer, "viewer"), (removed, "member")] {
            try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: first.project.id), \(bind: companyID), \(bind: person.requireID()), \(bind: role))")
        }
        try await sql("UPDATE workspace_memberships SET state = 'removed' WHERE workspace_id = \(bind: companyID) AND user_id = \(bind: removed.requireID())")
        let personal = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: outsider.requireID(), on: db) }
        let own = try await project(outsider, workspace: try personal.requireID(), name: "Personal · Plot 9")
        let legacyProject = Project(name: "Legacy · no workspace", reference: "LG", ownerId: try outsider.requireID())
        try await legacyProject.save(on: app.db)
        try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
        let targets = [first.project.id, second.project.id, own.project.id, try legacyProject.requireID(), UUID()]
        for person in [owner, admin, manager, member, viewer, bare, removed, outsider] {
            for target in targets {
                let personID = try person.requireID()
                let exclusive = await outcome { try await self.app.db.transaction { db in try await ProjectAccessService.require(.read, projectID: target, actorID: personID, on: db).1 } }
                // The legacy branch writes (it attaches the project to the owner's personal workspace); undo so both see the same start.
                try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
                let shared = await outcome { try await self.app.db.transaction { db in try await ProjectAccessService.readContext(projectID: target, actorID: personID, on: db).actions } }
                try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
                XCTAssertEqual(shared, exclusive, "\(person.name ?? "?") reading \(target)")
            }
        }
        // The project it returns is the project the general check returns.
        let viaContext = try await app.db.transaction { db in try await ProjectAccessService.readContext(projectID: first.project.id, actorID: manager.requireID(), on: db) }
        let viaCheck = try await app.db.transaction { db in try await ProjectAccessService.require(.read, projectID: first.project.id, actorID: manager.requireID(), on: db) }
        XCTAssertEqual(try json(PlatformProjectResponse(viaContext.project, actions: viaContext.actions)), try json(PlatformProjectResponse(viaCheck.0, actions: viaCheck.1)))
        XCTAssertEqual(viaContext.workspaceTimezone, company.timezone)

        // The project list: same items, order and capabilities as one general check per project.
        for person in [owner, admin, manager, member, viewer, bare, removed, outsider] {
            let response = try await request(.GET, "api/v2/projects?workspaceId=\(companyID)", user: person)
            let personID = try person.requireID()
            let expected: [String] = try await app.db.transaction { db -> [String] in
                guard (try? await WorkspaceAccessService.role(actorID: personID, workspace: company, on: db)) != nil else { return ["refused"] }
                var ids = try await Project.query(on: db).filter(\.$workspaceId == companyID).filter(\.$archivedAt == nil).sort(\.$updatedAt, .descending).sort(\.$id).all()
                if try await WorkspaceAccessService.role(actorID: personID, workspace: company, on: db) == "member" {
                    let granted = try await VerifiedIdentityService.sql(db).raw("SELECT project_id FROM project_access WHERE state = 'active' AND workspace_id = \(bind: companyID) AND user_id = \(bind: personID)").all().map { try $0.decode(column: "project_id", as: UUID.self) }
                    ids = ids.filter { granted.contains($0.id!) }
                }
                var out: [String] = []
                for p in ids { out.append("\(p.id!) " + (try await ProjectAccessService.require(.read, projectID: p.requireID(), actorID: personID, on: db)).1.map(\.rawValue).sorted().joined(separator: ",")) }
                return out
            }
            if expected == ["refused"] { XCTAssertEqual(response.status, .notFound, response.body.string); continue }
            XCTAssertEqual(response.status, .ok, response.body.string)
            let page = try response.content.decode(PlatformProjectController.Page.self)
            XCTAssertEqual(page.items.map { "\($0.project.id) " + $0.capabilities.joined(separator: ",") }, expected, "\(person.name ?? "?")")
        }
    }

    func testWorkspaceSummaryAndRegisterAgreeWithEveryProjectRegister() async throws {
        let owner = try await user("owner"), member = try await user("member"), outsider = try await user("outsider")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Workspace Reads Ltd", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID()
        try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: member.requireID(), role: "member", on: db) }
        let p1 = try await project(owner, workspace: companyID, name: "Beech · Plot 1")
        let p2 = try await project(owner, workspace: companyID, name: "alder · Plot 2")
        let p3 = try await project(owner, workspace: companyID, name: "Cedar · Plot 3")
        let unmanaged = try await project(owner, workspace: companyID, name: "Imported · awaiting verification")
        try await sql("UPDATE projects SET platform_managed = FALSE WHERE id = \(bind: unmanaged.project.id)")
        let a = try await contractor(owner, workspace: companyID, project: p1, name: "Aster Plastering")
        let b = try await contractor(owner, workspace: companyID, project: p1, name: "Birch Joinery")
        try await populate(owner, p1, contractors: [a, b], count: 40, seed: 1)
        try await populate(owner, p2, contractors: [a, b], count: 31, seed: 2)
        try await populate(owner, p3, contractors: [b], count: 12, seed: 3)
        try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: p2.project.id), \(bind: companyID), \(bind: member.requireID()), 'member')")
        let managed = [p1, p2, p3]

        // Work summary == each project's register (owner), with the unmanaged project reported, not counted.
        let response = try await request(.GET, "api/v2/workspaces/\(companyID)/work-summary", user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let summary = try response.content.decode(WorkspaceWorkController.Summary.self)
        XCTAssertEqual(Set(summary.projects.map(\.projectId)), Set((managed + [unmanaged]).map(\.project.id)))
        XCTAssertEqual(summary.projects.first { $0.projectId == unmanaged.project.id }?.unavailable, "project_import_required")
        var totalAwaiting = 0, grand = 0
        for envelope in managed {
            let project = try await Project.find(envelope.project.id, on: app.db)!
            let row = summary.projects.first { $0.projectId == envelope.project.id }!
            let register = try await SnagRegisterService.list(.init(), project: project, on: app.db)
            XCTAssertEqual(try json(row.summary), try json(register.summary))
            let unassigned = try await SnagRegisterService.list(.init(status: "open", contractorId: "unassigned"), project: project, on: app.db).total
            let changes = try await SnagRegisterService.list(.init(status: "changes_requested"), project: project, on: app.db).total
            let next7 = try await SnagRegisterService.list(.init(due: "next7"), project: project, on: app.db).total
            let next7Closed = try await SnagRegisterService.list(.init(status: "closed", due: "next7"), project: project, on: app.db).total
            XCTAssertEqual(row.unassignedOpen, unassigned); XCTAssertEqual(row.changesRequested, changes)
            XCTAssertEqual(row.dueNext7, next7); XCTAssertEqual(row.dueNext7Closed, next7Closed)
            totalAwaiting += register.summary.awaitingReview; grand += register.summary.total
        }
        XCTAssertEqual(summary.totals.awaitingReview, totalAwaiting); XCTAssertEqual(summary.totals.total, grand)
        XCTAssertEqual(summary.projects.first { $0.projectId == p1.project.id }?.preparedLinks, 0, "the owner may share: counted (none prepared)")

        // The Member sees only the granted project; an outsider sees nothing.
        let memberSummary = try await request(.GET, "api/v2/workspaces/\(companyID)/work-summary", user: member)
        let memberView = try memberSummary.content.decode(WorkspaceWorkController.Summary.self)
        XCTAssertEqual(memberView.projects.map(\.projectId), [p2.project.id])
        XCTAssertNil(memberView.projects.first?.preparedLinks, "a project Member may not share: not counted")
        let outsiderSummary = try await request(.GET, "api/v2/workspaces/\(companyID)/work-summary", user: outsider).status
        let outsiderRegister = try await request(.GET, "api/v2/workspaces/\(companyID)/snags", user: outsider).status
        let memberOther = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?projectId=\(p1.project.id)", user: member).status
        let ownerUnmanaged = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?projectId=\(unmanaged.project.id)", user: owner).status
        XCTAssertEqual(outsiderSummary, .notFound); XCTAssertEqual(outsiderRegister, .notFound)
        XCTAssertEqual(memberOther, .notFound); XCTAssertEqual(ownerUnmanaged, .conflict)

        // The workspace register is exactly the union of the project registers, bounded to 50 rows a page.
        let queries: [String] = ["", "status=open", "q=kitchen", "due=overdue", "due=next7", "contractorId=unassigned&status=open", "priority=critical",
                                 "sort=due", "sort=due&direction=desc", "sort=updated&direction=asc", "sort=priority&direction=desc", "direction=desc", "archived=true",
                                 "contractorId=\(a.uuidString)", "location=hall&status=closed"]
        for q in queries {
            var rows: [String] = [], total = -1, page = 1
            while true {
                let r = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?\(q)\(q.isEmpty ? "" : "&")page=\(page)", user: owner)
                XCTAssertEqual(r.status, .ok, "\(q): \(r.body.string)")
                let body = try r.content.decode(WorkspaceWorkController.Page.self)
                XCTAssertLessThanOrEqual(body.items.count, 50)
                XCTAssertEqual(body.unavailable.map(\.projectId), [unmanaged.project.id])
                total = body.total
                rows += body.items.map { "\($0.projectId) \($0.item.snag.id)" }
                if !body.hasMore { break }
                page += 1
            }
            var expected: [String] = [], expectedTotal = 0
            var query = SnagRegisterQuery()
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                switch kv[0] { case "status": query.status = kv[1]; case "q": query.q = kv[1]; case "due": query.due = kv[1]; case "contractorId": query.contractorId = kv[1]
                case "priority": query.priority = kv[1]; case "sort": query.sort = kv[1]; case "direction": query.direction = kv[1]; case "archived": query.archived = kv[1] == "true"
                case "location": query.location = kv[1]; default: XCTFail(kv[0]) }
            }
            for envelope in managed {
                let project = try await Project.find(envelope.project.id, on: app.db)!
                var p = 1
                while true {
                    query.page = p
                    let register = try await SnagRegisterService.list(query, project: project, on: app.db)
                    if p == 1 { expectedTotal += register.total }
                    expected += register.items.map { "\(envelope.project.id) \($0.snag.id)" }
                    if !register.hasMore { break }
                    p += 1
                }
            }
            XCTAssertEqual(total, expectedTotal, q)
            XCTAssertEqual(rows.count, Set(rows).count, "\(q): no row on two pages")
            XCTAssertEqual(Set(rows), Set(expected), q)
            if q.isEmpty {
                // Grouped by project name (case-insensitive: alder, Beech, Cedar), then reference.
                let order = rows.map { String($0.prefix(36)) }
                let grouped = order.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
                XCTAssertEqual(grouped, [p2, p1, p3].map { $0.project.id.uuidString })
            }
        }
        // The review queue: canonical submissions in projects the person may review; its total is the summary's.
        let queue = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?queue=review", user: owner)
        XCTAssertEqual(try queue.content.decode(WorkspaceWorkController.Page.self).total, summary.totals.awaitingReview)
        let memberQueue = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?queue=review", user: member)
        XCTAssertEqual(try memberQueue.content.decode(WorkspaceWorkController.Page.self).total, 0, "a project Member cannot review")
        let mixed = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?queue=review&status=open", user: owner).status
        XCTAssertEqual(mixed, .badRequest)
    }
}
