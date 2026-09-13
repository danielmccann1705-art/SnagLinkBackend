@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import SotoS3

/// Actual HTTP boundary for preparation → publication → authenticated readback.
final class LegacyImportCommitHTTPTests: XCTestCase {
    var app: Application!
    var http: StagedOriginalHTTPStub!
    var client: AWSClient!
    let api = "http://127.0.0.1:55480"
    lazy var binding = try! ImportServerBinding(environment: "development", apiOrigin: api)
    override func setUp() async throws {
        guard let value = Environment.get("DATABASE_URL"), let url = URLComponents(string: value),
              url.host == "127.0.0.1", url.port == 55439, url.path == "/snaglist_release_import_commit_http_0913" else {
            throw XCTSkip("Explicit owned local synthetic import-commit HTTP test database required")
        }
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[ImportServerBindingKey.self] = binding
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = true
        http = StagedOriginalHTTPStub()
        client = AWSClient(credentialProvider: .static(accessKeyId: "synthetic", secretAccessKey: "synthetic"), retryPolicy: .noRetry, httpClient: http)
        app.storage[StagedImportOriginalStoreKey.self] = SotoStagedImportOriginalStore(s3: S3(client: client, endpoint: "https://synthetic.invalid"), privateBucket: "synthetic-private")
    }
    override func tearDown() async throws {
        if let client { try await client.shutdown() }
        if let app { try await app.asyncShutdown() }
    }
    private func jwt(_ user: User) throws -> String {
        try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: user.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: user.requireID(), authVersion: user.authVersion))
    }
    private func post(_ path: String, _ object: [String: Any], user: User?) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(.POST, path, beforeRequest: { req in
            req.headers.contentType = .json; req.body = .init(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            if let user { req.headers.bearerAuthorization = .init(token: try self.jwt(user)) }
        }, afterResponse: { value async in result = value })
        return result
    }
    private func get(_ path: String, user: User?) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(.GET, path, beforeRequest: { req in
            if let user { req.headers.bearerAuthorization = .init(token: try self.jwt(user)) }
        }, afterResponse: { value async in result = value })
        return result
    }
    private func scopeObject(_ scope: StagedLegacyImportScope) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as! [String: Any]
    }
    func testPreparePublishAndReadBackOverHTTPWithVerifiedBytesAndDeniedStranger() async throws {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("commit-http-\(UUID())@example.test", name: "Synthetic manager", on: db) }
        let actor = try StagedLegacyImportActor(id: user.requireID(), authVersion: user.authVersion)
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: actor.id, on: db).requireID() }
        let raw = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json"))
        let fixture = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let archive = (fixture["source"] as! [String: Any])["archiveID"] as! String
        let descriptor = try JSONSerialization.data(withJSONObject: LegacyImportCommitTests.remap(fixture, suffix: UUID().uuidString, keep: [archive]), options: [.sortedKeys])
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: descriptor)
        let stage = StagedLegacyImportCommand(formatVersion: 1, sessionId: UUID(), mutation: .init(operationId: UUID(), deviceId: UUID()), expectedActorId: actor.id,
            expectedAuthVersion: actor.authVersion, expectedWorkspaceKind: "personal", destination: binding.destination, selectedProjectId: source.project.id,
            sourceFingerprint: source.source.sourceFingerprint, exportSHA256: LegacyProjectImportDecoder.digest(descriptor), exportByteCount: descriptor.count,
            acknowledgement: .init(version: StagedLegacyImportCommand.Acknowledgement.supportedVersion, wording: StagedLegacyImportCommand.Acknowledgement.supportedWording, accepted: true))
        _ = try await StagedLegacyImportService.create(stage, descriptor: descriptor, workspaceID: workspace, actor: actor, binding: binding, on: app.db)
        let scope = StagedLegacyImportService.scope(stage, workspaceID: workspace)
        let filesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-files-v1.json")
        let files = Dictionary(uniqueKeysWithValues: (try JSONSerialization.jsonObject(with: Data(contentsOf: filesURL)) as! [[String: Any]]).map { ($0["path"] as! String, Data(base64Encoded: $0["base64"] as! String)!) })
        let store = app.storage[StagedImportOriginalStoreKey.self]!
        for row in try await VerifiedIdentityService.sql(app.db).raw("SELECT declaration_id, archive_path FROM staged_legacy_import_files WHERE session_id = \(bind: scope.sessionId)").all() {
            let command = StagedImportOriginalCommand(scope: scope, declarationId: try row.decode(column: "declaration_id", as: UUID.self), operationId: UUID(), expectedSessionRevision: 1)
            _ = try await StagedImportOriginalService.retain(command, actor: actor, binding: binding, body: stagedTestBody(files[try row.decode(column: "archive_path", as: String.self)]!), store: store, on: app.db)
        }
        let base = "api/v2/workspaces/\(workspace)/import-sessions/\(scope.sessionId)"
        let projectionID = UUID(), projectionOperation = UUID()
        let projectionBody: [String: Any] = ["formatVersion": 1, "command": ["projectionId": projectionID.uuidString, "scope": try scopeObject(scope), "operationId": projectionOperation.uuidString, "expectedSourceRevision": 1, "policy": LegacyCanonicalProjection.policy]]
        let anonymous = try await post(base + "/projection", projectionBody, user: nil); XCTAssertEqual(anonymous.status, .unauthorized)
        let prepared = try await post(base + "/projection", projectionBody, user: user)
        XCTAssertEqual(prepared.status, .ok, prepared.body.string); XCTAssertEqual(prepared.headers.first(name: .cacheControl), "no-store")
        let status = try PlatformMutationService.decode(LegacyImportPreparationStatus.self, prepared.body.string)
        XCTAssertTrue(status.readyToPublish); XCTAssertEqual(status.receivedFileCount, 12); XCTAssertEqual(status.renderedDrawingCount, 1); XCTAssertNil(status.commit)
        XCTAssertFalse(prepared.body.string.contains("archivePath")); XCTAssertFalse(prepared.body.string.contains("Documents/"))
        let again = try await post(base + "/projection", projectionBody, user: user); XCTAssertEqual(again.status, .ok, again.body.string)
        let statusRead = try await post(base + "/projection/status", ["formatVersion": 1, "scope": try scopeObject(scope), "projectionId": projectionID.uuidString], user: user)
        XCTAssertEqual(statusRead.status, .ok, statusRead.body.string)
        let commitID = UUID(), commitOperation = UUID()
        var commitBody: [String: Any] = ["formatVersion": 1, "command": ["commitId": commitID.uuidString, "scope": try scopeObject(scope), "projectionId": projectionID.uuidString,
            "operationId": commitOperation.uuidString, "expectedSourceRevision": 1, "expectedGraphSHA256": status.projection.graphSHA256,
            "acknowledgement": ["version": LegacyImportCommitCommand.Acknowledgement.supportedVersion, "wording": LegacyImportCommitCommand.Acknowledgement.supportedWording, "accepted": true]]]
        var unacknowledged = commitBody, command = commitBody["command"] as! [String: Any], ack = command["acknowledgement"] as! [String: Any]
        ack["accepted"] = false; command["acknowledgement"] = ack; unacknowledged["command"] = command
        let refused = try await post(base + "/commit", unacknowledged, user: user); XCTAssertEqual(refused.status, .badRequest)
        let published = try await post(base + "/commit", commitBody, user: user)
        XCTAssertEqual(published.status, .ok, published.body.string)
        let receipt = try PlatformMutationService.decode(LegacyImportCommitReceipt.self, published.body.string)
        XCTAssertEqual(receipt.state, "published"); XCTAssertEqual(receipt.projectId, source.project.id)
        let replay = try await post(base + "/commit", commitBody, user: user); XCTAssertEqual(replay.body.string, published.body.string)
        let receiptRead = try await post(base + "/commit/receipt", ["formatVersion": 1, "scope": try scopeObject(scope), "commitId": commitID.uuidString], user: user)
        XCTAssertEqual(receiptRead.status, .ok); XCTAssertEqual(receiptRead.body.string, published.body.string)
        commitBody["command"] = { var c = commitBody["command"] as! [String: Any]; c["commitId"] = UUID().uuidString; c["operationId"] = UUID().uuidString; return c }()
        let conflict = try await post(base + "/commit", commitBody, user: user); XCTAssertEqual(conflict.status, .conflict)
        // Abort and further uploads are refused after publication; the source receipt is unchanged.
        let abort = try await post(base + "/abort", ["formatVersion": 1, "scope": try scopeObject(scope), "mutation": ["operationId": UUID().uuidString, "deviceId": scope.deviceId.uuidString], "expectedRevision": 1], user: user)
        XCTAssertEqual(abort.status, .conflict); XCTAssertTrue(abort.body.string.contains("import_preparation_published"))
        let sourceReceipt = try await post(base + "/receipt", ["formatVersion": 1, "scope": try scopeObject(scope)], user: user)
        XCTAssertEqual(sourceReceipt.status, .ok); XCTAssertTrue(sourceReceipt.body.string.contains("staged_incomplete"))
        // Readback: graph, drawings, verified bytes; stranger denied; anonymous unauthorized.
        let projectID = receipt.projectId
        let graph = try await get("api/v2/projects/\(projectID)/imported-graph", user: user)
        XCTAssertEqual(graph.status, .ok, graph.body.string)
        let decoded = try PlatformMutationService.decode(LegacyImportReadService.Graph.self, graph.body.string)
        XCTAssertEqual(decoded.files.count, 12); XCTAssertEqual(decoded.drawings.count, 1); XCTAssertEqual(decoded.photos.count, 3)
        XCTAssertFalse(graph.body.string.contains("staged-import/")); XCTAssertFalse(graph.body.string.contains("archivePath"))
        let file = decoded.files.first { $0.rendition != nil }!
        let rendition = try await get(file.rendition!.contentPath.dropFirst().description, user: user)
        XCTAssertEqual(rendition.status, .ok); XCTAssertEqual(rendition.headers.first(name: .contentType), "image/jpeg"); XCTAssertTrue(rendition.headers.first(name: .cacheControl)?.contains("no-store") == true)
        XCTAssertEqual(LegacyProjectImportDecoder.digest(Data(rendition.body.readableBytesView)), file.rendition!.sha256)
        let original = try await get(file.original.contentPath.dropFirst().description, user: user)
        XCTAssertEqual(original.status, .ok); XCTAssertEqual(LegacyProjectImportDecoder.digest(Data(original.body.readableBytesView)), file.sha256)
        let page = decoded.drawings[0].pages[0]
        let thumb = try await get(page.thumbnail.contentPath.dropFirst().description, user: user)
        XCTAssertEqual(thumb.status, .ok); XCTAssertEqual(LegacyProjectImportDecoder.digest(Data(thumb.body.readableBytesView)), page.thumbnail.sha256)
        let sheets = try await get("api/v2/projects/\(projectID)/drawings", user: user); XCTAssertEqual(sheets.status, .ok)
        let register = try await get("api/v2/projects/\(projectID)/snags", user: user)
        XCTAssertEqual(register.status, .ok, register.body.string); XCTAssertTrue(register.body.string.contains("legacyUnverified")); XCTAssertTrue(register.body.string.contains("legacy_unverified"))
        let stranger = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("stranger-\(UUID())@example.test", name: "Synthetic stranger", on: db) }
        let denied = try await get("api/v2/projects/\(projectID)/imported-graph", user: stranger); XCTAssertEqual(denied.status, .notFound)
        let deniedBytes = try await get(file.original.contentPath.dropFirst().description, user: stranger); XCTAssertEqual(deniedBytes.status, .notFound)
        let anonymousBytes = try await get(file.original.contentPath.dropFirst().description, user: nil); XCTAssertEqual(anonymousBytes.status, .unauthorized)
        let deniedReceipt = try await post(base + "/commit/receipt", ["formatVersion": 1, "scope": try scopeObject(scope), "commitId": commitID.uuidString], user: stranger)
        XCTAssertEqual(deniedReceipt.status, .notFound)
    }
}
