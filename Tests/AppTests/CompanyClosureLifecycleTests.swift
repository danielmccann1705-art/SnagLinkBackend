@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CompanyClosureLifecycleTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    struct Fixture {
        let owner: User, member: User, company: UUID, project: UUID, personalProject: UUID, retainedCompany: UUID
    }
    private func fixture() async throws -> Fixture {
        try await app.db.transaction { db in
            let owner = try await VerifiedIdentityService.resolveEmail("closure-owner-\(UUID())@example.test", name: "Synthetic owner", on: db)
            let member = try await VerifiedIdentityService.resolveEmail("closure-member-\(UUID())@example.test", name: "Synthetic member", on: db)
            let company = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Company to close", actorID: owner.requireID(), on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: company.requireID(), userID: member.requireID(), role: "member", on: db)
            let retained = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Member's own company", actorID: member.requireID(), on: db)
            let personal = try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
            let project = Project(name: "Company evidence", reference: "CO", ownerId: try owner.requireID())
            project.workspaceId = try company.requireID(); try await project.save(on: db)
            let own = Project(name: "Personal evidence", reference: "ME", ownerId: try owner.requireID())
            own.workspaceId = try personal.requireID(); try await own.save(on: db)
            return try .init(owner: owner, member: member, company: company.requireID(), project: project.requireID(), personalProject: own.requireID(), retainedCompany: retained.requireID())
        }
    }
    private func token(_ user: User) throws -> String {
        try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: user.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: user.requireID(), authVersion: user.authVersion, authenticatedAt: Date()))
    }
    private func prepare(_ f: Fixture) async throws -> AccountDeletionRequest {
        let receipt = UUID().uuidString + UUID().uuidString
        let confirmation = try await app.db.transaction { db in
            try await CompanyClosureConfirmationService.issue(userID: f.owner.requireID(), body: .init(workspaceID: f.company, receiptReference: receipt), on: db)
        }
        var body = AccountDeletionRequest(confirmation: "DELETE", receiptReference: receipt)
        body.companyClosures = [.init(workspaceID: f.company, confirmationReference: confirmation.confirmationReference, confirmation: "CLOSE COMPANY")]
        return body
    }
    private func acceptRoute(_ f: Fixture, body: AccountDeletionRequest, expected: HTTPResponseStatus = .accepted) async throws {
        let auth = try token(f.owner)
        try await app.test(.DELETE, "api/v2/account", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: auth)
            try request.content.encode(body)
        }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, expected)
            XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
            if expected == .accepted {
                let receipt = try response.content.decode(AccountDeletionReceipt.self)
                XCTAssertEqual(receipt.state, "pending"); XCTAssertNil(receipt.completedAt)
            }
        })
    }
    private func lease(_ f: Fixture) async throws -> AccountDeletionWorker.Lease {
        let sql = try VerifiedIdentityService.sql(app.db), token = UUID()
        let row = try await sql.raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE user_id=\(bind: f.owner.requireID()) RETURNING id").first()
        let id = try XCTUnwrap(row).decode(column: "id", as: UUID.self)
        return try .init(id: id, userID: f.owner.requireID(), token: token, attempt: 1)
    }
    private func child(_ f: Fixture) async throws -> SQLRow {
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT * FROM company_closure_jobs WHERE workspace_id=\(bind: f.company)").first()
        return try XCTUnwrap(row)
    }
    func testConfirmedRouteRevokesCompanyAccessThenWorkerCompletesWithoutTouchingOtherAccounts() async throws {
        let f = try await fixture(), body = try await prepare(f)
        try await acceptRoute(f, body: body)
        let closing = try await Team.find(f.company, on: app.db)
        XCTAssertEqual(closing?.lifecycleState, "closing"); XCTAssertEqual(closing?.kind, "company")
        let owner = try await User.find(f.owner.requireID(), on: app.db)
        XCTAssertEqual(owner?.lifecycleState, "deleted"); XCTAssertNil(owner?.email)
        let sealed = try await child(f)
        XCTAssertEqual(try sealed.decode(column: "state", as: String.self), "erasing")
        XCTAssertNotNil(try sealed.decode(column: "erasure_inventory_hash", as: String?.self))
        XCTAssertEqual(try sealed.decode(column: "other_member_count", as: Int64.self), 1)
        let active = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM workspace_memberships WHERE workspace_id=\(bind: f.company) AND state='active'").first()
        XCTAssertEqual(try active?.decode(column: "n", as: Int.self), 0)
        let owned = try await lease(f)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let result = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(result, "completed")
        let company = try await Team.find(f.company, on: app.db), personal = try await Project.find(f.personalProject, on: app.db)
        XCTAssertNil(company); XCTAssertNil(personal)
        let retained = try await Team.find(f.retainedCompany, on: app.db)
        XCTAssertEqual(retained?.lifecycleState, "active")
        _ = try await VerifiedIdentityService.activeUser(f.member.requireID(), on: app.db)
        let final = try await child(f)
        XCTAssertEqual(try final.decode(column: "state", as: String.self), "completed")
        let replay = try await AccountDeletionService.request(userID: f.owner.requireID(), body: body, app: app)
        XCTAssertEqual(replay.state, "completed")
    }
    func testUnknownCompanyObjectBlocksCompletionButPersonalDatabaseRowsAreErased() async throws {
        let f = try await fixture(), snag = UUID(), link = UUID(), completion = UUID()
        let sql = try VerifiedIdentityService.sql(app.db)
        let item = Snag(id: snag, reference: "S-1", title: "Company snag", projectId: f.project, ownerId: try f.owner.requireID())
        item.workspaceId = f.company; try await item.save(on: app.db)
        try await sql.raw("INSERT INTO magic_links(id,token,access_level,expires_at,snag_ids,project_id,created_by_id,created_at) VALUES(\(bind: link),\(bind: UUID().uuidString),'view',NOW()+INTERVAL '1 day','{}',\(bind: f.project),\(bind: f.member.requireID()),NOW())").run()
        try await sql.raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind: completion),\(bind: snag),\(bind: link),'Synthetic contractor','pending',NOW())").run()
        try await HistoricalCompletionPhotoFixture.insert(completionID: completion, url: "/uploads/photos/\(UUID()).jpg", on: app.db)
        let body = try await prepare(f)
        try await acceptRoute(f, body: body)
        let owned = try await lease(f)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let result = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(result, "blocked")
        let row = try await sql.raw("SELECT database_cleanup_state,object_cleanup_state,last_error_kind FROM account_deletion_jobs WHERE id=\(bind: owned.id)").first()
        XCTAssertEqual(try row?.decode(column: "database_cleanup_state", as: String.self), "completed")
        XCTAssertEqual(try row?.decode(column: "object_cleanup_state", as: String.self), "blocked")
        XCTAssertEqual(try row?.decode(column: "last_error_kind", as: String.self), "unresolved_legacy_object_ownership")
        let personal = try await Project.find(f.personalProject, on: app.db), company = try await Team.find(f.company, on: app.db)
        XCTAssertNil(personal); XCTAssertNil(company)
        let pending = try await child(f)
        XCTAssertEqual(try pending.decode(column: "state", as: String.self), "awaiting_objects")
        XCTAssertNotNil(try pending.decode(column: "database_completed_at", as: Date?.self))
        XCTAssertNil(try pending.decode(column: "completed_at", as: Date?.self))
        let unresolved = try await sql.raw("SELECT source_id FROM account_deletion_unresolved_objects WHERE job_id=\(bind: owned.id)").all()
        XCTAssertFalse(unresolved.isEmpty)
    }
    func testChangedInventoryAndDuplicateScopeRollBackAllAcceptance() async throws {
        for duplicate in [false, true] {
            let f = try await fixture()
            var body = try await prepare(f)
            if duplicate { body.companyClosures = body.companyClosures! + body.companyClosures! }
            else { try await VerifiedIdentityService.sql(app.db).raw("UPDATE projects SET name='Changed evidence' WHERE id=\(bind: f.project)").run() }
            try await acceptRoute(f, body: body, expected: .conflict)
            _ = try await VerifiedIdentityService.activeUser(f.owner.requireID(), on: app.db)
            let team = try await Team.find(f.company, on: app.db)
            XCTAssertEqual(team?.lifecycleState, "active")
            let job = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind: f.owner.requireID())").first()
            XCTAssertNil(job)
        }
    }
    func testExpiredLeaseRollsBackGraphBoundaryAndReplacementCanResume() async throws {
        let f = try await fixture(), body = try await prepare(f)
        try await acceptRoute(f, body: body)
        let owned = try await lease(f)
        do {
            try await AccountDeletionWorker.withCurrentLease(owned, on: app.db) { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("UPDATE account_deletion_jobs SET last_error_kind='synthetic_write',lease_expires_at=clock_timestamp()-INTERVAL '1 second' WHERE id=\(bind: owned.id)").run()
            }
            XCTFail("Work cannot commit after its lease expires")
        } catch let error as Abort { XCTAssertEqual(error.identifier, "deletion_lease_expired") }
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT last_error_kind FROM account_deletion_jobs WHERE id=\(bind: owned.id)").first()
        XCTAssertNotEqual(try row?.decode(column: "last_error_kind", as: String?.self), "synthetic_write")
        let replacement = try await lease(f)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let retained = try await Team.find(f.company, on: app.db)
        XCTAssertNotNil(retained)
        try await AccountDeletionWorker.perform(replacement, app: app, on: app.db)
        let result = try await AccountDeletionWorker.finish(replacement, on: app.db)
        XCTAssertEqual(result, "completed")
    }
    func testDurableChildCannotBeReboundForgedOrCompletedOutsideItsLeasedContext() async throws {
        let f = try await fixture(), body = try await prepare(f)
        try await acceptRoute(f, body: body)
        let sql = try VerifiedIdentityService.sql(app.db)
        for query: SQLQueryString in [
            "UPDATE company_closure_jobs SET workspace_id=\(bind: f.retainedCompany) WHERE workspace_id=\(bind: f.company)",
            "UPDATE company_closure_jobs SET state='awaiting_objects',database_completed_at=NOW() WHERE workspace_id=\(bind: f.company)",
            "UPDATE company_closure_jobs SET state='completed',completed_at=NOW() WHERE workspace_id=\(bind: f.company)",
            "INSERT INTO company_closure_jobs(id,account_deletion_job_id,workspace_id,confirmed_revision,mode,project_count,snag_count,other_member_count,state,requested_at,confirmation_id,inventory_hash) SELECT \(bind: UUID()),account_deletion_job_id,\(bind: f.retainedCompany),confirmed_revision,mode,project_count,snag_count,other_member_count,'erasing',NOW(),confirmation_id,inventory_hash FROM company_closure_jobs WHERE workspace_id=\(bind: f.company)"
        ] {
            do { try await sql.raw(query).run(); XCTFail("A child may not create or broaden closure authority") }
            catch { }
        }
        let unchanged = try await child(f)
        XCTAssertEqual(try unchanged.decode(column: "state", as: String.self), "erasing")
        let unrelated = try await sql.raw("SELECT id FROM company_closure_jobs WHERE workspace_id=\(bind: f.retainedCompany)").first()
        XCTAssertNil(unrelated)
        let owned = try await lease(f)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let result = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(result, "completed")
    }

    func testAllocatedUnuploadedCompanyPlaceholderCompletesThroughLocalWorker() async throws {
        try XCTSkipIf(Environment.get("R2_PRIVATE_BUCKET_NAME") != nil, "Local private-media adapter required")
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("company-placeholder-deletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        app.directory = .init(workingDirectory: storageRoot.path)

        let f = try await fixture()
        let foundProject = try await Project.find(f.project, on: app.db)
        let project = try XCTUnwrap(foundProject)
        project.platformManaged = true
        try await project.save(on: app.db)
        let snag = Snag(id: UUID(), reference: "S-PHOTO", title: "Allocated company photo",
                        projectId: f.project, ownerId: try f.owner.requireID())
        snag.workspaceId = f.company; snag.displayNumber = 1; snag.publishedAt = Date()
        try await snag.save(on: app.db)
        let assetID = UUID()
        _ = try await PrivateMediaService.allocate(.init(
            mutation: .init(operationId: UUID(), deviceId: UUID()), id: assetID, expectedRevision: snag.revision,
            purpose: "capture", intentId: nil, sha256: String(repeating: "a", count: 64), byteCount: 24, mimeType: "image/jpeg"
        ), snag: snag, project: project, actorID: try f.owner.requireID(), on: app.db)
        // The historical row shape: allocation stopped writing either address in
        // B2, so a row that carries the `view.jpg` placeholder is one allocated
        // before that change. Staging still holds them and the worker still has to
        // finish them. NULL to a value is the one transition the key-preservation
        // trigger allows.
        let prefix = "platform/\(f.company.uuidString)/\(try project.requireID().uuidString)/\(assetID.uuidString)"
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE media_assets SET original_key = \(bind: prefix + "/original"), rendition_key = \(bind: prefix + "/view.jpg")
            WHERE id = \(bind: assetID)
            """).run()
        let asset = try await PrivateMediaService.row(assetID, snagID: snag.requireID(), projectID: project.requireID(), on: app.db)
        let placeholder = try asset.decode(column: "rendition_key", as: String.self)
        XCTAssertTrue(placeholder.hasSuffix("/view.jpg"))
        let object = storageRoot.appendingPathComponent("PrivateMedia", isDirectory: true).appendingPathComponent(placeholder)
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic company placeholder".utf8).write(to: object)

        let body = try await prepare(f)
        try await acceptRoute(f, body: body)
        app.storage[AccountDeletionWorkerDependenciesKey.self] = nil
        let owned = try await lease(f)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let result = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(result, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
        let manifest = try await VerifiedIdentityService.sql(app.db).raw("SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind:owned.id) AND storage_kind='private_media' AND object_key=\(bind:placeholder)").first()
        XCTAssertNotNil(try manifest?.decode(column: "completed_at", as: Date?.self))
    }

}
