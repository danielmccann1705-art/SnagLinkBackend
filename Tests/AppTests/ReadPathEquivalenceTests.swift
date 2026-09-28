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
    // MARK: - One statement per read after the lock (Lane 2, 28 Sep 2026, evening)

    /// The contractor labels were a lookup set returned by a separate query in no specified order; the one-statement
    /// read returns them sorted by id. Everything else must be byte-identical.
    private func canonical(_ page: SnagRegisterService.Page) -> SnagRegisterService.Page {
        .init(items: page.items, page: page.page, hasMore: page.hasMore, total: page.total, summary: page.summary,
              contractors: page.contractors.sorted { $0.id.uuidString < $1.id.uuidString }, evidence: page.evidence)
    }
    private func canonical(_ page: WorkspaceWorkController.Page) -> WorkspaceWorkController.Page {
        .init(items: page.items, page: page.page, hasMore: page.hasMore, total: page.total,
              contractors: page.contractors.sorted { $0.id.uuidString < $1.id.uuidString }, evidence: page.evidence,
              projectIds: page.projectIds, unavailable: page.unavailable, asOfDate: page.asOfDate)
    }
    /// Evidence for the register: two ready, attached captures on one snag (the earlier one is the preview), one
    /// ready capture on another, one not yet attached and one not ready (neither counted).
    private func photos(_ owner: User, _ envelope: PlatformProjectResponse, snags: [UUID]) async throws {
        let ownerID = try owner.requireID()
        func add(_ snag: UUID, state: String, attached: Bool, age: Double) async throws {
            let id = UUID(), sha = String(repeating: "a", count: 63) + "\(Int(age) % 10)"
            let prefix = "platform/\(envelope.workspaceId)/\(envelope.project.id)/\(id)"
            try await sql("""
                INSERT INTO media_assets (id, workspace_id, project_id, snag_id, creator_id, purpose, state,
                    original_sha256, original_size, original_mime, original_key, rendition_key,
                    rendition_sha256, rendition_size, width, height, base_snag_revision, created_at, expires_at, ready_at, attached_at)
                VALUES (\(bind: id), \(bind: envelope.workspaceId), \(bind: envelope.project.id), \(bind: snag), \(bind: ownerID), 'capture', \(bind: state),
                    \(bind: sha), 1000, 'image/jpeg', \(bind: prefix + "/original"), \(bind: prefix + "/view.jpg"),
                    \(bind: state == "ready" ? Optional(sha) : nil), \(bind: state == "ready" ? Optional(900) : nil), \(bind: state == "ready" ? Optional(40) : nil), \(bind: state == "ready" ? Optional(30) : nil),
                    1, NOW() - \(bind: "\(Int(age)) minutes")::interval, NOW() + INTERVAL '1 day', \(bind: state == "ready" ? Optional(Date()) : nil), \(bind: attached ? Optional(Date()) : nil))
                """)
        }
        try await add(snags[0], state: "ready", attached: true, age: 30)
        try await add(snags[0], state: "ready", attached: true, age: 10)
        try await add(snags[1], state: "ready", attached: true, age: 20)
        try await add(snags[2], state: "ready", attached: false, age: 5)
        try await add(snags[3], state: "allocated", attached: false, age: 5)
    }
    private func readOutcome(_ body: () async throws -> String) async -> String {
        do { return "allowed " + (try await body()) }
        catch let abort as AbortError { return "refused \(abort.status.code) \(abort.reason) \((abort as? Abort)?.identifier ?? "")" }
        catch { return "error \(error)" }
    }

    func testOneStatementRegisterReadIsIdenticalToThePreviousStatements() async throws {
        let owner = try await user("owner")
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let wsID = try workspace.requireID(), ownerID = try owner.requireID()
        let envelope = try await project(owner, workspace: wsID, name: "One statement · Plot 1")
        let a = try await contractor(owner, workspace: wsID, project: envelope, name: "Aster Plastering")
        let b = try await contractor(owner, workspace: wsID, project: envelope, name: "Birch Joinery")
        try await populate(owner, envelope, contractors: [a, b], count: 64, seed: 1)
        let project = try await Project.find(envelope.project.id, on: app.db)!
        let first = try await Self.legacyList(.init(), project: project, on: app.db, now: Date())
        try await photos(owner, envelope, snags: first.items.prefix(4).map(\.snag.id))
        let now = ISO8601DateFormatter().date(from: "2026-09-10T12:30:00Z")!
        var filters = Self.filterMatrix
        filters += [.init(contractorId: a.uuidString), .init(page: 3), .init(page: 9), .init(q: "no such text anywhere"), .init(page: 4, archived: true)]
        var sawEvidence = false, sawContractors = false, sawEmpty = false
        for f in filters {
            let old = try await Self.legacyList(f, project: project, on: app.db, now: now)
            let new = try await app.db.transaction { db in try await SnagRegisterService.read(f, projectID: envelope.project.id, actorID: ownerID, on: db, now: now) }
            let label = try json(f)
            XCTAssertEqual(try json(new), try json(canonical(old)), "filters \(label)")
            sawEvidence = sawEvidence || !new.evidence.isEmpty; sawContractors = sawContractors || new.contractors.count > 1; sawEmpty = sawEmpty || new.items.isEmpty
        }
        XCTAssertTrue(sawEvidence && sawContractors && sawEmpty, "the matrix covers evidence, several contractors and an empty page")
        let reference = try await Self.legacyList(.init(), project: project, on: app.db, now: now)
        XCTAssertEqual(reference.evidence.first { $0.snagId == first.items[0].snag.id }?.count, 2, "two ready, attached photos; the others are not counted")
        // Through HTTP (the controller uses the one-statement read).
        for query in ["", "due=overdue", "status=open&page=2", "q=kitchen&sort=priority&direction=desc", "contractorId=\(a.uuidString)"] {
            let response = try await request(.GET, "api/v2/projects/\(envelope.project.id)/snags?\(query)", user: owner)
            XCTAssertEqual(response.status, .ok, response.body.string)
            var f = SnagRegisterQuery()
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                switch kv[0] { case "status": f.status = kv[1]; case "q": f.q = kv[1]; case "due": f.due = kv[1]; case "contractorId": f.contractorId = kv[1]
                case "sort": f.sort = kv[1]; case "direction": f.direction = kv[1]; case "page": f.page = Int(kv[1]); default: XCTFail(kv[0]) }
            }
            let old = try await Self.legacyList(f, project: project, on: app.db, now: Date())
            XCTAssertEqual(try json(response.content.decode(SnagRegisterService.Page.self)), try json(canonical(old)), query)
        }
        // Refusals in the previous order: an invalid filter is still a 400 for someone who may read …
        let invalid = try await request(.GET, "api/v2/projects/\(envelope.project.id)/snags?page=0", user: owner).status
        XCTAssertEqual(invalid, .badRequest)
        // … and a 404 for someone who may not (access is decided first).
        let stranger = try await user("stranger")
        let hidden = try await request(.GET, "api/v2/projects/\(envelope.project.id)/snags?page=0", user: stranger).status
        XCTAssertEqual(hidden, .notFound)
    }

    func testOneStatementRegisterReadDecidesAndRefusesExactlyAsBefore() async throws {
        let owner = try await user("owner"), admin = try await user("admin"), manager = try await user("manager"), member = try await user("member")
        let viewer = try await user("viewer"), bare = try await user("bare"), removed = try await user("removed"), outsider = try await user("outsider")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "One Statement Ltd", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID()
        for (person, role) in [(admin, "admin"), (manager, "member"), (member, "member"), (viewer, "member"), (bare, "member"), (removed, "member")] {
            try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: person.requireID(), role: role, on: db) }
        }
        let first = try await project(owner, workspace: companyID, name: "Company · Plot 1")
        let unmanaged = try await project(owner, workspace: companyID, name: "Company · Imported")
        let archived = try await project(owner, workspace: companyID, name: "Company · Archived")
        try await populate(owner, first, contractors: [try await contractor(owner, workspace: companyID, project: first, name: "Cedar Roofing")], count: 12, seed: 4)
        try await sql("UPDATE projects SET platform_managed = FALSE WHERE id = \(bind: unmanaged.project.id)")
        try await sql("UPDATE projects SET archived_at = NOW() WHERE id = \(bind: archived.project.id)")
        for (person, role) in [(manager, "manager"), (member, "member"), (viewer, "viewer"), (removed, "member")] {
            try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: first.project.id), \(bind: companyID), \(bind: person.requireID()), \(bind: role))")
        }
        try await sql("UPDATE workspace_memberships SET state = 'removed' WHERE workspace_id = \(bind: companyID) AND user_id = \(bind: removed.requireID())")
        let personal = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: outsider.requireID(), on: db) }
        let own = try await project(outsider, workspace: try personal.requireID(), name: "Personal · Plot 9")
        let legacyProject = Project(name: "Legacy · no workspace", reference: "LG", ownerId: try outsider.requireID())
        try await legacyProject.save(on: app.db)
        try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
        let targets = [first.project.id, unmanaged.project.id, archived.project.id, own.project.id, try legacyProject.requireID(), UUID()]
        let now = Date()
        for person in [owner, admin, manager, member, viewer, bare, removed, outsider] {
            for target in targets {
                for f in [SnagRegisterQuery(), SnagRegisterQuery(status: "open", sort: "due"), SnagRegisterQuery(page: 0)] {
                    let personID = try person.requireID()
                    let before = await readOutcome {
                        try await self.app.db.transaction { db in
                            let context = try await ProjectAccessService.readContext(projectID: target, actorID: personID, on: db)
                            return try self.json(self.canonical(try await SnagRegisterService.list(f, project: context.project, timezone: context.workspaceTimezone, on: db, now: now)))
                        }
                    }
                    try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
                    let after = await readOutcome {
                        try await self.app.db.transaction { db in try self.json(try await SnagRegisterService.read(f, projectID: target, actorID: personID, on: db, now: now)) }
                    }
                    try await sql("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacyProject.requireID())")
                    let label = try json(f)
                    XCTAssertEqual(after, before, "\(person.name ?? "?") reading \(target) with \(label)")
                }
            }
        }
        // An unusable workspace calendar takes the previous statements and gives their answer.
        do {
            try await sql("UPDATE teams SET timezone = 'Not/AZone' WHERE id = \(bind: companyID)")
            let ownerID = try owner.requireID()
            let before = await readOutcome { try await self.app.db.transaction { db in
                let context = try await ProjectAccessService.readContext(projectID: first.project.id, actorID: ownerID, on: db)
                return try self.json(try await SnagRegisterService.list(.init(), project: context.project, timezone: context.workspaceTimezone, on: db, now: now)) } }
            let after = await readOutcome { try await self.app.db.transaction { db in try self.json(try await SnagRegisterService.read(.init(), projectID: first.project.id, actorID: ownerID, on: db, now: now)) } }
            XCTAssertEqual(after, before); XCTAssertTrue(before.contains("timezone_required"), before)
            try await sql("UPDATE teams SET timezone = 'Europe/London' WHERE id = \(bind: companyID)")
        } catch { XCTAssertTrue("\(error)".contains("violates"), "only a schema constraint may refuse the invalid calendar: \(error)") }
    }

    // The workspace scope as it was read before (five statements for a company workspace): the reference.
    static func legacyScope(workspaceID: UUID, actorID: UUID, offset: Int = 0, candidateLimit: Int? = nil, on db: Database) async throws -> (role: String, timezone: String, projects: [String]) {
        try await WorkspaceAccessService.readLock(workspaceID, on: db)
        guard let team = try await Team.find(workspaceID, on: db) else { throw Abort(.notFound) }
        let role = try await WorkspaceAccessService.role(actorID: actorID, workspace: team, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        let memberOnly = team.kind == "company" && role == "member"
        let limit = candidateLimit.map { "LIMIT \($0) OFFSET \(offset)" } ?? ""
        let rows = try await sql.raw("""
            SELECT p.*,
                   (SELECT g.role FROM project_access g WHERE g.state = 'active' AND g.workspace_id = p.workspace_id AND g.project_id = p.id AND g.user_id = \(bind: actorID) LIMIT 1) AS access_grant_role
            FROM projects p
            WHERE p.workspace_id = \(bind: workspaceID) AND p.archived_at IS NULL
              AND (\(bind: !memberOnly) OR p.id IN (SELECT project_id FROM project_access WHERE state = 'active' AND workspace_id = \(bind: workspaceID) AND user_id = \(bind: actorID)))
            ORDER BY p.updated_at DESC, p.id
            \(unsafeRaw: limit)
            """).all()
        let memberRow = team.kind == "company"
            ? try await sql.raw("SELECT role, state FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: actorID)").first()
            : nil
        let membership: ProjectAccessPolicy.Membership? = try memberRow.flatMap { row in
            guard let parsed = ProjectAccessPolicy.WorkspaceRole(rawValue: try row.decode(column: "role", as: String.self)) else { return nil }
            return .init(workspaceID: workspaceID, userID: actorID, role: parsed, active: try row.decode(column: "state", as: String.self) == "active")
        }
        guard let kind = ProjectAccessPolicy.WorkspaceKind(rawValue: team.kind) else { throw Abort(.forbidden) }
        let workspace = ProjectAccessPolicy.Workspace(id: workspaceID, kind: kind, ownerID: team.ownerUserId, active: team.lifecycleState == "active")
        var projects: [String] = []
        for row in rows {
            let project = try row.decode(fluentModel: Project.self)
            let projectID = try project.requireID()
            let grant: ProjectAccessPolicy.Grant? = try row.decode(column: "access_grant_role", as: String?.self).flatMap { raw in
                guard let parsed = ProjectAccessPolicy.ProjectRole(rawValue: raw) else { return nil }
                return .init(workspaceID: workspaceID, projectID: projectID, userID: actorID, role: parsed)
            }
            let actions = ProjectAccessPolicy.allowedActions(actorID: actorID, workspace: workspace,
                project: .init(id: projectID, workspaceID: workspaceID, creatorID: project.ownerId), membership: membership, grant: grant)
            projects.append("\(projectID) \(project.name) " + actions.map(\.rawValue).sorted().joined(separator: ","))
        }
        return (role, team.timezone, projects)
    }

    func testWorkspaceScopeIsReadInOneStatementWithTheSameAnswers() async throws {
        let owner = try await user("owner"), admin = try await user("admin"), manager = try await user("manager"), member = try await user("member")
        let removed = try await user("removed"), outsider = try await user("outsider"), gone = try await user("gone")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Scope Ltd", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID()
        for (person, role) in [(admin, "admin"), (manager, "member"), (member, "member"), (removed, "member"), (gone, "member")] {
            try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: person.requireID(), role: role, on: db) }
        }
        var projects: [PlatformProjectResponse] = []
        for n in 1...4 { projects.append(try await project(owner, workspace: companyID, name: "Scope · Plot \(n)")) }
        try await sql("UPDATE projects SET archived_at = NOW() WHERE id = \(bind: projects[3].project.id)")
        try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: projects[0].project.id), \(bind: companyID), \(bind: manager.requireID()), 'manager')")
        try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: projects[1].project.id), \(bind: companyID), \(bind: member.requireID()), 'member')")
        try await sql("UPDATE workspace_memberships SET state = 'removed' WHERE workspace_id = \(bind: companyID) AND user_id = \(bind: removed.requireID())")
        let personal = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: outsider.requireID(), on: db) }
        let personalID = try personal.requireID()
        _ = try await project(outsider, workspace: personalID, name: "Personal · Plot 1")
        _ = try await project(outsider, workspace: personalID, name: "Personal · Plot 2")
        do { try await sql("UPDATE users SET lifecycle_state = 'deleted' WHERE id = \(bind: gone.requireID())") }
        catch { XCTAssertTrue("\(error)".contains("violates"), "\(error)") }
        func compare(_ label: String) async throws {
            for workspace in [companyID, personalID, UUID()] {
                for person in [owner, admin, manager, member, removed, outsider, gone] {
                    for (offset, limit) in [(0, nil), (0, 2), (1, 2), (3, 2)] as [(Int, Int?)] {
                        let personID = try person.requireID()
                        let before = await readOutcome { try await self.app.db.transaction { db in
                            let s = try await Self.legacyScope(workspaceID: workspace, actorID: personID, offset: offset, candidateLimit: limit, on: db)
                            return "\(s.role) \(s.timezone) " + s.projects.joined(separator: " | ") } }
                        let after = await readOutcome { try await self.app.db.transaction { db in
                            let s = try await WorkspaceReadScope.load(workspaceID: workspace, actorID: personID, offset: offset, candidateLimit: limit, on: db)
                            XCTAssertEqual(s.workspaceID, workspace); XCTAssertEqual(try s.team.requireID(), workspace)
                            return "\(s.role) \(s.team.timezone) " + s.projects.map { "\($0.project.id!) \($0.project.name) " + $0.actions.map(\.rawValue).sorted().joined(separator: ",") }.joined(separator: " | ") } }
                        XCTAssertEqual(after, before, "\(label): \(person.name ?? "?") in \(workspace) offset \(offset) limit \(String(describing: limit))")
                    }
                }
            }
        }
        try await compare("active workspaces")
        do {
            try await sql("UPDATE teams SET lifecycle_state = 'deleting' WHERE id = \(bind: companyID)")
            try await compare("a company that is being deleted")
        } catch { XCTAssertTrue("\(error)".contains("violates"), "\(error)") }
    }

    // The workspace register page as it was read before (count, page, contractors, photos: four statements): the reference.
    static func legacyWorkspacePage(_ filters: SnagRegisterQuery, queue: String?, workspaceID: UUID, order: [UUID], unavailable: [WorkspaceWorkController.Unavailable],
                                    today: String, nextWeek: String, on db: Database) async throws -> WorkspaceWorkController.Page {
        let page = filters.page ?? 1, size = WorkspaceWorkController.pageSize
        let base = Snag.query(on: db).filter(\.$projectId ~~ order)
        if filters.archived == true { base.filter(\.$archivedAt != nil) } else { base.filter(\.$archivedAt == nil) }
        if queue == "review" { base.filter(\.$workflowQualification == nil) }
        let query = SnagRegisterService.matching(filters, base: base, today: today, nextWeek: nextWeek)
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
        let values = try await query.sort(\.$id).range(((page - 1) * size)..<(page * size)).all()
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
        return .init(items: values.map { .init(projectId: $0.projectId, item: PlatformSnagResponse($0)) }, page: page, hasMore: page * size < total, total: total,
                     contractors: try contractors.map { .init(id: try $0.requireID(), companyName: $0.companyName, contactName: $0.contactName, isArchived: $0.isArchived) },
                     evidence: evidence, projectIds: order, unavailable: unavailable, asOfDate: today)
    }

    func testWorkspaceRegisterPagesAreIdenticalToThePreviousStatements() async throws {
        let owner = try await user("owner"), member = try await user("member")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Register Pages Ltd", actorID: owner.requireID(), on: db) }
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
        for envelope in [p1, p2] {
            let project = try await Project.find(envelope.project.id, on: app.db)!
            let page = try await SnagRegisterService.list(.init(), project: project, on: app.db)
            try await photos(owner, envelope, snags: page.items.prefix(4).map(\.snag.id))
        }
        try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: p2.project.id), \(bind: companyID), \(bind: member.requireID()), 'member')")
        let queries: [String] = ["", "page=2", "status=open", "q=kitchen", "due=overdue", "due=next7", "contractorId=unassigned&status=open", "priority=critical",
                                 "sort=due", "sort=due&direction=desc", "sort=updated&direction=asc", "sort=priority&direction=desc", "direction=desc", "archived=true",
                                 "contractorId=\(a.uuidString)", "location=hall&status=closed", "queue=review", "queue=review&direction=desc", "projectId=\(p1.project.id)",
                                 "projectId=\(p2.project.id)&page=2", "page=9", "q=nothing+matches+this"]
        var sawEvidence = false
        for person in [owner, member] {
            for q in queries {
                let response = try await request(.GET, "api/v2/workspaces/\(companyID)/snags?\(q)", user: person)
                guard response.status == .ok else { XCTAssertEqual(response.status, .notFound, "\(q): \(response.body.string)"); continue }
                let new = try response.content.decode(WorkspaceWorkController.Page.self)
                var f = SnagRegisterQuery(); var queue: String? = nil; var only: UUID? = nil
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    let value = kv[1].replacingOccurrences(of: "+", with: " ")
                    switch kv[0] { case "status": f.status = value; case "q": f.q = value; case "due": f.due = value; case "contractorId": f.contractorId = value
                    case "priority": f.priority = value; case "sort": f.sort = value; case "direction": f.direction = value; case "archived": f.archived = value == "true"
                    case "location": f.location = value; case "page": f.page = Int(value); case "queue": queue = value; case "projectId": only = UUID(uuidString: value)
                    default: XCTFail(kv[0]) }
                }
                if queue == "review" { f.status = "awaiting_review"; if f.sort == nil { f.sort = "updated"; f.direction = f.direction ?? "asc" } }
                let personID = try person.requireID()
                let old = try await app.db.transaction { db -> WorkspaceWorkController.Page in
                    let scope = try await WorkspaceReadScope.load(workspaceID: companyID, actorID: personID, on: db)
                    let window = try SnagRegisterService.calendarWindow(identifier: scope.team.timezone, now: Date())
                    var candidates = scope.readable
                    if let only { candidates = candidates.filter { $0.project.id == only } }
                    if queue == "review" { candidates = candidates.filter { $0.actions.contains(.review) } }
                    let unavailable = try candidates.filter { !$0.project.platformManaged }.map { WorkspaceWorkController.Unavailable(projectId: try $0.project.requireID(), reason: "project_import_required") }
                    let order = try candidates.filter { $0.project.platformManaged }
                        .sorted { ($0.project.name.lowercased(), $0.project.id!.uuidString) < ($1.project.name.lowercased(), $1.project.id!.uuidString) }
                        .map { try $0.project.requireID() }
                    return try await Self.legacyWorkspacePage(f, queue: queue, workspaceID: companyID, order: order, unavailable: unavailable, today: window.today, nextWeek: window.nextWeek, on: db)
                }
                XCTAssertEqual(try json(new), try json(canonical(old)), "\(person.name ?? "?"): \(q)")
                sawEvidence = sawEvidence || !new.evidence.isEmpty
            }
        }
        XCTAssertTrue(sawEvidence)
    }
    func testWorkSummaryReadsPreparedLinksInTheSameStatementWithTheSameCounts() async throws {
        let owner = try await user("owner"), member = try await user("member")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Prepared Links Ltd", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID(), ownerID = try owner.requireID()
        try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: member.requireID(), role: "member", on: db) }
        let p1 = try await project(owner, workspace: companyID, name: "Links · Plot 1")
        let p2 = try await project(owner, workspace: companyID, name: "Links · Plot 2")
        let p3 = try await project(owner, workspace: companyID, name: "Links · Plot 3")
        let oak = try await contractor(owner, workspace: companyID, project: p1, name: "Oak Glazing")
        try await populate(owner, p1, contractors: [oak], count: 14, seed: 5)
        try await populate(owner, p2, contractors: [oak], count: 6, seed: 6)
        try await sql("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: p2.project.id), \(bind: companyID), \(bind: member.requireID()), 'member')")
        func link(_ envelope: PlatformProjectResponse, state: String, expiresInDays: Double) async throws {
            try await sql("""
                INSERT INTO link_grants (id, workspace_id, project_id, creator_id, mode, state, revision, duration_days, created_at, expires_at, revoked_at)
                VALUES (\(bind: UUID()), \(bind: companyID), \(bind: envelope.project.id), \(bind: ownerID), 'read_only', \(bind: state), 1, 14, NOW(),
                        NOW() + \(bind: "\(Int(expiresInDays * 24)) hours")::interval, \(bind: state == "revoked" ? Optional(Date()) : nil))
                """)
        }
        try await link(p1, state: "prepared", expiresInDays: 3); try await link(p1, state: "prepared", expiresInDays: 10)
        try await link(p1, state: "prepared", expiresInDays: -1); try await link(p1, state: "revoked", expiresInDays: 5)
        try await link(p2, state: "prepared", expiresInDays: 1)
        let ids = [p1.project.id, p2.project.id, p3.project.id]
        let window = try SnagRegisterService.calendarWindow(identifier: company.timezone, now: Date())
        for sharing in [ids, [p2.project.id], []] {
            let (combined, prepared) = try await SnagRegisterService.summariesAndPreparedLinks(projectIDs: ids, sharing: sharing, today: window.today, nextWeek: window.nextWeek, on: app.db)
            let reference = try await SnagRegisterService.summaries(projectIDs: ids, archived: false, today: window.today, nextWeek: window.nextWeek, on: app.db)
            var expected: [UUID: Int] = [:]
            if !sharing.isEmpty {
                for row in try await VerifiedIdentityService.sql(app.db).raw("""
                    SELECT project_id, count(*) AS n FROM link_grants
                    WHERE project_id = ANY(\(bind: sharing)) AND state = 'prepared' AND expires_at > now() GROUP BY project_id
                    """).all() { expected[try row.decode(column: "project_id", as: UUID.self)] = try row.decode(column: "n", as: Int.self) }
            }
            XCTAssertEqual(prepared, expected, "sharing \(sharing.count)")
            for id in ids {
                let a = combined[id]!, b = reference[id]!
                XCTAssertEqual(try json(a.summary), try json(b.summary))
                XCTAssertEqual([a.unassignedOpen, a.changesRequested, a.dueNext7, a.dueNext7Closed], [b.unassignedOpen, b.changesRequested, b.dueNext7, b.dueNext7Closed])
            }
        }
        let all = try await SnagRegisterService.summariesAndPreparedLinks(projectIDs: ids, sharing: ids, today: window.today, nextWeek: window.nextWeek, on: app.db)
        XCTAssertEqual(all.prepared, [p1.project.id: 2, p2.project.id: 1], "expired and revoked links are not counted")
        // Through HTTP: the owner may share (counted), a project Member may not (absent).
        let response = try await request(.GET, "api/v2/workspaces/\(companyID)/work-summary", user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let summary = try response.content.decode(WorkspaceWorkController.Summary.self)
        XCTAssertEqual(summary.projects.first { $0.projectId == p1.project.id }?.preparedLinks, 2)
        XCTAssertEqual(summary.projects.first { $0.projectId == p3.project.id }?.preparedLinks, 0)
        XCTAssertEqual(summary.totals.preparedLinks, 3)
        let memberView = try await request(.GET, "api/v2/workspaces/\(companyID)/work-summary", user: member).content.decode(WorkspaceWorkController.Summary.self)
        XCTAssertEqual(memberView.projects.map(\.projectId), [p2.project.id]); XCTAssertNil(memberView.projects.first?.preparedLinks)
    }
}
