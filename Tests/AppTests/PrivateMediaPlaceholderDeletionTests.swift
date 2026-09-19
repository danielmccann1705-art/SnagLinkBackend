@testable import App
import Fluent
import FluentSQL
import XCTVapor

final class PrivateMediaPlaceholderDeletionTests: XCTestCase {
    var app: Application!
    var storageRoot: URL!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        try XCTSkipIf(Environment.get("R2_PRIVATE_BUCKET_NAME") != nil, "Local private-media adapter required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("private-media-deletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        app.directory = .init(workingDirectory: storageRoot.path)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
    }

    private func key(filename: String = "view.jpg") -> String {
        "platform/\(UUID())/\(UUID())/\(UUID())/\(filename)"
    }

    private func localURL(_ key: String) -> URL {
        storageRoot.appendingPathComponent("PrivateMedia", isDirectory: true).appendingPathComponent(key)
    }

    private func putSyntheticBytes(at key: String) throws {
        let url = localURL(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic private bytes".utf8).write(to: url)
    }

    private func assertRejected(file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Malformed or non-deletion key was accepted", file: file, line: line)
        } catch { }
    }

    private func user(_ prefix: String) async throws -> User {
        try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmail("\(prefix)-\(UUID())@example.test", name: "Synthetic owner", on: $0)
        }
    }

    private func personalGraph(owner: User) async throws -> (Project, Snag, String) {
        let workspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: owner.requireID(), on: $0) }
        let project = Project(id: UUID(), name: "Private project", reference: UUID().uuidString, ownerId: try owner.requireID())
        project.workspaceId = try workspace.requireID(); project.platformManaged = true
        try await project.save(on: app.db)
        let snag = Snag(id: UUID(), reference: "S-1", title: "Allocated photo", projectId: try project.requireID(), ownerId: try owner.requireID())
        snag.workspaceId = try workspace.requireID(); snag.displayNumber = 1; snag.publishedAt = Date()
        try await snag.save(on: app.db)
        let assetID = UUID()
        _ = try await PrivateMediaService.allocate(.init(
            mutation: .init(operationId: UUID(), deviceId: UUID()), id: assetID, expectedRevision: snag.revision,
            purpose: "capture", intentId: nil, sha256: String(repeating: "a", count: 64), byteCount: 24, mimeType: "image/jpeg"
        ), snag: snag, project: project, actorID: try owner.requireID(), on: app.db)
        let row = try await PrivateMediaService.row(assetID, snagID: snag.requireID(), projectID: project.requireID(), on: app.db)
        return (project, snag, try row.decode(column: "rendition_key", as: String.self))
    }

    private func directJob(userID: UUID, key: String, databaseState: String = "completed") async throws -> AccountDeletionWorker.Lease {
        let id = UUID(), token = UUID(), sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,database_cleanup_state,
                apple_revocation_state,object_cleanup_state,lease_token,lease_expires_at)
            VALUES(\(bind:id),\(bind:userID),\(bind:"placeholder-"+UUID().uuidString),NOW(),'leased',NOW(),\(bind:databaseState),
                'not_applicable','pending',\(bind:token),NOW()+INTERVAL '5 minutes')
            """).run()
        try await sql.raw("INSERT INTO account_deletion_objects(job_id,storage_kind,object_key) VALUES(\(bind:id),'private_media',\(bind:key))").run()
        return .init(id: id, userID: userID, token: token, attempt: 1)
    }

    private func personalIntent(userID: UUID, key: String, jobID: UUID) async throws -> UUID {
        let id = UUID(), sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("""
            INSERT INTO object_write_intents(id,writer_token_hash,source_kind,source_id,scope_user_id,ownership_kind,
                storage_kind,object_key,sha256,byte_count,content_type,state,created_at)
            VALUES(\(bind:id),\(bind:String(repeating:"a",count:64)),'completion_upload',\(bind:UUID()),\(bind:userID),'personal',
                'private_media',\(bind:key),\(bind:String(repeating:"b",count:64)),24,'image/jpeg','active',NOW())
            """).run()
        try await app.db.transaction { db in
            let scoped = try VerifiedIdentityService.sql(db)
            try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind:jobID.uuidString),true)").run()
            try await scoped.raw("INSERT INTO account_deletion_write_intents(job_id,intent_id) VALUES(\(bind:jobID),\(bind:id))").run()
        }
        return id
    }

    func testDeletionOnlyPlaceholderRemovesExactLocalObjectAndMissingRetrySucceeds() async throws {
        let placeholder = key()
        try putSyntheticBytes(at: placeholder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(placeholder).path))
        try await StorageService.deleteAccountObject(kind: "private_media", key: placeholder, app: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL(placeholder).path))
        try await StorageService.deleteAccountObject(kind: "private_media", key: placeholder, app: app)

        for current in [key(filename: "original"), key(filename: "view-" + String(repeating: "c", count: 64) + ".jpg")] {
            try putSyntheticBytes(at: current)
            try await StorageService.deleteAccountObject(kind: "private_media", key: current, app: app)
            XCTAssertFalse(FileManager.default.fileExists(atPath: localURL(current).path))
        }
    }

    func testPlaceholderRemainsUnavailableToUploadAndReadAndMalformedDeletionKeysFailClosed() async throws {
        let placeholder = key()
        await assertRejected { try await StorageService.uploadPrivate(Data("bytes".utf8), key: placeholder, mime: "image/jpeg", app: self.app) }
        await assertRejected { _ = try await StorageService.downloadPrivate(key: placeholder, app: self.app) }

        let workspace = UUID(), project = UUID(), asset = UUID()
        let malformed = [
            "uploads/\(workspace)/\(project)/\(asset)/view.jpg",
            "platform/not-a-uuid/\(project)/\(asset)/view.jpg",
            "platform/\(workspace)/../\(asset)/view.jpg",
            "platform/\(workspace)/\(project)/\(asset)/extra/view.jpg",
            "/platform/\(workspace)/\(project)/\(asset)/view.jpg",
            "platform/\(workspace)/\(project)/\(asset)/VIEW.JPG"
        ]
        for candidate in malformed {
            await assertRejected { try await StorageService.deleteAccountObject(kind: "private_media", key: candidate, app: self.app) }
        }
        for wrongKind in ["private_import", "private_drawing", "legacy_photo", "unknown"] {
            await assertRejected { try await StorageService.deleteAccountObject(kind: wrongKind, key: placeholder, app: self.app) }
        }
    }

    func testAllocatedUnuploadedPersonalPlaceholderCompletesThroughLocalWorker() async throws {
        let owner = try await user("placeholder-personal")
        let (_, _, placeholder) = try await personalGraph(owner: owner)
        XCTAssertTrue(placeholder.hasSuffix("/view.jpg"))
        try putSyntheticBytes(at: placeholder)
        let reference = UUID().uuidString + UUID().uuidString
        _ = try await AccountDeletionService.request(userID: owner.requireID(), body: .init(confirmation: "DELETE", receiptReference: reference), app: app)
        let token = UUID(), sql = try VerifiedIdentityService.sql(app.db)
        let row = try await sql.raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:token),lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE user_id=\(bind:owner.requireID()) RETURNING id").first()
        let jobID = try XCTUnwrap(row).decode(column: "id", as: UUID.self)
        let lease = AccountDeletionWorker.Lease(id: jobID, userID: try owner.requireID(), token: token, attempt: 1)
        try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
        let finished = try await AccountDeletionWorker.finish(lease, on: app.db)
        XCTAssertEqual(finished, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL(placeholder).path))
        let manifest = try await sql.raw("SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind:jobID) AND storage_kind='private_media' AND object_key=\(bind:placeholder)").first()
        XCTAssertNotNil(try manifest?.decode(column: "completed_at", as: Date?.self))
    }

    func testLiveReferenceAndUnsettledIntentsStillBlockPlaceholderDeletion() async throws {
        let retained = try await user("placeholder-retained")
        let (_, _, liveKey) = try await personalGraph(owner: retained)
        try putSyntheticBytes(at: liveKey)
        let foreign = try await user("placeholder-foreign")
        let liveLease = try await directJob(userID: foreign.requireID(), key: liveKey)
        try await AccountDeletionWorker.perform(liveLease, app: app, on: app.db)
        let liveState = try await AccountDeletionWorker.finish(liveLease, on: app.db)
        XCTAssertEqual(liveState, "blocked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(liveKey).path))

        let writer = try await user("placeholder-writer"), pendingKey = key()
        try putSyntheticBytes(at: pendingKey)
        let activeLease = try await directJob(userID: writer.requireID(), key: pendingKey, databaseState: "blocked")
        let intentID = try await personalIntent(userID: writer.requireID(), key: pendingKey, jobID: activeLease.id)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind:activeLease.id)").run()
        try await AccountDeletionWorker.perform(activeLease, app: app, on: app.db)
        let activeState = try await AccountDeletionWorker.finish(activeLease, on: app.db)
        XCTAssertEqual(activeState, "blocked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(pendingKey).path))

        try await VerifiedIdentityService.sql(app.db).raw("UPDATE object_write_intents SET state='uncertain' WHERE id=\(bind:intentID)").run()
        let retryToken = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:retryToken),lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE id=\(bind:activeLease.id)").run()
        let uncertainLease = AccountDeletionWorker.Lease(id: activeLease.id, userID: try writer.requireID(), token: retryToken, attempt: 2)
        try await AccountDeletionWorker.perform(uncertainLease, app: app, on: app.db)
        let uncertainState = try await AccountDeletionWorker.finish(uncertainLease, on: app.db)
        XCTAssertEqual(uncertainState, "blocked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(pendingKey).path))
    }
}
