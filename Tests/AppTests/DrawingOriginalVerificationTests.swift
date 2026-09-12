@testable import App
import XCTVapor
import Fluent
import FluentSQL
import Crypto

final class DrawingOriginalVerificationTests: XCTestCase {
    var app: Application!
    private let profile = "drawing-linux-byte-v1:0c398d19456a85be07a4999a8a40e30cbcddb5ebde3f2da8f9114fb028f04fcc"
    private let image = "sha256:47f90cd16a8cab01e8a0948ccb58b9189ce1b17ae9285d6d4029ee2aafac508e"
    // Framing/byte fixtures only; parser validity is a separate DRA-02 gate.
    private static let pdf = Data("%PDF-1.7\nSynthetic immutable object\n%%EOF\n".utf8)
    private static let png = Data([137,80,78,71,13,10,26,10,0,1,2,3])
    private static let jpeg = Data([255,216,255,224,0,1,2,3,255,217])
    private struct Fixture { let owner: User; let uploader: User; let project: Project }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    private func runtime() throws -> DrawingProcessorRuntimeIdentity { try .init(processorProfile: profile, imageDigest: image) }
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("drawing-original-\(UUID())@example.test", name:"Synthetic manager", on:db) }
    }
    private func fixture(company: Bool = false) async throws -> Fixture {
        let owner = try await user(), uploader = company ? try await user() : owner
        let project = try await app.db.transaction { db in
            let workspace = company ? try await WorkspaceAccessService.createCompany(id:UUID(),name:"Synthetic Willow Construction",actorID:owner.requireID(),on:db)
                : try await WorkspaceAccessService.personal(for:owner.requireID(),on:db)
            let project = Project(id:UUID(),name:"Willow Mews · Plot 12",reference:"WM12",ownerId:try owner.requireID())
            project.workspaceId = try workspace.requireID(); project.platformManaged = true
            try await project.save(on:db); return project
        }
        if company {
            let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID:project.workspaceId!,email:uploader.email!,role:"member",projects:[.init(projectId:project.requireID(),role:"member")],actorID:owner.requireID(),on:db) }
            _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token:invite.1,actorID:uploader.requireID(),on:db) }
        }
        return .init(owner:owner,uploader:uploader,project:project)
    }
    private func command(_ data: Data = pdf, mime: String = "application/pdf") -> DrawingAllocateCommand {
        .init(mutation:.init(operationId:UUID(),deviceId:UUID()),id:UUID(),purpose:.drawingSource,sha256:Self.hash(data),byteCount:data.count,mimeType:mime,originalFilename:"Synthetic original")
    }
    private func allocate(_ f: Fixture, command: DrawingAllocateCommand? = nil) async throws -> DrawingAssetRecord {
        try await CanonicalDrawingService.allocateWithExpectedRuntime(command ?? self.command(),workspaceID:f.project.workspaceId!,projectID:f.project.requireID(),actorID:f.uploader.requireID(),runtime:runtime(),on:app.db)
    }
    private func binding(_ f: Fixture, _ asset: DrawingAssetRecord, workspace: UUID? = nil, project: UUID? = nil,
                         actor: UUID? = nil, sha: String? = nil, profile: String? = nil) throws -> DrawingUploadBinding {
        .init(workspaceId:workspace ?? f.project.workspaceId!,projectId:try project ?? f.project.requireID(),assetId:asset.id,
              actorId:try actor ?? f.uploader.requireID(),sha256:sha ?? asset.sha256,byteCount:asset.byteCount,
              mimeType:asset.mimeType,processorProfile:profile ?? asset.processorProfile)
    }
    private func verify(_ binding: DrawingUploadBinding, _ reader: Reader) async throws -> DrawingOriginalReceipt {
        try await DrawingOriginalVerificationService.verifyStoredOriginal(binding,runtime:runtime(),reader:reader,on:app.db)
    }
    private func receiptCount(_ assetID: UUID) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM drawing_original_receipts WHERE asset_id = \(bind:assetID)").first()!.decode(column:"n",as:Int.self)
    }
    private func fails(_ status: HTTPResponseStatus, _ body: () async throws -> Void, file:StaticString = #filePath,line:UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection",file:file,line:line) }
        catch { XCTAssertEqual((error as? Abort)?.status,status,file:file,line:line) }
    }

    private actor Session {
        let data:Data; let chunk:Int; let hook:(@Sendable () async throws -> Void)?
        var offset=0; var ranHook=false; var closed=false
        init(_ data:Data,chunk:Int,hook:(@Sendable () async throws -> Void)?) { self.data=data;self.chunk=chunk;self.hook=hook }
        func next() async throws -> Data? {
            if !ranHook { ranHook=true;try await hook?() }
            guard !closed,offset<data.count else{return nil}
            let end=min(offset+chunk,data.count),result=Data(data[offset..<end]);offset=end;return result
        }
        func cancel(){closed=true}
    }
    private actor Reader:DrawingOriginalObjectReading {
        let data:Data;let mime:String;let chunk:Int;let hook:(@Sendable () async throws -> Void)?
        var opens=0;var cancellations=0;var targets:[String]=[]
        init(_ data:Data,mime:String="application/pdf",chunk:Int=3,hook:(@Sendable () async throws -> Void)?=nil){self.data=data;self.mime=mime;self.chunk=chunk;self.hook=hook}
        func openOriginal(_ target:DrawingOriginalReadTarget) async throws -> DrawingOriginalObjectRead {
            opens+=1;targets.append(target.originalKey)
            let session=Session(data,chunk:chunk,hook:hook)
            return .init(mimeType:mime,nextChunk:{try await session.next()},cancel:{await session.cancel();await self.didCancel()})
        }
        func didCancel(){cancellations+=1}
        func counts()->(Int,Int){(opens,cancellations)}
    }

    func testExplicitProfileAllocationKeepsDefaultAndRejectsChangedReplay() async throws {
        let f=try await fixture(),oldCommand=command()
        let old=try await CanonicalDrawingService.allocate(oldCommand,projectID:f.project.requireID(),actorID:f.uploader.requireID(),on:app.db)
        XCTAssertEqual(old.processorProfile,"drawing-initial-v1")
        await fails(.conflict){_=try await self.allocate(f,command:oldCommand)}
        let fresh=command(),first=try await allocate(f,command:fresh),retry=try await allocate(f,command:fresh)
        XCTAssertEqual(first.processorProfile,profile);XCTAssertEqual(first.id,retry.id);XCTAssertEqual(retry.revision,1)
        let changed=try DrawingProcessorRuntimeIdentity(processorProfile:"drawing-linux-byte-v1:"+String(repeating:"b",count:64),imageDigest:image)
        await fails(.conflict){_=try await CanonicalDrawingService.allocateWithExpectedRuntime(fresh,workspaceID:f.project.workspaceId!,projectID:f.project.requireID(),actorID:f.uploader.requireID(),runtime:changed,on:self.app.db)}
    }
    func testMeasuredReceiptUsesActualChunksAndDoesNotClaimDrawingReady() async throws {
        for (data,mime) in [(Self.pdf,"application/pdf"),(Self.png,"image/png"),(Self.jpeg,"image/jpeg")] {
            let f=try await fixture(),asset=try await allocate(f,command:command(data,mime:mime)),reader=Reader(data,mime:mime)
            let receipt=try await verify(binding(f,asset),reader)
            XCTAssertEqual(receipt.sha256,Self.hash(data));XCTAssertEqual(receipt.byteCount,data.count)
            XCTAssertEqual(receipt.mimeType,mime);XCTAssertEqual(receipt.processorProfile,profile);XCTAssertEqual(receipt.assetRevision,2)
            let current=try await CanonicalDrawingService.asset(asset.id,projectID:f.project.requireID(),on:app.db)
            XCTAssertEqual(current.state,"allocated");XCTAssertEqual(current.revision,2);XCTAssertNil(current.publishedAt)
            let counters=await reader.counts();XCTAssertEqual(counters.0,1);XCTAssertEqual(counters.1,1)
            let keys=await reader.targets;XCTAssertEqual(keys,["drawings/\(f.project.workspaceId!)/\(try f.project.requireID())/\(asset.id)/original"])
            let encoded=try PlatformMutationService.encode(receipt);XCTAssertFalse(encoded.contains("drawings/"));XCTAssertFalse(encoded.contains("leaseToken"))
        }
    }
    func testAllocationWaitsForConcurrentScopeWriteAndDoesNotAdoptNullWorkspace() async throws {
        let f = try await fixture(), input = command(), projectID = try f.project.requireID()
        // This project has no source/FK yet. Simulate a direct legacy writer
        // that does not take the workspace advisory lock, using its own row lock.
        let (attempt, observedRowWait) = try await app.db.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("SET LOCAL statement_timeout = '8s'").run()
            try await sql.raw("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: projectID)").run()
            let attempt = Task { try await self.allocate(f, command: input) }
            do {
                var observedRowWait = false
                // Observe the actual candidate SELECT waiting, not elapsed time
                // as proof. The writer connection performs this bounded poll.
                for _ in 0..<250 {
                    try await sql.raw("SELECT pg_stat_clear_snapshot()").run()
                    let waiting = try await sql.raw("""
                        SELECT 1 FROM pg_stat_activity
                        WHERE datname = current_database() AND usename = current_user
                          AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'
                          AND query LIKE '%drawing-runtime-allocation-scope%'
                        LIMIT 1
                        """).first()
                    if waiting != nil { observedRowWait = true; break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                // Returning commits the NULL workspace before the allocator's
                // locked read can finish. It must then reject before the helper.
                return (attempt, observedRowWait)
            } catch {
                attempt.cancel()
                throw error
            }
        }
        XCTAssertTrue(observedRowWait, "Allocator must lock the project row before calling the legacy helper")
        await fails(.notFound) { _ = try await attempt.value }
        let after = try await Project.find(projectID, on: app.db)
        XCTAssertNil(after?.workspaceId); XCTAssertEqual(after?.platformManaged, true)
        let sql = try VerifiedIdentityService.sql(app.db)
        let asset = try await sql.raw("SELECT 1 FROM drawing_assets WHERE id = \(bind: input.id)").first()
        let receipt = try await sql.raw("SELECT 1 FROM mutation_receipts WHERE actor_id = \(bind: f.uploader.requireID()) AND operation_id = \(bind: input.mutation.operationId)").first()
        XCTAssertNil(asset); XCTAssertNil(receipt)
    }
    func testConcurrentAndPostLeaseRetriesReturnOneHistoricalReceipt() async throws {
        let f=try await fixture(company:true),asset=try await allocate(f),expected=try binding(f,asset),reader=Reader(Self.pdf)
        let results=try await withThrowingTaskGroup(of:DrawingOriginalReceipt.self){group in
            for _ in 0..<3{group.addTask{try await self.verify(expected,reader)}}
            var values:[DrawingOriginalReceipt]=[];for try await value in group{values.append(value)};return values
        }
        XCTAssertEqual(Set(results.map(\.verifiedAt)).count,1);XCTAssertEqual(Set(results.map(\.assetRevision)),[2])
        let count=try await receiptCount(asset.id);XCTAssertEqual(count,1)
        _=try await CanonicalDrawingService.beginProcessing(assetID:asset.id,projectID:f.project.requireID(),actorID:f.uploader.requireID(),on:app.db)
        let replay=try await verify(expected,reader);XCTAssertEqual(replay.verifiedAt,results[0].verifiedAt);XCTAssertEqual(replay.assetRevision,2)
        await fails(.conflict){_=try await DrawingOriginalVerificationService.requireCurrentUpload(expected,runtime:self.runtime(),on:self.app.db)}
    }
    func testWrongStoredHashSizeAndContentTypeCannotCreateReceipt() async throws {
        for (bytes,mime) in [(Data(repeating:65,count:Self.pdf.count),"application/pdf"),(Data(Self.pdf.dropLast()),"application/pdf"),(Self.pdf+Data([1]),"application/pdf"),(Self.pdf,"image/png")] {
            let f=try await fixture(),asset=try await allocate(f),reader=Reader(bytes,mime:mime)
            await fails(.unprocessableEntity){_=try await self.verify(self.binding(f,asset),reader)}
            let count=try await receiptCount(asset.id);XCTAssertEqual(count,0)
            let after=try await CanonicalDrawingService.asset(asset.id,projectID:f.project.requireID(),on:app.db);XCTAssertEqual(after.revision,1)
            let counters=await reader.counts();XCTAssertEqual(counters.1,1)
        }
    }
    func testMatchingDeclaredHashDoesNotBypassSourceSignature() async throws {
        let invalid=Data("not a PDF although client declares its exact checksum".utf8),f=try await fixture(),asset=try await allocate(f,command:command(invalid))
        await fails(.unsupportedMediaType){_=try await self.verify(self.binding(f,asset),Reader(invalid))}
        let count=try await receiptCount(asset.id);XCTAssertEqual(count,0)
    }
    func testMalformedReaderFailureIsSanitizedAndCancelled() async throws {
        let f=try await fixture(),asset=try await allocate(f),reader=Reader(Self.pdf,hook:{throw Abort(.badRequest,reason:"SYNTHETIC_PRIVATE_PROVIDER_DETAIL")})
        do{_=try await verify(binding(f,asset),reader);XCTFail("Expected storage failure")}
        catch{XCTAssertEqual((error as? Abort)?.identifier,"drawing_storage_read_failed");XCTAssertFalse(String(describing:error).contains("SYNTHETIC_PRIVATE_PROVIDER_DETAIL"))}
        let counters=await reader.counts();XCTAssertEqual(counters.1,1)
        let count=try await receiptCount(asset.id);XCTAssertEqual(count,0)
    }
    func testInitialAuthorityRejectsForeignActorScopeAndViewer() async throws {
        let f=try await fixture(company:true),asset=try await allocate(f),stranger=try await user()
        for expected in [try binding(f,asset,workspace:UUID()),try binding(f,asset,project:UUID()),try binding(f,asset,actor:stranger.requireID()),try binding(f,asset,actor:f.owner.requireID())] {
            await fails(.notFound){_=try await DrawingOriginalVerificationService.requireCurrentUpload(expected,runtime:self.runtime(),on:self.app.db)}
        }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE project_access SET role='viewer' WHERE project_id=\(bind:f.project.requireID()) AND user_id=\(bind:f.uploader.requireID())").run()
        await fails(.forbidden){_=try await DrawingOriginalVerificationService.requireCurrentUpload(self.binding(f,asset),runtime:self.runtime(),on:self.app.db)}
    }
    func testRemovalDuringReadbackRollsBackReceiptAndRevision() async throws {
        let f=try await fixture(company:true),asset=try await allocate(f)
        let reader=Reader(Self.pdf,hook:{try await self.app.db.transaction{db in
            try await WorkspaceAccessService.changeMember(workspaceID:f.project.workspaceId!,targetID:f.uploader.requireID(),newRole:nil,expectedRevision:1,actorID:f.owner.requireID(),on:db)
        }})
        await fails(.notFound){_=try await self.verify(self.binding(f,asset),reader)}
        let count=try await receiptCount(asset.id);XCTAssertEqual(count,0)
        let after=try await CanonicalDrawingService.asset(asset.id,projectID:f.project.requireID(),on:app.db);XCTAssertEqual(after.revision,1)
        let counters=await reader.counts();XCTAssertEqual(counters.1,1)
    }
    func testCancellationAndOverlargeChunksDoNotCreateReceipts() async throws {
        let f=try await fixture(),asset=try await allocate(f),cancelled=Reader(Self.pdf,hook:{throw CancellationError()})
        do{_=try await verify(binding(f,asset),cancelled);XCTFail("Expected cancellation")}
        catch{XCTAssertTrue(error is CancellationError)}
        let counters=await cancelled.counts();XCTAssertEqual(counters.1,1)
        let large=Data("%PDF-1.7\n".utf8)+Data(repeating:65,count:70000)+Data("\n%%EOF".utf8)
        let largeAsset=try await allocate(f,command:command(large))
        await fails(.unprocessableEntity){_=try await self.verify(self.binding(f,largeAsset),Reader(large,chunk:70000))}
        let smallCount=try await receiptCount(asset.id),largeCount=try await receiptCount(largeAsset.id)
        XCTAssertEqual(smallCount,0);XCTAssertEqual(largeCount,0)
    }
    func testLegacyProjectAndPlaceholderCannotBeSilentlyClaimedOrRelabelled() async throws {
        let f=try await fixture(),legacy=Project(id:UUID(),name:"Legacy offline work",reference:"LOCAL",ownerId:try f.uploader.requireID())
        try await legacy.save(on:app.db)
        await fails(.notFound){_=try await CanonicalDrawingService.allocateWithExpectedRuntime(self.command(),workspaceID:f.project.workspaceId!,projectID:legacy.requireID(),actorID:f.uploader.requireID(),runtime:self.runtime(),on:self.app.db)}
        let after=try await Project.find(legacy.requireID(),on:app.db);XCTAssertNil(after?.workspaceId);XCTAssertEqual(after?.platformManaged,false)
        let old=try await CanonicalDrawingService.allocate(command(),projectID:f.project.requireID(),actorID:f.uploader.requireID(),on:app.db)
        await fails(.conflict){_=try await self.verify(self.binding(f,old,profile:self.profile),Reader(Self.pdf))}
    }
    func testImmutableReceiptAndDuplicateMigrationPreserveOriginalFact() async throws {
        let f=try await fixture(),asset=try await allocate(f),first=try await verify(binding(f,asset),Reader(Self.pdf))
        for mutate in [true,false] {
            var rejected=false
            do{try await app.db.transaction{db in
                let sql=try VerifiedIdentityService.sql(db)
                if mutate{try await sql.raw("UPDATE drawing_original_receipts SET measured_size=1 WHERE asset_id=\(bind:asset.id)").run()}
                else{try await sql.raw("DELETE FROM drawing_original_receipts WHERE asset_id=\(bind:asset.id)").run()}
            }}catch{rejected=true}
            XCTAssertTrue(rejected)
        }
        try await CreateDrawingOriginalReceipts().prepare(on:app.db);try await CreateDrawingOriginalReceipts().prepare(on:app.db)
        await fails(.conflict){try await CreateDrawingOriginalReceipts().revert(on:self.app.db)}
        let replay=try await verify(binding(f,asset),Reader(Self.pdf));XCTAssertEqual(replay.verifiedAt,first.verifiedAt)
        let count=try await receiptCount(asset.id);XCTAssertEqual(count,1)
    }
    func testArchivedProjectOrPrematureProcessingCannotReceiveNewReceipt() async throws {
        let archived=try await fixture(),a=try await allocate(archived)
        archived.project.archivedAt=Date();try await archived.project.save(on:app.db)
        await fails(.gone){_=try await self.verify(self.binding(archived,a),Reader(Self.pdf))}
        let processing=try await fixture(),b=try await allocate(processing)
        _=try await CanonicalDrawingService.beginProcessing(assetID:b.id,projectID:processing.project.requireID(),actorID:processing.uploader.requireID(),on:app.db)
        await fails(.conflict){_=try await self.verify(self.binding(processing,b),Reader(Self.pdf))}
        let count=try await receiptCount(b.id);XCTAssertEqual(count,0)
    }
    func testExpiredSourceIsRejectedBeforeOpeningPrivateStorage() async throws {
        let f=try await fixture(),source=try await allocate(f),expiredID=UUID(),now=Date()
        // Historical expired allocation fixture: the actual immutable expiry
        // cannot be changed after allocation and is not weakened for this test.
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,
                original_mime,original_filename,original_key,processor_profile,state,revision,created_at,expires_at)
            SELECT \(bind:expiredID),workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,
                original_mime,original_filename,\(bind:"drawings/\(f.project.workspaceId!)/\(try f.project.requireID())/\(expiredID)/original"),
                processor_profile,'allocated',1,\(bind:now.addingTimeInterval(-90000)),\(bind:now.addingTimeInterval(-1))
            FROM drawing_assets WHERE id=\(bind:source.id)
            """).run()
        let expired=try await CanonicalDrawingService.asset(expiredID,projectID:f.project.requireID(),on:app.db),reader=Reader(Self.pdf)
        await fails(.conflict){_=try await self.verify(self.binding(f,expired),reader)}
        let counters=await reader.counts();XCTAssertEqual(counters.0,0)
        let count=try await receiptCount(expired.id);XCTAssertEqual(count,0)
    }
    func testChangedIdentityAndCrossScopeReceiptInsertionCannotBeAccepted() async throws {
        let first=try await fixture(),a=try await allocate(first)
        await fails(.conflict){_=try await self.verify(self.binding(first,a,sha:String(repeating:"b",count:64)),Reader(Self.pdf))}
        _=try await verify(binding(first,a),Reader(Self.pdf))
        let second=try await fixture(),b=try await allocate(second)
        var rejected=false
        do{try await app.db.transaction{db in
            try await VerifiedIdentityService.sql(db).raw("""
                INSERT INTO drawing_original_receipts(asset_id,workspace_id,project_id,uploader_id,measured_sha256,
                    measured_size,measured_mime,processor_profile,verification_method,verified_at,asset_revision)
                SELECT \(bind:b.id),workspace_id,project_id,uploader_id,measured_sha256,measured_size,measured_mime,
                    processor_profile,verification_method,verified_at,asset_revision
                FROM drawing_original_receipts WHERE asset_id=\(bind:a.id)
                """).run()
        }}catch{rejected=true}
        XCTAssertTrue(rejected)
        let count=try await receiptCount(b.id);XCTAssertEqual(count,0)
        let after=try await CanonicalDrawingService.asset(b.id,projectID:second.project.requireID(),on:app.db);XCTAssertEqual(after.revision,1)
    }
}
