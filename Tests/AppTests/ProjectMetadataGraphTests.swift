@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class ProjectMetadataGraphTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Pinned synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("metadata-\(UUID())@example.test", name: "Synthetic manager", on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User?, body: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        let jwt = try user.map { try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: $0.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: $0.requireID())) }
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if method != .GET { req.headers.contentType = .json; req.body = .init(data: bytes) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func metadata() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func project(_ owner: User, company: Bool = false, fields: [String: Any] = [:]) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: owner.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
        }
        var values: [String: Any] = ["id": UUID().uuidString, "name": "Willow Mews · Plot 8", "reference": "WM08"]
        values.merge(fields) { _, new in new }
        let response = try await request(.POST, "api/v2/projects", user: owner, body: ["mutation": metadata(), "workspaceId": try workspace.requireID().uuidString, "project": values])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }
    private func snag(_ owner: User, project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "fields": ["title": "Seal shower tray"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func snapshot(_ owner: User, project: PlatformProjectResponse) async throws -> RegisterSnapshotPage {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/register-snapshots", user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(RegisterSnapshotPage.self)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: PlatformJSON) throws -> T { try PlatformMutationService.decode(type, PlatformMutationService.encode(value)) }

    func testNewProjectRoundTripsExplicitDatesCustomTypeAndImmutableSnapshot() async throws {
        let owner = try await user(), project = try await project(owner, fields: ["customProjectType": "Listed cottage refurbishment", "startOn": "2026-10-25", "expectedEndOn": "2027-03-28"])
        XCTAssertEqual(project.project.customProjectType, "Listed cottage refurbishment")
        XCTAssertEqual(project.canonical?.startOn, "2026-10-25"); XCTAssertEqual(project.canonical?.expectedEndOn, "2027-03-28")
        let row = try await Project.find(project.project.id, on: app.db)!
        let zone = try await CanonicalValueService.timezone(row, on: app.db)
        XCTAssertEqual(CanonicalValueService.dateFormatter(timezone: zone).string(from: row.startDate!), "2026-10-25")
        let first = try await snapshot(owner, project: project)
        XCTAssertTrue(first.coverage.contains("projectMetadataV2")); XCTAssertTrue(first.coverage.contains("assignmentHistory"))
        let response = try await request(.PATCH, "api/v2/projects/\(project.project.id)", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["customProjectType": "Roof and loft refurbishment"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let repeated = try await request(.GET, "api/v2/projects/\(project.project.id)/register-snapshots?snapshot=\(first.snapshotToken)&offset=0", user: owner)
        let retained = try repeated.content.decode(RegisterSnapshotPage.self)
        let old = try decode(PlatformProjectResponse.self, retained.items.first { $0.type == "project" }!.data)
        XCTAssertEqual(old.project.customProjectType, "Listed cottage refurbishment"); XCTAssertEqual(old.revision, 1)
        let delta = try await request(.GET, "api/v2/projects/\(project.project.id)/changes?cursor=\(first.changesCursor!)", user: owner)
        let page = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(page.coverage, first.coverage); XCTAssertEqual(page.changes.count, 1)
        let changed = try decode(PlatformProjectResponse.self, page.changes[0].data)
        XCTAssertEqual(changed.project.customProjectType, "Roof and loft refurbishment"); XCTAssertEqual(changed.revision, 2)
        XCTAssertEqual(changed.canonical?.startOn, "2026-10-25")
    }

    func testLegacyInstantsArePreservedWithoutInventingCalendarIntent() async throws {
        let owner = try await user(), project = try await project(owner, fields: ["startDate": "2026-09-10T23:30:00Z", "expectedEndDate": "2026-09-20T06:45:00Z"])
        XCTAssertEqual(project.project.startDate, ISO8601DateFormatter().date(from: "2026-09-10T23:30:00Z"))
        XCTAssertNil(project.canonical?.startOn); XCTAssertNil(project.canonical?.expectedEndOn)
        let row = try await Project.find(project.project.id, on: app.db)!
        XCTAssertEqual(row.startDate, project.project.startDate); XCTAssertNil(row.startOn)
        let response = try await request(.PATCH, "api/v2/projects/\(project.project.id)", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["startOn": "2026-09-11"]])
        XCTAssertEqual(response.status, .ok)
        let explicit = try response.content.decode(PlatformProjectResponse.self)
        XCTAssertEqual(explicit.canonical?.startOn, "2026-09-11"); XCTAssertNil(explicit.canonical?.expectedEndOn)
        XCTAssertEqual(explicit.project.expectedEndDate, project.project.expectedEndDate)
    }

    func testProjectPatchConcurrentReplayClearAndStaleConflictDoNotLoseOtherFields() async throws {
        let owner = try await user(), project = try await project(owner, fields: ["startOn": "2026-09-10", "expectedEndOn": "2026-09-20", "notes": "Retain access via side gate", "customProjectType": "Refurbishment"])
        let path = "api/v2/projects/\(project.project.id)"
        let body: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "fields": ["startOn": NSNull(), "customProjectType": NSNull()]]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask {
                let response = try await self.request(.PATCH, path, user: owner, body: body)
                XCTAssertEqual(response.status, .ok, response.body.string)
                let value = try response.content.decode(PlatformProjectResponse.self)
                XCTAssertEqual(value.revision, 2); XCTAssertNil(value.project.customProjectType); XCTAssertNil(value.canonical?.startOn); XCTAssertNil(value.project.startDate)
            } }
            try await group.waitForAll()
        }
        let row = try await Project.find(project.project.id, on: app.db)!
        XCTAssertEqual(row.notes, "Retain access via side gate"); XCTAssertEqual(row.expectedEndOn, "2026-09-20"); XCTAssertEqual(row.revision, 2)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_type = 'project' AND entity_id = \(bind: project.project.id) AND kind = 'updated'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
        var different = body; different["fields"] = ["notes": "Different operation"]
        let reused = try await request(.PATCH, path, user: owner, body: different)
        XCTAssertEqual(reused.status, .conflict); XCTAssertTrue(reused.body.string.contains("operation_reused"))
        let stale = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["notes": "Stale draft"]])
        XCTAssertEqual(stale.status, .conflict)
        let conflict = try stale.content.decode(ProjectRevisionConflict.Body.self)
        XCTAssertEqual(conflict.current.revision, 2); XCTAssertEqual(Set(conflict.changedFields), ["startOn", "startDate", "customProjectType"])
    }

    func testProjectPatchRejectsInvalidDatesCoordinatesAndProtectedFieldsAtomically() async throws {
        let owner = try await user(), project = try await project(owner, fields: ["startOn": "2026-10-10", "expectedEndOn": "2026-10-20"])
        let path = "api/v2/projects/\(project.project.id)"
        let invalid: [[String: Any]] = [["startOn": "2026-02-30"], ["startOn": "2026-10-21"], ["startDate": "2026-10-10"], ["startDate": "2026-10-10T01:00:00Z", "startOn": "2026-10-10"], ["latitude": 91], ["longitude": -181], ["name": NSNull()], ["customProjectType": String(repeating: "x", count: 201)]]
        for fields in invalid {
            let response = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": fields])
            XCTAssertEqual(response.status, .badRequest, response.body.string)
        }
        for key in ["ownerId", "workspaceId", "teamId", "status", "archivedAt", "platformManaged", "coverImagePath", "isFavorite"] {
            let response = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["notes": "Must roll back", key: "forged"]])
            XCTAssertEqual(response.status, .badRequest, key)
        }
        let row = try await Project.find(project.project.id, on: app.db)!
        XCTAssertEqual(row.revision, 1); XCTAssertNil(row.notes); XCTAssertEqual(row.startOn, "2026-10-10")
    }

    func testProjectManagerCanEditButMemberStrangerRemovedAndArchivedCannotReplay() async throws {
        let owner = try await user(), manager = try await user(), member = try await user(), stranger = try await user(), project = try await project(owner, company: true)
        try await join(manager, owner: owner, project: project, role: "manager"); try await join(member, owner: owner, project: project, role: "member")
        let path = "api/v2/projects/\(project.project.id)", body: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "fields": ["notes": "Site manager update"]]
        let unauth = try await request(.PATCH, path, user: nil, body: body); XCTAssertEqual(unauth.status, .unauthorized)
        let denied = try await request(.PATCH, path, user: member, body: body); XCTAssertEqual(denied.status, .forbidden)
        let hidden = try await request(.PATCH, path, user: stranger, body: body); XCTAssertEqual(hidden.status, .notFound); XCTAssertFalse(hidden.body.string.contains("Willow"))
        let permitted = try await request(.PATCH, path, user: manager, body: body); XCTAssertEqual(permitted.status, .ok, permitted.body.string)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: manager.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let removed = try await request(.PATCH, path, user: manager, body: body); XCTAssertEqual(removed.status, .notFound); XCTAssertFalse(removed.body.string.contains("Site manager"))
        let ownerBody: [String: Any] = ["mutation": metadata(), "expectedRevision": 2, "fields": ["notes": "Owner update"]]
        let edited = try await request(.PATCH, path, user: owner, body: ownerBody); XCTAssertEqual(edited.status, .ok)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId, on: db)
            let row = try await Project.find(project.project.id, on: db)!; row.archivedAt = Date(); try await row.save(on: db)
        }
        let archived = try await request(.PATCH, path, user: owner, body: ownerBody); XCTAssertEqual(archived.status, .gone); XCTAssertFalse(archived.body.string.contains("Owner update"))
    }

    func testProjectCreateAndEditReceiptsRecheckCurrentAuthorityAndKeepHistoricalPayload() async throws {
        let owner = try await user(), successor = try await user()
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Builders", actorID: owner.requireID(), on: db) }
        let workspaceID = try workspace.requireID(), id = UUID(), mutation = metadata()
        let body: [String: Any] = ["mutation": mutation, "workspaceId": workspaceID.uuidString, "project": ["id": id.uuidString, "name": "Original project", "reference": "ORG"]]
        let created = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(created.status, .ok)
        let project = try created.content.decode(PlatformProjectResponse.self)
        try await join(successor, owner: owner, project: project, role: "manager")
        let editBody: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "fields": ["name": "Updated project"]]
        let edited = try await request(.PATCH, "api/v2/projects/\(id)", user: owner, body: editBody); XCTAssertEqual(edited.status, .ok)
        let sql = try VerifiedIdentityService.sql(app.db), operation = UUID(uuidString: mutation["operationId"] as! String)!
        let originalReceipt = try await sql.raw("SELECT result_json FROM mutation_receipts WHERE actor_id = \(bind: owner.requireID()) AND operation_id = \(bind: operation)").first()!.decode(column: "result_json", as: String.self)
        try await app.db.transaction { db in
            let current = try await Team.find(workspaceID, on: db)!
            try await WorkspaceAccessService.transferOwnership(workspaceID: workspaceID, targetID: successor.requireID(), expectedRevision: current.revision, actorID: owner.requireID(), on: db)
        }
        let replay = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(replay.status, .ok)
        let saved = try replay.content.decode(PlatformProjectResponse.self)
        XCTAssertEqual(saved.project.name, "Original project"); XCTAssertEqual(saved.revision, 1)
        XCTAssertTrue(saved.capabilities.contains("manageCompanyMembers")); XCTAssertFalse(saved.capabilities.contains("transferOwnership")); XCTAssertFalse(saved.capabilities.contains("closeCompany"))
        let editReplay = try await request(.PATCH, "api/v2/projects/\(id)", user: owner, body: editBody)
        let savedEdit = try editReplay.content.decode(PlatformProjectResponse.self)
        XCTAssertEqual(savedEdit.revision, 2); XCTAssertFalse(savedEdit.capabilities.contains("transferOwnership"))
        let retainedReceipt = try await sql.raw("SELECT result_json FROM mutation_receipts WHERE actor_id = \(bind: owner.requireID()) AND operation_id = \(bind: operation)").first()!.decode(column: "result_json", as: String.self)
        XCTAssertEqual(originalReceipt, retainedReceipt)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(workspaceID, on: db)
            let row = try await Project.find(id, on: db)!; row.archivedAt = Date(); try await row.save(on: db)
        }
        let archived = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(archived.status, .gone); XCTAssertFalse(archived.body.string.contains("Original project"))
        try await app.db.transaction { db in
            let revision = try await VerifiedIdentityService.sql(db).raw("SELECT revision FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: owner.requireID())").first()!.decode(column: "revision", as: Int64.self)
            try await WorkspaceAccessService.changeMember(workspaceID: workspaceID, targetID: owner.requireID(), newRole: nil, expectedRevision: revision, actorID: successor.requireID(), on: db)
        }
        let removed = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(removed.status, .notFound); XCTAssertFalse(removed.body.string.contains("Original project"))
    }

    func testSharedProjectDeltaUsesReadersCapabilitiesNotOriginalWriters() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let first = try await snapshot(member, project: project)
        let edited = try await request(.PATCH, "api/v2/projects/\(project.project.id)", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["notes": "Shared site information"]])
        XCTAssertEqual(edited.status, .ok)
        let delta = try await request(.GET, "api/v2/projects/\(project.project.id)/changes?cursor=\(first.changesCursor!)", user: member)
        let changes = try delta.content.decode(ProjectChangePage.self)
        let response = try decode(PlatformProjectResponse.self, changes.changes.first { $0.type == "project" }!.data)
        XCTAssertEqual(Set(response.capabilities), ["read", "edit", "submitCompletion"])
        XCTAssertEqual(response.project.notes, "Shared site information")
    }

    func testAssignmentHistorySnapshotUsesHistoricalIDsAndRevisionsAndDeltasAreAtomic() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project)
        let base = "api/v2/projects/\(project.project.id)", path = base + "/snags/\(snag.snag.id)/assignment"
        // Explicit clearing is still an audited assignment action; no synthetic
        // contractor identities or inferred names are introduced by the graph.
        let first = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["tradeId": NSNull()]])
        XCTAssertEqual(first.status, .ok)
        let initial = try await snapshot(owner, project: project)
        let historical = try decode(AssignmentHistoryResponse.self, initial.items.first { $0.type == "assignmentHistory" }!.data)
        XCTAssertEqual(historical.snagRevision, 2); XCTAssertEqual(historical.actorUserId, owner.id); XCTAssertNil(historical.toTradeId)
        let body: [String: Any] = ["mutation": metadata(), "expectedRevision": 2, "fields": ["contractorId": NSNull()]]
        for _ in 0..<2 { let changed = try await request(.POST, path, user: owner, body: body); XCTAssertEqual(changed.status, .ok) }
        let delta = try await request(.GET, base + "/changes?cursor=\(initial.changesCursor!)", user: owner)
        let page = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(page.changes.count, 2); XCTAssertEqual(Set(page.changes.map(\.type)), ["snag", "assignmentHistory"]); XCTAssertEqual(Set(page.changes.map(\.transactionGroup)).count, 1)
        let event = page.changes.first { $0.type == "assignmentHistory" }!, second = try decode(AssignmentHistoryResponse.self, event.data)
        XCTAssertEqual(event.revision, 1); XCTAssertEqual(second.snagRevision, 3); XCTAssertNotEqual(second.id, historical.id)
        let final = try await snapshot(owner, project: project)
        let rows = try final.items.filter { $0.type == "assignmentHistory" }.map { try decode(AssignmentHistoryResponse.self, $0.data) }
        XCTAssertEqual(rows.map(\.id), [historical.id, second.id]); XCTAssertEqual(rows.map(\.snagRevision), [2, 3])
        let stale = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 2, "fields": ["tradeId": NSNull()]])
        XCTAssertEqual(stale.status, .conflict)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM assignment_history WHERE snag_id = \(bind: snag.snag.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 2)
    }

    func testAddedCoverageNeverRetrofillsOldSnapshotsOrCursorsAndRevocationReturnsNoHistory() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true), snag = try await snag(owner, project: project)
        try await join(member, owner: owner, project: project, role: "member")
        let first = try await snapshot(member, project: project), base = "api/v2/projects/\(project.project.id)"
        let oldCoverage = ["project", "snags"]
        // Persisted pre-upgrade cursor/manifest fixture; not a current-client API mutation.
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE register_snapshots SET coverage = \(bind: oldCoverage) WHERE actor_id = \(bind: member.requireID()) AND project_id = \(bind: project.project.id)").run()
        try await sql.raw("UPDATE project_change_cursors SET coverage = \(bind: oldCoverage) WHERE actor_id = \(bind: member.requireID()) AND project_id = \(bind: project.project.id)").run()
        let assignment = try await request(.POST, base + "/snags/\(snag.snag.id)/assignment", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["contractorId": NSNull()]])
        XCTAssertEqual(assignment.status, .ok)
        let saved = try await request(.GET, base + "/register-snapshots?snapshot=\(first.snapshotToken)&offset=0", user: member)
        XCTAssertEqual(try saved.content.decode(RegisterSnapshotPage.self).coverage, oldCoverage)
        let delta = try await request(.GET, base + "/changes?cursor=\(first.changesCursor!)", user: member)
        let page = try delta.content.decode(ProjectChangePage.self); XCTAssertEqual(page.coverage, oldCoverage)
        let following = try await request(.GET, base + "/changes?cursor=\(page.cursor)", user: member)
        XCTAssertEqual(try following.content.decode(ProjectChangePage.self).coverage, oldCoverage)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        for suffix in ["/register-snapshots?snapshot=\(first.snapshotToken)&offset=0", "/changes?cursor=\(page.cursor)"] {
            let denied = try await request(.GET, base + suffix, user: member)
            XCTAssertEqual(denied.status, .forbidden); XCTAssertFalse(denied.body.string.contains("assignmentHistory")); XCTAssertFalse(denied.body.string.contains("Willow"))
        }
    }

    func testAssignmentTransactionIsNotSplitAtDeltaPageBoundary() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project), first = try await snapshot(owner, project: project)
        // Pure ordering fixture puts the next real two-row assignment at the
        // 100th position. No customer/project contents are changed by these rows.
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            let high = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: project.workspaceId)").first()!.decode(column: "change_sequence", as: Int64.self)
            try await sql.raw("INSERT INTO platform_changes (workspace_id, sequence, project_id, entity_type, entity_id, revision, kind, changed_fields, payload_json, actor_id, created_at, transaction_group) SELECT \(bind: project.workspaceId), \(bind: high) + n, \(bind: project.project.id), 'orderingFixture', \(bind: UUID()), 1, 'created', '{}'::TEXT[], '{}', \(bind: owner.requireID()), NOW(), \(bind: UUID()) FROM generate_series(1,99) n").run()
            try await sql.raw("UPDATE teams SET change_sequence = change_sequence + 99 WHERE id = \(bind: project.workspaceId)").run()
        }
        let base = "api/v2/projects/\(project.project.id)"
        let assigned = try await request(.POST, base + "/snags/\(snag.snag.id)/assignment", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["tradeId": NSNull()]])
        XCTAssertEqual(assigned.status, .ok)
        let delta = try await request(.GET, base + "/changes?cursor=\(first.changesCursor!)", user: owner)
        let page = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(page.changes.count, 101); XCTAssertFalse(page.hasMore)
        let tail = Array(page.changes.suffix(2)); XCTAssertEqual(Set(tail.map(\.type)), ["snag", "assignmentHistory"]); XCTAssertEqual(Set(tail.map(\.transactionGroup)).count, 1)
        let after = try await request(.GET, base + "/changes?cursor=\(page.cursor)", user: owner)
        XCTAssertTrue(try after.content.decode(ProjectChangePage.self).changes.isEmpty)
    }

    func testAdditiveMigrationFreshPriorSchemaAndRerunPreserveRows() async throws {
        enum Rollback: Error { case complete }
        do {
            try await app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db), schema = "project_parity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                try await sql.raw("CREATE SCHEMA \(ident: schema)").run()
                try await sql.raw("SET LOCAL search_path TO \(ident: schema)").run()
                try await sql.raw("CREATE TABLE projects (id UUID PRIMARY KEY, name TEXT NOT NULL)").run()
                try await sql.raw("CREATE TABLE project_change_cursors (token_hash TEXT PRIMARY KEY)").run()
                try await sql.raw("CREATE TABLE assignment_history (id UUID PRIMARY KEY, project_id UUID, snag_id UUID, snag_revision BIGINT)").run()
                let id = UUID()
                try await sql.raw("INSERT INTO projects (id,name) VALUES (\(bind: id),'Preserved prior row')").run()
                try await sql.raw("INSERT INTO project_change_cursors (token_hash) VALUES ('prior-cursor')").run()
                try await CreateProjectMetadataParity().prepare(on: db)
                try await sql.raw("UPDATE projects SET custom_project_type = 'Preserved custom type', start_date = '2026-09-10T23:30:00Z'::TIMESTAMPTZ WHERE id = \(bind: id)").run()
                try await CreateProjectMetadataParity().prepare(on: db)
                let row = try await sql.raw("SELECT * FROM projects WHERE id = \(bind: id)").first()!
                XCTAssertEqual(try row.decode(column: "name", as: String.self), "Preserved prior row")
                XCTAssertEqual(try row.decode(column: "custom_project_type", as: String.self), "Preserved custom type")
                XCTAssertNil(try row.decode(column: "start_on", as: String?.self)); XCTAssertNotNil(try row.decode(column: "start_date", as: Date?.self))
                let cursor = try await sql.raw("SELECT coverage FROM project_change_cursors WHERE token_hash = 'prior-cursor'").first()!
                XCTAssertEqual(try cursor.decode(column: "coverage", as: [String].self), [])
                throw Rollback.complete
            }
        } catch Rollback.complete { }
        let owner = try await user(), project = try await project(owner, fields: ["customProjectType": "Existing row", "startOn": "2026-09-12"])
        try await CreateProjectMetadataParity().prepare(on: app.db)
        let stored = try await Project.find(project.project.id, on: app.db)!
        XCTAssertEqual(stored.customProjectType, "Existing row"); XCTAssertEqual(stored.startOn, "2026-09-12")
        do { try await CreateProjectMetadataParity().revert(on: app.db); XCTFail("Destructive rollback must be refused") }
        catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }
}
