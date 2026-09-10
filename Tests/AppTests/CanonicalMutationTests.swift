@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CanonicalMutationTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("canonical-\(UUID())@example.test", name: "Synthetic manager", on: db) }
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
    private func metadata(_ operation: UUID = UUID(), device: UUID = UUID()) -> [String: Any] { ["operationId": operation.uuidString, "deviceId": device.uuidString] }
    private func project(_ owner: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Willow Construction", actorID: owner.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
        }
        let body: [String: Any] = ["mutation": metadata(), "workspaceId": try workspace.requireID().uuidString,
                                   "project": ["id": UUID().uuidString, "name": "Willow Mews · Plot 3", "reference": "WM03", "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, project: PlatformProjectResponse, fields: [String: Any] = ["title": "Seal gap at shower tray", "location": "Plot 3 · First floor · Ensuite"]) async throws -> PlatformSnagResponse {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
                                         body: ["mutation": metadata(), "id": UUID().uuidString, "fields": fields])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }

    func testConcurrentCreateReplayProducesOneSnagOneReferenceAndOneChange() async throws {
        let owner = try await user(), project = try await project(owner), id = UUID()
        let body: [String: Any] = ["mutation": metadata(), "id": id.uuidString, "fields": ["title": "Touch up kitchen reveal"]]
        let path = "api/v2/projects/\(project.project.id)/snags"
        var results: [PlatformSnagResponse] = []
        try await withThrowingTaskGroup(of: PlatformSnagResponse.self) { group in
            for _ in 0..<6 { group.addTask {
                let response = try await self.request(.POST, path, user: owner, body: body)
                XCTAssertEqual(response.status, .ok, response.body.string)
                return try response.content.decode(PlatformSnagResponse.self)
            } }
            for try await value in group { results.append(value) }
        }
        XCTAssertEqual(Set(results.map { $0.snag.id }), [id]); XCTAssertEqual(Set(results.map { $0.snag.reference }), ["SL1"])
        let count = try await Snag.query(on: app.db).filter(\.$projectId == project.project.id).count()
        let events = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_id = \(bind: id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1); XCTAssertEqual(events, 1)
        let second = try await snag(owner, project: project); XCTAssertEqual(second.displayNumber, 2)
    }
    func testReusingOperationWithDifferentPayloadFailsAndDoesNotEdit() async throws {
        let owner = try await user(), project = try await project(owner), metadata = metadata(), id = UUID()
        var body: [String: Any] = ["mutation": metadata, "id": id.uuidString, "fields": ["title": "Original description"]]
        let path = "api/v2/projects/\(project.project.id)/snags"
        let first = try await request(.POST, path, user: owner, body: body); XCTAssertEqual(first.status, .ok)
        body["fields"] = ["title": "Different work"]
        let replay = try await request(.POST, path, user: owner, body: body)
        XCTAssertEqual(replay.status, .conflict); XCTAssertTrue(replay.body.string.contains("operation_reused"))
        let stored = try await Snag.find(id, on: app.db); XCTAssertEqual(stored?.title, "Original description")
    }
    func testExplicitNullClearsButOmittedFieldsStayAndStaleDraftConflicts() async throws {
        let owner = try await user(), project = try await project(owner)
        let initial = try await snag(owner, project: project, fields: ["title": "Kitchen reveal", "description": "Finish is uneven", "location": "Kitchen", "dueDate": "2026-09-20T09:00:00Z", "actualCost": 25])
        let path = "api/v2/projects/\(project.project.id)/snags/\(initial.snag.id)"
        let response = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1,
                                                                          "fields": ["description": NSNull(), "dueDate": NSNull(), "actualCost": NSNull()]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let changed = try response.content.decode(PlatformSnagResponse.self)
        XCTAssertNil(changed.snag.description); XCTAssertNil(changed.snag.dueDate); XCTAssertNil(changed.snag.actualCost)
        XCTAssertEqual(changed.snag.location, "Kitchen"); XCTAssertEqual(changed.revision, 2)
        let stale = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["location": "Old offline location"]])
        XCTAssertEqual(stale.status, .conflict, stale.body.string)
        let conflict = try stale.content.decode(RevisionConflict.Body.self)
        XCTAssertEqual(conflict.current.revision, 2); XCTAssertEqual(Set(conflict.changedFields), ["description", "dueDate", "actualCost"])
        let stored = try await Snag.find(initial.snag.id, on: app.db); XCTAssertEqual(stored?.location, "Kitchen")
    }
    func testCompetingEditsReturnOneSuccessAndOneConflict() async throws {
        let owner = try await user(), project = try await project(owner), initial = try await snag(owner, project: project)
        let path = "api/v2/projects/\(project.project.id)/snags/\(initial.snag.id)"
        var statuses: [HTTPResponseStatus] = []
        try await withThrowingTaskGroup(of: HTTPResponseStatus.self) { group in
            for title in ["First update", "Second update"] { group.addTask {
                try await self.request(.PATCH, path, user: owner, body: ["mutation": self.metadata(), "expectedRevision": 1, "fields": ["title": title]]).status
            } }
            for try await status in group { statuses.append(status) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1); XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1)
        let stored = try await Snag.find(initial.snag.id, on: app.db); XCTAssertEqual(stored?.revision, 2)
    }
    func testGenericPatchCannotCloseAssignOrChangeOwnership() async throws {
        let owner = try await user(), project = try await project(owner), initial = try await snag(owner, project: project)
        for field in ["status", "closedAt", "ownerId", "contractorId", "projectId", "reference", "drawingId", "photoURLs"] {
            let response = try await request(.PATCH, "api/v2/projects/\(project.project.id)/snags/\(initial.snag.id)", user: owner,
                                             body: ["mutation": metadata(), "expectedRevision": 1, "fields": [field: "forged"]])
            XCTAssertEqual(response.status, .badRequest, field + response.body.string)
        }
        let stored = try await Snag.find(initial.snag.id, on: app.db); XCTAssertEqual(stored?.revision, 1); XCTAssertEqual(stored?.status, "open")
    }
    func testCrossProjectAndGuessedIDsDoNotExposeOrReassignRecords() async throws {
        let owner = try await user(), stranger = try await user(), own = try await project(owner), other = try await project(stranger), initial = try await snag(stranger, project: other)
        let get = try await request(.GET, "api/v2/projects/\(other.project.id)/snags/\(initial.snag.id)", user: owner)
        XCTAssertEqual(get.status, .notFound)
        let wrongProject = try await request(.GET, "api/v2/projects/\(own.project.id)/snags/\(initial.snag.id)", user: owner)
        XCTAssertEqual(wrongProject.status, .notFound)
        let collision = try await request(.POST, "api/v2/projects/\(own.project.id)/snags", user: owner, body: ["mutation": metadata(), "id": initial.snag.id.uuidString, "fields": ["title": "Collision"]])
        XCTAssertEqual(collision.status, .conflict); XCTAssertFalse(collision.body.string.contains("shower"))
        let stored = try await Snag.find(initial.snag.id, on: app.db); XCTAssertEqual(stored?.projectId, other.project.id)
    }
    func testArchiveAndRestoreRetainClosureHistoryAndPreventStaleResurrection() async throws {
        let owner = try await user(), project = try await project(owner), initial = try await snag(owner, project: project)
        // Historical accepted closure fixture. The generic command is not used to close it.
        let record = try await Snag.find(initial.snag.id, on: app.db)!
        record.status = "closed"; record.closedAt = Date(); record.publishedAt = Date(); try await record.save(on: app.db)
        let path = "api/v2/projects/\(project.project.id)/snags/\(initial.snag.id)"
        let body: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "reason": "Duplicate raised during inspection"]
        let archive = try await request(.POST, path + "/archive", user: owner, body: body)
        XCTAssertEqual(archive.status, .ok, archive.body.string)
        let archived = try archive.content.decode(PlatformSnagResponse.self)
        XCTAssertNotNil(archived.archivedAt); XCTAssertNotNil(archived.snag.closedAt); XCTAssertEqual(archived.snag.status, "closed")
        let retry = try await request(.POST, path + "/archive", user: owner, body: body)
        XCTAssertEqual(retry.status, .ok); XCTAssertEqual(try retry.content.decode(PlatformSnagResponse.self).revision, 2)
        let stale = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["title": "Stale"]])
        XCTAssertEqual(stale.status, .conflict)
        let blocked = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 2, "fields": ["title": "Revived"]])
        XCTAssertEqual(blocked.status, .gone)
        let restore = try await request(.POST, path + "/restore", user: owner, body: ["mutation": metadata(), "expectedRevision": 2, "reason": "Distinct snag confirmed on site"])
        XCTAssertEqual(restore.status, .ok)
        let restored = try restore.content.decode(PlatformSnagResponse.self)
        XCTAssertNil(restored.archivedAt); XCTAssertEqual(restored.snag.id, initial.snag.id); XCTAssertEqual(restored.snag.reference, initial.snag.reference)
        XCTAssertEqual(restored.snag.status, "closed"); XCTAssertNotNil(restored.snag.closedAt)
    }
    func testContributorCanDiscardOwnDraftButCannotArchiveLoggedSnag() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let draft = try await snag(member, project: project)
        let path = "api/v2/projects/\(project.project.id)/snags/\(draft.snag.id)"
        let discard = try await request(.POST, path + "/archive", user: member, body: ["mutation": metadata(), "expectedRevision": 1, "reason": "Accidental draft"])
        XCTAssertEqual(discard.status, .ok, discard.body.string)
        let logged = try await snag(member, project: project), loggedPath = "api/v2/projects/\(project.project.id)/snags/\(logged.snag.id)"
        let publish = try await request(.POST, loggedPath + "/publish", user: member, body: ["mutation": metadata(), "expectedRevision": 1])
        XCTAssertEqual(publish.status, .ok)
        let denied = try await request(.POST, loggedPath + "/archive", user: member, body: ["mutation": metadata(), "expectedRevision": 2, "reason": "Try to erase"])
        XCTAssertEqual(denied.status, .forbidden)
    }
    func testRemovedMemberCannotReplaySuccessfulMutationReceipt() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let body: [String: Any] = ["mutation": metadata(), "id": UUID().uuidString, "fields": ["title": "Fix threshold"]]
        let path = "api/v2/projects/\(project.project.id)/snags"
        let first = try await request(.POST, path, user: member, body: body); XCTAssertEqual(first.status, .ok)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let replay = try await request(.POST, path, user: member, body: body)
        XCTAssertEqual(replay.status, .notFound); XCTAssertFalse(replay.body.string.contains("threshold"))
    }
    func testNewPersonalProjectsRejectLegacySnapshotAndRevisionlessWrites() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project)
        let update = try await request(.PATCH, "api/v1/snags/\(snag.snag.id)", user: owner, body: ["title": "Legacy bypass"])
        XCTAssertEqual(update.status, .notFound)
        let oldProject = try await request(.GET, "api/v1/projects/\(project.project.id)", user: owner)
        XCTAssertEqual(oldProject.status, .notFound)
        do {
            try await LegacyProjectAccess.requireAvailable(projectID: project.project.id, ownerID: owner.requireID(), on: app.db)
            XCTFail("Managed personal projects must reject old snapshots too")
        } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }
    func testSnapshotPaginationKeepsOriginalRowsAndDeltasCatchInterveningWrites() async throws {
        let owner = try await user(), project = try await project(owner), actorID = try owner.requireID()
        var records: [PlatformSnagResponse] = []
        // Exercise normal canonical services; this is algorithm coverage, not an iOS capture claim.
        records = try await app.db.transaction { db in
            let (p, _) = try await ProjectAccessService.require(.edit, projectID: project.project.id, actorID: actorID, on: db)
            var result: [PlatformSnagResponse] = []
            for index in 1...101 {
                result.append(try await PlatformSnagService.create(.init(mutation: .init(operationId: UUID(), deviceId: UUID()), id: UUID(), fields: ["title": .string("Plot inspection item \(index)")]), project: p, actorID: actorID, on: db))
            }
            return result
        }
        let path = "api/v2/projects/\(project.project.id)"
        let start = try await request(.POST, path + "/register-snapshots", user: owner)
        XCTAssertEqual(start.status, .ok, start.body.string)
        let first = try start.content.decode(RegisterSnapshotPage.self)
        XCTAssertEqual(first.total, 102); XCTAssertEqual(first.items.count, 100); XCTAssertNil(first.changesCursor)
        XCTAssertEqual(first.coverage, ["project", "snags", "contractors", "trades", "attachedMedia"])
        let last = records.last!
        let update = try await request(.PATCH, path + "/snags/\(last.snag.id)", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["title": "Changed while download was open"]])
        XCTAssertEqual(update.status, .ok)
        let new = try await snag(owner, project: project)
        let page = try await request(.GET, path + "/register-snapshots?snapshot=\(first.snapshotToken)&offset=100", user: owner)
        XCTAssertEqual(page.status, .ok, page.body.string)
        let final = try page.content.decode(RegisterSnapshotPage.self)
        XCTAssertEqual(final.items.count, 2); XCTAssertNil(final.nextOffset)
        let downloaded = try final.items.map { try PlatformMutationService.decode(PlatformSnagResponse.self, PlatformMutationService.encode($0.data)) }
        XCTAssertEqual(downloaded.last?.snag.title, "Plot inspection item 101")
        XCTAssertFalse(final.items.contains { $0.id == new.snag.id })
        XCTAssertEqual(Set((first.items + final.items).map(\.id)).count, 102)
        let delta = try await request(.GET, path + "/changes?cursor=\(final.changesCursor!)", user: owner)
        XCTAssertEqual(delta.status, .ok, delta.body.string)
        let changes = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(Set(changes.changes.map(\.id)), [last.snag.id, new.snag.id]); XCTAssertFalse(changes.hasMore)
        let repeatPage = try await request(.GET, path + "/changes?cursor=\(final.changesCursor!)", user: owner)
        XCTAssertEqual(try repeatPage.content.decode(ProjectChangePage.self).changes.map(\.id), changes.changes.map(\.id))
        let idle = try await request(.GET, path + "/changes?cursor=\(changes.cursor)", user: owner)
        XCTAssertTrue(try idle.content.decode(ProjectChangePage.self).changes.isEmpty)
    }
    func testSnapshotAndCursorNeverBecomeBearerAccessAndRemovalReturnsNoContent() async throws {
        let owner = try await user(), member = try await user(), stranger = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        _ = try await snag(owner, project: project)
        let path = "api/v2/projects/\(project.project.id)"
        let response = try await request(.POST, path + "/register-snapshots", user: member)
        let snapshot = try response.content.decode(RegisterSnapshotPage.self)
        let copied = try await request(.GET, path + "/register-snapshots?snapshot=\(snapshot.snapshotToken)&offset=0", user: stranger)
        XCTAssertEqual(copied.status, .notFound); XCTAssertFalse(copied.body.string.contains("shower"))
        let copiedCursor = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: stranger)
        XCTAssertEqual(copiedCursor.status, .gone); XCTAssertFalse(copiedCursor.body.string.contains("shower"))
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        for suffix in ["/register-snapshots?snapshot=\(snapshot.snapshotToken)&offset=0", "/changes?cursor=\(snapshot.changesCursor!)"] {
            let revoked = try await request(.GET, path + suffix, user: member)
            XCTAssertEqual(revoked.status, .forbidden, revoked.body.string)
            XCTAssertTrue(revoked.body.string.contains("project_access_revoked")); XCTAssertFalse(revoked.body.string.contains("shower"))
        }
    }
    func testRejoinedMemberMustBootstrapInsteadOfUsingOldCursor() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let path = "api/v2/projects/\(project.project.id)"
        let start = try await request(.POST, path + "/register-snapshots", user: member)
        let snapshot = try start.content.decode(RegisterSnapshotPage.self)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        _ = try await snag(owner, project: project)
        try await join(member, owner: owner, project: project, role: "member")
        let old = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: member)
        XCTAssertEqual(old.status, .conflict); XCTAssertTrue(old.body.string.contains("rebootstrap_required"))
        let fresh = try await request(.POST, path + "/register-snapshots", user: member)
        XCTAssertEqual(fresh.status, .ok); XCTAssertEqual(try fresh.content.decode(RegisterSnapshotPage.self).total, 2)
    }
    func testExpiredCursorAndSnapshotRequestExplicitRebootstrap() async throws {
        let owner = try await user(), project = try await project(owner), path = "api/v2/projects/\(project.project.id)"
        let start = try await request(.POST, path + "/register-snapshots", user: owner)
        let snapshot = try start.content.decode(RegisterSnapshotPage.self)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE register_snapshots SET expires_at = NOW() - INTERVAL '1 minute' WHERE project_id = \(bind: project.project.id)").run()
        try await sql.raw("UPDATE project_change_cursors SET expires_at = NOW() - INTERVAL '1 minute' WHERE project_id = \(bind: project.project.id)").run()
        for suffix in ["/register-snapshots?snapshot=\(snapshot.snapshotToken)&offset=0", "/changes?cursor=\(snapshot.changesCursor!)"] {
            let expired = try await request(.GET, path + suffix, user: owner)
            XCTAssertEqual(expired.status, .gone); XCTAssertTrue(expired.body.string.contains("rebootstrap_required"))
        }
    }
    func testArchiveAppearsInDeltaAndEmptyFilteredListIsNotATombstone() async throws {
        let owner = try await user(), project = try await project(owner), initial = try await snag(owner, project: project), path = "api/v2/projects/\(project.project.id)"
        let start = try await request(.POST, path + "/register-snapshots", user: owner)
        let snapshot = try start.content.decode(RegisterSnapshotPage.self)
        let empty = try await request(.GET, path + "/snags?status=closed", user: owner)
        XCTAssertTrue(try empty.content.decode(PlatformSnagController.Page.self).items.isEmpty)
        let untouched = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: owner)
        XCTAssertTrue(try untouched.content.decode(ProjectChangePage.self).changes.isEmpty)
        let archive = try await request(.POST, path + "/snags/\(initial.snag.id)/archive", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "reason": "Duplicate"])
        XCTAssertEqual(archive.status, .ok)
        let delta = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: owner)
        let events = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(events.changes.count, 1); XCTAssertEqual(events.changes.first?.kind, "archived")
        let current = try PlatformMutationService.decode(PlatformSnagResponse.self, PlatformMutationService.encode(events.changes[0].data))
        XCTAssertNotNil(current.archivedAt); XCTAssertEqual(current.snag.id, initial.snag.id)
    }
    func testRolledBackChangeDoesNotAdvanceCommittedCursorOrLeaveReferenceGap() async throws {
        let owner = try await user(), project = try await project(owner), actorID = try owner.requireID()
        let path = "api/v2/projects/\(project.project.id)"
        let start = try await request(.POST, path + "/register-snapshots", user: owner)
        let snapshot = try start.content.decode(RegisterSnapshotPage.self), abandonedID = UUID()
        do {
            try await app.db.transaction { db in
                let (p, _) = try await ProjectAccessService.require(.edit, projectID: project.project.id, actorID: actorID, on: db)
                _ = try await PlatformSnagService.create(.init(mutation: .init(operationId: UUID(), deviceId: UUID()), id: abandonedID, fields: ["title": .string("Interrupted before commit")]), project: p, actorID: actorID, on: db)
                // A different connection cannot see the allocated-but-uncommitted change.
                let visible = try await VerifiedIdentityService.sql(self.app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_id = \(bind: abandonedID)").first()!.decode(column: "n", as: Int.self)
                XCTAssertEqual(visible, 0)
                throw Abort(.serviceUnavailable, reason: "Synthetic interruption")
            }
            XCTFail("Should roll back")
        } catch let error as Abort { XCTAssertEqual(error.status, .serviceUnavailable) }
        let saved = try await snag(owner, project: project); XCTAssertEqual(saved.displayNumber, 1)
        let delta = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: owner)
        let changes = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(changes.changes.map(\.id), [saved.snag.id]); XCTAssertFalse(changes.changes.contains { $0.id == abandonedID })
    }

    func testProjectMemberCannotSetDeadlineDuringCreateOrEdit() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let path = "api/v2/projects/\(project.project.id)/snags"
        let create = try await request(.POST, path, user: member, body: ["mutation": metadata(), "id": UUID().uuidString, "fields": ["title": "Fix threshold", "dueDate": "2026-09-21T09:00:00Z"]])
        XCTAssertEqual(create.status, .forbidden)
        let original = try await snag(owner, project: project, fields: ["title": "Fix threshold", "dueDate": "2026-09-21T09:00:00Z"])
        let edit = try await request(.PATCH, path + "/\(original.snag.id)", user: member, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["dueDate": NSNull()]])
        XCTAssertEqual(edit.status, .forbidden)
        let exact = try await request(.PATCH, path + "/\(original.snag.id)", user: member, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["dueOn": "2026-09-30"]])
        XCTAssertEqual(exact.status, .forbidden)
        let saved = try await Snag.find(original.snag.id, on: app.db); XCTAssertNotNil(saved?.dueDate); XCTAssertEqual(saved?.revision, 1)
    }

    private func directory(_ owner: User, project: PlatformProjectResponse, type: String, fields: [String: Any], id: UUID = UUID(), expected: Int = 0) async throws -> DirectoryResponse {
        let path = "api/v2/workspaces/\(project.workspaceId)/\(type)" + (expected == 0 ? "" : "/\(id)")
        let response = try await request(expected == 0 ? .POST : .PATCH, path, user: owner,
                                         body: ["mutation": metadata(), "id": id.uuidString, "expectedRevision": expected, "projectId": project.project.id.uuidString, "fields": fields])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(DirectoryResponse.self)
    }
    func testDirectoryUsesScopedRelationsAndPreservesExplicitClears() async throws {
        let owner = try await user(), project = try await project(owner, company: true)
        let trade = try await directory(owner, project: project, type: "trades", fields: ["name": "Joinery", "colorHex": "8D6E63"])
        let contractor = try await directory(owner, project: project, type: "contractors", fields: ["companyName": "Synthetic Joinery", "email": "joinery@example.test", "notes": "Access via site office", "tradeIds": [trade.id.uuidString]])
        let linked = try await VerifiedIdentityService.sql(app.db).raw("SELECT trade_id FROM contractor_trades WHERE contractor_id = \(bind: contractor.id)").all()
        XCTAssertEqual(try linked.map { try $0.decode(column: "trade_id", as: UUID.self) }, [trade.id])
        let clear = try await directory(owner, project: project, type: "contractors", fields: ["email": NSNull(), "tradeIds": []], id: contractor.id, expected: 1)
        let data = try PlatformMutationService.decode(ContractorResponse.self, PlatformMutationService.encode(clear.data))
        XCTAssertNil(data.email); XCTAssertTrue(data.tradeIds.isEmpty); XCTAssertEqual(data.notes, "Access via site office"); XCTAssertEqual(clear.revision, 2)
        let stale = try await request(.PATCH, "api/v2/workspaces/\(project.workspaceId)/contractors/\(contractor.id)", user: owner,
                                      body: ["mutation": metadata(), "id": contractor.id.uuidString, "expectedRevision": 1, "fields": ["companyName": "Old name"]])
        XCTAssertEqual(stale.status, .conflict); XCTAssertTrue(stale.body.string.contains("revision_conflict"))
    }
    func testManagerDirectoryAccessDoesNotGrantMemberWriteOrAnotherCompanyScope() async throws {
        let owner = try await user(), manager = try await user(), member = try await user(), project = try await project(owner, company: true), other = try await self.project(owner, company: true)
        try await join(manager, owner: owner, project: project, role: "manager")
        try await join(member, owner: owner, project: project, role: "member")
        let entry = try await directory(manager, project: project, type: "contractors", fields: ["companyName": "Manager added contractor"])
        let path = "api/v2/workspaces/\(project.workspaceId)/contractors"
        let read = try await request(.GET, path + "?projectId=\(project.project.id)", user: member)
        XCTAssertEqual(read.status, .ok)
        let denied = try await request(.PATCH, path + "/\(entry.id)", user: member, body: ["mutation": metadata(), "id": entry.id.uuidString, "expectedRevision": 1, "projectId": project.project.id.uuidString, "fields": ["notes": "Not permitted"]])
        XCTAssertEqual(denied.status, .forbidden)
        let cross = try await request(.GET, "api/v2/workspaces/\(other.workspaceId)/contractors?projectId=\(project.project.id)", user: owner)
        XCTAssertEqual(cross.status, .notFound)
    }
    func testCrossWorkspaceTradeAndAssignmentRejectedByServiceAndDatabase() async throws {
        let owner = try await user(), first = try await project(owner, company: true), second = try await project(owner, company: true)
        let foreignTrade = try await directory(owner, project: second, type: "trades", fields: ["name": "Electrical"])
        let foreignContractor = try await directory(owner, project: second, type: "contractors", fields: ["companyName": "Other company contractor"])
        let invalid = try await request(.POST, "api/v2/workspaces/\(first.workspaceId)/contractors", user: owner,
                                        body: ["mutation": metadata(), "id": UUID().uuidString, "expectedRevision": 0, "fields": ["companyName": "Bad relation", "tradeIds": [foreignTrade.id.uuidString]]])
        XCTAssertEqual(invalid.status, .badRequest)
        let snag = try await snag(owner, project: first)
        let assignment = try await request(.POST, "api/v2/projects/\(first.project.id)/snags/\(snag.snag.id)/assignment", user: owner,
                                           body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["contractorId": foreignContractor.id.uuidString]])
        XCTAssertEqual(assignment.status, .badRequest)
        do {
            try await app.db.transaction { db in try await VerifiedIdentityService.sql(db).raw("UPDATE snags SET contractor_id = \(bind: foreignContractor.id) WHERE id = \(bind: snag.snag.id)").run() }
            XCTFail("Database must reject cross-workspace assignment independently")
        } catch { /* Constraint rejection; never dump SQL/provider details. */ }
        let saved = try await Snag.find(snag.snag.id, on: app.db); XCTAssertNil(saved?.contractorId); XCTAssertEqual(saved?.revision, 1)
    }
    func testAssignmentClearAndRetryRetainOneHistoryPerOperation() async throws {
        let owner = try await user(), project = try await project(owner, company: true), snag = try await snag(owner, project: project)
        let contractor = try await directory(owner, project: project, type: "contractors", fields: ["companyName": "Synthetic Decorating"])
        let path = "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/assignment"
        let command: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "fields": ["contractorId": contractor.id.uuidString]]
        for _ in 0..<2 { let response = try await request(.POST, path, user: owner, body: command); XCTAssertEqual(response.status, .ok) }
        let clear = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 2, "fields": ["contractorId": NSNull()]])
        XCTAssertEqual(clear.status, .ok)
        let result = try clear.content.decode(PlatformSnagResponse.self)
        XCTAssertNil(result.snag.contractorId); XCTAssertNil(result.snag.assignedAt); XCTAssertEqual(result.revision, 3)
        let history = try await VerifiedIdentityService.sql(app.db).raw("SELECT from_contractor_id, to_contractor_id FROM assignment_history WHERE snag_id = \(bind: snag.snag.id) ORDER BY snag_revision").all()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try history[0].decode(column: "to_contractor_id", as: UUID?.self), contractor.id)
        XCTAssertEqual(try history[1].decode(column: "from_contractor_id", as: UUID?.self), contractor.id)
        XCTAssertNil(try history[1].decode(column: "to_contractor_id", as: UUID?.self))
    }
    func testWorkspaceDirectoryIncludedInSnapshotAndSubsequentChangesButNotLegacyLists() async throws {
        let owner = try await user(), project = try await project(owner)
        let trade = try await directory(owner, project: project, type: "trades", fields: ["name": "Plumbing"])
        let contractor = try await directory(owner, project: project, type: "contractors", fields: ["companyName": "Synthetic Plumbing", "tradeIds": [trade.id.uuidString]])
        let start = try await request(.POST, "api/v2/projects/\(project.project.id)/register-snapshots", user: owner)
        let snapshot = try start.content.decode(RegisterSnapshotPage.self)
        XCTAssertEqual(Set(snapshot.items.map(\.type)), ["project", "contractor", "trade"])
        _ = try await directory(owner, project: project, type: "contractors", fields: ["notes": "Site gate code shared separately"], id: contractor.id, expected: 1)
        let delta = try await request(.GET, "api/v2/projects/\(project.project.id)/changes?cursor=\(snapshot.changesCursor!)", user: owner)
        let changes = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(changes.changes.count, 1); XCTAssertEqual(changes.changes.first?.type, "contractor")
        let oldContractors = try await request(.GET, "api/v1/contractors", user: owner)
        let oldTrades = try await request(.GET, "api/v1/trades", user: owner)
        XCTAssertFalse(oldContractors.body.string.contains(contractor.id.uuidString)); XCTAssertFalse(oldTrades.body.string.contains(trade.id.uuidString))
    }


    func testExactCostsSurviveDatabaseResponseAndExplicitNullWithoutRounding() async throws {
        let owner = try await user(), project = try await project(owner)
        let initial = try await snag(owner, project: project, fields: ["title": "Make good oak threshold", "costEstimateDecimal": "1200.100001", "actualCostDecimal": "0", "dueOn": "2026-10-25"])
        XCTAssertEqual(initial.canonical?.costEstimateDecimal, "1200.100001")
        XCTAssertEqual(initial.canonical?.actualCostDecimal, "0")
        XCTAssertEqual(initial.canonical?.dueOn, "2026-10-25")
        let stored = try await Snag.find(initial.snag.id, on: app.db)
        XCTAssertEqual(stored?.costEstimateDecimal, Decimal(string: "1200.100001"))
        XCTAssertEqual(stored?.actualCostDecimal, Decimal.zero)
        let path = "api/v2/projects/\(project.project.id)/snags/\(initial.snag.id)"
        let result = try await request(.PATCH, path, user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["actualCostDecimal": NSNull(), "dueOn": NSNull()]])
        XCTAssertEqual(result.status, .ok, result.body.string)
        let updated = try result.content.decode(PlatformSnagResponse.self)
        XCTAssertNil(updated.canonical?.actualCostDecimal); XCTAssertNil(updated.snag.actualCost)
        XCTAssertNil(updated.canonical?.dueOn); XCTAssertNil(updated.snag.dueDate)
        XCTAssertEqual(updated.canonical?.costEstimateDecimal, "1200.100001")
    }
    func testInvalidOrAmbiguousExactValuesCannotConsumeReferenceOrCreateRecord() async throws {
        let owner = try await user(), project = try await project(owner)
        let cases: [[String: Any]] = [
            ["costEstimateDecimal": 12.25], ["costEstimateDecimal": "1.0000001"],
            ["actualCostDecimal": "1,200.50"], ["actualCostDecimal": "-1"],
            ["actualCostDecimal": "1000000000.000001"], ["actualCostDecimal": "NaN"],
            ["costEstimateDecimal": "1e3"], ["costEstimate": 1, "costEstimateDecimal": "1"],
            ["dueOn": "2026-02-29"], ["dueOn": "2026-04-31"],
            ["dueOn": "2026-10-25T00:00:00Z"], ["dueOn": "2026-01-01", "dueDate": NSNull()]
        ]
        for var fields in cases {
            fields["title"] = "Synthetic invalid value"
            let result = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
                body: ["mutation": metadata(), "id": UUID().uuidString, "fields": fields])
            XCTAssertEqual(result.status, .badRequest, result.body.string)
        }
        let valid = try await snag(owner, project: project, fields: ["title": "Valid leap-day deadline", "dueOn": "2028-02-29"])
        XCTAssertEqual(valid.displayNumber, 1); XCTAssertEqual(valid.canonical?.dueOn, "2028-02-29")
    }
    func testCandidateTimestampAdapterUsesWorkspaceCalendarAndDateOnlyNeverShifts() async throws {
        let owner = try await user(), project = try await project(owner)
        let timestamp = try await snag(owner, project: project, fields: ["title": "Late evening site inspection", "dueDate": "2026-03-29T23:30:00Z"])
        XCTAssertEqual(timestamp.canonical?.dueOn, "2026-03-30") // British Summer Time
        let calendar = try await snag(owner, project: project, fields: ["title": "Clock change day", "dueOn": "2026-03-29"])
        let response = try await request(.GET, "api/v2/projects/\(project.project.id)/snags/\(calendar.snag.id)", user: owner)
        XCTAssertEqual(try response.content.decode(PlatformSnagResponse.self).canonical?.dueOn, "2026-03-29")
    }
    func testDatabaseRejectsInvalidCalendarAndCostEvenWhenServiceIsBypassed() async throws {
        let owner = try await user(), project = try await project(owner), initial = try await snag(owner, project: project)
        for sqlValue in ["invalid-date", "2026-02-29"] {
            do {
                try await app.db.transaction { db in
                    try await VerifiedIdentityService.sql(db).raw("UPDATE snags SET due_on = \(bind: sqlValue) WHERE id = \(bind: initial.snag.id)").run()
                }
                XCTFail("Invalid calendar date reached storage")
            } catch {}
        }
        do {
            try await app.db.transaction { db in
                try await VerifiedIdentityService.sql(db).raw("UPDATE snags SET actual_cost_decimal = -1 WHERE id = \(bind: initial.snag.id)").run()
            }
            XCTFail("Negative cost reached storage")
        } catch {}
        let stored = try await Snag.find(initial.snag.id, on: app.db)
        XCTAssertNil(stored?.dueOn); XCTAssertNil(stored?.actualCostDecimal)
    }


    private func grantCommand(_ owner: User, project: PlatformProjectResponse, target: User, role: String?, revision: Int, operation: UUID = UUID(), device: UUID = UUID()) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v2/projects/\(project.project.id)/members", user: owner,
            body: ["mutation": metadata(operation, device: device), "userId": try target.requireID().uuidString,
                   "role": role as Any? ?? NSNull(), "expectedRevision": revision])
    }
    func testProjectRemovalBlocksReadsAndRegrantInvalidatesOldCursorEvenWithSameRole() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let path = "api/v2/projects/\(project.project.id)"
        let snapshotResult = try await request(.POST, path + "/register-snapshots", user: member)
        let snapshot = try snapshotResult.content.decode(RegisterSnapshotPage.self)
        let removed = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1)
        XCTAssertEqual(removed.status, .ok, removed.body.string)
        XCTAssertEqual(try removed.content.decode(ProjectGrantResponse.self).state, "removed")
        let denied = try await request(.GET, path, user: member); XCTAssertEqual(denied.status, .notFound)
        let delta = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: member)
        XCTAssertEqual(delta.status, .forbidden); XCTAssertTrue(delta.body.string.contains("project_access_revoked"))
        let list = try await request(.GET, "api/v2/projects?workspaceId=\(project.workspaceId)", user: member)
        XCTAssertEqual(try list.content.decode(PlatformProjectController.Page.self).items.count, 0)
        let restored = try await grantCommand(owner, project: project, target: member, role: "member", revision: 2)
        XCTAssertEqual(restored.status, .ok, restored.body.string)
        let oldCursor = try await request(.GET, path + "/changes?cursor=\(snapshot.changesCursor!)", user: member)
        XCTAssertEqual(oldCursor.status, .conflict); XCTAssertTrue(oldCursor.body.string.contains("rebootstrap_required"))
        let oldSnapshot = try await request(.GET, path + "/register-snapshots?snapshot=\(snapshot.snapshotToken)&offset=0", user: member)
        XCTAssertEqual(oldSnapshot.status, .conflict)
        let newSnapshot = try await request(.POST, path + "/register-snapshots", user: member)
        XCTAssertEqual(newSnapshot.status, .ok)
    }
    func testStaleGrantCannotUndoRemovalAndRetryDoesNotDuplicateAuthorityChange() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let operation = UUID(), device = UUID()
        let first = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1, operation: operation, device: device)
        let repeated = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1, operation: operation, device: device)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(repeated.status, .ok)
        XCTAssertEqual(try repeated.content.decode(ProjectGrantResponse.self).revision, 2)
        let stale = try await grantCommand(owner, project: project, target: member, role: "manager", revision: 1)
        XCTAssertEqual(stale.status, .conflict, stale.body.string)
        let conflict = try stale.content.decode(ProjectGrantConflict.Body.self)
        XCTAssertEqual(conflict.current.state, "removed"); XCTAssertEqual(conflict.current.revision, 2)
        let staleCreation = try await grantCommand(owner, project: project, target: member, role: "member", revision: 0)
        XCTAssertEqual(staleCreation.status, .conflict)
        let changedPayload = try await grantCommand(owner, project: project, target: member, role: "member", revision: 1, operation: operation, device: device)
        XCTAssertEqual(changedPayload.status, .conflict); XCTAssertTrue(changedPayload.body.string.contains("operation_reused"))
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM workspace_activity WHERE workspace_id = \(bind: project.workspaceId) AND action = 'project_access_removed'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
    }
    func testOnlyCompanyAdministratorCanRemoveProjectAccessAndMissingRoleCannotRemove() async throws {
        let owner = try await user(), manager = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(manager, owner: owner, project: project, role: "manager")
        try await join(member, owner: owner, project: project, role: "member")
        let denied = try await grantCommand(manager, project: project, target: member, role: nil, revision: 1)
        XCTAssertEqual(denied.status, .forbidden)
        let omitted = try await request(.POST, "api/v2/projects/\(project.project.id)/members", user: owner,
            body: ["mutation": metadata(), "userId": try member.requireID().uuidString, "expectedRevision": 1])
        XCTAssertEqual(omitted.status, .badRequest)
        let current = try await request(.GET, "api/v2/projects/\(project.project.id)", user: member)
        XCTAssertEqual(current.status, .ok)
        let rows = try await request(.GET, "api/v2/projects/\(project.project.id)/members", user: manager)
        XCTAssertEqual(rows.status, .ok)
        XCTAssertEqual(try rows.content.decode(WorkspaceController.ProjectMemberPage.self).items.count, 2)
        let privateRows = try await request(.GET, "api/v2/projects/\(project.project.id)/members", user: member)
        XCTAssertEqual(privateRows.status, .forbidden)
    }
    func testFreshMemberInvitationDoesNotResurrectFormerManagerPrivileges() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "manager")
        let removed = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1)
        XCTAssertEqual(removed.status, .ok)
        try await join(member, owner: owner, project: project, role: "member")
        let current = try await request(.GET, "api/v2/projects/\(project.project.id)", user: member)
        let result = try current.content.decode(PlatformProjectResponse.self)
        XCTAssertTrue(result.capabilities.contains("edit")); XCTAssertFalse(result.capabilities.contains("review"))
        let access = try await ProjectGrantService.current(projectID: project.project.id, targetID: member.requireID(), on: app.db)
        XCTAssertEqual(access.role, "member"); XCTAssertEqual(access.revision, 3)
    }

    func testPendingInvitationCannotUndoLaterProjectRemoval() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let issued = try await app.db.transaction { db in
            try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member",
                projects: [.init(projectId: project.project.id, role: "manager")], actorID: owner.requireID(), on: db)
        }
        let removed = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1)
        XCTAssertEqual(removed.status, .ok)
        for route in ["preview", "accept"] {
            let result = try await request(.POST, "api/v2/invitations/\(route)", user: member, body: ["token": issued.1])
            XCTAssertEqual(result.status, .conflict, result.body.string)
            XCTAssertTrue(result.body.string.contains("invitation_grant_changed"))
        }
        let current = try await ProjectGrantService.current(projectID: project.project.id, targetID: member.requireID(), on: app.db)
        XCTAssertEqual(current.state, "removed"); XCTAssertEqual(current.revision, 2)
        let pending = try await TeamInvite.find(issued.0.requireID(), on: app.db)
        XCTAssertEqual(pending?.status, "pending")
    }

    func testAcceptedInvitationPreviewStopsShowingProjectAfterAccessRemoval() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        let issued = try await app.db.transaction { db in
            try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member",
                projects: [.init(projectId: project.project.id, role: "member")], actorID: owner.requireID(), on: db)
        }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: issued.1, actorID: member.requireID(), on: db) }
        let before = try await request(.POST, "api/v2/invitations/preview", user: member, body: ["token": issued.1])
        XCTAssertEqual(try before.content.decode(InvitationPreview.self).projects.count, 1)
        _ = try await grantCommand(owner, project: project, target: member, role: nil, revision: 1)
        let after = try await request(.POST, "api/v2/invitations/preview", user: member, body: ["token": issued.1])
        XCTAssertEqual(after.status, .ok)
        XCTAssertTrue(try after.content.decode(InvitationPreview.self).projects.isEmpty)
    }
    func testCompetingProjectPermissionEditsCannotBothCommit() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        var statuses: [HTTPResponseStatus] = []
        try await withThrowingTaskGroup(of: HTTPResponseStatus.self) { group in
            for role: String? in ["manager", nil] {
                group.addTask { try await self.grantCommand(owner, project: project, target: member, role: role, revision: 1).status }
            }
            for try await status in group { statuses.append(status) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1)
        let current = try await ProjectGrantService.current(projectID: project.project.id, targetID: member.requireID(), on: app.db)
        XCTAssertEqual(current.revision, 2)
    }

    func testRegisterSearchIsLiteralCaseInsensitiveAndRemainsInsideProject() async throws {
        let owner = try await user(), project = try await project(owner), other = try await self.project(owner)
        let wanted = try await snag(owner, project: project, fields: ["title": "Re-seal 100%_ finish", "description": "Builder's note: uneven edge", "location": "Plot 12 · Kitchen", "priority": "high"])
        _ = try await snag(owner, project: project, fields: ["title": "Other finish", "location": "Plot 13 · Kitchen", "priority": "low"])
        _ = try await snag(owner, project: other, fields: ["title": "Re-seal 100%_ finish", "location": "Plot 12 · Kitchen", "priority": "high"])
        let path = "api/v2/projects/\(project.project.id)/snags"
        for term in ["100%_", "BUILDER'S", "plot 12", wanted.snag.reference.lowercased()] {
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let response = try await request(.GET, path + "?q=" + encoded, user: owner)
            XCTAssertEqual(response.status, .ok, response.body.string)
            let page = try response.content.decode(PlatformSnagController.Page.self)
            XCTAssertEqual(page.items.map(\.snag.id), [wanted.snag.id]); XCTAssertEqual(page.total, 1)
            XCTAssertEqual(page.summary.total, 2)
        }
        let combined = try await request(.GET, path + "?location=plot%2012&priority=high&contractorId=unassigned", user: owner)
        XCTAssertEqual(try combined.content.decode(PlatformSnagController.Page.self).items.map(\.snag.id), [wanted.snag.id])
        let stranger = try await user()
        let denied = try await request(.GET, path + "?q=finish", user: stranger)
        XCTAssertEqual(denied.status, .notFound)
    }

    func testRegisterUsesWorkspaceCalendarForOverdueAndPlacesMissingDatesLast() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let dueYesterday = try await snag(owner, project: envelope, fields: ["title": "Window seal", "dueOn": "2026-09-10"])
        let dueToday = try await snag(owner, project: envelope, fields: ["title": "Door closer", "dueOn": "2026-09-11"])
        let noDate = try await snag(owner, project: envelope, fields: ["title": "Paint reveal"])
        let closed = try await snag(owner, project: envelope, fields: ["title": "Historical closure fixture", "dueOn": "2026-09-09"])
        // Workflow state fixture only; this is not an integration-journey seed.
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE snags SET status = 'closed' WHERE id = \(bind: closed.snag.id)").run()
        let project = try await Project.find(envelope.project.id, on: app.db)!
        let now = ISO8601DateFormatter().date(from: "2026-09-10T23:30:00Z")!
        let overdue = try await SnagRegisterService.list(.init(due: "overdue"), project: project, on: app.db, now: now)
        XCTAssertEqual(overdue.items.map(\.snag.id), [dueYesterday.snag.id])
        XCTAssertEqual(overdue.summary.overdue, 1)
        let today = try await SnagRegisterService.list(.init(due: "today"), project: project, on: app.db, now: now)
        XCTAssertEqual(today.items.map(\.snag.id), [dueToday.snag.id])
        let ascending = try await SnagRegisterService.list(.init(sort: "due"), project: project, on: app.db, now: now)
        XCTAssertEqual(ascending.items.map(\.snag.id), [closed.snag.id, dueYesterday.snag.id, dueToday.snag.id, noDate.snag.id])
        let descending = try await SnagRegisterService.list(.init(sort: "due", direction: "desc"), project: project, on: app.db, now: now)
        XCTAssertEqual(descending.items.map(\.snag.id), [dueToday.snag.id, dueYesterday.snag.id, closed.snag.id, noDate.snag.id])
    }

    func testRegisterHasBoundedPagesAccurateFilteredCountsAndContractorLabels() async throws {
        let owner = try await user(), project = try await project(owner)
        let contractor = try await directory(owner, project: project, type: "contractors", fields: ["companyName": "Willow Joinery & Refurbishment Ltd"])
        var ids: [UUID] = []
        for index in 1...51 {
            let value = try await snag(owner, project: project, fields: ["title": "Synthetic inspection item \(index)", "priority": index == 51 ? "critical" : "medium"])
            ids.append(value.snag.id)
        }
        let path = "api/v2/projects/\(project.project.id)/snags"
        _ = try await request(.POST, path + "/\(ids[50])/assignment", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "fields": ["contractorId": contractor.id.uuidString]])
        let first = try await request(.GET, path, user: owner).content.decode(PlatformSnagController.Page.self)
        let second = try await request(.GET, path + "?page=2", user: owner).content.decode(PlatformSnagController.Page.self)
        XCTAssertEqual(first.items.count, 50); XCTAssertTrue(first.hasMore); XCTAssertEqual(first.total, 51)
        XCTAssertEqual(second.items.map(\.snag.id), [ids[50]]); XCTAssertFalse(second.hasMore)
        XCTAssertTrue(Set(first.items.map(\.snag.id)).isDisjoint(with: second.items.map(\.snag.id)))
        XCTAssertEqual(second.contractors.first?.companyName, "Willow Joinery & Refurbishment Ltd")
        let filtered = try await request(.GET, path + "?contractorId=\(contractor.id)&sort=priority&direction=desc", user: owner).content.decode(PlatformSnagController.Page.self)
        XCTAssertEqual(filtered.total, 1); XCTAssertEqual(filtered.summary.total, 51)
        let empty = try await request(.GET, path + "?q=no-match", user: owner).content.decode(PlatformSnagController.Page.self)
        XCTAssertEqual(empty.total, 0); XCTAssertEqual(empty.summary.total, 51); XCTAssertFalse(empty.hasMore)
    }

    func testRegisterRejectsMalformedFiltersInsteadOfSilentlyBroadeningResults() async throws {
        let owner = try await user(), project = try await project(owner)
        for query in ["page=bad", "page=0", "archived=perhaps", "status=approved", "priority=urgent", "due=yesterday", "sort=title", "direction=up", "contractorId=invalid"] {
            let response = try await request(.GET, "api/v2/projects/\(project.project.id)/snags?" + query, user: owner)
            XCTAssertEqual(response.status, .badRequest, query + ": " + response.body.string)
        }
    }

}
