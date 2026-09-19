@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class ObjectWriteIntentTests: XCTestCase {
    var app: Application!
    actor StorageProbe {
        private var started = false
        private var release: CheckedContinuation<Void, Never>?
        private var present = false
        private var deletedKeys: [String] = []
        func hold() async {
            started = true
            await withCheckedContinuation { release = $0 }
        }
        func hasStarted() -> Bool { started }
        func resume() { release?.resume(); release = nil }
        func commit() { present = true }
        func remove(_ key: String, original: String) { deletedKeys.append(key); if key == original { present = false } }
        func containsObject() -> Bool { present }
        func deleted(_ key: String) -> Bool { deletedKeys.contains(key) }
    }
    enum SyntheticFailure: Error { case responseLost }
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture() async throws -> (UUID, CompletionUploadObjectService.Allocation, Data) {
        let user = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("intent-\(UUID())@example.test", name: "Synthetic writer", on: db)
        }
        let id = try user.requireID(), data = Data("synthetic immutable bytes".utf8)
        let allocation = try await CompletionUploadObjectService.allocate(principal: .user(id), fileExtension: "jpg", contentType: "image/jpeg", fileSize: data.count, on: app.db)
        return (id, allocation, data)
    }
    private func lease(userID: UUID) async throws -> AccountDeletionWorker.Lease {
        let token = UUID()
        let row = try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE user_id=\(bind: userID) RETURNING id").first()
        return try .init(id: XCTUnwrap(row).decode(column: "id", as: UUID.self), userID: userID, token: token, attempt: 1)
    }
    private func endAccount(_ userID: UUID) async throws {
        _ = try await AccountDeletionService.request(userID: userID, body: .init(confirmation: "DELETE", receiptReference: UUID().uuidString + UUID().uuidString), app: app)
    }
    func testInflightWriteRemainsTrackedAfterGraphErasureAndCleanupWaitsForDefiniteSettlement() async throws {
        let (userID, allocation, data) = try await fixture(), probe = StorageProbe()
        let database = app.db
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, key in
            await probe.remove(key, original: allocation.storageKey)
        })
        let writer = Task {
            try await ObjectWriteIntentService.write(.init(storageKind: "legacy_completion_photo", key: allocation.storageKey, data: data, contentType: "image/jpeg"),
                source: .init(kind: "completion_upload", id: allocation.id), on: database, authorize: { db in
                    try await CompletionUploadObjectService.lockForWrite(allocation, on: db)
                    return .init(userID: userID)
                }) {
                    await probe.hold()
                    await probe.commit()
                }
        }
        defer { writer.cancel(); Task { await probe.resume() } }
        for _ in 0..<300 {
            if await probe.hasStarted() { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard await probe.hasStarted() else { try await writer.value; return XCTFail("Writer did not reach synthetic IO") }
        try await endAccount(userID)
        let first = try await lease(userID: userID)
        try await AccountDeletionWorker.perform(first, app: app, on: app.db)
        let firstState = try await AccountDeletionWorker.finish(first, on: app.db)
        XCTAssertEqual(firstState, "blocked")
        let prematurelyDeleted = await probe.deleted(allocation.storageKey)
        XCTAssertFalse(prematurelyDeleted)
        let captured = try await VerifiedIdentityService.sql(app.db).raw("SELECT i.state,i.sha256,i.byte_count FROM object_write_intents i JOIN account_deletion_write_intents d ON d.intent_id=i.id WHERE d.job_id=\(bind: first.id) AND i.object_key=\(bind: allocation.storageKey)").first()
        XCTAssertEqual(try captured?.decode(column: "state", as: String.self), "active")
        XCTAssertEqual(try captured?.decode(column: "sha256", as: String.self), PrivateImageProcessor.digest(data))
        XCTAssertEqual(try captured?.decode(column: "byte_count", as: Int64.self), Int64(data.count))
        let anchor = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM completion_upload_objects WHERE id=\(bind: allocation.id)").first()
        XCTAssertNil(anchor, "Intent survives erased source graph")
        await probe.resume(); try await writer.value
        let lateObject = await probe.containsObject()
        XCTAssertTrue(lateObject, "Synthetic late PUT landed, still awaiting cleanup")
        let second = try await lease(userID: userID)
        try await AccountDeletionWorker.perform(second, app: app, on: app.db)
        let finalState = try await AccountDeletionWorker.finish(second, on: app.db)
        XCTAssertEqual(finalState, "completed")
        let remains = await probe.containsObject()
        XCTAssertFalse(remains)
    }
    func testRemoteCommitWithLostResponseStaysUncertainAcrossApplicationRestart() async throws {
        let (userID, allocation, data) = try await fixture(), probe = StorageProbe()
        do {
            try await ObjectWriteIntentService.write(.init(storageKind: "legacy_completion_photo", key: allocation.storageKey, data: data, contentType: "image/jpeg"),
                source: .init(kind: "completion_upload", id: allocation.id), on: app.db, authorize: { db in
                    try await CompletionUploadObjectService.lockForWrite(allocation, on: db)
                    return .init(userID: userID)
                }) {
                    await probe.commit()
                    throw SyntheticFailure.responseLost
                }
            XCTFail("Lost provider response must not become a successful write")
        } catch SyntheticFailure.responseLost { }
        try await endAccount(userID)
        try await app.asyncShutdown(); app = nil
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, key in
            await probe.remove(key, original: allocation.storageKey)
        })
        for _ in 0..<2 {
            let owned = try await lease(userID: userID)
            try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
            let state = try await AccountDeletionWorker.finish(owned, on: app.db)
            XCTAssertEqual(state, "blocked")
        }
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state,settled_at,writer_token_hash FROM object_write_intents WHERE source_id=\(bind: allocation.id)").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "uncertain")
        XCTAssertNil(try row?.decode(column: "settled_at", as: Date?.self))
        XCTAssertEqual(try row?.decode(column: "writer_token_hash", as: String.self).count, 64)
        let deleted = await probe.deleted(allocation.storageKey), remains = await probe.containsObject()
        XCTAssertFalse(deleted); XCTAssertTrue(remains)
    }
    func testRevokedAccountCannotAdmitNewIntentOrReachStorage() async throws {
        let (userID, allocation, data) = try await fixture(), probe = StorageProbe()
        try await endAccount(userID)
        do {
            try await ObjectWriteIntentService.write(.init(storageKind: "legacy_completion_photo", key: allocation.storageKey, data: data, contentType: "image/jpeg"),
                source: .init(kind: "completion_upload", id: allocation.id), on: app.db, authorize: { db in
                    try await CompletionUploadObjectService.lockForWrite(allocation, on: db)
                    return .init(userID: userID)
                }) { await probe.commit() }
            XCTFail("Revoked writer must never reach external storage")
        } catch let error as Abort { XCTAssertEqual(error.status, .unauthorized) }
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM object_write_intents WHERE source_id=\(bind: allocation.id)").first()
        XCTAssertNil(row)
        let present = await probe.containsObject()
        XCTAssertFalse(present)
    }
    func testCompanyWithOnlyDurableWriteEvidenceRequiresExplicitClosure() async throws {
        let (userID, _, _) = try await fixture()
        let company = try await app.db.transaction { db in
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Retained storage evidence", actorID: userID, on: db)
        }
        let workspaceID = try company.requireID()
        let project = Project(name: "Later removed project", reference: "OLD", ownerId: userID)
        project.workspaceId = workspaceID; try await project.save(on: app.db)
        let projectID = try project.requireID()
        let snag = Snag(id: UUID(), reference: "S-1", title: "Removed media source", projectId: projectID, ownerId: userID)
        snag.workspaceId = workspaceID; snag.displayNumber = 1; snag.publishedAt = Date()
        try await snag.save(on: app.db)
        let snagID = try snag.requireID(), assetID = UUID(), data = Data("synthetic retained object".utf8)
        let key = "platform/intent-fixture/\(assetID)/original", rendition = "platform/intent-fixture/\(assetID)/rendition.jpg"
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,
                original_sha256,original_size,original_mime,original_key,rendition_key,base_snag_revision,created_at,expires_at)
            VALUES(\(bind: assetID),\(bind: workspaceID),\(bind: projectID),\(bind: snagID),\(bind: userID),'capture','allocated',
                \(bind: PrivateImageProcessor.digest(data)),\(bind: data.count),'image/jpeg',\(bind: key),\(bind: rendition),1,NOW(),NOW()+INTERVAL '1 day')
            """).run()
        try await ObjectWriteIntentService.write(.init(storageKind: "private_media", key: key, data: data, contentType: "image/jpeg"), source: .init(kind: "media_asset", id: assetID), on: app.db, authorize: { db in
            try await WorkspaceAccessService.lock(workspaceID, on: db)
            guard try await VerifiedIdentityService.sql(db).raw("SELECT id FROM media_assets WHERE id=\(bind: assetID) AND workspace_id=\(bind: workspaceID) AND creator_id=\(bind: userID) AND state='allocated' FOR UPDATE").first() != nil else { throw Abort(.conflict) }
            return .init(userID: userID, workspaceID: workspaceID, projectID: projectID)
        }) { }
        // Normal source removal is permitted; the independent write ledger must
        // survive it. Protected completion-allocation evidence is never bypassed.
        try await app.db.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("DELETE FROM media_assets WHERE id=\(bind: assetID)").run()
            try await sql.raw("DELETE FROM snags WHERE id=\(bind: snagID)").run()
            try await sql.raw("DELETE FROM projects WHERE id=\(bind: projectID)").run()
        }
        let result = try await app.db.transaction { db in try await CompanyDeletionPreparationService.prepare(userID: userID, on: db) }
        let retained = try XCTUnwrap(result.companies.first { $0.workspaceID == workspaceID })
        XCTAssertEqual(retained.projectCount, 0); XCTAssertEqual(retained.snagCount, 0); XCTAssertEqual(retained.otherMemberCount, 0)
        XCTAssertFalse(retained.genuinelyEmpty)
        XCTAssertEqual(retained.action, "transfer_or_confirm_closure")
    }

    func testDeadlineFailureBeforeStorageClosureIsProvenUnissuedAndSettled() async throws {
        let (userID, allocation, data) = try await fixture(), probe = StorageProbe()
        let ticket = try await app.db.transaction { db in
            try await CompletionUploadObjectService.lockForWrite(allocation, on: db)
            return try await ObjectWriteIntentService.begin(
                .init(storageKind: "legacy_completion_photo", key: allocation.storageKey, data: data, contentType: "image/jpeg"),
                source: .init(kind: "completion_upload", id: allocation.id), scope: .init(userID: userID), on: db)
        }
        do {
            try await ObjectWriteIntentService.execute(ticket, on: app.db, beforeIssuing: { throw StagedImportOriginalError.deadlineExceeded }) {
                await probe.commit()
            }
            XCTFail("No storage call may occur after preflight fails")
        } catch StagedImportOriginalError.deadlineExceeded { }
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state,settled_at FROM object_write_intents WHERE id=\(bind: ticket.id)").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "settled")
        XCTAssertNotNil(try row?.decode(column: "settled_at", as: Date?.self))
        let present = await probe.containsObject()
        XCTAssertFalse(present)
    }

}
