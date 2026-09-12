@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class PrivateMediaTests: XCTestCase {
    var app: Application!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("media-\(UUID())@example.test", name: "Synthetic photo tester", on: db) }
    }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:], bytes: Data? = nil, mime: String = "image/png") async throws -> XCTHTTPResponse {
        let jwt: String?
        if let user {
            let id = try user.requireID()
            jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        } else { jwt = nil }
        let payload = try bytes ?? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if method != .GET {
                req.headers.replaceOrAdd(name: .contentType, value: bytes == nil ? "application/json" : mime)
                req.body = .init(data: payload)
            }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func project(_ user: User, company: Bool = false) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: user.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: user.requireID(), on: db)
        }
        let response = try await call(.POST, "api/v2/projects", user, body: ["mutation": meta(), "workspaceId": try workspace.requireID().uuidString, "project": ["id": UUID().uuidString, "name": "Plot 12", "reference": "WC12"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ user: User, _ project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let response = try await call(.POST, "api/v2/projects/\(project.project.id)/snags", user, body: ["mutation": meta(), "id": UUID().uuidString, "fields": ["title": "Seal shower tray", "location": "Plot 12 · Ensuite"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func path(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media" }
    private func command(_ snag: PlatformSnagResponse, bytes: Data = png, purpose: String = "capture", intent: UUID? = nil) -> [String: Any] {
        var value: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": snag.revision, "purpose": purpose, "sha256": PrivateImageProcessor.digest(bytes), "byteCount": bytes.count, "mimeType": "image/png"]
        if let intent { value["intentId"] = intent.uuidString }
        return value
    }
    private func allocate(_ user: User, _ path: String, _ command: [String: Any]) async throws -> MediaAssetResponse {
        let result = try await call(.POST, path, user, body: command)
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(MediaAssetResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }
    func testAllocationAndUploadRetriesKeepIdentityAndStripMetadataWithoutPublicObjects() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag), body = command(snag)
        let allocated = try await allocate(owner, path, body), replay = try await allocate(owner, path, body)
        XCTAssertEqual(allocated.id, replay.id); XCTAssertEqual(allocated.state, "allocated"); XCTAssertNil(allocated.contentPath)
        let missing = try await call(.GET, path + "/\(allocated.id)/content", owner)
        XCTAssertEqual(missing.status, .notFound)
        let uploaded = try await call(.PUT, path + "/\(allocated.id)/content", owner, bytes: Self.png)
        XCTAssertEqual(uploaded.status, .ok, uploaded.body.string)
        let ready = try uploaded.content.decode(MediaAssetResponse.self)
        XCTAssertEqual(ready.state, "ready"); XCTAssertNil(ready.attachedAt); XCTAssertEqual(ready.width, 32); XCTAssertEqual(ready.height, 24)
        let retry = try await call(.PUT, path + "/\(allocated.id)/content", owner, bytes: Self.png)
        XCTAssertEqual(try retry.content.decode(MediaAssetResponse.self).revision, ready.revision)
        let image = try await call(.GET, path + "/\(allocated.id)/content", owner)
        XCTAssertEqual(image.status, .ok); XCTAssertEqual(image.headers.contentType?.description, "image/jpeg")
        XCTAssertTrue(image.headers[.cacheControl].contains("no-store")); XCTAssertFalse(image.body.string.contains("PRIVATE_LOCATION_TEST_MARKER"))
        let raw = try await PrivateMediaService.row(ready.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        let originalKey = try raw.decode(column: "original_key", as: String.self)
        let storedOriginal = try await StorageService.downloadPrivate(key: originalKey, app: app)
        XCTAssertEqual(storedOriginal, Self.png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.publicDirectory + originalKey))
        let publicRoute = try await call(.GET, originalKey, nil)
        XCTAssertEqual(publicRoute.status, .notFound)
        XCTAssertFalse(uploaded.body.string.contains("original_key")); XCTAssertFalse(uploaded.body.string.contains("r2"))
    }
    func testBytesCannotOverwriteAllocationAndMalformedImagesNeverBecomeReady() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let media = try await allocate(owner, path, command(snag))
        let mismatch = try await call(.PUT, path + "/\(media.id)/content", owner, bytes: Self.png + Data([1]))
        XCTAssertEqual(mismatch.status, .unprocessableEntity)
        let wrongType = try await call(.PUT, path + "/\(media.id)/content", owner, bytes: Self.png, mime: "image/jpeg")
        XCTAssertEqual(wrongType.status, .unprocessableEntity)
        for invalid in [Data("not a photo, even if it is more than 12 bytes".utf8), Self.png.prefix(70)] {
            let asset = try await allocate(owner, path, command(snag, bytes: invalid))
            let result = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: invalid)
            XCTAssertTrue([HTTPResponseStatus.unsupportedMediaType, .unprocessableEntity].contains(result.status), result.body.string)
            let row = try await PrivateMediaService.row(asset.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
            XCTAssertEqual(try row.decode(column: "state", as: String.self), "allocated")
        }
    }
    func testAttachmentIsRevisionedIdempotentAndNeverChangesWorkflow() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let media = try await allocate(owner, path, command(snag)), attach: [String: Any] = ["mutation": meta(), "expectedRevision": snag.revision]
        let unready = try await call(.POST, path + "/\(media.id)/attach", owner, body: attach)
        XCTAssertEqual(unready.status, .conflict)
        _ = try await call(.PUT, path + "/\(media.id)/content", owner, bytes: Self.png)
        let result = try await call(.POST, path + "/\(media.id)/attach", owner, body: attach)
        XCTAssertEqual(result.status, .ok, result.body.string)
        let attached = try result.content.decode(PlatformSnagResponse.self)
        XCTAssertEqual(attached.revision, snag.revision + 1); XCTAssertEqual(attached.workflowRevision, snag.workflowRevision); XCTAssertEqual(attached.snag.status, "open")
        let retry = try await call(.POST, path + "/\(media.id)/attach", owner, body: attach)
        XCTAssertEqual(try retry.content.decode(PlatformSnagResponse.self).revision, attached.revision)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_id = \(bind: media.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
        let registerResponse = try await call(.GET, "api/v2/projects/\(project.project.id)/snags", owner)
        let register = try registerResponse.content.decode(SnagRegisterService.Page.self)
        XCTAssertEqual(register.evidence.map { $0.asset.id }, [media.id]); XCTAssertEqual(register.evidence.first?.count, 1)
        let snapshot = try await app.db.transaction { db in try await RegisterSyncService.create(projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertTrue(snapshot.coverage.contains("attachedMedia"))
        XCTAssertEqual(snapshot.items.filter { $0.type == "media" }.map(\.id), [media.id])
        let second = try await allocate(owner, path, command(attached))
        _ = try await call(.PUT, path + "/\(second.id)/content", owner, bytes: Self.png)
        let stale = try await call(.POST, path + "/\(second.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": snag.revision])
        XCTAssertEqual(stale.status, .conflict); XCTAssertTrue(stale.body.string.contains("revision_conflict"))
        let row = try await PrivateMediaService.row(second.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        XCTAssertNil(try row.decode(column: "attached_at", as: Date?.self))
        let delta = try await app.db.transaction { db in try await RegisterSyncService.changes(cursor: snapshot.changesCursor!, projectID: project.project.id, actorID: owner.requireID(), on: db) }
        XCTAssertFalse(delta.changes.contains { $0.id == second.id }, "Private unfinished upload must not appear in shared change history")
        let laterRegister = try await call(.GET, "api/v2/projects/\(project.project.id)/snags", owner)
        XCTAssertEqual(try laterRegister.content.decode(SnagRegisterService.Page.self).evidence.map { $0.asset.id }, [media.id])
    }
    func testUnattachedPhotosAreUploaderPrivateAndRemovalBlocksReadUploadAndReceiptReplay() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner, company: true)
        try await join(member, owner: owner, project: project, role: "member")
        let snag = try await snag(member, project), path = path(project, snag), command = command(snag)
        let asset = try await allocate(member, path, command)
        _ = try await call(.PUT, path + "/\(asset.id)/content", member, bytes: Self.png)
        let hidden = try await call(.GET, path + "/\(asset.id)/content", owner)
        XCTAssertEqual(hidden.status, .notFound)
        let hiddenOriginal = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(hiddenOriginal.status, .notFound)
        let hijack = try await call(.POST, path + "/\(asset.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": 1])
        XCTAssertEqual(hijack.status, .notFound)
        let attach = try await call(.POST, path + "/\(asset.id)/attach", member, body: ["mutation": meta(), "expectedRevision": 1])
        XCTAssertEqual(attach.status, .ok)
        let shared = try await call(.GET, path + "/\(asset.id)/content", owner)
        XCTAssertEqual(shared.status, .ok)
        let sharedOriginal = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(sharedOriginal.status, .ok)
        XCTAssertEqual(Data(buffer: sharedOriginal.body), Self.png)
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: project.workspaceId, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        for method in [HTTPMethod.GET, .PUT] {
            let denied = try await call(method, path + "/\(asset.id)/content", member, bytes: method == .PUT ? Self.png : nil)
            XCTAssertEqual(denied.status, .notFound)
        }
        let replay = try await call(.POST, path, member, body: command)
        XCTAssertEqual(replay.status, .notFound)
        let removedOriginal = try await call(.GET, path + "/\(asset.id)/original", member)
        XCTAssertEqual(removedOriginal.status, .notFound)
    }
    func testCrossScopeReferencesAndAnonymousAccessCannotUsePrivateMedia() async throws {
        let owner = try await user(), stranger = try await user(), project = try await project(owner), other = try await self.project(stranger)
        let snag = try await snag(owner, project), otherSnag = try await self.snag(stranger, other), path = path(project, snag)
        let asset = try await allocate(owner, path, command(snag))
        _ = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: Self.png)
        let anonymous = try await call(.GET, path + "/\(asset.id)/content", nil)
        XCTAssertEqual(anonymous.status, .unauthorized)
        let strangerRead = try await call(.GET, path + "/\(asset.id)/content", stranger)
        XCTAssertEqual(strangerRead.status, .notFound)
        let anonymousOriginal = try await call(.GET, path + "/\(asset.id)/original", nil)
        XCTAssertEqual(anonymousOriginal.status, .unauthorized)
        let strangerOriginal = try await call(.GET, path + "/\(asset.id)/original", stranger)
        XCTAssertEqual(strangerOriginal.status, .notFound)
        let foreignOriginal = try await call(.GET, self.path(other, otherSnag) + "/\(asset.id)/original", stranger)
        XCTAssertEqual(foreignOriginal.status, .notFound)
        let substituted = try await call(.POST, self.path(other, otherSnag) + "/\(asset.id)/attach", stranger, body: ["mutation": meta(), "expectedRevision": 1])
        XCTAssertEqual(substituted.status, .notFound)
        do {
            try await VerifiedIdentityService.sql(app.db).raw("UPDATE media_assets SET snag_id = \(bind: otherSnag.snag.id) WHERE id = \(bind: asset.id)").run()
            XCTFail("Composite snag/project ownership must be enforced by the database")
        } catch { /* Foreign-key violation expected. */ }
    }
    func testCompletionAssetsNeedAnIntentionAndCannotBeAttachedAsCapture() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let missing = try await call(.POST, path, owner, body: command(snag, purpose: "completion"))
        XCTAssertEqual(missing.status, .badRequest)
        let intent = UUID(), media = try await allocate(owner, path, command(snag, purpose: "completion", intent: intent))
        XCTAssertEqual(media.intentId, intent)
        _ = try await call(.PUT, path + "/\(media.id)/content", owner, bytes: Self.png)
        let invalidAttach = try await call(.POST, path + "/\(media.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": 1])
        XCTAssertEqual(invalidAttach.status, .conflict)
        let row = try await Snag.find(snag.snag.id, on: app.db)
        XCTAssertEqual(row?.status, "open"); XCTAssertEqual(row?.revision, 1)
    }
    func testExpiredUploadsAndArchivedSnagsCannotAcquireNewEvidence() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let expired = try await allocate(owner, path, command(snag))
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE media_assets SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE id = \(bind: expired.id)").run()
        let denied = try await call(.PUT, path + "/\(expired.id)/content", owner, bytes: Self.png)
        XCTAssertEqual(denied.status, .gone)
        let asset = try await allocate(owner, path, command(snag))
        let archive = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/archive", owner, body: ["mutation": meta(), "expectedRevision": 1, "reason": "Duplicate raised during inspection"])
        XCTAssertEqual(archive.status, .ok)
        let lateUpload = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: Self.png)
        XCTAssertEqual(lateUpload.status, .gone)
    }

    func testManagerDescriptorsVerifyBothOriginalAndProcessedBytesAndDecodeOlderReceipts() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let asset = try await allocate(owner, path, command(snag))
        XCTAssertNil(asset.original); XCTAssertNil(asset.processed)
        let unready = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(unready.status, .notFound)
        let uploaded = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: Self.png)
        let ready = try uploaded.content.decode(MediaAssetResponse.self)
        let original = try XCTUnwrap(ready.original), processed = try XCTUnwrap(ready.processed)
        XCTAssertEqual(original.contentPath, "/" + path + "/\(asset.id)/original")
        XCTAssertEqual(processed.contentPath, ready.contentPath)
        XCTAssertEqual(original.mimeType, "image/png"); XCTAssertEqual(processed.mimeType, "image/jpeg")
        XCTAssertEqual(original.sha256, ready.originalSHA256); XCTAssertEqual(original.byteCount, ready.byteCount)
        for descriptor in [original, processed] {
            let response = try await call(.GET, descriptor.contentPath, owner)
            XCTAssertEqual(response.status, .ok, response.body.string)
            let bytes = Data(buffer: response.body)
            XCTAssertEqual(PrivateImageProcessor.digest(bytes), descriptor.sha256)
            XCTAssertEqual(bytes.count, descriptor.byteCount)
            XCTAssertEqual(response.headers.contentType?.description, descriptor.mimeType)
            XCTAssertTrue(response.headers[.cacheControl].contains("no-store"))
            XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
            XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
            if descriptor.mimeType == "image/png" { XCTAssertEqual(bytes, Self.png) }
            else { XCTAssertNotEqual(bytes, Self.png); XCTAssertFalse(response.body.string.contains("PRIVATE_LOCATION_TEST_MARKER")) }
        }
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: uploaded.body)) as? [String: Any])
        legacy.removeValue(forKey: "original"); legacy.removeValue(forKey: "processed")
        let old = try PlatformMutationService.decode(MediaAssetResponse.self, String(decoding: JSONSerialization.data(withJSONObject: legacy), as: UTF8.self))
        XCTAssertEqual(old.id, ready.id); XCTAssertEqual(old.contentPath, ready.contentPath)
        XCTAssertNil(old.original); XCTAssertNil(old.processed)
        let attach = try await call(.POST, path + "/\(asset.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": snag.revision])
        XCTAssertEqual(attach.status, .ok)
        let snapshot = try await app.db.transaction { db in try await RegisterSyncService.create(projectID: project.project.id, actorID: owner.requireID(), on: db) }
        let item = try XCTUnwrap(snapshot.items.first { $0.type == "media" && $0.id == asset.id })
        let snapshotMedia = try PlatformMutationService.decode(MediaAssetResponse.self, PlatformMutationService.encode(item.data))
        XCTAssertEqual(snapshotMedia.original?.sha256, original.sha256)
        XCTAssertEqual(snapshotMedia.processed?.sha256, processed.sha256)
        XCTAssertFalse(uploaded.body.string.contains("original_key")); XCTAssertFalse(uploaded.body.string.contains("rendition_key"))
    }

    func testOriginalDownloadRejectsStoredByteCorruptionAndDeclaredSizeMismatch() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let asset = try await allocate(owner, path, command(snag))
        _ = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: Self.png)
        let row = try await PrivateMediaService.row(asset.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        let key = try row.decode(column: "original_key", as: String.self)
        var corrupt = Self.png; corrupt[corrupt.count - 1] ^= 1
        try await StorageService.uploadPrivate(corrupt, key: key, mime: "image/png", app: app)
        let denied = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(denied.status, .serviceUnavailable); XCTAssertTrue(denied.body.string.contains("media_unavailable"))
        try await StorageService.uploadPrivate(Self.png, key: key, mime: "image/png", app: app)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE media_assets SET original_size = original_size + 1 WHERE id = \(bind: asset.id)").run()
        let wrongSize = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(wrongSize.status, .serviceUnavailable)
        let processed = try await call(.GET, path + "/\(asset.id)/content", owner)
        XCTAssertEqual(processed.status, .ok, "An unavailable original does not replace the separate processed bytes")
    }

    func testIncompleteReadyMetadataRequiresRepairButPreservesOriginalRecoveryAccess() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project), path = path(project, snag)
        let asset = try await allocate(owner, path, command(snag))
        _ = try await call(.PUT, path + "/\(asset.id)/content", owner, bytes: Self.png)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE media_assets SET rendition_sha256 = 'historical-unavailable' WHERE id = \(bind: asset.id)").run()
        for suffix in ["", "/content"] {
            let response = try await call(.GET, path + "/\(asset.id)" + suffix, owner)
            XCTAssertEqual(response.status, .serviceUnavailable)
            XCTAssertTrue(response.body.string.contains("media_metadata_unavailable"))
        }
        let original = try await call(.GET, path + "/\(asset.id)/original", owner)
        XCTAssertEqual(original.status, .ok); XCTAssertEqual(Data(buffer: original.body), Self.png)
    }
}
