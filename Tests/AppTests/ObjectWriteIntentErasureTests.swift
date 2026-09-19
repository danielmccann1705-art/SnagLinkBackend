@testable import App
import Fluent
import FluentSQL
import XCTVapor

final class ObjectWriteIntentErasureTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
    }

    private func user(_ prefix: String) async throws -> User {
        try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmail("\(prefix)-\(UUID())@example.test", name: "Synthetic member", on: $0)
        }
    }

    private func job(userID: UUID, databaseState: String = "blocked") async throws -> UUID {
        let id = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,apple_revocation_state,object_cleanup_state)
            VALUES(\(bind:id),\(bind:userID),\(bind:"intent-"+UUID().uuidString),NOW(),'ready',NOW(),
                \(bind:databaseState),'not_applicable','pending')
            """).run()
        return id
    }

    @discardableResult
    private func intent(userID: UUID?, workspaceID: UUID?, projectID: UUID?, linkID: UUID? = nil,
                        ownershipKind: String = "personal", sourceKind: String = "media_asset",
                        key: String, state: String = "active") async throws -> UUID {
        let id = UUID(), sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("""
            INSERT INTO object_write_intents(id,writer_token_hash,source_kind,source_id,scope_user_id,
                ownership_kind,scope_workspace_id,scope_project_id,scope_magic_link_id,storage_kind,object_key,sha256,
                byte_count,content_type,state,created_at,settled_at)
            VALUES(\(bind:id),\(bind:String(repeating:"a",count:32)+id.uuidString.lowercased().replacingOccurrences(of:"-",with:"")),
                \(bind:sourceKind),\(bind:UUID()),\(bind:userID),\(bind:ownershipKind),\(bind:workspaceID),\(bind:projectID),\(bind:linkID),
                'private_media',\(bind:key),\(bind:String(repeating:"b",count:64)),10,'image/jpeg',
                'active',NOW(),NULL)
            """).run()
        if state == "settled" {
            try await sql.raw("UPDATE object_write_intents SET state='settled',settled_at=NOW() WHERE id=\(bind:id)").run()
        } else if state == "uncertain" {
            try await sql.raw("UPDATE object_write_intents SET state='uncertain' WHERE id=\(bind:id)").run()
        }
        return id
    }

    func testPersonalCaptureUsesGraphScopeAndNeverUploaderForCompanyObject() async throws {
        let target = try await user("intent-target"), owner = try await user("intent-owner")
        let personal = try await app.db.transaction { try await WorkspaceAccessService.personal(for: target.requireID(), on: $0) }
        let company = try await app.db.transaction {
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Retained company", actorID: owner.requireID(), on: $0)
        }
        let personalProject = Project(id: UUID(), name: "Personal", reference: UUID().uuidString, ownerId: try target.requireID())
        personalProject.workspaceId = try personal.requireID(); personalProject.platformManaged = true; try await personalProject.save(on: app.db)
        let companyProject = Project(id: UUID(), name: "Company", reference: UUID().uuidString, ownerId: try owner.requireID())
        companyProject.workspaceId = try company.requireID(); companyProject.platformManaged = true; try await companyProject.save(on: app.db)
        let personalKey = "platform/intents/\(UUID())", companyKey = "platform/intents/\(UUID())"
        let personalIntent = try await intent(userID: target.requireID(), workspaceID: personal.requireID(), projectID: personalProject.requireID(), key: personalKey)
        let companyIntent = try await intent(userID: target.requireID(), workspaceID: company.requireID(), projectID: companyProject.requireID(),
                                             ownershipKind: "workspace", key: companyKey)
        do {
            _ = try await intent(userID: target.requireID(), workspaceID: nil, projectID: companyProject.requireID(),
                                 ownershipKind: "personal", key: "platform/intents/\(UUID())")
            XCTFail("A live company project cannot be admitted as personal ownership")
        } catch { }
        let jobID = try await job(userID: target.requireID())

        try await app.db.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("CREATE TEMP TABLE account_deletion_workspaces(id UUID PRIMARY KEY) ON COMMIT DROP").run()
            try await sql.raw("CREATE TEMP TABLE account_deletion_projects(id UUID PRIMARY KEY,workspace_id UUID) ON COMMIT DROP").run()
            try await sql.raw("CREATE TEMP TABLE account_deletion_sessions(id UUID PRIMARY KEY) ON COMMIT DROP").run()
            try await sql.raw("CREATE TEMP TABLE account_deletion_links(id UUID PRIMARY KEY,token TEXT UNIQUE) ON COMMIT DROP").run()
            try await sql.raw("INSERT INTO account_deletion_workspaces VALUES(\(bind:personal.requireID()))").run()
            try await sql.raw("INSERT INTO account_deletion_projects VALUES(\(bind:personalProject.requireID()),\(bind:personal.requireID()))").run()
            try await sql.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:jobID.uuidString),true)").run()
            try await AccountDeletionGraphService.captureWriteIntents(jobID: jobID, userFallbackID: target.requireID(), on: sql)
        }

        let sql = try VerifiedIdentityService.sql(app.db)
        let personalLink = try await sql.raw("SELECT 1 FROM account_deletion_write_intents WHERE job_id=\(bind:jobID) AND intent_id=\(bind:personalIntent)").first()
        let companyLink = try await sql.raw("SELECT 1 FROM account_deletion_write_intents WHERE job_id=\(bind:jobID) AND intent_id=\(bind:companyIntent)").first()
        let personalManifest = try await sql.raw("SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND object_key=\(bind:personalKey)").first()
        let companyManifest = try await sql.raw("SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND object_key=\(bind:companyKey)").first()
        XCTAssertNotNil(personalLink)
        XCTAssertNil(companyLink)
        XCTAssertNotNil(personalManifest)
        XCTAssertNil(companyManifest)
        do {
            try await app.db.transaction { db in
                let scoped = try VerifiedIdentityService.sql(db)
                try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:jobID.uuidString),true)").run()
                try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:jobID),\(bind:companyIntent))").run()
            }
            XCTFail("A personal job cannot claim a retained company write")
        } catch { }
    }

    func testUnsettledIntentBlocksDeletionAndCompletionUntilExplicitSettlement() async throws {
        let target = try await user("intent-worker"), jobID = try await job(userID: target.requireID())
        let key = "platform/intents/\(UUID())", intentID = try await intent(userID: target.requireID(), workspaceID: nil, projectID: nil,
                                                                            sourceKind: "completion_upload", key: key)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:jobID.uuidString),true)").run()
            try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:jobID),\(bind:intentID))").run()
        }
        try await sql.raw("INSERT INTO account_deletion_objects(job_id,storage_kind,object_key) VALUES(\(bind:jobID),'private_media',\(bind:key))").run()
        try await sql.raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind:jobID)").run()
        do {
            try await sql.raw("UPDATE account_deletion_jobs SET object_cleanup_state='completed' WHERE id=\(bind:jobID)").run()
            XCTFail("An active write must make object completion impossible")
        } catch { }
        try await sql.raw("UPDATE object_write_intents SET state='uncertain' WHERE id=\(bind:intentID)").run()
        do {
            try await sql.raw("UPDATE account_deletion_jobs SET object_cleanup_state='completed' WHERE id=\(bind:jobID)").run()
            XCTFail("An uncertain write must remain blocking")
        } catch { }
        try await sql.raw("UPDATE object_write_intents SET state='settled',settled_at=NOW() WHERE id=\(bind:intentID)").run()
        try await sql.raw("UPDATE account_deletion_objects SET completed_at=NOW() WHERE job_id=\(bind:jobID) AND object_key=\(bind:key)").run()
        try await sql.raw("UPDATE account_deletion_jobs SET object_cleanup_state='completed' WHERE id=\(bind:jobID)").run()
        let state = try await sql.raw("SELECT object_cleanup_state FROM account_deletion_jobs WHERE id=\(bind:jobID)").first()!
        XCTAssertEqual(try state.decode(column: "object_cleanup_state", as: String.self), "completed")
    }

    func testOtherScopeIntentRemainsAReferenceButSameJobSettledIntentDoesNot() async throws {
        let target = try await user("intent-reference"), jobID = try await job(userID: target.requireID())
        let key = "platform/intents/\(UUID())"
        let owned = try await intent(userID: target.requireID(), workspaceID: nil, projectID: nil,
                                     sourceKind: "completion_upload", key: key, state: "settled")
        let sql = try VerifiedIdentityService.sql(app.db)
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:jobID.uuidString),true)").run()
            try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:jobID),\(bind:owned))").run()
        }
        let sameJobReferenced = try await AccountDeletionGraphService.objectIsReferenced(
            kind: "private_media", key: key, excludingJobID: jobID, on: app.db)
        XCTAssertFalse(sameJobReferenced)
        let otherUser = try await user("intent-other-job")
        let otherIntent = try await intent(userID: otherUser.requireID(), workspaceID: nil, projectID: nil,
                                           sourceKind: "completion_upload", key: key, state: "settled")
        let unlinkedReferenced = try await AccountDeletionGraphService.objectIsReferenced(
            kind: "private_media", key: key, excludingJobID: jobID, on: app.db)
        XCTAssertTrue(unlinkedReferenced)
        let otherJob = try await job(userID: otherUser.requireID())
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:otherJob.uuidString),true)").run()
            try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:otherJob),\(bind:otherIntent))").run()
        }
        let crossJobScheduledReference = try await AccountDeletionGraphService.objectIsReferenced(
            kind: "private_media", key: key, excludingJobID: jobID, on: app.db)
        XCTAssertFalse(crossJobScheduledReference)

        let retainedKey = "platform/intents/\(UUID())"
        let retainedOwner = try await user("intent-retained")
        let retainedWorkspace = try await app.db.transaction {
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Retained evidence", actorID: retainedOwner.requireID(), on: $0)
        }
        let retainedProject = Project(id: UUID(), name: "Retained", reference: UUID().uuidString, ownerId: try retainedOwner.requireID())
        retainedProject.workspaceId = try retainedWorkspace.requireID(); retainedProject.platformManaged = true; try await retainedProject.save(on: app.db)
        let retainedSnag = Snag(id: UUID(), reference: "R-1", title: "Retained snag", projectId: try retainedProject.requireID(), ownerId: try retainedOwner.requireID())
        retainedSnag.workspaceId = try retainedWorkspace.requireID(); retainedSnag.displayNumber = 1; retainedSnag.publishedAt = Date(); try await retainedSnag.save(on: app.db)
        try await sql.raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,original_sha256,original_size,
                original_mime,original_key,rendition_key,rendition_sha256,rendition_size,width,height,
                revision,base_snag_revision,created_at,expires_at,ready_at,attached_at)
            VALUES(\(bind:UUID()),\(bind:retainedWorkspace.requireID()),\(bind:retainedProject.requireID()),\(bind:retainedSnag.requireID()),
                \(bind:retainedOwner.requireID()),'capture','ready',\(bind:String(repeating:"c",count:64)),10,'image/jpeg',\(bind:retainedKey),
                \(bind:retainedKey+"/rendition"),\(bind:String(repeating:"d",count:64)),9,10,10,
                1,1,NOW(),NOW()+INTERVAL '1 day',NOW(),NOW())
            """).run()
        let retainedIntent = try await intent(userID: otherUser.requireID(), workspaceID: nil, projectID: nil,
                                              sourceKind: "completion_upload", key: retainedKey, state: "settled")
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:otherJob.uuidString),true)").run()
            try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:otherJob),\(bind:retainedIntent))").run()
        }
        let retainedReferenced = try await AccountDeletionGraphService.objectIsReferenced(
            kind: "private_media", key: retainedKey, excludingJobID: jobID, on: app.db)
        XCTAssertTrue(retainedReferenced, "A live retained-party database reference remains authoritative")
    }

    func testIntentControlRowsDoNotChangeSealedCompanyInventory() async throws {
        let owner = try await user("intent-company")
        let company = try await app.db.transaction {
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Inventory company", actorID: owner.requireID(), on: $0)
        }
        let project = Project(id: UUID(), name: "Inventory project", reference: UUID().uuidString, ownerId: try owner.requireID())
        project.workspaceId = try company.requireID(); project.platformManaged = true; try await project.save(on: app.db)
        let before = try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID: company.requireID(), on: $0) }
        let intentID = try await intent(userID: owner.requireID(), workspaceID: company.requireID(), projectID: project.requireID(),
                                        ownershipKind: "workspace", key: "platform/intents/\(UUID())")
        let afterInsert = try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID: company.requireID(), on: $0) }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE object_write_intents SET state='settled',settled_at=NOW() WHERE id=\(bind:intentID)").run()
        let afterSettlement = try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID: company.requireID(), on: $0) }
        XCTAssertEqual(before.projectCount, afterInsert.projectCount)
        XCTAssertEqual(before.snagCount, afterInsert.snagCount)
        XCTAssertEqual(before.otherMemberCount, afterInsert.otherMemberCount)
        XCTAssertEqual(before.fingerprint, afterInsert.fingerprint)
        XCTAssertEqual(before.fingerprint, afterSettlement.fingerprint)
    }
}
