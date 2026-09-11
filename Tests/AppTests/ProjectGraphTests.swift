@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import PostgresNIO

final class ProjectGraphTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("graph-\(UUID())@example.test", name: "Synthetic site manager", on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User?, body: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        let jwt = try user.map { user in
            try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: user.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: user.requireID()))
        }
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if method != .GET { req.headers.contentType = .json; req.body = .init(data: bytes) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func metadata() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func project(_ owner: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: owner.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
        }
        let result = try await request(.POST, "api/v2/projects", user: owner, body: ["mutation": metadata(), "workspaceId": try workspace.requireID().uuidString,
            "project": ["id": UUID().uuidString, "name": "Willow Mews · Plot 7", "reference": "WM07"]])
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ owner: User, project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let response = try await request(.POST, "api/v2/projects/\(project.project.id)/snags", user: owner,
            body: ["mutation": metadata(), "id": UUID().uuidString, "fields": ["title": "Seal shower tray", "location": "Plot 7 · Ensuite"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }
    private func comments(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/comments" }
    private func discovery(_ user: User) async throws -> ProjectDiscoveryPage {
        let response = try await request(.POST, "api/v2/project-discovery-snapshots", user: user)
        XCTAssertEqual(response.status, .ok, response.body.string)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        return try response.content.decode(ProjectDiscoveryPage.self)
    }

    func testDiscoveryRequiresAuthAndEmptyInventoryIsExplicitlyComplete() async throws {
        let unauthenticated = try await request(.POST, "api/v2/project-discovery-snapshots", user: nil)
        XCTAssertEqual(unauthenticated.status, .unauthorized)
        let user = try await user(), empty = try await discovery(user)
        XCTAssertEqual(empty.total, 0); XCTAssertTrue(empty.items.isEmpty); XCTAssertTrue(empty.complete); XCTAssertNil(empty.nextOffset)
        let retry = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(empty.snapshotToken)&offset=0", user: user)
        XCTAssertEqual(retry.status, .ok)
    }

    func testUnscopedLegacyProjectsCannotDisappearFromACompleteInventory() async throws {
        let owner = try await user()
        _ = try await project(owner)
        let previous = try await discovery(owner), legacyID = UUID()
        // Exercise the actual older-client create route; it still has no workspace.
        let created = try await request(.POST, "api/v1/projects", user: owner,
            body: ["id": legacyID.uuidString, "name": "Older local project", "reference": "OLD"])
        XCTAssertEqual(created.status, .ok, created.body.string)
        let create = try await request(.POST, "api/v2/project-discovery-snapshots", user: owner)
        let page = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(previous.snapshotToken)&offset=0", user: owner)
        for response in [create, page] {
            XCTAssertEqual(response.status, .conflict)
            XCTAssertTrue(response.body.string.contains("project_ownership_reconciliation_required"))
            XCTAssertFalse(response.body.string.contains("Willow")); XCTAssertFalse(response.body.string.contains("Older local project"))
        }
        let retained = try await Project.find(legacyID, on: app.db)
        XCTAssertNotNil(retained); XCTAssertNil(retained?.workspaceId); XCTAssertEqual(retained?.platformManaged, false)
    }

    func testDiscoveryLimitBoundsDuplicateDownloadsButDoesNotBlockChangedAccess() async throws {
        let owner = try await user()
        for _ in 0..<5 { _ = try await discovery(owner) }
        let bounded = try await request(.POST, "api/v2/project-discovery-snapshots", user: owner)
        XCTAssertEqual(bounded.status, .tooManyRequests); XCTAssertTrue(bounded.body.string.contains("discovery_limit"))
        let created = try await project(owner)
        let changed = try await discovery(owner)
        XCTAssertEqual(changed.items.map { $0.project.project.id }, [created.project.id])
    }

    func testDiscoveryIsImmutableAcrossMetadataUpdatesAndListsEachProjectOnce() async throws {
        let owner = try await user(), project = try await project(owner)
        // Bounded graph algorithm fixtures, not an ordinary native capture claim.
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId, on: db)
            for i in 0..<51 {
                let p = Project(name: "Original plot \(i)", reference: "P\(i)", ownerId: try owner.requireID())
                p.workspaceId = project.workspaceId; p.platformManaged = true; try await p.save(on: db)
            }
        }
        let first = try await discovery(owner)
        XCTAssertEqual(first.total, 52); XCTAssertEqual(first.items.count, 50); XCTAssertEqual(first.nextOffset, 50); XCTAssertFalse(first.complete)
        let original = try await Project.query(on: app.db).filter(\.$workspaceId == project.workspaceId).sort(\.$id).all()
        let last = original.last!, originalName = last.name
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId, on: db)
            last.name = "Changed after snapshot"; try await last.save(on: db)
        }
        let response = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(first.snapshotToken)&offset=50", user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let final = try response.content.decode(ProjectDiscoveryPage.self)
        XCTAssertTrue(final.complete); XCTAssertNil(final.nextOffset)
        let items = first.items + final.items
        XCTAssertEqual(Set(items.map { $0.project.project.id }).count, 52)
        XCTAssertEqual(items.first { $0.project.project.id == last.id }?.project.project.name, originalName)
        XCTAssertTrue(items.allSatisfy { $0.bootstrapState == "register_available" && $0.coverage == RegisterSyncService.coverage })
        XCTAssertFalse(items[0].coverage.contains("drawings"))
    }

    func testDiscoveryTokensAreActorBoundAndAccessRemovalReturnsNoContent() async throws {
        let owner = try await user(), member = try await user(), stranger = try await user(), company = try await project(owner, company: true)
        try await join(member, owner: owner, project: company, role: "member")
        let before = try await discovery(member)
        XCTAssertEqual(before.items.map { $0.project.project.id }, [company.project.id])
        let path = "api/v2/project-discovery-snapshots?snapshot=\(before.snapshotToken)&offset=0"
        let stolen = try await request(.GET, path, user: stranger)
        XCTAssertEqual(stolen.status, .notFound); XCTAssertFalse(stolen.body.string.contains("Willow"))
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: company.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let removed = try await request(.GET, path, user: member)
        XCTAssertEqual(removed.status, .conflict); XCTAssertTrue(removed.body.string.contains("discovery_restart_required")); XCTAssertFalse(removed.body.string.contains("Willow"))
        let fresh = try await discovery(member); XCTAssertTrue(fresh.items.isEmpty)
    }

    func testDiscoveryDetectsNewGrantsAndNewProjectsIncludingOldProjectRecords() async throws {
        let owner = try await user(), member = try await user(), company = try await project(owner, company: true)
        let before = try await discovery(member)
        try await join(member, owner: owner, project: company, role: "member")
        let changed = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(before.snapshotToken)&offset=0", user: member)
        XCTAssertEqual(changed.status, .conflict)
        let fresh = try await discovery(member); XCTAssertEqual(fresh.items.map { $0.project.project.id }, [company.project.id])
        let ownerBefore = try await discovery(owner)
        _ = try await project(owner)
        let newlyCreated = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(ownerBefore.snapshotToken)&offset=0", user: owner)
        XCTAssertEqual(newlyCreated.status, .conflict)
    }

    func testDiscoveryDetectsRejoinedSameRoleAndExpiredOrMalformedPages() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let before = try await discovery(member), path = "api/v2/project-discovery-snapshots?snapshot=\(before.snapshotToken)"
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        try await join(member, owner: owner, project: project, role: "member")
        let old = try await request(.GET, path + "&offset=0", user: member); XCTAssertEqual(old.status, .conflict)
        let malformed = try await request(.GET, path + "&offset=1", user: member); XCTAssertEqual(malformed.status, .badRequest)
        let current = try await discovery(member)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE project_discovery_snapshots SET expires_at = NOW() - INTERVAL '1 second' WHERE actor_id = \(bind: member.requireID())").run()
        let expired = try await request(.GET, "api/v2/project-discovery-snapshots?snapshot=\(current.snapshotToken)&offset=0", user: member)
        XCTAssertEqual(expired.status, .gone); XCTAssertTrue(expired.body.string.contains("discovery_restart_required"))
    }

    func testLegacyAndArchivedProjectsNeverClaimRegisterBootstrapAndPrivateProjectsStayPrivate() async throws {
        let owner = try await user(), member = try await user(), company = try await project(owner, company: true), personal = try await project(owner)
        try await join(member, owner: owner, project: company, role: "member")
        let legacy = Project(name: "Unimported on-device report", reference: "LEG", ownerId: try owner.requireID()); legacy.workspaceId = personal.workspaceId
        try await legacy.save(on: app.db)
        let archived = try await Project.find(personal.project.id, on: app.db)!; archived.archivedAt = Date(); try await archived.save(on: app.db)
        let own = try await discovery(owner)
        XCTAssertEqual(own.items.first { $0.project.project.id == legacy.id }?.bootstrapState, "import_required")
        XCTAssertEqual(own.items.first { $0.project.project.id == personal.project.id }?.bootstrapState, "archived")
        XCTAssertTrue(own.items.filter { $0.bootstrapState != "register_available" }.allSatisfy { $0.coverage.isEmpty })
        let shared = try await discovery(member); XCTAssertEqual(shared.items.map { $0.project.project.id }, [company.project.id])
    }

    func testCommentCreationIsIdempotentServerAttributedAndDoesNotChangeCloseout() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project), id = UUID()
        let path = comments(project, snag)
        let body: [String: Any] = ["mutation": metadata(), "id": id.uuidString, "body": "  Use flexible sanitary sealant.  ", "authorUserId": UUID().uuidString, "authorName": "Forged author", "visibility": "contractor"]
        var comments: [ProjectCommentResponse] = []
        try await withThrowingTaskGroup(of: ProjectCommentResponse.self) { group in
            for _ in 0..<4 { group.addTask {
                let response = try await self.request(.POST, path, user: owner, body: body)
                XCTAssertEqual(response.status, .ok, response.body.string)
                return try response.content.decode(ProjectCommentResponse.self)
            } }
            for try await comment in group { comments.append(comment) }
        }
        XCTAssertEqual(Set(comments.map(\.id)), [id]); XCTAssertTrue(comments.allSatisfy { $0.authorUserId == owner.id && $0.authorName == owner.name && $0.visibility == "internal" && $0.body == "Use flexible sanitary sealant." })
        let row = try await Snag.find(snag.snag.id, on: app.db)!
        XCTAssertEqual(row.revision, snag.revision); XCTAssertEqual(row.workflowRevision, snag.workflowRevision); XCTAssertEqual(row.status, snag.snag.status)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_id = \(bind: id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
        var changed = body; changed["body"] = "Different work"
        let reused = try await request(.POST, path, user: owner, body: changed); XCTAssertEqual(reused.status, .conflict); XCTAssertTrue(reused.body.string.contains("operation_reused"))
    }

    func testCommentPermissionAndThreadScopeCannotBeForged() async throws {
        let owner = try await user(), member = try await user(), viewer = try await user(), stranger = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        // The persisted policy supports Viewer, but current public grant creation
        // only exposes Manager/Member. Seed a scoped read-only policy fixture; do
        // not claim a working Viewer invitation/provisioning UI from this test.
        try await join(viewer, owner: owner, project: project, role: "member")
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId, on: db)
            try await VerifiedIdentityService.sql(db).raw("UPDATE project_access SET role = 'viewer', revision = revision + 1 WHERE project_id = \(bind: project.project.id) AND workspace_id = \(bind: project.workspaceId) AND user_id = \(bind: viewer.requireID()) AND state = 'active'").run()
        }
        let firstSnag = try await snag(owner, project: project), secondSnag = try await snag(owner, project: project), path = comments(project, firstSnag)
        let parent = try await request(.POST, path, user: member, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Confirm colour with site manager"])
        XCTAssertEqual(parent.status, .ok, parent.body.string)
        let root = try parent.content.decode(ProjectCommentResponse.self)
        let wrongSnag = try await request(.POST, comments(project, secondSnag), user: member, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Cross-snag reply", "parentCommentId": root.id.uuidString])
        XCTAssertEqual(wrongSnag.status, .notFound)
        let denied = try await request(.POST, path, user: viewer, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Viewer write"])
        XCTAssertEqual(denied.status, .forbidden)
        let hidden = try await request(.GET, path, user: stranger); XCTAssertEqual(hidden.status, .notFound); XCTAssertFalse(hidden.body.string.contains("colour"))
        let read = try await request(.GET, path, user: viewer); XCTAssertEqual(read.status, .ok)
        let reply = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Use white", "parentCommentId": root.id.uuidString])
        XCTAssertEqual(reply.status, .ok)
        let child = try reply.content.decode(ProjectCommentResponse.self)
        let nested = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Third level", "parentCommentId": child.id.uuidString])
        XCTAssertEqual(nested.status, .badRequest)
        let blank = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "  \n "])
        XCTAssertEqual(blank.status, .badRequest)
    }

    func testCommentsJoinConsistentSnapshotAndSubsequentDeltas() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project), path = comments(project, snag)
        let initial = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Check silicone adhesion"])
        let firstComment = try initial.content.decode(ProjectCommentResponse.self)
        let bootstrap = try await request(.POST, "api/v2/projects/\(project.project.id)/register-snapshots", user: owner)
        let snapshot = try bootstrap.content.decode(RegisterSnapshotPage.self)
        XCTAssertTrue(snapshot.coverage.contains("comments")); XCTAssertEqual(snapshot.items.filter { $0.type == "comment" }.map(\.id), [firstComment.id])
        let next = try await request(.POST, path, user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Use manufacturer primer"])
        let secondComment = try next.content.decode(ProjectCommentResponse.self)
        let delta = try await request(.GET, "api/v2/projects/\(project.project.id)/changes?cursor=\(snapshot.changesCursor!)", user: owner)
        let changes = try delta.content.decode(ProjectChangePage.self)
        XCTAssertEqual(changes.changes.map(\.id), [secondComment.id]); XCTAssertEqual(changes.changes.map(\.type), ["comment"])
        let repeatSnapshot = try await request(.GET, "api/v2/projects/\(project.project.id)/register-snapshots?snapshot=\(snapshot.snapshotToken)&offset=0", user: owner)
        XCTAssertFalse(try repeatSnapshot.content.decode(RegisterSnapshotPage.self).items.contains { $0.id == secondComment.id })
    }

    func testRedactionRetainsAuditAndThreadButCannotLeakThroughOldReceiptsSnapshotsOrCursors() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project), path = comments(project, snag)
        let body: [String: Any] = ["mutation": metadata(), "id": UUID().uuidString, "body": "Text removed after review"]
        let response = try await request(.POST, path, user: owner, body: body), comment = try response.content.decode(ProjectCommentResponse.self)
        let snapshotResponse = try await request(.POST, "api/v2/projects/\(project.project.id)/register-snapshots", user: owner)
        let old = try snapshotResponse.content.decode(RegisterSnapshotPage.self)
        let redaction: [String: Any] = ["mutation": metadata(), "expectedRevision": 1, "reason": "Wrong inspection note"]
        let removed = try await request(.POST, path + "/\(comment.id)/redact", user: owner, body: redaction)
        XCTAssertEqual(removed.status, .ok, removed.body.string)
        let tombstone = try removed.content.decode(ProjectCommentResponse.self)
        XCTAssertNil(tombstone.body); XCTAssertNotNil(tombstone.redactedAt); XCTAssertEqual(tombstone.revision, 2)
        for suffix in ["register-snapshots?snapshot=\(old.snapshotToken)&offset=0", "changes?cursor=\(old.changesCursor!)"] {
            let invalidated = try await request(.GET, "api/v2/projects/\(project.project.id)/" + suffix, user: owner)
            XCTAssertEqual(invalidated.status, .conflict); XCTAssertTrue(invalidated.body.string.contains("rebootstrap_required")); XCTAssertFalse(invalidated.body.string.contains("Text removed"))
        }
        let replay = try await request(.POST, path, user: owner, body: body)
        XCTAssertEqual(replay.status, .ok); XCTAssertNil(try replay.content.decode(ProjectCommentResponse.self).body)
        let repeatRedaction = try await request(.POST, path + "/\(comment.id)/redact", user: owner, body: redaction)
        XCTAssertEqual(repeatRedaction.status, .ok)
        let stale = try await request(.POST, path + "/\(comment.id)/redact", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "reason": "Stale removal"])
        XCTAssertEqual(stale.status, .conflict); XCTAssertTrue(stale.body.string.contains("comment_revision_conflict"))
        let fresh = try await request(.POST, "api/v2/projects/\(project.project.id)/register-snapshots", user: owner)
        XCTAssertEqual(fresh.status, .ok); XCTAssertFalse(fresh.body.string.contains("Text removed"))
        let stored = try await VerifiedIdentityService.sql(app.db).raw("SELECT body, revision FROM project_comments WHERE id = \(bind: comment.id)").first()!
        XCTAssertEqual(try stored.decode(column: "body", as: String.self), "Text removed after review"); XCTAssertEqual(try stored.decode(column: "revision", as: Int64.self), 2)
    }

    func testOtherContributorsCannotRedactAndRemovedAuthorsCannotReplay() async throws {
        let owner = try await user(), member = try await user(), other = try await user(), project = try await project(owner, company: true)
        for user in [member, other] { try await join(user, owner: owner, project: project, role: "member") }
        let snag = try await snag(owner, project: project), path = comments(project, snag)
        let body: [String: Any] = ["mutation": metadata(), "id": UUID().uuidString, "body": "Author's internal note"]
        let response = try await request(.POST, path, user: member, body: body), comment = try response.content.decode(ProjectCommentResponse.self)
        let denied = try await request(.POST, path + "/\(comment.id)/redact", user: other, body: ["mutation": metadata(), "expectedRevision": 1, "reason": "Not my note"])
        XCTAssertEqual(denied.status, .forbidden)
        let manager = try await request(.POST, path + "/\(comment.id)/redact", user: owner, body: ["mutation": metadata(), "expectedRevision": 1, "reason": "Contains incorrect detail"])
        XCTAssertEqual(manager.status, .ok)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let replay = try await request(.POST, path, user: member, body: body)
        XCTAssertEqual(replay.status, .notFound); XCTAssertFalse(replay.body.string.contains("internal note"))
    }

    func testCommentDatabaseRejectsCrossSnagParentAndMigrationRerunPreservesRecords() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project), other = try await self.snag(owner, project: project)
        let created = try await request(.POST, comments(project, snag), user: owner, body: ["mutation": metadata(), "id": UUID().uuidString, "body": "Preserved through migration"])
        let comment = try created.content.decode(ProjectCommentResponse.self)
        do {
            try await app.db.transaction { db in
                try await VerifiedIdentityService.sql(db).raw("INSERT INTO project_comments (id, workspace_id, project_id, snag_id, parent_comment_id, author_user_id, author_name, body, created_at) VALUES (\(bind: UUID()), \(bind: project.workspaceId), \(bind: project.project.id), \(bind: other.snag.id), \(bind: comment.id), \(bind: owner.requireID()), 'Synthetic', 'Wrong parent', NOW())").run()
            }
            XCTFail("Database must reject a cross-snag parent independently of the controller")
        } catch let error as PSQLError { XCTAssertEqual(error.serverInfo?[.sqlState], "23503") }
        try await CreateProjectDiscoveryAndComments().prepare(on: app.db)
        let preserved = try await ProjectCommentService.find(comment.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        XCTAssertEqual(preserved.body, comment.body); XCTAssertEqual(preserved.revision, 1)
        let retainedProject = try await Project.find(project.project.id, on: app.db)
        XCTAssertNotNil(retainedProject)
    }

    func testCommentKeysetPagesUseStableIDsEvenWhenCreationTimesTie() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project: project)
        // Synthetic pagination fixtures intentionally share one timestamp.
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO project_comments (id, workspace_id, project_id, snag_id, author_user_id, author_name, body, created_at)
            SELECT gen_random_uuid(), \(bind: project.workspaceId), \(bind: project.project.id), \(bind: snag.snag.id),
                \(bind: owner.requireID()), 'Synthetic manager', 'Inspection note ' || i::TEXT, NOW()
            FROM generate_series(1, 101) AS i
            """).run()
        let path = comments(project, snag)
        let firstResponse = try await request(.GET, path, user: owner), first = try firstResponse.content.decode(ProjectCommentController.Page.self)
        XCTAssertEqual(first.items.count, 100); XCTAssertNotNil(first.nextAfter)
        let secondResponse = try await request(.GET, path + "?after=\(first.nextAfter!)", user: owner), second = try secondResponse.content.decode(ProjectCommentController.Page.self)
        XCTAssertEqual(second.items.count, 1); XCTAssertNil(second.nextAfter)
        XCTAssertEqual(Set((first.items + second.items).map(\.id)).count, 101)
        let wrongScope = try await request(.GET, path + "?after=\(UUID())", user: owner)
        XCTAssertEqual(wrongScope.status, .notFound)
    }

    func testAdditiveMigrationCreatesFreshTablesInIsolatedRolledBackSchema() async throws {
        enum Finished: Error { case rollback }
        let schema = "graph_migration_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try await app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("CREATE SCHEMA \(ident: schema)").run()
                _ = try await sql.raw("SELECT set_config('search_path', \(bind: schema), true)").first()
                // Minimal prior-schema foreign-key surface, not a claim that every
                // historical migration was rerun on a new Neon database.
                try await sql.raw("CREATE TABLE users (id UUID PRIMARY KEY)").run()
                try await sql.raw("CREATE TABLE teams (id UUID PRIMARY KEY)").run()
                try await sql.raw("CREATE TABLE projects (id UUID PRIMARY KEY, workspace_id UUID NOT NULL, UNIQUE(id, workspace_id))").run()
                try await sql.raw("CREATE TABLE snags (id UUID PRIMARY KEY, project_id UUID NOT NULL, UNIQUE(id, project_id))").run()
                try await CreateProjectDiscoveryAndComments().prepare(on: db)
                try await CreateProjectDiscoveryAndComments().prepare(on: db)
                let rows = try await sql.raw("SELECT table_name FROM information_schema.tables WHERE table_schema = \(bind: schema) AND table_name IN ('project_comments', 'project_discovery_snapshots', 'project_discovery_items')").all()
                XCTAssertEqual(rows.count, 3)
                throw Finished.rollback
            }
        } catch Finished.rollback { }
        let retainedSchema = try await VerifiedIdentityService.sql(app.db).raw("SELECT schema_name FROM information_schema.schemata WHERE schema_name = \(bind: schema)").first()
        XCTAssertNil(retainedSchema)
    }
}
