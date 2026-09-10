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
        XCTAssertEqual(first.coverage, ["project", "snags"])
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

}
