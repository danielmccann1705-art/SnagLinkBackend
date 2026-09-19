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
}
