@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

private enum StagedHTTPFixture {
    static var source: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json")) } }
    static let api = "http://127.0.0.1:55480"
    static func envelope(actor: UUID = UUID(), kind: String = "personal") throws -> [String: Any] {
        let source = try self.source, value = try JSONDecoder().decode(LegacyProjectImportSource.self, from: source)
        return ["formatVersion": 1, "command": ["sessionId": UUID().uuidString, "mutation": ["operationId": UUID().uuidString, "deviceId": UUID().uuidString],
            "expectedActorId": actor.uuidString, "expectedWorkspaceKind": kind,
            "destination": ["environment": "development", "apiOrigin": api], "selectedProjectId": value.project.id.uuidString,
            "sourceFingerprint": value.source.sourceFingerprint, "exportSHA256": LegacyProjectImportDecoder.digest(source), "exportByteCount": source.count,
            "acknowledgement": ["version": StagedLegacyImportCommand.Acknowledgement.supportedVersion,
                "wording": StagedLegacyImportCommand.Acknowledgement.supportedWording, "accepted": true]], "descriptorBase64": source.base64EncodedString()]
    }
    static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func scope(_ object: [String: Any], workspace: UUID) -> [String: Any] {
        let command = object["command"] as! [String: Any], mutation = command["mutation"] as! [String: Any]
        return ["sessionId": command["sessionId"]!, "workspaceId": workspace.uuidString, "deviceId": mutation["deviceId"]!, "destination": command["destination"]!,
                "exportSHA256": command["exportSHA256"]!, "sourceFingerprint": command["sourceFingerprint"]!, "selectedProjectId": command["selectedProjectId"]!]
    }
    static func invalid(_ bytes: Data, status: HTTPResponseStatus = .badRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try StagedLegacyImportHTTP.create(bytes), file: file, line: line) { XCTAssertEqual(($0 as? Abort)?.status, status, file: file, line: line) }
    }
}

final class StagedLegacyImportWireTests: XCTestCase {
    func testExactNativeBytesSurviveEnvelopeAndAuthVersionComesFromServer() throws {
        let actor = UUID(), object = try StagedHTTPFixture.envelope(actor: actor)
        let value = try StagedLegacyImportHTTP.create(StagedHTTPFixture.data(object))
        XCTAssertEqual(value.descriptor, try StagedHTTPFixture.source)
        let command = value.command.bound(to: .init(id: actor, authVersion: 7))
        XCTAssertEqual(command.expectedAuthVersion, 7); XCTAssertEqual(command.expectedActorId, actor)
    }
    func testClosedKeysRejectAuthVersionSecretsUnknownMissingAndNullFields() throws {
        let object = try StagedHTTPFixture.envelope()
        for field in ["authVersion", "expectedAuthVersion", "token", "pin", "consent", "filePath", "commit"] {
            var changed = object, command = changed["command"] as! [String: Any]; command[field] = "not accepted"; changed["command"] = command
            StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
        }
        for target in ["root", "command", "mutation", "destination", "acknowledgement"] {
            var changed = object, command = object["command"] as! [String: Any]
            if target == "root" { changed["unknown"] = true }
            else if target == "command" { command["unknown"] = true; changed["command"] = command }
            else { var nested = command[target] as! [String: Any]; nested["unknown"] = true; command[target] = nested; changed["command"] = command }
            StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
        }
        for key in object.keys {
            var changed = object; changed.removeValue(forKey: key); StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
            changed = object; changed[key] = NSNull(); StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
        }
    }
    func testDuplicateKeysEscapedAliasesArraysDepthAndTrailingJSONAreRejected() throws {
        let original = String(decoding: try StagedHTTPFixture.data(StagedHTTPFixture.envelope()), as: UTF8.self)
        for key in ["formatVersion", "format\\u0056ersion"] {
            StagedHTTPFixture.invalid(Data(("{\"\(key)\":1," + original.dropFirst()).utf8))
        }
        StagedHTTPFixture.invalid(Data(original.replacingOccurrences(of: "\"operationId\":", with: "\"operationId\":\"\(UUID())\",\"operationId\":").utf8))
        StagedHTTPFixture.invalid(Data((original + "{}").utf8))
        StagedHTTPFixture.invalid(Data("{\"formatVersion\":[[[[[[[[1]]]]]]]]}".utf8))
        StagedHTTPFixture.invalid(Data("{\"formatVersion\":{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":{\"g\":1}}}}}}}}".utf8))
    }
    func testBase64RequiresCanonicalPaddingAlphabetAndExactDecodedCount() throws {
        let original = try StagedHTTPFixture.envelope()
        for encoded in ["/w==\n", "_w==", "/w", "/x==", "====", "!!!!", "AA=A"] {
            var changed = original, command = changed["command"] as! [String: Any]; command["exportByteCount"] = 1; changed["command"] = command; changed["descriptorBase64"] = encoded
            StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
        }
        var changed = original, command = changed["command"] as! [String: Any]; command["exportByteCount"] = 2; changed["command"] = command; changed["descriptorBase64"] = "/w=="
        StagedHTTPFixture.invalid(try StagedHTTPFixture.data(changed))
    }
    func testEightMiBExactSourceBoundaryAndTwelveMiBEnvelopeCap() throws {
        var object = try StagedHTTPFixture.envelope(), command = object["command"] as! [String: Any]
        let bytes = Data(repeating: 97, count: 8 * 1024 * 1024)
        command["exportByteCount"] = bytes.count; object["command"] = command; object["descriptorBase64"] = bytes.base64EncodedString()
        XCTAssertEqual(try StagedLegacyImportHTTP.create(StagedHTTPFixture.data(object)).descriptor, bytes)
        command["exportByteCount"] = bytes.count + 1; object["command"] = command
        StagedHTTPFixture.invalid(try StagedHTTPFixture.data(object), status: .payloadTooLarge)
        StagedHTTPFixture.invalid(Data(repeating: 32, count: 12 * 1024 * 1024 + 1), status: .payloadTooLarge)
    }
    func testReadAbortRequireExactScopeURLAndRevisionWithoutExtraFields() throws {
        let object = try StagedHTTPFixture.envelope(), workspace = UUID(), scope = StagedHTTPFixture.scope(object, workspace: workspace), session = UUID(uuidString: scope["sessionId"] as! String)!
        let read: [String: Any] = ["formatVersion": 1, "scope": scope]
        XCTAssertEqual(try StagedLegacyImportHTTP.read(StagedHTTPFixture.data(read), workspaceID: workspace, sessionID: session).scope.workspaceId, workspace)
        XCTAssertThrowsError(try StagedLegacyImportHTTP.read(StagedHTTPFixture.data(read), workspaceID: UUID(), sessionID: session)) { XCTAssertEqual(($0 as? Abort)?.status, .conflict) }
        var abort = read; abort["mutation"] = ["operationId": UUID().uuidString, "deviceId": scope["deviceId"]!]; abort["expectedRevision"] = 1
        XCTAssertEqual(try StagedLegacyImportHTTP.abort(StagedHTTPFixture.data(abort), workspaceID: workspace, sessionID: session).expectedRevision, 1)
        abort["expectedRevision"] = 0
        XCTAssertThrowsError(try StagedLegacyImportHTTP.abort(StagedHTTPFixture.data(abort), workspaceID: workspace, sessionID: session))
        var hidden = read; hidden["descriptorBase64"] = object["descriptorBase64"]
        XCTAssertThrowsError(try StagedLegacyImportHTTP.read(StagedHTTPFixture.data(hidden), workspaceID: workspace, sessionID: session))
    }
}

final class StagedLegacyImportHTTPTests: XCTestCase {
    var app: Application!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: StagedHTTPFixture.api)
    override func setUp() async throws {
        guard let url = Environment.get("DATABASE_URL"), let parts = URLComponents(string: url), parts.host == "127.0.0.1", parts.port == 55439,
              parts.path == "/snaglist_release_staged_import_0913" else { throw XCTSkip("Pinned owned local synthetic PostgreSQL required") }
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[ImportServerBindingKey.self] = binding
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture(company: Bool = false) async throws -> (User, UUID, [String: Any]) {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("stage-http-\(UUID())@example.test", name: "Synthetic manager", on: db) }
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: user.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: user.requireID(), on: db)
        }
        return (user, try workspace.requireID(), try StagedHTTPFixture.envelope(actor: user.requireID(), kind: company ? "company" : "personal"))
    }
    private func request(_ object: [String: Any]?, workspace: UUID, session: String? = nil, action: String? = nil, user: User? = nil,
                         cookie: String? = nil, csrf: String? = nil, origin: String? = nil, raw: Data? = nil, contentType: HTTPMediaType = .json) async throws -> XCTHTTPResponse {
        let jwt = try user.map { try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: $0.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: $0.requireID(), authVersion: $0.authVersion)) }
        let path = "api/v2/workspaces/\(workspace)/import-sessions" + (session.map { "/" + $0 } ?? "") + (action.map { "/" + $0 } ?? "")
        let bytes = try raw ?? StagedHTTPFixture.data(object!)
        var result: XCTHTTPResponse!
        try await app.test(.POST, path, beforeRequest: { req in
            req.headers.contentType = contentType; req.body = .init(data: bytes)
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: BrowserSessionService.cookieName + "=" + cookie) }
            if let csrf { req.headers.replaceOrAdd(name: "X-CSRF-Token", value: csrf) }
            if let origin { req.headers.replaceOrAdd(name: .origin, value: origin) }
        }, afterResponse: { value async in result = value })
        return result
    }
    private func receipt(_ response: XCTHTTPResponse) throws -> StagedLegacyImportReceipt {
        try PlatformMutationService.decode(StagedLegacyImportReceipt.self, response.body.string)
    }
    func testOrdinaryAuthenticatedCreateReadAbortAndLostResponseRetryStayNonExecutable() async throws {
        let (user, workspace, object) = try await fixture(), scope = StagedHTTPFixture.scope(object, workspace: workspace), session = scope["sessionId"] as! String
        let first = try await request(object, workspace: workspace, user: user)
        XCTAssertEqual(first.status, .ok, first.body.string); XCTAssertEqual(first.headers.first(name: .cacheControl), "no-store")
        let staged = try receipt(first); XCTAssertEqual(staged.state, "staged_incomplete"); XCTAssertFalse(staged.importExecutable)
        let replay = try await request(object, workspace: workspace, user: user); XCTAssertEqual(first.body.string, replay.body.string)
        let read = try await request(["formatVersion": 1, "scope": scope], workspace: workspace, session: session, action: "receipt", user: user)
        XCTAssertEqual(read.status, .ok); XCTAssertEqual(read.body.string, first.body.string)
        XCTAssertFalse(read.body.string.contains("descriptorBase64")); XCTAssertFalse(read.body.string.contains("Willow")); XCTAssertFalse(read.body.string.contains("archivePath"))
        let abort: [String: Any] = ["formatVersion": 1, "scope": scope, "mutation": ["operationId": UUID().uuidString, "deviceId": scope["deviceId"]!], "expectedRevision": 1]
        let stopped = try await request(abort, workspace: workspace, session: session, action: "abort", user: user)
        XCTAssertEqual(stopped.status, .ok, stopped.body.string); XCTAssertEqual(try receipt(stopped).state, "aborted")
        let retry = try await request(object, workspace: workspace, user: user); XCTAssertEqual(try receipt(retry).state, "aborted")
        let sources = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM staged_legacy_import_sources WHERE session_id = \(bind: staged.sessionId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(sources, 1)
    }
    func testMissingAuthenticationAndProductionOptInCannotActivateRoutes() async throws {
        let (user, workspace, object) = try await fixture()
        let anonymous = try await request(object, workspace: workspace); XCTAssertEqual(anonymous.status, .unauthorized)
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = false
        let disabled = try await request(object, workspace: workspace, user: user); XCTAssertEqual(disabled.status, .serviceUnavailable)
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = true
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "staging")
        let stagingBinding = try ImportServerBinding(environment: "staging", apiOrigin: "https://staging-api.example.test")
        app.storage[ImportServerBindingKey.self] = stagingBinding
        var stagingObject = object, command = object["command"] as! [String: Any]
        command["destination"] = ["environment": stagingBinding.environment, "apiOrigin": stagingBinding.apiOrigin]; stagingObject["command"] = command
        let staging = try await request(stagingObject, workspace: workspace, user: user); XCTAssertEqual(staging.status, .ok, staging.body.string)
        XCTAssertEqual(try receipt(staging).destination.environment, "staging")
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://app.example.test", environment: "production")
        app.storage[ImportServerBindingKey.self] = try ImportServerBinding(environment: "production", apiOrigin: "https://api.example.test")
        let production = try await request(object, workspace: workspace, user: user); XCTAssertEqual(production.status, .serviceUnavailable)
        XCTAssertTrue(production.body.string.contains("staged_import_disabled"))
    }
    func testBrowserCookieRequiresCSRFOriginAndUnrevokedSessionForEveryAction() async throws {
        let (user, workspace, object) = try await fixture()
        let session = try await BrowserSessionService.create(for: user, config: PlatformConfiguration.load(on: app), on: app.db)
        let missing = try await request(object, workspace: workspace, cookie: session.token); XCTAssertEqual(missing.status, .forbidden)
        let badOrigin = try await request(object, workspace: workspace, cookie: session.token, csrf: session.principal.csrfToken, origin: "https://wrong.example.test")
        XCTAssertEqual(badOrigin.status, .forbidden)
        let wrongCSRF = try await request(object, workspace: workspace, cookie: session.token, csrf: "incorrect", origin: "https://portal.example.test")
        XCTAssertEqual(wrongCSRF.status, .forbidden)
        let good = try await request(object, workspace: workspace, cookie: session.token, csrf: session.principal.csrfToken, origin: "https://portal.example.test")
        XCTAssertEqual(good.status, .ok, good.body.string)
        let scope = StagedHTTPFixture.scope(object, workspace: workspace)
        let readWithoutCSRF = try await request(["formatVersion": 1, "scope": scope], workspace: workspace, session: scope["sessionId"] as? String, action: "receipt", cookie: session.token, origin: "https://portal.example.test")
        XCTAssertEqual(readWithoutCSRF.status, .forbidden)
        try await BrowserSessionService.revoke(session.principal.sessionID, on: app.db)
        let revoked = try await request(object, workspace: workspace, cookie: session.token, csrf: session.principal.csrfToken, origin: "https://portal.example.test")
        XCTAssertEqual(revoked.status, .unauthorized)
    }
    func testCurrentAccountWorkspaceMembershipAndOpaqueReceiptIsolation() async throws {
        let (owner, workspace, object) = try await fixture(company: true), (other, _, _) = try await fixture()
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO workspace_memberships (workspace_id,user_id,role,state,revision,created_at,updated_at) VALUES (\(bind: workspace),\(bind: other.requireID()),'admin','active',1,now(),now())").run()
        let created = try await request(object, workspace: workspace, user: owner); XCTAssertEqual(created.status, .ok)
        let scope = StagedHTTPFixture.scope(object, workspace: workspace)
        let otherRead = try await request(["formatVersion": 1, "scope": scope], workspace: workspace, session: scope["sessionId"] as? String, action: "receipt", user: other)
        XCTAssertEqual(otherRead.status, .notFound)
        let otherCreate = try await request(object, workspace: workspace, user: other); XCTAssertEqual(otherCreate.status, .conflict)
        try await sql.raw("UPDATE workspace_memberships SET state = 'removed',revision = revision+1 WHERE workspace_id = \(bind: workspace) AND user_id = \(bind: owner.requireID())").run()
        let removed = try await request(object, workspace: workspace, user: owner); XCTAssertEqual(removed.status, .notFound)
        try await sql.raw("UPDATE users SET auth_version = auth_version+1 WHERE id = \(bind: owner.requireID())").run()
        let oldJWT = try await request(object, workspace: workspace, user: owner); XCTAssertEqual(oldJWT.status, .unauthorized)
    }
    func testWrongBodyMetadataDuplicateAndSourceBytesFailWithoutSourceWrite() async throws {
        let (user, workspace, object) = try await fixture(), scope = StagedHTTPFixture.scope(object, workspace: workspace), id = UUID(uuidString: scope["sessionId"] as! String)!
        let wrongType = try await request(object, workspace: workspace, user: user, contentType: .plainText); XCTAssertEqual(wrongType.status, .badRequest)
        let tooLarge = try await request(nil, workspace: workspace, user: user, raw: Data(repeating: 32, count: StagedLegacyImportHTTP.maximumCreateBytes + 1))
        XCTAssertEqual(tooLarge.status, .payloadTooLarge)
        let original = String(decoding: try StagedHTTPFixture.data(object), as: UTF8.self)
        let duplicate = try await request(nil, workspace: workspace, user: user, raw: Data(("{\"formatVersion\":1," + original.dropFirst()).utf8)); XCTAssertEqual(duplicate.status, .badRequest)
        var wrongSource = object; wrongSource["descriptorBase64"] = Data(repeating: 32, count: try StagedHTTPFixture.source.count).base64EncodedString()
        let mismatch = try await request(wrongSource, workspace: workspace, user: user); XCTAssertEqual(mismatch.status, .conflict)
        XCTAssertTrue(mismatch.body.string.contains("staged_import_source_mismatch"))
        let n = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM staged_legacy_import_sources WHERE session_id = \(bind: id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(n, 0)
    }
}
