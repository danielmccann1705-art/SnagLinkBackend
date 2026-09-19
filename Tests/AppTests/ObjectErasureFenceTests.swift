@testable import App
import Fluent
import FluentSQL
import XCTVapor

final class ObjectErasureFenceTests: XCTestCase {
    var app: Application!
    enum Failure: Error { case responseLost }
    actor Storage: ObjectErasureFenceStorage {
        nonisolated let target: ObjectStorageWriteTarget
        let wrongKey: Bool
        let body: Data
        let wrongMarker: Bool
        let wrongMIME: Bool
        let losesResponse: Bool
        private var puts = 0
        init(target: ObjectStorageWriteTarget, wrongKey: Bool = false, body: Data = Data(),
             wrongMarker: Bool = false, wrongMIME: Bool = false, losesResponse: Bool = false) {
            self.target=target; self.wrongKey=wrongKey; self.body=body
            self.wrongMarker=wrongMarker; self.wrongMIME=wrongMIME; self.losesResponse=losesResponse
        }
        func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String {
            XCTAssertEqual(contentType, ObjectErasureFenceService.contentType)
            XCTAssertEqual(metadata, ["snaglist-erasure": ObjectErasureFenceService.marker])
            puts += 1
            if losesResponse { throw Failure.responseLost }
            return "synthetic-etag"
        }
        func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback {
            XCTAssertEqual(maximumBytes, 1)
            return .init(target: target, key: wrongKey ? key+"-foreign" : key, body: body, byteCount: Int64(body.count),
                contentType: wrongMIME ? "image/jpeg" : ObjectErasureFenceService.contentType,
                metadata: ["snaglist-erasure": wrongMarker ? "foreign" : ObjectErasureFenceService.marker], etag: "synthetic-etag")
        }
        func putCount() -> Int { puts }
    }
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> UUID {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("fence-\(UUID())@example.test", name: "Synthetic member", on: db).requireID()
        }
    }
    private func target(identity: String = "synthetic-r2-account", bucket: String = "synthetic-private", namespace: String = "fences-v1/") -> ObjectStorageWriteTarget {
        .init(backend: "r2", backendIdentity: identity, bucket: bucket, namespace: namespace, writeProtocol: .createOnlyV1)
    }
    private func intent(userID: UUID, key: String, kind: String = "private_media", target: ObjectStorageWriteTarget?) async throws -> UUID {
        try await app.db.transaction { db in
            try await ObjectWriteIntentService.begin(.init(storageKind: kind, key: key, data: Data("synthetic".utf8), contentType: "image/jpeg"),
                source: .init(kind: "media_asset", id: UUID()), scope: .init(userID: userID), target: target, on: db).id
        }
    }
    private func endAndLease(_ id: UUID) async throws -> AccountDeletionWorker.Lease {
        _ = try await AccountDeletionService.request(userID: id, body: .init(confirmation: "DELETE", receiptReference: UUID().uuidString+UUID().uuidString), app: app)
        let token=UUID()
        let row=try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:token),lease_expires_at=clock_timestamp()+INTERVAL '5 minutes' WHERE user_id=\(bind:id) RETURNING id").first()!
        return try .init(id: row.decode(column: "id", as: UUID.self), userID: id, token: token, attempt: 1)
    }
    private func fixture() async throws -> (AccountDeletionWorker.Lease, UUID, ObjectStorageWriteTarget, String) {
        let id=try await user(), destination=target(), key="fences-v1/\(UUID())"
        let write=try await intent(userID:id,key:key,target:destination)
        return try await (endAndLease(id),write,destination,key)
    }
    private func resolved(_ lease: AccountDeletionWorker.Lease, _ intentID: UUID) async throws -> Bool {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT object_write_is_resolved(\(bind:lease.id),\(bind:intentID)) AS resolved").first()!.decode(column:"resolved",as:Bool.self)
    }
    private func rejected(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Operation must fail closed",file:file,line:line) } catch { }
    }
    func testHistoricalDefaultsNeverBecomeFenceableOrAggregateComplete() async throws {
        let id=try await user(), key="fences-v1/\(UUID())", write=try await intent(userID:id,key:key,target:nil)
        let lease=try await endAndLease(id)
        let row=try await VerifiedIdentityService.sql(app.db).raw("SELECT write_protocol,storage_backend FROM object_write_intents WHERE id=\(bind:write)").first()!
        XCTAssertEqual(try row.decode(column:"write_protocol",as:String.self),"legacy_unknown")
        XCTAssertNil(try row.decode(column:"storage_backend",as:String?.self))
        await rejected { _ = try await ObjectErasureFenceService.request(lease,target:self.target(),kind:"private_media",key:key,on:self.app.db) }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE account_deletion_jobs SET object_cleanup_state='completed' WHERE id=\(bind:lease.id)").run() }
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testWrongBackendBucketNamespaceAndForeignJobAreRejected() async throws {
        let (lease,write,destination,key)=try await fixture()
        for wrong in [target(identity:"foreign-backend"),target(bucket:"foreign-bucket"),target(namespace:"foreign/")] {
            await rejected { _ = try await ObjectErasureFenceService.request(lease,target:wrong,kind:"private_media",key:key,on:self.app.db) }
        }
        let foreign=try await endAndLease(user())
        await rejected { _ = try await ObjectErasureFenceService.request(foreign,target:destination,kind:"private_media",key:key,on:self.app.db) }
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testUnknownWriterOfDifferentKindStillBlocksSamePhysicalKey() async throws {
        let id=try await user(), destination=target(), key="fences-v1/\(UUID())"
        let write=try await intent(userID:id,key:key,target:destination)
        _ = try await intent(userID:id,key:key,kind:"legacy_photo",target:nil)
        let lease=try await endAndLease(id)
        await rejected { _ = try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:self.app.db) }
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testRetainedForeignScopeBlocksFenceEvenWithMatchingProtocol() async throws {
        let owner=try await user(), foreign=try await user(), destination=target(), key="fences-v1/\(UUID())"
        _ = try await intent(userID:owner,key:key,target:destination)
        _ = try await intent(userID:foreign,key:key,kind:"private_drawing",target:destination)
        let lease=try await endAndLease(owner)
        await rejected { _ = try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:self.app.db) }
    }
    func testMixedKnownTargetsCannotResolveOneManifestEntry() async throws {
        let id=try await user(), destination=target(), key="fences-v1/\(UUID())"
        _ = try await intent(userID:id,key:key,target:destination)
        _ = try await intent(userID:id,key:key,target:target(bucket:"second-bucket"))
        let lease=try await endAndLease(id)
        await rejected { _ = try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:self.app.db) }
    }
    func testAdapterRejectsWrongTargetKeyMarkerMIMEAndNonemptyContent() async throws {
        let (lease,write,destination,key)=try await fixture()
        let ticket=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let wrongTarget=Storage(target:target(bucket:"foreign-bucket"))
        await rejected { _ = try await ObjectErasureFenceService.verify(ticket,using:wrongTarget,on:self.app.db) }
        let puts=await wrongTarget.putCount(); XCTAssertEqual(puts,0)
        for storage in [Storage(target:destination,wrongKey:true),Storage(target:destination,body:Data("x".utf8)),
                        Storage(target:destination,wrongMarker:true),Storage(target:destination,wrongMIME:true),Storage(target:destination,losesResponse:true)] {
            await rejected { _ = try await ObjectErasureFenceService.verify(ticket,using:storage,on:self.app.db) }
        }
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testForgedAttestationAndEvidenceRebindingAreRejected() async throws {
        let (lease,_,destination,key)=try await fixture()
        let first=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let second=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let evidence=try await ObjectErasureFenceService.verify(first,using:Storage(target:destination),on:app.db)
        await rejected { try await ObjectErasureFenceService.attest(second,evidence:evidence,on:self.app.db) }
        await rejected {
            try await self.app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("SELECT set_config('snaglist.object_erasure_lease',\(bind:lease.token.uuidString),true)").run()
                // A current worker lease is insufficient without the separately
                // held attempt capability. Fail at the proof boundary itself.
                try await sql.raw("""
                INSERT INTO object_erasure_fence_attestations(id,fence_id,attempt_id,storage_backend,storage_backend_identity,storage_bucket,
                    storage_namespace,object_key,object_sha256,byte_count,content_type,marker,provider_etag,verified_at)
                VALUES(\(bind:UUID()),\(bind:first.fenceID),\(bind:first.attemptID),'r2',\(bind:destination.backendIdentity),\(bind:destination.bucket),
                    \(bind:destination.namespace),\(bind:key),\(bind:ObjectErasureFenceService.emptySHA256),0,
                    \(bind:ObjectErasureFenceService.contentType),\(bind:ObjectErasureFenceService.marker),'forged',clock_timestamp())
                """).run()
            }
        }
    }
    func testReplacedLeaseRejectsOldProofButRestartCanIssueExactNewAttempt() async throws {
        let (lease,write,destination,key)=try await fixture()
        let old=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let oldEvidence=try await ObjectErasureFenceService.verify(old,using:Storage(target:destination),on:app.db)
        let replacement=AccountDeletionWorker.Lease(id:lease.id,userID:lease.userID,token:UUID(),attempt:2)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET lease_token=\(bind:replacement.token),lease_expires_at=clock_timestamp()+INTERVAL '5 minutes' WHERE id=\(bind:lease.id)").run()
        await rejected { try await ObjectErasureFenceService.attest(old,evidence:oldEvidence,on:self.app.db) }
        try await app.asyncShutdown(); app=try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self]=true
        let retry=try await ObjectErasureFenceService.request(replacement,target:destination,kind:"private_media",key:key,on:app.db)
        XCTAssertEqual(retry.fenceID,old.fenceID); XCTAssertNotEqual(retry.attemptID,old.attemptID)
        let proof=try await ObjectErasureFenceService.verify(retry,using:Storage(target:destination),on:app.db)
        try await ObjectErasureFenceService.attest(retry,evidence:proof,on:app.db)
        let done=try await resolved(replacement,write); XCTAssertTrue(done)
    }
    func testExpiredLeaseRejectsAttestationAndLeavesManifestPending() async throws {
        let (lease,write,destination,key)=try await fixture()
        let ticket=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let proof=try await ObjectErasureFenceService.verify(ticket,using:Storage(target:destination),on:app.db)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET lease_expires_at=clock_timestamp()-INTERVAL '1 second' WHERE id=\(bind:lease.id)").run()
        await rejected { try await ObjectErasureFenceService.attest(ticket,evidence:proof,on:self.app.db) }
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testAttestedFenceResolvesWithoutSettlementAndWorkerNeverDeletesIt() async throws {
        let (lease,write,destination,key)=try await fixture()
        let ticket=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let proof=try await ObjectErasureFenceService.verify(ticket,using:Storage(target:destination),on:app.db)
        try await ObjectErasureFenceService.attest(ticket,evidence:proof,on:app.db)
        try await ObjectErasureFenceService.attest(ticket,evidence:proof,on:app.db)
        let needed = try await ObjectErasureFenceService.requestIfNeeded(lease,target:destination,kind:"private_media",key:key,on:app.db)
        XCTAssertNil(needed,"A recovered worker must not create another attempt after successful attestation")
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _,_,_ in .revoked },deleteObject: { _,_ in XCTFail("Permanent fence must not be deleted") })
        try await AccountDeletionWorker.perform(lease,app:app,on:app.db)
        let final=try await AccountDeletionWorker.finish(lease,on:app.db); XCTAssertEqual(final,"completed")
        try await app.asyncShutdown(); app=try await Application.make(.testing); try await configure(app)
        let attested = try await ObjectErasureFenceService.isAttested(ticket,on:app.db)
        XCTAssertTrue(attested,"Exact prior capability can observe durable success after completion and restart")
        try await ObjectErasureFenceService.attest(ticket,evidence:proof,on:app.db)
        let state=try await VerifiedIdentityService.sql(app.db).raw("SELECT state FROM object_write_intents WHERE id=\(bind:write)").first()!.decode(column:"state",as:String.self)
        XCTAssertEqual(state,"active","A fence resolves risk; it does not claim the original writer terminated")
        let count=try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM object_erasure_fence_attestations WHERE fence_id=\(bind:ticket.fenceID)").first()!.decode(column:"n",as:Int.self)
        XCTAssertEqual(count,1)
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("DELETE FROM object_erasure_fences WHERE id=\(bind:ticket.fenceID)").run() }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE object_erasure_fence_attestations SET object_key='rebound' WHERE fence_id=\(bind:ticket.fenceID)").run() }
    }
    func testRequestedFenceDeniesNewAdmissionAndCannotCountAsComplete() async throws {
        let (lease,write,destination,key)=try await fixture()
        _ = try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let foreign=try await user()
        await rejected { _ = try await self.intent(userID:foreign,key:key,kind:"private_drawing",target:destination) }
        await rejected { _ = try await self.intent(userID:foreign,key:key,kind:"legacy_photo",target:nil) }
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _,_,_ in .revoked },deleteObject: { _,_ in XCTFail("Requested fence must not be deleted") })
        try await AccountDeletionWorker.perform(lease,app:app,on:app.db)
        let final=try await AccountDeletionWorker.finish(lease,on:app.db); XCTAssertEqual(final,"blocked")
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testTargetAndProtocolCannotBeReboundOrRetrofitted() async throws {
        let id=try await user(), key="fences-v1/\(UUID())"
        let legacy=try await intent(userID:id,key:key,target:nil)
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE object_write_intents SET storage_backend='r2',storage_backend_identity='synthetic',storage_bucket='synthetic',storage_namespace='fences-v1/',write_protocol='create_only_v1' WHERE id=\(bind:legacy)").run() }
        let current=try await intent(userID:id,key:key+"-new",target:target())
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE object_write_intents SET storage_bucket='foreign' WHERE id=\(bind:current)").run() }
    }

    func testExpiredLeaseCannotStartRemoteFenceIO() async throws {
        let (lease,write,destination,key)=try await fixture()
        let ticket=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET lease_expires_at=clock_timestamp()-INTERVAL '1 second' WHERE id=\(bind:lease.id)").run()
        let storage=Storage(target:destination)
        await rejected { _ = try await ObjectErasureFenceService.verify(ticket,using:storage,on:self.app.db) }
        let puts=await storage.putCount(); XCTAssertEqual(puts,0)
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }
    func testAttestationObservationTimeComesFromDatabaseClock() async throws {
        let (lease,_,destination,key)=try await fixture()
        let ticket=try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:key,on:app.db)
        let proof=try await ObjectErasureFenceService.verify(ticket,using:Storage(target:destination),on:app.db)
        try await ObjectErasureFenceService.attest(ticket,evidence:proof,on:app.db)
        let valid=try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT v.verified_at>=a.requested_at AND v.verified_at<=clock_timestamp()
                AND v.verified_at<=a.expires_at AND v.recorded_at<=clock_timestamp() AS valid
            FROM object_erasure_fence_attestations v JOIN object_erasure_fence_attempts a ON a.id=v.attempt_id
            WHERE v.fence_id=\(bind:ticket.fenceID)
            """).first()!.decode(column:"valid",as:Bool.self)
        XCTAssertTrue(valid,"Verification time is recorded at the DB authority boundary, with no backend wall-clock input")
    }
    func testSurvivingForeignAllocationBlocksFenceAcrossStorageKinds() async throws {
        let foreign=try await user(), owner=try await user()
        let allocation=try await CompletionUploadObjectService.allocate(principal:.user(foreign),fileExtension:"jpg",contentType:"image/jpeg",fileSize:9,on:app.db)
        let destination=target(namespace:"uploads/")
        let write=try await intent(userID:owner,key:allocation.storageKey,target:destination)
        let lease=try await endAndLease(owner)
        await rejected { _ = try await ObjectErasureFenceService.request(lease,target:destination,kind:"private_media",key:allocation.storageKey,on:self.app.db) }
        let remaining=try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM completion_upload_objects WHERE id=\(bind:allocation.id)").first()
        XCTAssertNotNil(remaining,"A different member's allocation remains protected even without another write intent")
        let done=try await resolved(lease,write); XCTAssertFalse(done)
    }

}
