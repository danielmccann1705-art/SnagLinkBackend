@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class DrawingProcessingAuthorityTests: XCTestCase {
    var app: Application!
    private let profile = "drawing-linux-byte-v1:0c398d19456a85be07a4999a8a40e30cbcddb5ebde3f2da8f9114fb028f04fcc"
    private let image = "sha256:47f90cd16a8cab01e8a0948ccb58b9189ce1b17ae9285d6d4029ee2aafac508e"
    private let sourceHash = String(repeating: "a", count: 64)
    private struct Fixture { let owner: User; let uploader: User; let project: Project; let assetId: UUID; let token: UUID }
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("drawing-authority-\(UUID())@example.test", name: "Synthetic manager", on: db)
        }
    }
    private func fixture(company: Bool = false, assetTTL: TimeInterval = 86400, leaseTTL: TimeInterval = 300,
                         sourceProfile: String? = nil) async throws -> Fixture {
        let owner = try await user(), uploader = company ? try await user() : owner
        let project = try await app.db.transaction { db in
            let workspace = company
                ? try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: owner.requireID(), on: db)
                : try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
            let project = Project(id: UUID(), name: "Willow Mews · Plot 12", reference: "WM12", ownerId: try owner.requireID())
            project.workspaceId = try workspace.requireID(); project.platformManaged = true
            try await project.save(on: db); return project
        }
        if company {
            let invitation = try await app.db.transaction { db in
                try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId!, email: uploader.email!, role: "member",
                    projects: [.init(projectId: project.requireID(), role: "member")], actorID: owner.requireID(), on: db)
            }
            _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invitation.1, actorID: uploader.requireID(), on: db) }
        }
        // Synthetic database fixtures only. Existing allocate() still uses its
        // placeholder profile; this does not claim a verified upload/dispatch.
        let asset = UUID(), token = UUID(), now = Date(), projectID = try project.requireID()
        try await app.db.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,
                    original_mime,original_filename,original_key,processor_profile,state,revision,created_at,expires_at)
                VALUES(\(bind: asset),\(bind: project.workspaceId!),\(bind: projectID),\(bind: uploader.requireID()),
                    'drawing_source',\(bind: self.sourceHash),1024,'application/pdf','Synthetic plans.pdf',
                    \(bind: "drawings/\(project.workspaceId!)/\(projectID)/\(asset)/original"),
                    \(bind: sourceProfile ?? self.profile),'processing',2,\(bind: now),\(bind: now.addingTimeInterval(assetTTL)))
                """).run()
            try await sql.raw("""
                INSERT INTO drawing_processing_jobs(asset_id,project_id,lease_token,lease_expires_at,attempt,state)
                VALUES(\(bind: asset),\(bind: projectID),\(bind: token),\(bind: now.addingTimeInterval(leaseTTL)),1,'processing')
                """).run()
        }
        return .init(owner: owner, uploader: uploader, project: project, assetId: asset, token: token)
    }
    private func identity(_ fixture: Fixture, workspace: UUID? = nil, project: UUID? = nil, asset: UUID? = nil,
                          actor: UUID? = nil, token: UUID? = nil, hash: String? = nil, bytes: Int = 1024,
                          mime: String = "application/pdf", profile: String? = nil) throws -> DrawingProcessingIdentity {
        .init(workspaceId: workspace ?? fixture.project.workspaceId!, projectId: try project ?? fixture.project.requireID(),
              assetId: asset ?? fixture.assetId, actorId: try actor ?? fixture.uploader.requireID(),
              leaseToken: token ?? fixture.token, sourceSHA256: hash ?? sourceHash,
              sourceBytes: bytes, sourceMIME: mime, processorProfile: profile ?? self.profile)
    }
    private func check(_ expected: DrawingProcessingIdentity) async throws -> DrawingProcessingStorageScope {
        try await DrawingProcessingAuthority.requireCurrent(expected,
            runtime: .init(processorProfile: profile, imageDigest: image), on: app.db)
    }
    private func fails(_ status: HTTPResponseStatus, _ body: () async throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected authority rejection", file: file, line: line) }
        catch { XCTAssertEqual((error as? Abort)?.status, status, file: file, line: line) }
    }

    func testCurrentPersonalAndCompanyUploaderReceiveBoundedScopeWithoutChangingJob() async throws {
        for company in [false, true] {
            let f = try await fixture(company: company), expected = try identity(f)
            let before = try await CanonicalDrawingService.asset(f.assetId, projectID: f.project.requireID(), on: app.db)
            for _ in 0..<2 {
                let result = try await check(expected)
                XCTAssertEqual(result.workspaceId, f.project.workspaceId); XCTAssertEqual(result.assetId, f.assetId)
                XCTAssertEqual(result.actorId, try f.uploader.requireID()); XCTAssertEqual(result.projectId, try f.project.requireID())
                XCTAssertEqual(result.purpose, .drawingSource); XCTAssertEqual(result.sha256, sourceHash)
                XCTAssertEqual(result.byteCount, 1024); XCTAssertEqual(result.mimeType, "application/pdf")
                XCTAssertEqual(result.processorProfile, profile); XCTAssertEqual(result.attempt, 1)
                XCTAssertGreaterThan(result.leaseExpiresAt, Date()); XCTAssertLessThanOrEqual(result.leaseExpiresAt, before.expiresAt)
            }
            let after = try await CanonicalDrawingService.asset(f.assetId, projectID: f.project.requireID(), on: app.db)
            XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.state, "processing")
            let pages = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM drawing_asset_pages WHERE asset_id = \(bind: f.assetId)").first()!.decode(column: "n", as: Int.self)
            XCTAssertEqual(pages, 0)
        }
    }
    func testWrongScopeActorAndTokenNeverReceiveAuthority() async throws {
        let f = try await fixture(company: true), stranger = try await user()
        for expected in [try identity(f, workspace: UUID()), try identity(f, project: UUID()), try identity(f, asset: UUID()),
                         try identity(f, actor: stranger.requireID()), try identity(f, actor: f.owner.requireID())] {
            await fails(.notFound) { _ = try await self.check(expected) }
        }
        await fails(.conflict) { _ = try await self.check(self.identity(f, token: UUID())) }
    }
    func testChangedSourceAndPlaceholderProfilesCannotPass() async throws {
        let f = try await fixture()
        for expected in [try identity(f, hash: String(repeating: "b", count: 64)), try identity(f, bytes: 1025),
                         try identity(f, mime: "image/png"), try identity(f, profile: "drawing-initial-v1")] {
            await fails(.conflict) { _ = try await self.check(expected) }
        }
        let placeholder = try await fixture(sourceProfile: "drawing-initial-v1")
        await fails(.conflict) { _ = try await self.check(self.identity(placeholder)) }
        XCTAssertThrowsError(try DrawingProcessorRuntimeIdentity(processorProfile: "drawing-initial-v1", imageDigest: image))
        XCTAssertThrowsError(try DrawingProcessorRuntimeIdentity(processorProfile: profile, imageDigest: "mutable-tag"))
    }
    func testExpiredSourceOrLeaseAndCompletedJobBlockFurtherStorage() async throws {
        let expiredSource = try await fixture(assetTTL: -1), expiredLease = try await fixture(leaseTTL: -1)
        for f in [expiredSource, expiredLease] {
            await fails(.conflict) { _ = try await self.check(self.identity(f)) }
        }
        let f = try await fixture()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE drawing_processing_jobs SET state = 'complete' WHERE asset_id = \(bind: f.assetId)").run()
        await fails(.conflict) { _ = try await self.check(self.identity(f)) }
    }
    func testAbsentJobYieldsNamedConflictForAllocatedAndProcessingSource() async throws {
        for state in ["allocated", "processing"] {
            let f = try await fixture()
            try await app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("DELETE FROM drawing_processing_jobs WHERE asset_id = \(bind: f.assetId)").run()
                try await sql.raw("UPDATE drawing_assets SET state = \(bind: state) WHERE id = \(bind: f.assetId)").run()
            }
            do { _ = try await check(identity(f)); XCTFail("Missing job must not grant authority") }
            catch {
                XCTAssertEqual((error as? Abort)?.status, .conflict)
                XCTAssertEqual((error as? Abort)?.identifier, "drawing_processing_authority_changed")
            }
        }
    }
    func testEveryNonProcessingSourceStateRejectsBeforeReadingLease() async throws {
        for state in ["allocated", "ready", "failed", "retired"] {
            let f = try await fixture()
            // A ready source requires immutable result identity; other source
            // states retain their valid job fields but must never authorise IO.
            if state == "ready" {
                try await VerifiedIdentityService.sql(app.db).raw("UPDATE drawing_assets SET state = 'ready', ready_at = \(bind: Date()), result_hash = \(bind: sourceHash) WHERE id = \(bind: f.assetId)").run()
            } else {
                try await VerifiedIdentityService.sql(app.db).raw("UPDATE drawing_assets SET state = \(bind: state) WHERE id = \(bind: f.assetId)").run()
            }
            await fails(.conflict) { _ = try await self.check(self.identity(f)) }
        }
    }
    func testExistingSourcePreventsProjectWorkspaceRemovalOrMove() async throws {
        let f = try await fixture(), otherOwner = try await user()
        let other = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: otherOwner.requireID(), on: db) }
        for destination in [nil, try other.requireID()] as [UUID?] {
            var rejected = false
            do {
                try await app.db.transaction { db in
                    try await VerifiedIdentityService.sql(db).raw("UPDATE projects SET workspace_id = \(bind: destination) WHERE id = \(bind: f.project.requireID())").run()
                }
            } catch { rejected = true }
            XCTAssertTrue(rejected, "Immutable source composite FK must preserve project scope")
            let current = try await Project.find(f.project.requireID(), on: app.db)
            XCTAssertEqual(current?.workspaceId, f.project.workspaceId)
            _ = try await check(identity(f))
        }
    }
    func testReclaimedLeaseRejectsOldContextAndUsesCurrentAttempt() async throws {
        let f = try await fixture(), old = try identity(f), replacement = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE drawing_processing_jobs SET lease_token = \(bind: replacement), attempt = 2 WHERE asset_id = \(bind: f.assetId)").run()
        await fails(.conflict) { _ = try await self.check(old) }
        let current = try await check(identity(f, token: replacement)); XCTAssertEqual(current.attempt, 2)
    }
    func testRemovedAndDowngradedUploaderAreRecheckedOnEveryCall() async throws {
        let removed = try await fixture(company: true), beforeRemoval = try identity(removed)
        _ = try await check(beforeRemoval)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.changeMember(workspaceID: removed.project.workspaceId!, targetID: removed.uploader.requireID(),
                newRole: nil, expectedRevision: 1, actorID: removed.owner.requireID(), on: db)
        }
        await fails(.notFound) { _ = try await self.check(beforeRemoval) }
        let viewer = try await fixture(company: true), beforeDowngrade = try identity(viewer)
        _ = try await check(beforeDowngrade)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE project_access SET role = 'viewer' WHERE project_id = \(bind: viewer.project.requireID()) AND user_id = \(bind: viewer.uploader.requireID())").run()
        await fails(.forbidden) { _ = try await self.check(beforeDowngrade) }
    }
    func testArchivedProjectAndDisabledAccountCannotContinue() async throws {
        let archived = try await fixture()
        archived.project.archivedAt = Date(); try await archived.project.save(on: app.db)
        await fails(.gone) { _ = try await self.check(self.identity(archived)) }
        let disabled = try await fixture()
        disabled.uploader.lifecycleState = "deleted"; try await disabled.uploader.save(on: app.db)
        await fails(.unauthorized) { _ = try await self.check(self.identity(disabled)) }
    }
    func testLegacyUnscopedProjectIsNotImplicitlyAttachedDuringAuthorityRead() async throws {
        let f = try await fixture(), legacy = Project(id: UUID(), name: "Local legacy project", reference: "LEGACY", ownerId: try f.uploader.requireID())
        try await legacy.save(on: app.db)
        await fails(.notFound) { _ = try await self.check(self.identity(f, project: legacy.requireID())) }
        let after = try await Project.find(legacy.requireID(), on: app.db)
        XCTAssertNil(after?.workspaceId); XCTAssertEqual(after?.platformManaged, false)
    }
}
