@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class AccountDeletionGraphTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user(_ name: String = "Synthetic member") async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("graph-delete-\(UUID())@example.test", name: name, on: db)
        }
    }
    private func project(owner: User, workspace: Team, name: String) async throws -> Project {
        let value = Project(id: UUID(), name: name, reference: UUID().uuidString.prefix(8).description, ownerId: try owner.requireID())
        value.workspaceId = try workspace.requireID(); value.platformManaged = true
        try await value.save(on: app.db)
        return value
    }
    private func snag(owner: User, project: Project) async throws -> Snag {
        let value = Snag(id: UUID(), reference: "S-1", title: "Synthetic snag", projectId: try project.requireID(), ownerId: try owner.requireID())
        value.workspaceId = project.workspaceId; value.displayNumber = 1; value.publishedAt = Date()
        try await value.save(on: app.db)
        return value
    }
    private func media(project: Project, snag: Snag, creator: User, prefix: String) async throws -> (String, String) {
        let original = "platform/\(prefix)/\(UUID())/original", rendition = "platform/\(prefix)/\(UUID())/rendition.jpg"
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,original_sha256,original_size,
                original_mime,original_key,rendition_key,rendition_sha256,rendition_size,width,height,revision,base_snag_revision,
                created_at,expires_at,ready_at,attached_at)
            VALUES(\(bind: UUID()),\(bind: project.workspaceId!),\(bind: project.requireID()),\(bind: snag.requireID()),\(bind: creator.requireID()),
                'capture','ready',\(bind: String(repeating:"a",count:64)),100,'image/jpeg',\(bind: original),\(bind: rendition),
                \(bind: String(repeating:"b",count:64)),90,10,10,1,1,NOW(),NOW()+INTERVAL '1 day',NOW(),NOW())
            """).run()
        return (original, rendition)
    }
    private func link(project: Project, creator: User, token: String = UUID().uuidString) async throws -> (UUID, String) {
        let id = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO magic_links(id,token,access_level,expires_at,snag_ids,project_id,created_by_id,created_at)
            VALUES(\(bind:id),\(bind:token),'view',NOW()+INTERVAL '1 day','{}',\(bind:project.requireID()),\(bind:creator.requireID()),NOW())
            """).run()
        return (id, token)
    }
    private func reference() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }
    private func stagedImport(actor: User, workspace: Team, kind: String = "personal") async throws -> UUID {
        let id=UUID(), sourceProjectID=UUID(), hash=String(repeating:"a",count:64)
        let sql=try VerifiedIdentityService.sql(app.db)
        try await sql.raw("""
            INSERT INTO staged_legacy_imports(id,actor_id,workspace_id,workspace_kind,environment,api_origin,device_id,operation_id,
                auth_version,authority_fingerprint,source_project_id,source_fingerprint,export_sha256,export_byte_count,request_hash,
                state,revision,acknowledgement_version,acknowledgement_wording,acknowledged_at,created_at,updated_at,summary_json)
            VALUES(\(bind:id),\(bind:actor.requireID()),\(bind:workspace.requireID()),\(bind:kind),'development','https://example.test',
                \(bind:UUID()),\(bind:UUID()),1,\(bind:hash),\(bind:sourceProjectID),\(bind:hash),\(bind:hash),2,\(bind:hash),
                'staged_incomplete',1,'test-v1','Synthetic acknowledgement',NOW(),NOW(),NOW(),'{}')
            """).run()
        try await sql.raw("INSERT INTO staged_legacy_import_sources(session_id,descriptor) VALUES(\(bind:id),decode('e30=','base64'))").run()
        return id
    }
    private func count(_ table: String, where clause: SQLQueryString) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE \(clause)").first()!.decode(column:"n",as:Int.self)
    }

    private struct Fixture {
        let target: User, personal: Project, company: Project, companySnag: Snag
        let personalKeys: [String], companyKeys: [String]
        let commentID: UUID, drawingID: UUID, pinSnagID: UUID
        let receiptOperation: UUID, importSession: UUID, legacyPhoto: String, legacyDrawing: String, completionPhoto: String
    }

    private func fixture() async throws -> Fixture {
        let target = try await user("Member Name"), owner = try await user("Company Owner")
        let personalWorkspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: target.requireID(), on: $0) }
        let companyWorkspace = try await app.db.transaction { db in
            let team = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic company", actorID: owner.requireID(), on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: target.requireID(), role: "member", on: db)
            return team
        }
        let personal = try await project(owner: target, workspace: personalWorkspace, name: "Private project")
        let company = try await project(owner: owner, workspace: companyWorkspace, name: "Company evidence")
        let importSession = try await stagedImport(actor:target,workspace:personalWorkspace)
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO project_access(project_id,workspace_id,user_id,role,state,revision,created_at,updated_at)
            VALUES(\(bind: company.requireID()),\(bind: companyWorkspace.requireID()),\(bind: target.requireID()),'member','active',1,NOW(),NOW())
            """).run()
        let personalSnag = try await snag(owner: target, project: personal)
        let companySnag = try await snag(owner: owner, project: company)
        let personalMedia = try await media(project: personal, snag: personalSnag, creator: target, prefix: "private")
        let companyMedia = try await media(project: company, snag: companySnag, creator: target, prefix: "company")

        let privateLink = try await link(project: personal, creator: target)
        let legacyPhoto = "/uploads/synced-photos/\(UUID()).jpg", legacyThumb = "/uploads/synced-photos/\(UUID())-thumb.jpg"
        let legacyDrawing = "/uploads/synced-drawings/\(UUID()).pdf"
        let completionPhoto = "/uploads/photos/\(UUID()).jpg", privateCompletion = UUID()
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO synced_photos(id,magic_link_token,snag_id,label,file_path,thumbnail_file_path,created_at) VALUES(\(bind:UUID()),\(bind:privateLink.1),\(bind:personalSnag.requireID()),'before',\(bind:legacyPhoto),\(bind:legacyThumb),NOW())").run()
        try await sql.raw("INSERT INTO synced_drawings(id,magic_link_token,drawing_id,file_path,file_name,created_at) VALUES(\(bind:UUID()),\(bind:privateLink.1),\(bind:UUID()),\(bind:legacyDrawing),'plan.pdf',NOW())").run()
        try await sql.raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:privateCompletion),\(bind:personalSnag.requireID()),\(bind:privateLink.0),'Synthetic contractor','pending',NOW())").run()
        try await HistoricalCompletionPhotoFixture.insert(completionID:privateCompletion,url:completionPhoto,on:app.db)

        let commentID = UUID()
        try await sql.raw("""
            INSERT INTO project_comments(id,workspace_id,project_id,snag_id,author_user_id,author_name,body,created_at)
            VALUES(\(bind:commentID),\(bind:company.workspaceId!),\(bind:company.requireID()),\(bind:companySnag.requireID()),
                \(bind:target.requireID()),'Member Name','Keep the company decision',NOW())
            """).run()
        try await sql.raw("UPDATE teams SET change_sequence=change_sequence+1 WHERE id=\(bind:company.workspaceId!)").run()
        let targetID = try target.requireID()
        let payload = "{\"id\":\"\(commentID.uuidString.lowercased())\",\"authorUserId\":\"\(targetID.uuidString.lowercased())\",\"authorName\":\"Member Name\",\"name\":\"Company evidence\"}"
        try await sql.raw("""
            INSERT INTO platform_changes(workspace_id,sequence,project_id,entity_type,entity_id,revision,kind,changed_fields,payload_json,actor_id,created_at,transaction_group)
            VALUES(\(bind:company.workspaceId!),1,\(bind:company.requireID()),'comment',\(bind:commentID),1,'created','{}',\(bind:payload),\(bind:owner.requireID()),NOW(),\(bind:UUID()))
            """).run()
        let receiptOperation = UUID()
        try await sql.raw("""
            INSERT INTO mutation_receipts(actor_id,operation_id,device_id,workspace_id,request_hash,result_json,created_at)
            VALUES(\(bind:target.requireID()),\(bind:receiptOperation),\(bind:UUID()),\(bind:company.workspaceId!),
                \(bind:String(repeating:"c",count:64)),\(bind:payload),NOW())
            """).run()

        // A company PDF, version page and pin remain even though the uploader/member is erased.
        let assetID=UUID(), pageID=UUID(), drawingID=UUID(), versionID=UUID(), versionPageID=UUID()
        try await app.db.transaction { db in
            let tx = try VerifiedIdentityService.sql(db)
            try await tx.raw("SET CONSTRAINTS ALL DEFERRED").run()
            try await tx.raw("""
                INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,original_mime,
                    original_filename,original_key,processor_profile,state,revision,created_at,expires_at,ready_at,published_at,result_hash)
                VALUES(\(bind:assetID),\(bind:company.workspaceId!),\(bind:company.requireID()),\(bind:target.requireID()),'drawing_source',
                    \(bind:String(repeating:"d",count:64)),100,'application/pdf','plan.pdf',\(bind:"drawings/company/\(assetID)/original"),
                    \(bind:"drawing-linux-byte-v1:"+String(repeating:"e",count:64)),'ready',3,NOW(),NOW()+INTERVAL '1 day',NOW(),NOW(),\(bind:String(repeating:"f",count:64)))
                """).run()
            try await tx.raw("""
                INSERT INTO drawing_asset_pages(id,asset_id,project_id,source_page_index,source_page_label,geometry_json,rendition_key,rendition_sha256,rendition_size,thumbnail_key,thumbnail_sha256,thumbnail_size)
                VALUES(\(bind:pageID),\(bind:assetID),\(bind:company.requireID()),0,'1','{}',\(bind:"drawings/company/\(assetID)/page.jpg"),
                    \(bind:String(repeating:"1",count:64)),100,\(bind:"drawings/company/\(assetID)/thumb.jpg"),\(bind:String(repeating:"2",count:64)),50)
                """).run()
            try await tx.raw("INSERT INTO drawings(id,workspace_id,project_id,name,sort_order,revision,current_version_id,created_by,created_at,updated_at) VALUES(\(bind:drawingID),\(bind:company.workspaceId!),\(bind:company.requireID()),'Sheet 1',0,1,\(bind:versionID),\(bind:target.requireID()),NOW(),NOW())").run()
            try await tx.raw("INSERT INTO drawing_versions(id,drawing_id,project_id,asset_id,version_number,published_by,published_at) VALUES(\(bind:versionID),\(bind:drawingID),\(bind:company.requireID()),\(bind:assetID),1,\(bind:target.requireID()),NOW())").run()
            try await tx.raw("INSERT INTO drawing_version_pages(id,version_id,drawing_id,asset_id,asset_page_id,project_id,page_index) VALUES(\(bind:versionPageID),\(bind:versionID),\(bind:drawingID),\(bind:assetID),\(bind:pageID),\(bind:company.requireID()),0)").run()
            try await tx.raw("INSERT INTO snag_drawing_pins(snag_id,project_id,drawing_id,version_id,version_page_id,x,y,revision,snag_revision,recorded_by,recorded_at) VALUES(\(bind:companySnag.requireID()),\(bind:company.requireID()),\(bind:drawingID),\(bind:versionID),\(bind:versionPageID),0.25,0.75,1,1,\(bind:target.requireID()),NOW())").run()
        }
        return .init(target:target,personal:personal,company:company,companySnag:companySnag,
                     personalKeys:[personalMedia.0,personalMedia.1,legacyPhoto,legacyThumb,legacyDrawing],companyKeys:[companyMedia.0,companyMedia.1,"drawings/company/\(assetID)/original"],
                     commentID:commentID,drawingID:drawingID,pinSnagID:try companySnag.requireID(),receiptOperation:receiptOperation,importSession:importSession,legacyPhoto:legacyPhoto,legacyDrawing:legacyDrawing,completionPhoto:completionPhoto)
    }

    func testPersonalGraphIsErasedButCompanyEvidencePDFAndPinRemain() async throws {
        let f = try await fixture(), ref = reference()
        let retainedOwner = try await user("Retained owner")
        let transferSource = try await user("Transfer source"), transferTarget = try await user("Transfer target")
        let personalOffer = UUID(), companyOffer = UUID()
        let sql = try VerifiedIdentityService.sql(app.db)
        try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO snag_deletions(id,snag_id,owner_id,project_id,file_paths,created_at) VALUES(\(bind:UUID()),\(bind:UUID()),\(bind:retainedOwner.requireID()),\(bind:f.company.requireID()),ARRAY[\(bind:f.legacyPhoto)],NOW())").run()
        try await sql.raw("""
            INSERT INTO ownership_transfer_offers(id,workspace_id,owner_user_id,target_user_id,workspace_revision,target_membership_revision,state,created_at)
            VALUES(\(bind:personalOffer),\(bind:f.personal.workspaceId!),\(bind:transferSource.requireID()),\(bind:transferTarget.requireID()),1,1,'pending',NOW()),
                  (\(bind:companyOffer),\(bind:f.company.workspaceId!),\(bind:transferSource.requireID()),\(bind:transferTarget.requireID()),1,1,'pending',NOW())
            """).run()
        _ = try await AccountDeletionService.request(userID: f.target.requireID(), body: .init(confirmation:"DELETE",receiptReference:ref), app:app)
        let erasedPersonal = try await Project.find(f.personal.requireID(), on: app.db)
        let retainedCompany = try await Project.find(f.company.requireID(), on: app.db)
        let drawingCount = try await count("drawings",where:"id=\(bind:f.drawingID)")
        let pinCount = try await count("snag_drawing_pins",where:"snag_id=\(bind:f.pinSnagID)")
        let importCount = try await count("staged_legacy_imports",where:"id=\(bind:f.importSession)")
        let personalOfferCount = try await count("ownership_transfer_offers",where:"id=\(bind:personalOffer)")
        let companyOfferCount = try await count("ownership_transfer_offers",where:"id=\(bind:companyOffer)")
        XCTAssertNil(erasedPersonal)
        XCTAssertNotNil(retainedCompany)
        XCTAssertEqual(drawingCount,1)
        XCTAssertEqual(pinCount,1)
        XCTAssertEqual(importCount,0)
        XCTAssertEqual(personalOfferCount,0)
        XCTAssertEqual(companyOfferCount,1)
        let comment = try await VerifiedIdentityService.sql(app.db).raw("SELECT author_name,body FROM project_comments WHERE id=\(bind:f.commentID)").first()!
        XCTAssertEqual(try comment.decode(column:"author_name",as:String.self),"Former member")
        XCTAssertEqual(try comment.decode(column:"body",as:String.self),"Keep the company decision")
        let propagated = try await VerifiedIdentityService.sql(app.db).raw("SELECT revision,kind,changed_fields,payload_json FROM platform_changes WHERE entity_id=\(bind:f.commentID) ORDER BY sequence DESC LIMIT 1").first()!
        XCTAssertEqual(try propagated.decode(column:"revision",as:Int64.self),2)
        XCTAssertEqual(try propagated.decode(column:"kind",as:String.self),"updated")
        XCTAssertEqual(try propagated.decode(column:"changed_fields",as:[String].self),["authorName"])
        let propagatedPayload=try propagated.decode(column:"payload_json",as:String.self)
        XCTAssertTrue(propagatedPayload.contains("Former member")); XCTAssertFalse(propagatedPayload.contains("Member Name"))
        try await ProjectCommentService.requireCurrentContent(projectID:f.company.requireID(),since:1,on:app.db)
        let departure = try await VerifiedIdentityService.sql(app.db).raw("SELECT detail FROM workspace_activity WHERE workspace_id=\(bind:f.company.workspaceId!) AND action='member_removed' AND actor_user_id=\(bind:f.target.requireID()) AND target_id=\(bind:f.target.requireID()) ORDER BY created_at DESC LIMIT 1").first()
        let departureDetail=try departure?.decode(column:"detail",as:String?.self)
        XCTAssertNotNil(departure); XCTAssertNil(departureDetail)
        let job = try await VerifiedIdentityService.sql(app.db).raw("SELECT id,database_cleanup_state,object_cleanup_state,last_error_kind FROM account_deletion_jobs WHERE user_id=\(bind:f.target.requireID())").first()!
        XCTAssertEqual(try job.decode(column:"database_cleanup_state",as:String.self),"completed")
        XCTAssertEqual(try job.decode(column:"object_cleanup_state",as:String.self),"blocked")
        XCTAssertEqual(try job.decode(column:"last_error_kind",as:String.self),"unresolved_legacy_object_ownership")
        let jobID = try job.decode(column:"id",as:UUID.self)
        let keys = try await VerifiedIdentityService.sql(app.db).raw("SELECT storage_kind,object_key FROM account_deletion_objects WHERE job_id=\(bind:jobID)").all()
        let manifested = try Set(keys.map { try $0.decode(column:"object_key",as:String.self) })
        XCTAssertTrue(Set(f.personalKeys).isSubset(of:manifested))
        XCTAssertFalse(manifested.contains(f.completionPhoto),"A client-supplied URL is not trusted object ownership evidence")
        XCTAssertTrue(Set(f.companyKeys).isDisjoint(with:manifested),"Company media must not follow its uploader into erasure")
        XCTAssertTrue(keys.contains { (try? $0.decode(column:"storage_kind",as:String.self)) == "legacy_drawing" })
        let unresolved = try await VerifiedIdentityService.sql(app.db).raw("SELECT reason FROM account_deletion_unresolved_objects WHERE job_id=\(bind:jobID) AND object_reference=\(bind:f.completionPhoto)").first()!
        XCTAssertEqual(try unresolved.decode(column:"reason",as:String.self),"unknown_local_namespace")
        let legacyPhotoStillReferenced = try await AccountDeletionGraphService.objectIsReferenced(kind:"legacy_photo",key:f.legacyPhoto,on:app.db)
        let legacyDrawingStillReferenced = try await AccountDeletionGraphService.objectIsReferenced(kind:"legacy_drawing",key:f.legacyDrawing,on:app.db)
        XCTAssertTrue(legacyPhotoStillReferenced,"A surviving deletion backlog must prevent storage deletion")
        XCTAssertFalse(legacyDrawingStillReferenced)
    }

    func testCopiedPayloadsAreStructurallyRedactedAndReceiptStillRecognisesOperation() async throws {
        let f=try await fixture(); _=try await AccountDeletionService.request(userID:f.target.requireID(),body:.init(confirmation:"DELETE",receiptReference:reference()),app:app)
        // The append-only change log also contains the new pseudonymised DTO.
        // Inspect the original copied payload explicitly; SQL row order is not a contract.
        let payload=try await VerifiedIdentityService.sql(app.db).raw("SELECT payload_json FROM platform_changes WHERE entity_id=\(bind:f.commentID) AND sequence=1").first()!.decode(column:"payload_json",as:String.self)
        XCTAssertTrue(payload.contains("Former member")); XCTAssertTrue(payload.contains("Company evidence")); XCTAssertFalse(payload.contains("Member Name"))
        let allCopies = try await VerifiedIdentityService.sql(app.db).raw("SELECT payload_json FROM platform_changes WHERE entity_id=\(bind:f.commentID) ORDER BY sequence").all()
        XCTAssertGreaterThanOrEqual(allCopies.count, 2)
        for row in allCopies {
            let copy = try row.decode(column: "payload_json", as: String.self)
            XCTAssertTrue(copy.contains("Former member")); XCTAssertFalse(copy.contains("Member Name"))
        }
        let receipt=try await VerifiedIdentityService.sql(app.db).raw("SELECT request_hash,result_json,account_deletion_redacted_at FROM mutation_receipts WHERE actor_id=\(bind:f.target.requireID()) AND operation_id=\(bind:f.receiptOperation)").first()!
        XCTAssertEqual(try receipt.decode(column:"request_hash",as:String.self),String(repeating:"c",count:64))
        XCTAssertEqual(try receipt.decode(column:"result_json",as:String.self),"{\"accountDeletionRedacted\":true}")
        XCTAssertNotNil(try receipt.decode(column:"account_deletion_redacted_at",as:Date?.self))
        do {
            _ = try await PlatformMutationService.replay(PlatformJSON.self,actorID:f.target.requireID(),
                mutation:.init(operationId:f.receiptOperation,deviceId:UUID()),hash:String(repeating:"c",count:64),on:app.db)
            XCTFail("A late retry must be recognised without decoding or reapplying its removed body")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status,.conflict); XCTAssertEqual(abort.identifier,"already_applied_refresh_required")
        }
    }

    func testGraphRejectsCrossAccountJob() async throws {
        let first=try await user(), second=try await user(), job=UUID()
        try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,database_cleanup_state,apple_revocation_state,object_cleanup_state,last_error_kind) VALUES(\(bind:job),\(bind:first.requireID()),\(bind:UUID().uuidString),NOW(),'ready',NOW(),'blocked','not_applicable','blocked','database_erasure_pending')").run()
        do { try await app.db.transaction { try await AccountDeletionGraphService.erase(userID:second.requireID(),jobID:job,on:$0) }; XCTFail("Cross-account job must fail") } catch { }
        let state=try await VerifiedIdentityService.sql(app.db).raw("SELECT database_cleanup_state FROM account_deletion_jobs WHERE id=\(bind:job)").first()!.decode(column:"database_cleanup_state",as:String.self)
        XCTAssertEqual(state,"blocked")
    }

    func testImportImmutableEscapeRejectsForeignDeletionJobScope() async throws {
        let owner=try await user(), foreign=try await user()
        let personal=try await app.db.transaction { try await WorkspaceAccessService.personal(for:owner.requireID(),on:$0) }
        let session=try await stagedImport(actor:owner,workspace:personal), job=UUID()
        let sql=try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,database_cleanup_state,apple_revocation_state,object_cleanup_state,last_error_kind) VALUES(\(bind:job),\(bind:foreign.requireID()),\(bind:UUID().uuidString),NOW(),'ready',NOW(),'blocked','not_applicable','blocked','database_erasure_pending')").run()
        do {
            try await app.db.transaction { db in
                let tx=try VerifiedIdentityService.sql(db)
                try await tx.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:job.uuidString),true)").run()
                try await tx.raw("DELETE FROM staged_legacy_import_sources WHERE session_id=\(bind:session)").run()
            }
            XCTFail("A foreign job must not unlock another account's immutable import")
        } catch { }
        let retainedSourceCount=try await count("staged_legacy_import_sources",where:"session_id=\(bind:session)")
        XCTAssertEqual(retainedSourceCount,1)
    }

    func testGraphFailureRollsBackIdentityJobManifestAndPersonalRows() async throws {
        let f=try await fixture()
        let targetID=try f.target.requireID()
        let malformed="{\"authorUserId\":\"\(targetID.uuidString.lowercased())\",not-json"
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE platform_changes SET payload_json=\(bind:malformed) WHERE entity_id=\(bind:f.commentID)").run()
        do {
            _=try await AccountDeletionService.request(userID:f.target.requireID(),body:.init(confirmation:"DELETE",receiptReference:reference()),app:app)
            XCTFail("Malformed retained payload must fail closed")
        } catch { }
        let user=try await VerifiedIdentityService.activeUser(f.target.requireID(),on:app.db)
        let retainedPersonal = try await Project.find(f.personal.requireID(),on:app.db)
        let jobCount = try await count("account_deletion_jobs",where:"user_id=\(bind:f.target.requireID())")
        XCTAssertNotNil(user.email)
        XCTAssertNotNil(retainedPersonal)
        XCTAssertEqual(jobCount,0)
    }

    func testGraphIsIdempotentAndOrdinaryImmutableDeletesStayBlocked() async throws {
        let f=try await fixture(), ref=reference(); _=try await AccountDeletionService.request(userID:f.target.requireID(),body:.init(confirmation:"DELETE",receiptReference:ref),app:app)
        let job=try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind:f.target.requireID())").first()!.decode(column:"id",as:UUID.self)
        try await app.db.transaction { try await AccountDeletionGraphService.erase(userID:f.target.requireID(),jobID:job,on:$0) }
        let retainedCompany = try await Project.find(f.company.requireID(),on:app.db)
        XCTAssertNotNil(retainedCompany)
        do { try await VerifiedIdentityService.sql(app.db).raw("DELETE FROM drawing_asset_pages WHERE project_id=\(bind:f.company.requireID())").run(); XCTFail("Ordinary immutable delete must fail") } catch { }
    }

    func testSharedCompletionPhotoReferenceIsDurableAndBlocksFalseCompletion() async throws {
        let f=try await fixture(), owner=try await user(), companyLink=try await link(project:f.company,creator:owner), completion=UUID()
        let sql=try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:completion),\(bind:f.companySnag.requireID()),\(bind:companyLink.0),'Company contractor','pending',NOW())").run()
        try await HistoricalCompletionPhotoFixture.insert(completionID:completion,url:f.completionPhoto,on:app.db)
        _=try await AccountDeletionService.request(userID:f.target.requireID(),body:.init(confirmation:"DELETE",receiptReference:reference()),app:app)
        let job=try await sql.raw("SELECT id,object_cleanup_state,last_error_kind FROM account_deletion_jobs WHERE user_id=\(bind:f.target.requireID())").first()!
        XCTAssertEqual(try job.decode(column:"object_cleanup_state",as:String.self),"blocked")
        XCTAssertEqual(try job.decode(column:"last_error_kind",as:String.self),"unresolved_legacy_object_ownership")
        let jobID=try job.decode(column:"id",as:UUID.self)
        let unresolved=try await sql.raw("SELECT object_reference,reason FROM account_deletion_unresolved_objects WHERE job_id=\(bind:jobID)").first()!
        XCTAssertEqual(try unresolved.decode(column:"object_reference",as:String.self),f.completionPhoto)
        XCTAssertEqual(try unresolved.decode(column:"reason",as:String.self),"shared_reference")
        let companyPhotoCount = try await count("completion_photos",where:"completion_id=\(bind:completion)")
        XCTAssertEqual(companyPhotoCount,1,"Company reference must remain")
    }

    func testTerminalUserCannotCreateLateLegacyGraphOrLinkCopies() async throws {
        let target=try await user(), personal=try await app.db.transaction { try await WorkspaceAccessService.personal(for:target.requireID(),on:$0) }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET lifecycle_state='deleted',email=NULL,name=NULL WHERE id=\(bind:target.requireID())").run()
        let late=Project(id:UUID(),name:"Late",reference:"LATE",ownerId:try target.requireID()); late.workspaceId=try personal.requireID()
        do { try await late.save(on:app.db); XCTFail("Late project must be rejected") } catch { }
        do {
            try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO synced_drawings(id,magic_link_token,drawing_id,file_path,file_name,created_at) VALUES(\(bind:UUID()),'missing',\(bind:UUID()),'/uploads/synced-drawings/late.pdf','late.pdf',NOW())").run()
            XCTFail("Unbound legacy copy must be rejected")
        } catch { }
    }

    // MARK: - what the enumeration edges do and do not take

    /// Matrix #9. The `p.id IN account_deletion_projects` conjunct, exercised with
    /// a company project.
    ///
    /// A Contractor link is owned by the account that created it, because a link has
    /// no account behind it and `created_by_id` is the only party with an identity.
    /// That ownership is still bounded by the project: a link this account created
    /// on somebody else's company project names photographs that belong to the
    /// company, and they are not this deletion's to destroy.
    func testAContractorLinkOnACompanyProjectIsNeverEnumerated() async throws {
        let target = try await user("Departing member"), owner = try await user("Company owner")
        let companyWorkspace = try await app.db.transaction { db -> Team in
            let team = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Retained company", actorID: owner.requireID(), on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: target.requireID(), role: "member", on: db)
            return team
        }
        let companyProject = try await project(owner: owner, workspace: companyWorkspace, name: "Company project")
        let companySnag = try await snag(owner: owner, project: companyProject)
        let companyLink = try await link(project: companyProject, creator: target)
        let photo = "/uploads/synced-photos/\(UUID()).jpg", thumbnail = "/uploads/synced-photos/\(UUID())-thumb.jpg"
        let drawing = "/uploads/synced-drawings/\(UUID()).pdf"
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO synced_photos(id,magic_link_token,snag_id,label,file_path,thumbnail_file_path,created_at) VALUES(\(bind:UUID()),\(bind:companyLink.1),\(bind:companySnag.requireID()),'before',\(bind:photo),\(bind:thumbnail),NOW())").run()
        try await sql.raw("INSERT INTO synced_drawings(id,magic_link_token,drawing_id,file_path,file_name,created_at) VALUES(\(bind:UUID()),\(bind:companyLink.1),\(bind:UUID()),\(bind:drawing),'plan.pdf',NOW())").run()

        _ = try await AccountDeletionService.request(userID: target.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)

        let jobID = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind:target.requireID())").first()!.decode(column: "id", as: UUID.self)
        let rows = try await sql.raw("SELECT object_key FROM account_deletion_objects WHERE job_id=\(bind:jobID)").all()
        let manifested = try Set(rows.map { try $0.decode(column: "object_key", as: String.self) })
        XCTAssertTrue(Set([photo, thumbnail, drawing]).isDisjoint(with: manifested),
                      "a Contractor link on a company project follows the project, never the account that made the link")
        let photoCount = try await count("synced_photos", where: "magic_link_token=\(bind:companyLink.1)")
        let drawingCount = try await count("synced_drawings", where: "magic_link_token=\(bind:companyLink.1)")
        let linkCount = try await count("magic_links", where: "id=\(bind:companyLink.0)")
        XCTAssertEqual(photoCount, 1, "the company's evidence survives its member's deletion")
        XCTAssertEqual(drawingCount, 1)
        XCTAssertEqual(linkCount, 1, "the link is revoked, not erased, because the project it serves is retained")
    }

    /// Matrix #13 and #14. The only uploader-rooted rule in the manifest, and both
    /// halves of what makes it safe.
    ///
    /// An upload the account allocated and nothing shows is the account's own to
    /// destroy. The same upload, once a completion this deletion is *not* erasing
    /// still displays it, is not — and the difference is a negative existence test
    /// over retained completions, not a second ownership edge.
    func testTheUploaderBranchTakesAnUnshownUploadAndNeverOneARetainedCompletionDisplays() async throws {
        let target = try await user("Upload owner"), retainedOwner = try await user("Retained owner")
        _ = try await app.db.transaction { try await WorkspaceAccessService.personal(for: target.requireID(), on: $0) }
        let retainedWorkspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: retainedOwner.requireID(), on: $0) }
        let retainedProject = try await project(owner: retainedOwner, workspace: retainedWorkspace, name: "Retained project")
        let retainedSnag = try await snag(owner: retainedOwner, project: retainedProject)
        let retainedLink = try await link(project: retainedProject, creator: retainedOwner)
        let retainedCompletion = UUID(), sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:retainedCompletion),\(bind:retainedSnag.requireID()),\(bind:retainedLink.0),'Synthetic contractor','pending',NOW())").run()

        let unshown = try await CompletionUploadObjectService.allocate(
            principal: .user(try target.requireID()), fileExtension: "jpg", contentType: "image/jpeg", fileSize: 128, on: app.db)
        let displayed = try await CompletionUploadObjectService.allocate(
            principal: .user(try target.requireID()), fileExtension: "jpg", contentType: "image/jpeg", fileSize: 128, on: app.db)
        // The live route cannot produce this row: `require_trusted_completion_photo`
        // insists an attached upload and its completion share a Contractor link, and
        // a signed-in upload has none. That guard is the first layer. The fixture
        // synthesises the row it exists to prevent, so that the manifest's own
        // negative test is proved to hold on its own rather than by relying on it.
        //
        // The second deliberate exception to the rule that a test never disables a
        // production trigger — `HistoricalCompletionPhotoFixture` is the other — and
        // the only one that is not a pre-migration row. It cannot be written any
        // other way. The uploader branch keys on `uploaded_by_user_id`, which only a
        // `.user` allocation sets, and `CompletionUploadObjectService.attach`, the
        // sole product writer of `completion_photos`, takes a Contractor link and so
        // can only ever attach a link-owned upload. Building `displayed` from a link
        // instead would let the insert through and leave the assertion passing for
        // the wrong reason: a link-owned object is excluded from the manifest because
        // it is not uploader-rooted at all, which is not what the negative existence
        // test over retained completions is about.
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("LOCK TABLE completion_photos IN ACCESS EXCLUSIVE MODE").run()
            try await scoped.raw("ALTER TABLE completion_photos DISABLE TRIGGER completion_photo_trusted_insert").run()
            try await scoped.raw("""
                INSERT INTO completion_photos(id,completion_id,url,uploaded_at,upload_object_id)
                VALUES(\(bind:displayed.id),\(bind:retainedCompletion),\(bind:displayed.issuedURL),NOW(),\(bind:displayed.id))
                """).run()
            try await scoped.raw("ALTER TABLE completion_photos ENABLE TRIGGER completion_photo_trusted_insert").run()
        }

        _ = try await AccountDeletionService.request(userID: target.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)

        let jobID = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind:target.requireID())").first()!.decode(column: "id", as: UUID.self)
        let rows = try await sql.raw("SELECT object_key FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND storage_kind='legacy_completion_photo'").all()
        let manifested = try Set(rows.map { try $0.decode(column: "object_key", as: String.self) })
        XCTAssertEqual(manifested, Set([unshown.storageKey, unshown.thumbnailKey]),
                       "the allocation nothing shows is enumerated; the one a retained completion displays is absent")
        let survived = try await count("completion_upload_objects", where: "id=\(bind:displayed.id)")
        let released = try await count("completion_upload_objects", where: "id=\(bind:unshown.id)")
        XCTAssertEqual(survived, 1, "an object a retained completion still displays is not even removed from the registry")
        XCTAssertEqual(released, 0)
    }

    // MARK: - one physical object, two spellings

    /// Matrix #30. The historical writer stores a synced photo's path with a
    /// leading slash and records the write intent for the very same bytes without
    /// one, so one object reaches the manifest as two rows.
    ///
    /// Before this packet only one of them was protected: the fence exclusion
    /// compared physical keys but the unresolved-write exclusion compared exact
    /// strings, so the slashed row found no intent, passed every check, and was
    /// deleted while a write to that address was still in flight — and
    /// `deleteOwnedSyncedPhoto` strips the slash before deleting, so it was the
    /// same object.
    func testOneLegacyObjectUnderBothSpellingsIsProtectedTogetherAndDeletedOnce() async throws {
        let target = try await user("Sync owner")
        let workspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: target.requireID(), on: $0) }
        let personal = try await project(owner: target, workspace: workspace, name: "Private project")
        let personalSnag = try await snag(owner: target, project: personal)
        let personalLink = try await link(project: personal, creator: target)
        let filename = "\(UUID()).jpg"
        let slashed = "/uploads/synced-photos/\(filename)", unslashed = "uploads/synced-photos/\(filename)"
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO synced_photos(id,magic_link_token,snag_id,label,file_path,created_at) VALUES(\(bind:UUID()),\(bind:personalLink.1),\(bind:personalSnag.requireID()),'before',\(bind:slashed),NOW())").run()
        let writeID = try await app.db.transaction { db in
            try await ObjectWriteIntentRows.insert(
                .init(storageKind: "legacy_photo", key: unslashed, data: Data("synthetic".utf8), contentType: "image/jpeg"),
                source: .init(kind: "legacy_link", id: personalLink.0),
                scope: .init(userID: try target.requireID(), projectID: try personal.requireID(), magicLinkID: personalLink.0),
                target: nil, on: db)
        }
        let deleted = DeletedKeys()
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked }, deleteObject: { _, key in await deleted.record(key) })

        _ = try await AccountDeletionService.request(userID: target.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)
        let jobID = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind:target.requireID())").first()!.decode(column: "id", as: UUID.self)
        let manifestRows = try await sql.raw("SELECT object_key FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND storage_kind='legacy_photo'").all()
        let manifested = try Set(manifestRows.map { try $0.decode(column: "object_key", as: String.self) })
        XCTAssertEqual(manifested, Set([slashed, unslashed]), "the graph and the intent spell the same object two ways")

        // While the write is unresolved, neither spelling may be touched.
        let blockedState = try await pass(jobID: jobID, userID: try target.requireID())
        let untouched = await deleted.all()
        XCTAssertTrue(untouched.isEmpty, "a write that may still create these bytes blocks both rows, not just its own spelling")
        XCTAssertEqual(blockedState, "blocked")

        try await sql.raw("UPDATE object_write_intents SET state='settled',settled_at=NOW() WHERE id=\(bind:writeID)").run()
        let finalState = try await pass(jobID: jobID, userID: try target.requireID())
        XCTAssertEqual(finalState, "completed")
        let attempted = await deleted.all()
        let physical = Set(attempted.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 })
        XCTAssertEqual(physical, Set([unslashed]), "two manifest rows, one physical object, and the repeat is idempotent")
        let pending = try await count("account_deletion_objects", where: "job_id=\(bind:jobID) AND completed_at IS NULL")
        XCTAssertEqual(pending, 0)
    }

    // MARK: - a write that belongs to two accounts

    /// Matrix #19, request path. An intent this deletion would have to capture also
    /// names an import session outside its scope, so the graph refuses to capture a
    /// partial set and the whole request fails. Nothing has been destroyed, the
    /// person is present, and they can retry once the entanglement is gone.
    func testACrossScopeWriteAbortsTheDeletionRequestAndErasesNothing() async throws {
        let target = try await user("Entangled writer"), companyOwner = try await user("Unrelated owner")
        let personalWorkspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: target.requireID(), on: $0) }
        let personal = try await project(owner: target, workspace: personalWorkspace, name: "Private project")
        let foreignWorkspace = try await app.db.transaction { db in
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Unrelated company", actorID: companyOwner.requireID(), on: db)
        }
        let foreignSession = try await stagedImport(actor: target, workspace: foreignWorkspace, kind: "company")
        _ = try await app.db.transaction { db in
            try await ObjectWriteIntentRows.insert(
                .init(storageKind: "private_import", key: "staged-import/\(UUID())/original",
                      data: Data("synthetic".utf8), contentType: "application/pdf"),
                source: .init(kind: "staged_original", id: UUID(), sessionID: foreignSession),
                scope: .init(userID: try target.requireID()), target: nil, on: db)
        }
        do {
            _ = try await AccountDeletionService.request(userID: target.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)
            XCTFail("A write that crosses the deletion boundary must refuse the whole request")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .conflict)
            XCTAssertEqual(abort.identifier, "object_write_scope_ambiguous")
        }
        let account = try await VerifiedIdentityService.activeUser(target.requireID(), on: app.db)
        let retained = try await Project.find(personal.requireID(), on: app.db)
        let jobCount = try await count("account_deletion_jobs", where: "user_id=\(bind:target.requireID())")
        XCTAssertNotNil(account.email, "the account is untouched")
        XCTAssertNotNil(retained)
        XCTAssertEqual(jobCount, 0, "and no job is left behind to retry something that cannot succeed")
    }

    // MARK: - the re-proof made immediately before a destructive act

    /// Matrix #43. Layer 2 is the check made immediately before a physical delete;
    /// layer 3 is the check made before a fence, which destroys nothing. The
    /// destructive one must not be the weaker of the two, so it now asks the fence's
    /// own question — `object_erasure_has_graph_reference` over all six kinds —
    /// rather than keeping a second copy of it for the row's own kind alone.
    func testLayerTwoRefusesAKeyAnyOfTheSixKindsStillReferences() async throws {
        let owner = try await user("Reference owner")
        let workspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: owner.requireID(), on: $0) }
        let live = try await project(owner: owner, workspace: workspace, name: "Live project")
        let liveSnag = try await snag(owner: owner, project: live)
        let keys = try await media(project: live, snag: liveSnag, creator: owner, prefix: "live")
        let kinds = ["private_media", "private_drawing", "private_import", "legacy_photo", "legacy_drawing", "legacy_completion_photo"]
        for kind in kinds {
            let referenced = try await AccountDeletionGraphService.objectIsReferenced(kind: kind, key: keys.0, on: app.db)
            XCTAssertTrue(referenced, "a live media row must stop a delete offered under \(kind)")
        }
        let unnamed = "platform/live/\(UUID())/original"
        for kind in kinds {
            let referenced = try await AccountDeletionGraphService.objectIsReferenced(kind: kind, key: unnamed, on: app.db)
            XCTAssertFalse(referenced, "\(kind): an address nothing names is not made referenced by asking about it")
        }
        do {
            _ = try await AccountDeletionGraphService.objectIsReferenced(kind: "private_video", key: keys.0, on: app.db)
            XCTFail("A manifest row of an unknown kind is corrupt, not a licence to guess what it meant")
        } catch { }
    }

    // MARK: - helpers for the cases above

    /// Records every physical address the worker was asked to delete.
    actor DeletedKeys {
        private var keys: [String] = []
        func record(_ key: String) { keys.append(key) }
        func all() -> [String] { keys }
    }

    /// One worker pass over this account's job, under a lease PostgreSQL issued.
    private func pass(jobID: UUID, userID: UUID) async throws -> String? {
        let token = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:token),
                lease_expires_at=clock_timestamp()+INTERVAL '5 minutes' WHERE id=\(bind:jobID)
            """).run()
        let lease = AccountDeletionWorker.Lease(id: jobID, userID: userID, token: token, attempt: 1)
        try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
        return try await AccountDeletionWorker.finish(lease, on: app.db)
    }
}
