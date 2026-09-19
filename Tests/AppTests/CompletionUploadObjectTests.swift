@testable import App
import XCTVapor
import Fluent
import FluentSQL
import PostgresNIO

final class CompletionUploadObjectTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil,"Isolated synthetic PostgreSQL required")
        app=try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self]=true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user() async throws -> User {
        try await app.db.transaction { try await VerifiedIdentityService.resolveEmail("upload-\(UUID())@example.test",name:"Synthetic uploader",on:$0) }
    }
    private func graph(owner: User) async throws -> (Project,Snag,MagicLink) {
        let workspace=try await app.db.transaction { try await WorkspaceAccessService.personal(for:owner.requireID(),on:$0) }
        let project=Project(id:UUID(),name:"Synthetic project",reference:UUID().uuidString,ownerId:try owner.requireID())
        project.workspaceId=try workspace.requireID(); project.platformManaged=true; try await project.save(on:app.db)
        let snag=Snag(id:UUID(),reference:"S-1",title:"Synthetic snag",projectId:try project.requireID(),ownerId:try owner.requireID())
        snag.workspaceId=try workspace.requireID(); snag.displayNumber=1; snag.publishedAt=Date(); try await snag.save(on:app.db)
        let link=MagicLink(id:UUID(),token:"upload-\(UUID())",accessLevel:.update,expiresAt:Date().addingTimeInterval(3600),
                           snagIds:[try snag.requireID()],projectId:try project.requireID(),createdById:try owner.requireID())
        try await link.save(on:app.db)
        return (project,snag,link)
    }
    private func ready(_ principal: CompletionUploadObjectService.Principal) async throws -> CompletionUploadObjectService.Allocation {
        let allocation=try await CompletionUploadObjectService.allocate(principal:principal,fileExtension:"jpg",contentType:"image/jpeg",fileSize:128,on:app.db)
        try await app.db.transaction { db in
            try await CompletionUploadObjectService.lockForWrite(allocation,on:db)
            try await CompletionUploadObjectService.markReady(allocation,thumbnailReady:true,on:db)
        }
        return allocation
    }

    func testExactIssuedURLAttachesOnceWithStableIdentity() async throws {
        let owner=try await user(), (_,snag,link)=try await graph(owner:owner), completion=UUID()
        let snagID=try snag.requireID(), linkID=try link.requireID()
        let principal=CompletionUploadObjectService.Principal.link(id:linkID,projectID:link.projectId,creatorID:link.createdById)
        let allocation=try await ready(principal)
        try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:completion),\(bind:snagID),\(bind:linkID),'Synthetic contractor','pending',NOW())").run()
        try await app.db.transaction { try await CompletionUploadObjectService.attach(urls:[allocation.issuedURL],completionID:completion,link:link,on:$0) }
        let row=try await VerifiedIdentityService.sql(app.db).raw("SELECT id,upload_object_id,url,thumbnail_url FROM completion_photos WHERE completion_id=\(bind:completion)").first()!
        let photoID=try row.decode(column:"id",as:UUID.self)
        let objectID=try row.decode(column:"upload_object_id",as:UUID.self)
        let issuedURL=try row.decode(column:"url",as:String.self)
        let thumbnailURL=try row.decode(column:"thumbnail_url",as:String.self)
        XCTAssertEqual(photoID,allocation.id); XCTAssertEqual(objectID,allocation.id)
        XCTAssertEqual(issuedURL,allocation.issuedURL); XCTAssertEqual(thumbnailURL,allocation.plannedThumbnailURL)
        do {
            try await app.db.transaction { try await CompletionUploadObjectService.attach(urls:[allocation.issuedURL],completionID:completion,link:link,on:$0) }
            XCTFail("An attached upload object must not attach twice")
        } catch { }
        let count=try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM completion_photos WHERE upload_object_id=\(bind:allocation.id)").first()!.decode(column:"n",as:Int.self)
        XCTAssertEqual(count,1)
    }

    func testForgedHistoricalAndOtherLinkURLsCannotManufactureOwnership() async throws {
        let first=try await user(), second=try await user()
        let (_,firstSnag,firstLink)=try await graph(owner:first), (_,secondSnag,secondLink)=try await graph(owner:second)
        let principal=CompletionUploadObjectService.Principal.link(id:try firstLink.requireID(),projectID:firstLink.projectId,creatorID:firstLink.createdById)
        let allocation=try await ready(principal), completion=UUID()
        let firstSnagID=try firstSnag.requireID(), secondSnagID=try secondSnag.requireID(), secondLinkID=try secondLink.requireID()
        try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO completions(id,snag_id,magic_link_id,contractor_name,status,submitted_at) VALUES(\(bind:completion),\(bind:secondSnagID),\(bind:secondLinkID),'Synthetic contractor','pending',NOW())").run()
        for url in [allocation.issuedURL,"https://example.test/uploads/photos/forged.jpg"] {
            do {
                try await app.db.transaction { try await CompletionUploadObjectService.attach(urls:[url],completionID:completion,link:secondLink,on:$0) }
                XCTFail("An unissued or other-link URL must be rejected")
            } catch { }
        }
        let photoCount=try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM completion_photos WHERE completion_id=\(bind:completion)").first()!.decode(column:"n",as:Int.self)
        let state=try await VerifiedIdentityService.sql(app.db).raw("SELECT state FROM completion_upload_objects WHERE id=\(bind:allocation.id)").first()!.decode(column:"state",as:String.self)
        XCTAssertEqual(photoCount,0); XCTAssertEqual(state,"ready")
        XCTAssertNotEqual(firstSnagID,secondSnagID)
        do {
            try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO completion_photos(id,completion_id,url,uploaded_at) VALUES(\(bind:UUID()),\(bind:completion),'https://example.test/uploads/photos/unledgered.jpg',NOW())").run()
            XCTFail("A post-migration writer must not insert an unledgered completion reference")
        } catch { }
    }

    func testTerminalJWTAccountCannotAllocateUploadOwnership() async throws {
        let target=try await user(), id=try target.requireID()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET lifecycle_state='deleted',email=NULL,name=NULL WHERE id=\(bind:id)").run()
        do {
            _=try await CompletionUploadObjectService.allocate(principal:.user(id),fileExtension:"jpg",contentType:"image/jpeg",fileSize:128,on:app.db)
            XCTFail("A terminal account must not allocate a post-deletion object")
        } catch { }
        let count=try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM completion_upload_objects WHERE uploaded_by_user_id=\(bind:id)").first()!.decode(column:"n",as:Int.self)
        XCTAssertEqual(count,0)
    }

    func testDeletionManifestsPersonalLedgerButRetainsCompanyLedgerByProjectScope() async throws {
        let target=try await user(), companyOwner=try await user()
        let (_,_,personalLink)=try await graph(owner:target)
        let company=try await app.db.transaction { try await WorkspaceAccessService.createCompany(id:UUID(),name:"Synthetic company",actorID:companyOwner.requireID(),on:$0) }
        try await app.db.transaction { try await WorkspaceAccessService.putMembership(workspaceID:company.requireID(),userID:target.requireID(),role:"member",on:$0) }
        let project=Project(id:UUID(),name:"Company evidence",reference:UUID().uuidString,ownerId:try companyOwner.requireID())
        project.workspaceId=try company.requireID(); project.platformManaged=true; try await project.save(on:app.db)
        let companyLink=MagicLink(id:UUID(),token:"company-\(UUID())",accessLevel:.update,expiresAt:Date().addingTimeInterval(3600),
                                  snagIds:[],projectId:try project.requireID(),createdById:try target.requireID())
        try await companyLink.save(on:app.db)
        let personal=try await ready(.link(id:try personalLink.requireID(),projectID:personalLink.projectId,creatorID:personalLink.createdById))
        let retained=try await ready(.link(id:try companyLink.requireID(),projectID:companyLink.projectId,creatorID:companyLink.createdById))
        let reference=(UUID().uuidString+UUID().uuidString).replacingOccurrences(of:"-",with:"")
        let targetID=try target.requireID()
        _=try await AccountDeletionService.request(userID:targetID,body:.init(confirmation:"DELETE",receiptReference:reference),app:app)
        let sql=try VerifiedIdentityService.sql(app.db)
        let jobID=try await sql.raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind:targetID)").first()!.decode(column:"id",as:UUID.self)
        let personalManifest=try await sql.raw("SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND storage_kind='legacy_completion_photo' AND object_key=\(bind:personal.storageKey)").first()
        let companyManifest=try await sql.raw("SELECT 1 FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND object_key=\(bind:retained.storageKey)").first()
        let retainedLedger=try await sql.raw("SELECT 1 FROM completion_upload_objects WHERE id=\(bind:retained.id)").first()
        let unresolvedCount=try await sql.raw("SELECT count(*) AS n FROM account_deletion_unresolved_objects WHERE job_id=\(bind:jobID)").first()!.decode(column:"n",as:Int.self)
        XCTAssertNotNil(personalManifest); XCTAssertNil(companyManifest); XCTAssertNotNil(retainedLedger); XCTAssertEqual(unresolvedCount,0)
    }

    func testMigrationPreservesHistoricalRowsAndFencesOldWriters() async throws {
        let schema="completion_upload_migration_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let historicalID=UUID(), historicalCompletion=UUID(), linkID=UUID(), projectID=UUID(), trustedCompletion=UUID(), objectID=UUID()
        try await IsolatedMigrationDatabase.withSchema(app:app,schema:schema) { db in
            let sql=try VerifiedIdentityService.sql(db)
            try await sql.raw("CREATE TABLE users(id UUID PRIMARY KEY)").run()
            try await sql.raw("CREATE TABLE account_deletion_jobs(id UUID PRIMARY KEY,user_id UUID NOT NULL,database_cleanup_state TEXT NOT NULL)").run()
            try await sql.raw("""
                CREATE TABLE account_deletion_objects(
                    job_id UUID NOT NULL,object_key TEXT NOT NULL,storage_kind TEXT NOT NULL,
                    CONSTRAINT account_deletion_objects_storage_kind_check CHECK(storage_kind IN ('private_media','private_import','private_drawing','legacy_photo','legacy_drawing')),
                    PRIMARY KEY(job_id,storage_kind,object_key))
                """).run()
            try await sql.raw("CREATE TABLE magic_links(id UUID PRIMARY KEY,project_id UUID NOT NULL)").run()
            try await sql.raw("CREATE TABLE completions(id UUID PRIMARY KEY,magic_link_id UUID NOT NULL)").run()
            try await sql.raw("""
                CREATE TABLE completion_photos(
                    id UUID PRIMARY KEY,completion_id UUID NOT NULL,url TEXT NOT NULL,thumbnail_url TEXT,
                    filename TEXT,content_type TEXT,file_size INTEGER,uploaded_at TIMESTAMPTZ NOT NULL)
                """).run()
            try await sql.raw("CREATE FUNCTION account_deletion_erasure_allowed(JSONB) RETURNS BOOLEAN LANGUAGE SQL AS $$ SELECT FALSE $$").run()
            try await sql.raw("INSERT INTO completions VALUES(\(bind:historicalCompletion),\(bind:UUID()))").run()
            try await sql.raw("INSERT INTO completion_photos(id,completion_id,url,uploaded_at) VALUES(\(bind:historicalID),\(bind:historicalCompletion),'/uploads/photos/historical.jpg',NOW())").run()

            try await CreateCompletionUploadObjects().prepare(on:db)

            let historical=try await sql.raw("SELECT upload_object_id,url FROM completion_photos WHERE id=\(bind:historicalID)").first()
            XCTAssertNil(try historical?.decode(column:"upload_object_id",as:UUID?.self))
            XCTAssertEqual(try historical?.decode(column:"url",as:String.self),"/uploads/photos/historical.jpg")
            do {
                try await sql.raw("INSERT INTO completion_photos(id,completion_id,url,uploaded_at) VALUES(\(bind:UUID()),\(bind:historicalCompletion),'/uploads/photos/old-binary.jpg',NOW())").run()
                XCTFail("An old binary must not add an unledgered reference after migration")
            } catch let error as PSQLError {
                XCTAssertEqual(error.serverInfo?[.sqlState],"23514")
            }

            let issuedURL="/uploads/photos/\(objectID.uuidString.lowercased()).jpg"
            let thumbnailURL="/uploads/photos/\(objectID.uuidString.lowercased())-thumb.jpg"
            try await sql.raw("INSERT INTO magic_links VALUES(\(bind:linkID),\(bind:projectID))").run()
            try await sql.raw("INSERT INTO completions VALUES(\(bind:trustedCompletion),\(bind:linkID))").run()
            try await sql.raw("""
                INSERT INTO completion_upload_objects(id,storage_key,thumbnail_key,issued_url,issued_thumbnail_url,filename,content_type,file_size,
                    magic_link_id,project_id,state,thumbnail_ready,created_at,ready_at)
                VALUES(\(bind:objectID),\(bind:"uploads/photos/\(objectID.uuidString.lowercased()).jpg"),
                    \(bind:"uploads/photos/\(objectID.uuidString.lowercased())-thumb.jpg"),\(bind:issuedURL),\(bind:thumbnailURL),
                    'synthetic.jpg','image/jpeg',128,\(bind:linkID),\(bind:projectID),'ready',TRUE,NOW(),NOW())
                """).run()
            try await sql.raw("""
                INSERT INTO completion_photos(id,completion_id,url,thumbnail_url,filename,content_type,file_size,upload_object_id,uploaded_at)
                VALUES(\(bind:objectID),\(bind:trustedCompletion),\(bind:issuedURL),\(bind:thumbnailURL),'synthetic.jpg','image/jpeg',128,\(bind:objectID),NOW())
                """).run()
            let trusted=try await sql.raw("SELECT upload_object_id FROM completion_photos WHERE id=\(bind:objectID)").first()
            XCTAssertEqual(try trusted?.decode(column:"upload_object_id",as:UUID?.self),objectID)
        }
    }
}
