@testable import App
import Fluent
import FluentSQL
import XCTVapor

final class AccountDeletionCompanyGraphTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil,"Isolated synthetic PostgreSQL required")
        app=try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self]=true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private struct Graph {
        let owner: User; let workspace: Team; let project: Project; let snag: Snag
        let linkID: UUID; let linkToken: String; let mediaKeys: [String]
    }
    private func makeGraph(name: String = "Closing company") async throws -> Graph {
        let owner=try await app.db.transaction { try await VerifiedIdentityService.resolveEmail("company-graph-\(UUID())@example.test",name:"Synthetic owner",on:$0) }
        let workspace=try await app.db.transaction { try await WorkspaceAccessService.createCompany(id:UUID(),name:name,actorID:owner.requireID(),on:$0) }
        let project=Project(id:UUID(),name:"Company project",reference:UUID().uuidString,ownerId:try owner.requireID())
        project.workspaceId=try workspace.requireID(); project.platformManaged=true; try await project.save(on:app.db)
        let snag=Snag(id:UUID(),reference:"S-1",title:"Company snag",projectId:try project.requireID(),ownerId:try owner.requireID())
        snag.workspaceId=try workspace.requireID(); snag.displayNumber=1; snag.publishedAt=Date(); try await snag.save(on:app.db)
        let original="platform/company/\(UUID())/original", rendition="platform/company/\(UUID())/rendition.jpg"
        let linkID=UUID(), linkToken="company-\(UUID())", sql=try VerifiedIdentityService.sql(app.db)
        try await sql.raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,original_sha256,original_size,
                original_mime,original_key,rendition_key,rendition_sha256,rendition_size,width,height,revision,base_snag_revision,
                created_at,expires_at,ready_at,attached_at)
            VALUES(\(bind:UUID()),\(bind:workspace.requireID()),\(bind:project.requireID()),\(bind:snag.requireID()),\(bind:owner.requireID()),
                'capture','ready',\(bind:String(repeating:"a",count:64)),100,'image/jpeg',\(bind:original),\(bind:rendition),
                \(bind:String(repeating:"b",count:64)),90,10,10,1,1,NOW(),NOW()+INTERVAL '1 day',NOW(),NOW())
            """).run()
        try await sql.raw("""
            INSERT INTO magic_links(id,token,access_level,expires_at,snag_ids,project_id,created_by_id,created_at)
            VALUES(\(bind:linkID),\(bind:linkToken),'update',NOW()+INTERVAL '1 day',ARRAY[\(bind:snag.requireID())],\(bind:project.requireID()),\(bind:owner.requireID()),NOW())
            """).run()
        return .init(owner:owner,workspace:workspace,project:project,snag:snag,linkID:linkID,linkToken:linkToken,mediaKeys:[original,rendition])
    }
    private func parent(owner: UUID) async throws -> UUID {
        let id=UUID(), lease=UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,database_cleanup_state,
                apple_revocation_state,object_cleanup_state,lease_token,lease_expires_at)
            VALUES(\(bind:id),\(bind:owner),\(bind:"company-graph-"+UUID().uuidString),NOW(),'leased',NOW(),'blocked','not_applicable','pending',
                \(bind:lease),NOW()+INTERVAL '5 minutes')
            """).run()
        return id
    }
    private func child(graph: Graph, parentID: UUID) async throws -> UUID {
        let workspaceID=try graph.workspace.requireID(), ownerID=try graph.owner.requireID()
        return try await app.db.transaction { db in
            let sql=try VerifiedIdentityService.sql(db), confirmation=UUID(), now=Date()
            let inventory=try await AccountDeletionGraphService.companyInventory(workspaceID:workspaceID,on:db)
            let parentReceipt=try await sql.raw("SELECT receipt_hash FROM account_deletion_jobs WHERE id=\(bind:parentID)").first()!.decode(column:"receipt_hash",as:String.self)
            let revision=try await sql.raw("SELECT revision FROM teams WHERE id=\(bind:workspaceID)").first()!.decode(column:"revision",as:Int64.self)
            try await sql.raw("""
                INSERT INTO company_closure_confirmations(id,actor_user_id,workspace_id,reference_hash,receipt_hash,workspace_revision,
                    project_count,snag_count,other_member_count,inventory_hash,created_at,expires_at)
                VALUES(\(bind:confirmation),\(bind:ownerID),\(bind:workspaceID),\(bind:"ref-"+UUID().uuidString),\(bind:parentReceipt),\(bind:revision),
                    \(bind:inventory.projectCount),\(bind:inventory.snagCount),\(bind:inventory.otherMemberCount),\(bind:inventory.fingerprint),\(bind:now),\(bind:now.addingTimeInterval(600)))
                """).run()
            try await sql.raw("UPDATE company_closure_confirmations SET consumed_at=clock_timestamp() WHERE id=\(bind:confirmation)").run()
            let confirmed=CompanyClosureConfirmationService.Confirmed(confirmationID:confirmation,workspaceID:workspaceID,
                workspaceRevision:revision,inventory:inventory)
            try await CompanyClosureLifecycleService.create([confirmed],parentJobID:parentID,on:db)
            try await CompanyClosureLifecycleService.freezeAndSeal([confirmed],parentJobID:parentID,on:db)
            return try await sql.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind:parentID) AND workspace_id=\(bind:workspaceID)").first()!.decode(column:"id",as:UUID.self)
        }
    }

    func testExactCompanyGraphIsErasedAndUnrelatedCompanyIsRetained() async throws {
        let graph=try await makeGraph(), retained=try await makeGraph(name:"Retained company")
        let sql=try VerifiedIdentityService.sql(app.db), completion=UUID()
        try await sql.raw("INSERT INTO synced_photos(id,magic_link_token,snag_id,label,file_path,created_at) VALUES(\(bind:UUID()),\(bind:graph.linkToken),\(bind:graph.snag.requireID()),'evidence','/uploads/synced-photos/company.jpg',NOW())").run()
        try await sql.raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:completion),\(bind:graph.snag.requireID()),\(bind:graph.linkID),'Synthetic contractor','pending',NOW())").run()
        try await app.db.transaction { db in
            let scoped=try VerifiedIdentityService.sql(db)
            try await scoped.raw("LOCK TABLE completion_photos IN ACCESS EXCLUSIVE MODE").run()
            try await scoped.raw("ALTER TABLE completion_photos DISABLE TRIGGER completion_photo_trusted_insert").run()
            try await scoped.raw("INSERT INTO completion_photos(id,completion_id,url,uploaded_at) VALUES(\(bind:UUID()),\(bind:completion),'/uploads/photos/historical-company.jpg',NOW())").run()
            try await scoped.raw("ALTER TABLE completion_photos ENABLE TRIGGER completion_photo_trusted_insert").run()
        }
        let parentID=try await parent(owner:graph.owner.requireID()), childID=try await child(graph:graph,parentID:parentID)
        try await app.db.transaction { try await AccountDeletionGraphService.eraseCompany(workspaceID:graph.workspace.requireID(),closureJobID:childID,parentJobID:parentID,on:$0) }
        let erasedTeam=try await Team.find(graph.workspace.requireID(),on:app.db)
        let retainedTeam=try await Team.find(retained.workspace.requireID(),on:app.db)
        let retainedProject=try await Project.find(retained.project.requireID(),on:app.db)
        XCTAssertNil(erasedTeam); XCTAssertNotNil(retainedTeam); XCTAssertNotNil(retainedProject)
        for key in graph.mediaKeys + ["/uploads/synced-photos/company.jpg"] {
            let manifest=try await sql.raw("SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind:parentID) AND object_key=\(bind:key)").first()
            XCTAssertNotNil(manifest)
        }
        let unresolved=try await sql.raw("SELECT 1 FROM account_deletion_unresolved_objects WHERE job_id=\(bind:parentID) AND object_reference='/uploads/photos/historical-company.jpg'").first()
        XCTAssertNotNil(unresolved)
        let state=try await sql.raw("SELECT state,database_completed_at FROM company_closure_jobs WHERE id=\(bind:childID)").first()!
        XCTAssertEqual(try state.decode(column:"state",as:String.self),"awaiting_objects")
        XCTAssertNotNil(try state.decode(column:"database_completed_at",as:Date?.self))
    }

    func testWrongWorkspaceAndInventoryMismatchRollBackWithoutCrossCompanyDeletion() async throws {
        let graph=try await makeGraph(), other=try await makeGraph(name:"Other company")
        let parentID=try await parent(owner:graph.owner.requireID()), childID=try await child(graph:graph,parentID:parentID)
        try await app.db.transaction { db in
            let scoped=try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:parentID.uuidString),true),set_config('snaglist.company_closure_job_id',\(bind:childID.uuidString),true)").run()
            try await scoped.raw("UPDATE projects SET name='Changed after final seal' WHERE id=\(bind:graph.project.requireID())").run()
        }
        do {
            try await app.db.transaction { try await AccountDeletionGraphService.eraseCompany(workspaceID:graph.workspace.requireID(),closureJobID:childID,parentJobID:parentID,on:$0) }
            XCTFail("A changed post-freeze inventory must fail")
        } catch let error as Abort { XCTAssertEqual(error.identifier,"company_closure_inventory_changed") }
        let firstProject=try await Project.find(graph.project.requireID(),on:app.db)
        XCTAssertNotNil(firstProject)
        do {
            try await app.db.transaction { try await AccountDeletionGraphService.eraseCompany(workspaceID:other.workspace.requireID(),closureJobID:childID,parentJobID:parentID,on:$0) }
            XCTFail("A child cannot authorize another workspace")
        } catch let error as Abort { XCTAssertEqual(error.identifier,"company_closure_scope_mismatch") }
        let otherProject=try await Project.find(other.project.requireID(),on:app.db)
        XCTAssertNotNil(otherProject)
    }

    func testClosingWorkspaceRejectsDirectAndLegacyLateWrites() async throws {
        let graph=try await makeGraph(), other=try await makeGraph(name:"Open company")
        let completion=Completion(snagId:try graph.snag.requireID(),magicLinkId:graph.linkID,contractorName:"Synthetic")
        try await completion.save(on:app.db)
        try await HistoricalCompletionPhotoFixture.insert(completionID:try completion.requireID(),url:"https://example.test/company.jpg",on:app.db)
        let parentID=try await parent(owner:graph.owner.requireID())
        _=try await child(graph:graph,parentID:parentID)
        let sql=try VerifiedIdentityService.sql(app.db)
        do {
            try await sql.raw("UPDATE projects SET name='Late change' WHERE id=\(bind:graph.project.requireID())").run()
            XCTFail("Closing company updates must be rejected")
        } catch { }
        do {
            try await sql.raw("INSERT INTO synced_reports(id,magic_link_token,report_json,created_at) VALUES(\(bind:UUID()),\(bind:graph.linkToken),'{}',NOW())").run()
            XCTFail("A late legacy link write must be rejected")
        } catch { }
        do {
            try await sql.raw("UPDATE magic_links SET project_id=\(bind:other.project.requireID()) WHERE id=\(bind:graph.linkID)").run()
            XCTFail("A closing row cannot be moved into an active workspace")
        } catch { }
        do {
            try await sql.raw("DELETE FROM snags WHERE id=\(bind:graph.snag.requireID())").run()
            XCTFail("A late delete must not change the sealed graph")
        } catch { }
        do {
            try await sql.raw("DELETE FROM completions WHERE id=\(bind:completion.requireID())").run()
            XCTFail("A cascade cannot bypass a closing company's parent guard")
        } catch { }
        let retainedPhotoCount=try await sql.raw("SELECT count(*) count FROM completion_photos WHERE completion_id=\(bind:completion.requireID())").first()!.decode(column:"count",as:Int64.self)
        let name=try await sql.raw("SELECT name FROM projects WHERE id=\(bind:graph.project.requireID())").first()!.decode(column:"name",as:String.self)
        XCTAssertEqual(name,"Company project"); XCTAssertEqual(retainedPhotoCount,1)
    }

    func testOpenCompanyAndReleasedLegacyLinkWritesRemainAvailable() async throws {
        let graph=try await makeGraph(), sql=try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE projects SET name='Allowed open change' WHERE id=\(bind:graph.project.requireID())").run()
        let legacyID=UUID(), legacyToken="legacy-\(UUID())"
        try await sql.raw("""
            INSERT INTO magic_links(id,token,access_level,expires_at,snag_ids,project_id,created_by_id,created_at)
            VALUES(\(bind:legacyID),\(bind:legacyToken),'update',NOW()+INTERVAL '1 day','{}',\(bind:UUID()),\(bind:graph.owner.requireID()),NOW())
            """).run()
        try await sql.raw("INSERT INTO synced_reports(id,magic_link_token,report_json,created_at) VALUES(\(bind:UUID()),\(bind:legacyToken),'{}',NOW())").run()
        let legacyReport=try await SyncedReport.query(on:app.db).filter(\.$magicLinkToken == legacyToken).first()
        XCTAssertNotNil(legacyReport)
    }

    func testCrossWorkspaceHistoricalCompletionFailsClosed() async throws {
        let first=try await makeGraph(), second=try await makeGraph(name:"Retained company"), completion=UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at)
            VALUES(\(bind:completion),\(bind:first.snag.requireID()),\(bind:second.linkID),'Synthetic contractor','pending',NOW())
            """).run()
        do {
            _=try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID:first.workspace.requireID(),on:$0) }
            XCTFail("A row that resolves to two companies must not be assigned to either deletion graph")
        } catch let error as Abort { XCTAssertEqual(error.identifier,"company_closure_scope_ambiguous") }
        let retainedCompletion=try await Completion.find(completion,on:app.db)
        XCTAssertNotNil(retainedCompletion)
    }

    func testInventoryDetectsContentChangesWithoutCountChangesAndExcludesControlRows() async throws {
        let graph=try await makeGraph(), workspaceID=try graph.workspace.requireID()
        let first=try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID:workspaceID,on:$0) }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE projects SET name='Same count, changed data' WHERE id=\(bind:graph.project.requireID())").run()
        let second=try await app.db.transaction { try await AccountDeletionGraphService.companyInventory(workspaceID:workspaceID,on:$0) }
        XCTAssertEqual(first.projectCount,second.projectCount); XCTAssertNotEqual(first.fingerprint,second.fingerprint)
    }

    // MARK: - a write that belongs to two accounts, reached by the worker

    /// Makes every job that already existed undue, so the pass below can only claim
    /// this test's own. `run` claims by a global predicate.
    private func parkExistingJobs() async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET available_at=clock_timestamp()+INTERVAL '1 day',
                lease_expires_at=CASE WHEN state='leased' THEN clock_timestamp()+INTERVAL '1 day' ELSE lease_expires_at END
            WHERE state IN ('ready','blocked','leased')
            """).run()
    }

    /// Matrix #19, worker path.
    ///
    /// The same refusal as the request path, reached where nobody is present. A
    /// confirmed company closure defers the personal graph to the worker, and the
    /// worker's erase meets an intent it would have to capture whose import session
    /// belongs to a workspace this deletion does not touch. The transaction aborts,
    /// which is right — but it will abort again on every pass, and the generic
    /// handler used to record it as `worker_unavailable` on a five-minute retry, so
    /// the one condition that means "two accounts' writes are entangled" looked
    /// exactly like a flaky provider, for ever. It is now a durable block carrying
    /// its own reason, and the job stops climbing the backoff curve pretending to
    /// make progress.
    func testACrossScopeWriteBlocksTheWorkerWithItsOwnReasonRatherThanLookingUnavailable() async throws {
        try await parkExistingJobs()
        let graph = try await makeGraph(), elsewhere = try await makeGraph(name: "Unrelated company")
        let ownerID = try graph.owner.requireID()
        let parentID = try await parent(owner: ownerID)
        _ = try await child(graph: graph, parentID: parentID)
        let sql = try VerifiedIdentityService.sql(app.db)
        // An import session this account started inside a workspace this deletion
        // does not close. The write is the account's own; the session is not, so the
        // capture cannot be completed and must not be completed partially.
        let session = UUID(), hash = String(repeating: "a", count: 64)
        try await sql.raw("""
            INSERT INTO staged_legacy_imports(id,actor_id,workspace_id,workspace_kind,environment,api_origin,device_id,operation_id,
                auth_version,authority_fingerprint,source_project_id,source_fingerprint,export_sha256,export_byte_count,request_hash,
                state,revision,acknowledgement_version,acknowledgement_wording,acknowledged_at,created_at,updated_at,summary_json)
            VALUES(\(bind:session),\(bind:ownerID),\(bind:elsewhere.workspace.requireID()),'company','development','https://example.test',
                \(bind:UUID()),\(bind:UUID()),1,\(bind:hash),\(bind:UUID()),\(bind:hash),\(bind:hash),2,\(bind:hash),
                'staged_incomplete',1,'test-v1','Synthetic acknowledgement',NOW(),NOW(),NOW(),'{}')
            """).run()
        _ = try await app.db.transaction { db in
            try await ObjectWriteIntentRows.insert(
                .init(storageKind: "private_import", key: "staged-import/\(UUID())/original",
                      data: Data("synthetic".utf8), contentType: "application/pdf"),
                source: .init(kind: "staged_original", id: UUID(), sessionID: session),
                scope: .init(userID: ownerID), target: nil, on: db)
        }
        try await sql.raw("""
            UPDATE account_deletion_jobs SET state='ready',lease_token=NULL,lease_expires_at=NULL,
                available_at=clock_timestamp()-INTERVAL '1 minute' WHERE id=\(bind:parentID)
            """).run()
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked },
            deleteObject: { _, _ in XCTFail("Nothing is deleted while the capture cannot be completed") })

        let counts = try await AccountDeletionWorker.run(app: app, limit: 1)
        XCTAssertEqual(counts.processed, 1, "the parked rows leave exactly this job claimable")
        XCTAssertEqual(counts.blocked, 1, "an entanglement that cannot resolve itself is not a retry")
        XCTAssertEqual(counts.retrying, 0)
        let row = try await sql.raw("SELECT state,last_error_kind,database_cleanup_state FROM account_deletion_jobs WHERE id=\(bind:parentID)").first()!
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "blocked")
        XCTAssertEqual(try row.decode(column: "last_error_kind", as: String.self), "object_write_scope_ambiguous")
        XCTAssertEqual(try row.decode(column: "database_cleanup_state", as: String.self), "blocked",
                       "the personal graph is not erased while a write it must capture also belongs to somewhere else")
        let retainedUser = try await VerifiedIdentityService.sql(app.db).raw("SELECT lifecycle_state FROM users WHERE id=\(bind:ownerID)").first()!
        XCTAssertEqual(try retainedUser.decode(column: "lifecycle_state", as: String.self), "active",
                       "the request path never ran, so the account was never marked deleted")
    }
}
