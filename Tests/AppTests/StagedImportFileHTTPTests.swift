@testable import App
import XCTVapor
import Fluent
import FluentSQL
import SotoS3

private enum FileWireFixture {
    static let scope = StagedLegacyImportScope(sessionId: UUID(), workspaceId: UUID(), deviceId: UUID(),
        destination: .init(environment: "development", apiOrigin: "http://127.0.0.1:55480"), exportSHA256: String(repeating: "a", count: 64),
        sourceFingerprint: String(repeating: "b", count: 64), selectedProjectId: UUID())
    static let command = StagedImportOriginalCommand(scope: scope, declarationId: UUID(), operationId: UUID(), expectedSessionRevision: 1)
    static func headers(_ command: StagedImportOriginalCommand = command, count: Int64 = 0) throws -> HTTPHeaders {
        let envelope = StagedImportFileHTTP.UploadEnvelope(formatVersion: 1, command: command)
        return [StagedImportFileHTTP.commandHeader: try JSONEncoder().encode(envelope).base64EncodedString(),
                "Content-Type": "application/octet-stream", "Content-Length": String(count)]
    }
    static func upload(_ headers: HTTPHeaders) throws -> (StagedImportOriginalCommand, Int64) {
        try StagedImportFileHTTP.upload(headers, workspace: scope.workspaceId, session: scope.sessionId, declaration: command.declarationId)
    }
}

final class StagedImportFileWireTests: XCTestCase {
    func testRawHeaderRoundtripZeroAndAdmissionBoundary() throws {
        for size: Int64 in [0, 1, StagedImportFileHTTP.maximumUploadBytes] {
            let (command, count) = try FileWireFixture.upload(FileWireFixture.headers(count: size))
            XCTAssertEqual(command.operationId, FileWireFixture.command.operationId); XCTAssertEqual(count, size)
        }
        XCTAssertThrowsError(try FileWireFixture.upload(FileWireFixture.headers(count: StagedImportFileHTTP.maximumUploadBytes + 1))) { XCTAssertEqual(($0 as? Abort)?.status, .payloadTooLarge) }
    }
    func testHeaderRejectsDuplicateFieldsNoncanonicalBase64AndUnknownClaims() throws {
        let original = try FileWireFixture.headers(), data = Data(base64Encoded: original.first(name: StagedImportFileHTTP.commandHeader)!)!
        for text in [original.first(name: StagedImportFileHTTP.commandHeader)! + "\n", "_w==", "/x==", String(repeating: "A", count: 6000)] {
            var headers = original; headers.replaceOrAdd(name: StagedImportFileHTTP.commandHeader, value: text)
            XCTAssertThrowsError(try FileWireFixture.upload(headers))
        }
        var duplicate = original; duplicate.add(name: StagedImportFileHTTP.commandHeader, value: original.first(name: StagedImportFileHTTP.commandHeader)!)
        XCTAssertThrowsError(try FileWireFixture.upload(duplicate))
        let json = String(decoding: data, as: UTF8.self)
        for prefix in ["\"formatVersion\":1,", "\"format\\u0056ersion\":1,", "\"token\":\"unaccepted\","] {
            var headers = original; headers.replaceOrAdd(name: StagedImportFileHTTP.commandHeader, value: Data(("{" + prefix + json.dropFirst()).utf8).base64EncodedString())
            XCTAssertThrowsError(try FileWireFixture.upload(headers))
        }
    }
    func testLengthAndContentMetadataAreStrict() throws {
        let original = try FileWireFixture.headers()
        for length in ["", "00", "+1", "-1", " 1", "1.0", "1e2", "99999999999999999999"] {
            var headers = original; headers.replaceOrAdd(name: .contentLength, value: length)
            XCTAssertThrowsError(try FileWireFixture.upload(headers))
        }
        var missing = original; missing.remove(name: .contentLength)
        XCTAssertThrowsError(try FileWireFixture.upload(missing)) { XCTAssertEqual(($0 as? Abort)?.status, .lengthRequired) }
        var duplicate = original; duplicate.add(name: .contentLength, value: "0"); XCTAssertThrowsError(try FileWireFixture.upload(duplicate))
        for pair in [("Content-Encoding", "gzip"), ("Transfer-Encoding", "chunked"), ("Content-Type", "multipart/form-data")] {
            var headers = original; headers.replaceOrAdd(name: pair.0, value: pair.1); XCTAssertThrowsError(try FileWireFixture.upload(headers))
        }
    }
    func testManifestClosedScopeBoundsAndURLIdentity() throws {
        let scope = FileWireFixture.scope
        let request = StagedImportFileManifestRequest(formatVersion: 1, scope: scope, expectedSessionRevision: 1, offset: 0, limit: 100)
        let bytes = try JSONEncoder().encode(request)
        XCTAssertEqual(try StagedImportFileHTTP.manifest(bytes, workspace: scope.workspaceId, session: scope.sessionId).limit, 100)
        XCTAssertThrowsError(try StagedImportFileHTTP.manifest(bytes, workspace: UUID(), session: scope.sessionId))
        for pair in [("limit", 101), ("offset", -1), ("expectedSessionRevision", 0)] {
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; object[pair.0] = pair.1
            XCTAssertThrowsError(try StagedImportFileHTTP.manifest(JSONSerialization.data(withJSONObject: object), workspace: scope.workspaceId, session: scope.sessionId))
        }
        XCTAssertThrowsError(try StagedImportFileHTTP.manifest(Data(repeating: 32, count: 16 * 1024 + 1), workspace: scope.workspaceId, session: scope.sessionId))
        XCTAssertThrowsError(try StagedImportFileHTTP.upload(FileWireFixture.headers(), workspace: scope.workspaceId, session: scope.sessionId, declaration: UUID()))
    }
    func testHandleDigestUsesExactUTF8DomainAndKeepsUnicodeRepresentationsDistinct() {
        let prefix = "Documents/Photos/00000000-0000-4000-8000-000000000001/"
        let composed = prefix + "caf\u{e9}.png", decomposed = prefix + "cafe\u{301}.png"
        XCTAssertEqual(StagedImportFileHTTP.sourceHandleDigest(composed), "8b7ad423b17441c15b952df1d229f8a23e1029553c4d51d6e1967a1b5c41e400")
        XCTAssertEqual(composed, decomposed) // Swift canonical String equality differs from exact byte identity.
        XCTAssertNotEqual(StagedImportFileHTTP.sourceHandleDigest(composed), StagedImportFileHTTP.sourceHandleDigest(decomposed))
        XCTAssertNotEqual(StagedImportFileHTTP.sourceHandleDigest(composed), SHA256Hasher.hash(token: composed))
    }
}

final class StagedImportFileHTTPTests: XCTestCase {
    var app: Application!
    var http: StagedOriginalHTTPStub!
    var s3Client: AWSClient!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55480")
    struct Fixture {
        let user: User
        let scope: StagedLegacyImportScope
        let data: Data
        let handleDigests: Set<String>
    }
    override func setUp() async throws {
        guard let raw = Environment.get("DATABASE_URL"), let url = URLComponents(string: raw), url.host == "127.0.0.1", url.port == 55439,
              url.path == "/snaglist_release_staged_file_http_0913" else { throw XCTSkip("Pinned owned local synthetic file-HTTP database required") }
        app = try await Application.make(.testing); try await configure(app); try await app.autoMigrate()
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[ImportServerBindingKey.self] = binding; app.storage[StagedLegacyImportHTTPEnabledKey.self] = true
        http = StagedOriginalHTTPStub()
        s3Client = AWSClient(credentialProvider: .static(accessKeyId: "synthetic", secretAccessKey: "synthetic"), retryPolicy: .noRetry, httpClient: http)
        app.storage[StagedImportOriginalStoreKey.self] = SotoStagedImportOriginalStore(s3: S3(client: s3Client, endpoint: "https://synthetic.invalid"), privateBucket: "synthetic-private")
    }
    override func tearDown() async throws { if let s3Client { try await s3Client.shutdown() }; if let app { try await app.asyncShutdown() } }
    private func fixture(data: Data = Data("synthetic opaque drawing original".utf8), declaredBytes: Int64? = nil) async throws -> Fixture {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("file-http-\(UUID())@example.test", name: "Synthetic site manager", on: db) }
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: user.requireID(), on: db) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json"))
        var handles = Set<String>()
        func rewrite(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["availability"] as? String == "verifiedBytes" {
                    object["bytes"] = declaredBytes ?? Int64(data.count); object["sha256"] = LegacyProjectImportDecoder.digest(data)
                    handles.insert(StagedImportFileHTTP.sourceHandleDigest(object["archivePath"] as! String))
                }
                return object.mapValues(rewrite)
            }
            if let list = value as? [Any] { return list.map(rewrite) }; return value
        }
        let bytes = try JSONSerialization.data(withJSONObject: rewrite(JSONSerialization.jsonObject(with: raw)), options: [.sortedKeys])
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: bytes)
        let command = StagedLegacyImportCommand(formatVersion: 1, sessionId: UUID(), mutation: .init(operationId: UUID(), deviceId: UUID()),
            expectedActorId: try user.requireID(), expectedAuthVersion: user.authVersion, expectedWorkspaceKind: "personal", destination: binding.destination,
            selectedProjectId: source.project.id, sourceFingerprint: source.source.sourceFingerprint, exportSHA256: LegacyProjectImportDecoder.digest(bytes), exportByteCount: bytes.count,
            acknowledgement: .init(version: StagedLegacyImportCommand.Acknowledgement.supportedVersion, wording: StagedLegacyImportCommand.Acknowledgement.supportedWording, accepted: true))
        _ = try await StagedLegacyImportService.create(command, descriptor: bytes, workspaceID: workspace.requireID(), actor: .init(id: user.requireID(), authVersion: user.authVersion), binding: binding, on: app.db)
        return try .init(user: user, scope: StagedLegacyImportService.scope(command, workspaceID: workspace.requireID()), data: data, handleDigests: handles)
    }
    private func request(_ fixture: Fixture, action: String, body: Data, headers: HTTPHeaders, user: User? = nil,
                         cookie: String? = nil, csrf: String? = nil, origin: String? = nil, live: Bool = false) async throws -> XCTHTTPResponse {
        var headers = headers
        if let user {
            let payload = try UserJWTPayload(subject: .init(value: user.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(300)), userId: user.requireID(), authVersion: user.authVersion)
            headers.bearerAuthorization = .init(token: try app.jwt.signers.sign(payload))
        }
        if let cookie { headers.replaceOrAdd(name: .cookie, value: BrowserSessionService.cookieName + "=" + cookie) }
        if let csrf { headers.replaceOrAdd(name: "X-CSRF-Token", value: csrf) }
        if let origin { headers.replaceOrAdd(name: .origin, value: origin) }
        let path = "api/v2/workspaces/\(fixture.scope.workspaceId)/import-sessions/\(fixture.scope.sessionId)/files/" + action
        let tester = try app.testable(method: live ? .running(hostname: "127.0.0.1", port: 0) : .inMemory)
        return try await tester.sendRequest(.POST, path, headers: headers, body: ByteBuffer(data: body))
    }
    private func manifest(_ fixture: Fixture, offset: Int = 0, limit: Int = 100) async throws -> StagedImportFileManifest {
        let command = StagedImportFileManifestRequest(formatVersion: 1, scope: fixture.scope, expectedSessionRevision: 1, offset: offset, limit: limit)
        let result = try await request(fixture, action: "manifest", body: JSONEncoder().encode(command), headers: ["Content-Type": "application/json"], user: fixture.user)
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try PlatformMutationService.decode(StagedImportFileManifest.self, result.body.string)
    }
    private func upload(_ fixture: Fixture, _ command: StagedImportOriginalCommand, user: User? = nil, cookie: String? = nil,
                        csrf: String? = nil, origin: String? = nil, live: Bool = false) async throws -> XCTHTTPResponse {
        try await request(fixture, action: "\(command.declarationId)/original", body: fixture.data, headers: FileWireFixture.headers(command, count: Int64(fixture.data.count)),
            user: user, cookie: cookie, csrf: csrf, origin: origin, live: live)
    }
    private func command(_ fixture: Fixture, _ entry: StagedImportFileManifest.Entry) -> StagedImportOriginalCommand {
        .init(scope: fixture.scope, declarationId: entry.declarationId, operationId: entry.operationId ?? UUID(), expectedSessionRevision: 1)
    }
    private func counts(_ fixture: Fixture) async throws -> (Int, Int) {
        let sql = try VerifiedIdentityService.sql(app.db)
        let op = try await sql.raw("SELECT count(*) AS n FROM staged_import_file_operations WHERE session_id = \(bind: fixture.scope.sessionId)").first()!.decode(column: "n", as: Int.self)
        let receipt = try await sql.raw("SELECT count(*) AS n FROM staged_import_original_receipts WHERE session_id = \(bind: fixture.scope.sessionId)").first()!.decode(column: "n", as: Int.self)
        return (op, receipt)
    }
    func testManifestPagingPrivateHandleMappingAndLostResponseResumeKeepSameOperation() async throws {
        let fixture = try await fixture(), first = try await manifest(fixture, limit: 5), rest = try await manifest(fixture, offset: 5)
        XCTAssertEqual(first.totalCount, 12); XCTAssertEqual(first.nextOffset, 5); XCTAssertNil(rest.nextOffset)
        let all = first.entries + rest.entries
        XCTAssertEqual(Set(all.map(\.sourceHandleSHA256)), fixture.handleDigests); XCTAssertEqual(all.map(\.ordinal), Array(0..<12))
        XCTAssertEqual(first.descriptorMaximumBytes, 8 * 1024 * 1024); XCTAssertEqual(first.singleRequestMaximumBytes, 50 * 1024 * 1024)
        XCTAssertEqual(first.supportedOriginalRoles.count, 8); XCTAssertFalse(first.canonicalReady)
        let json = try PlatformMutationService.encode(first)
        XCTAssertFalse(json.contains("archivePath")); XCTAssertFalse(json.contains("Documents/")); XCTAssertFalse(json.contains("staged-import/"))
        let command = command(fixture, first.entries[0]); await http.configure(lost: true)
        let uncertain = try await upload(fixture, command, user: fixture.user); XCTAssertEqual(uncertain.status, .serviceUnavailable)
        let pending = try await manifest(fixture); let entry = try XCTUnwrap(pending.entries.first { $0.declarationId == command.declarationId })
        XCTAssertEqual(entry.operationId, command.operationId); XCTAssertEqual(entry.storageState, "operation_reserved"); XCTAssertNil(entry.originalReceipt)
        let recovered = try await upload(fixture, self.command(fixture, entry), user: fixture.user); XCTAssertEqual(recovered.status, .ok, recovered.body.string)
        let replay = try await upload(fixture, command, user: fixture.user); XCTAssertEqual(recovered.body.string, replay.body.string)
        let final = try await manifest(fixture); let finished = try XCTUnwrap(final.entries.first { $0.declarationId == command.declarationId })
        XCTAssertEqual(finished.storageState, "persisted_original_verified"); XCTAssertFalse(try XCTUnwrap(finished.originalReceipt).canonicalReady)
        let transport = await http.snapshot(); XCTAssertEqual(transport.objects, 1); XCTAssertEqual(transport.yielded, fixture.data.count)
    }
    func testLiveSocketFiftyMiBStreamAndTrueEmptyBodyPreserveExactOriginals() async throws {
        for data in [Data(repeating: 87, count: 50 * 1024 * 1024), Data()] {
            let fixture = try await fixture(data: data), entry = try await manifest(fixture).entries[0]
            let response = try await upload(fixture, command(fixture, entry), user: fixture.user, live: true)
            XCTAssertEqual(response.status, .ok, response.body.string)
            let receipt = try PlatformMutationService.decode(StagedImportOriginalReceipt.self, response.body.string)
            XCTAssertEqual(receipt.measuredBytes, Int64(data.count)); XCTAssertEqual(receipt.measuredSHA256, LegacyProjectImportDecoder.digest(data))
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store"); XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
        }
    }
    func testAboveLimitOriginalRemainsVisibleAndCannotReserveEvenWithSmallAssertedLength() async throws {
        let fixture = try await fixture(declaredBytes: StagedImportFileHTTP.maximumUploadBytes + 1), list = try await manifest(fixture)
        XCTAssertEqual(list.entries.count, 12); XCTAssertTrue(list.entries.allSatisfy { !$0.uploadSupported && $0.storageState == "declared_only" })
        let result = try await upload(fixture, command(fixture, list.entries[0]), user: fixture.user)
        XCTAssertEqual(result.status, .payloadTooLarge)
        let count = try await counts(fixture); XCTAssertEqual(count.0, 0); XCTAssertEqual(count.1, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 0)
    }
    func testAuthenticationForeignDeclarationWrongLengthAndAbortedSourceCannotWrite() async throws {
        let fixture = try await fixture(declaredBytes: 999), list = try await manifest(fixture), command = command(fixture, list.entries[0])
        let anonymous = try await upload(fixture, command); XCTAssertEqual(anonymous.status, .unauthorized)
        let other = try await self.fixture(); let forbidden = try await upload(fixture, command, user: other.user); XCTAssertEqual(forbidden.status, .notFound)
        let wrongLength = try await upload(fixture, command, user: fixture.user); XCTAssertEqual(wrongLength.status, .badRequest)
        let foreign = StagedImportOriginalCommand(scope: fixture.scope, declarationId: UUID(), operationId: command.operationId, expectedSessionRevision: 1)
        let missing = try await upload(fixture, foreign, user: fixture.user); XCTAssertEqual(missing.status, .notFound)
        _ = try await StagedLegacyImportService.abort(.init(scope: fixture.scope, mutation: .init(operationId: UUID(), deviceId: fixture.scope.deviceId), expectedRevision: 1), actor: .init(id: fixture.user.requireID(), authVersion: fixture.user.authVersion), binding: binding, on: app.db)
        let aborted = try await upload(fixture, command, user: fixture.user); XCTAssertEqual(aborted.status, .gone)
        let count = try await counts(fixture); XCTAssertEqual(count.0, 0); XCTAssertEqual(count.1, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 0)
    }
    func testBrowserCSRFAndProductionGateApplyToManifestAndUploads() async throws {
        let fixture = try await fixture(), list = try await manifest(fixture), command = command(fixture, list.entries[0])
        let browser = try await BrowserSessionService.create(for: fixture.user, config: PlatformConfiguration.load(on: app), on: app.db)
        let missing = try await upload(fixture, command, cookie: browser.token); XCTAssertEqual(missing.status, .forbidden)
        let wrong = try await upload(fixture, command, cookie: browser.token, csrf: browser.principal.csrfToken, origin: "https://wrong.example.test")
        XCTAssertEqual(wrong.status, .forbidden)
        let body = try JSONEncoder().encode(StagedImportFileManifestRequest(formatVersion: 1, scope: fixture.scope, expectedSessionRevision: 1, offset: 0, limit: 100))
        let privateRead = try await request(fixture, action: "manifest", body: body, headers: ["Content-Type": "application/json"], cookie: browser.token)
        XCTAssertEqual(privateRead.status, .forbidden)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://app.example.test", environment: "production")
        app.storage[ImportServerBindingKey.self] = try ImportServerBinding(environment: "production", apiOrigin: "https://api.example.test")
        let disabled = try await upload(fixture, command, user: fixture.user); XCTAssertEqual(disabled.status, .serviceUnavailable)
        let disabledRead = try await request(fixture, action: "manifest", body: body, headers: ["Content-Type": "application/json"], user: fixture.user)
        XCTAssertEqual(disabledRead.status, .serviceUnavailable)
        let count = try await counts(fixture); XCTAssertEqual(count.0, 0)
    }
    func testBrowserRevokedAfterObjectIOCannotReceiveReceiptButNewSameAccountSessionCanResume() async throws {
        let fixture = try await fixture(), entry = try await manifest(fixture).entries[0], command = command(fixture, entry), database = app.db
        let browser = try await BrowserSessionService.create(for: fixture.user, config: PlatformConfiguration.load(on: app), on: database)
        await http.configure(afterPut: { try await BrowserSessionService.revoke(browser.principal.sessionID, on: database) })
        let revoked = try await upload(fixture, command, cookie: browser.token, csrf: browser.principal.csrfToken, origin: "https://portal.example.test", live: true)
        XCTAssertEqual(revoked.status, .unauthorized)
        let count = try await counts(fixture); XCTAssertEqual(count.0, 1); XCTAssertEqual(count.1, 0)
        let next = try await BrowserSessionService.create(for: fixture.user, config: PlatformConfiguration.load(on: app), on: database)
        let resumed = try await upload(fixture, command, cookie: next.token, csrf: next.principal.csrfToken, origin: "https://portal.example.test", live: true)
        XCTAssertEqual(resumed.status, .ok, resumed.body.string)
        let transport = await http.snapshot(); XCTAssertEqual(transport.objects, 1); XCTAssertEqual(transport.yielded, fixture.data.count)
    }
    func testBrowserSessionShareLockIsHeldThroughActualReceiptCommit() async throws {
        let fixture = try await fixture(), entry = try await manifest(fixture).entries[0], command = command(fixture, entry)
        let browser = try await BrowserSessionService.create(for: fixture.user, config: PlatformConfiguration.load(on: app), on: app.db)
        let sql = try VerifiedIdentityService.sql(app.db), suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let function = "synthetic_http_file_" + suffix, trigger = "synthetic_http_pause_" + suffix
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: function)() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF NEW.session_id='\(unsafeRaw: fixture.scope.sessionId.uuidString)'::uuid THEN PERFORM pg_sleep(1); END IF; RETURN NEW; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE INSERT ON staged_import_original_receipts FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: function)()").run()
        let upload = Task { try await self.upload(fixture, command, cookie: browser.token, csrf: browser.principal.csrfToken, origin: "https://portal.example.test", live: true) }
        var paused = false
        for _ in 0..<150 {
            let n = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND wait_event='PgSleep' AND query LIKE 'INSERT INTO staged_import_original_receipts%'").first()!.decode(column: "n", as: Int.self)
            if n > 0 { paused = true; break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        let database = app.db
        let revoke = Task { try await BrowserSessionService.revoke(browser.principal.sessionID, on: database) }
        var lockObserved = false
        for _ in 0..<30 {
            let n = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND wait_event_type='Lock' AND query LIKE 'UPDATE browser_sessions SET revoked_at%'").first()!.decode(column: "n", as: Int.self)
            if n > 0 { lockObserved = true; break }; try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try await upload.value; try await revoke.value
        try await sql.raw("DROP TRIGGER \(unsafeRaw: trigger) ON staged_import_original_receipts").run(); try await sql.raw("DROP FUNCTION \(unsafeRaw: function)()").run()
        XCTAssertTrue(paused); XCTAssertTrue(lockObserved); XCTAssertEqual(result.status, .ok, result.body.string)
        let denied = try await self.upload(fixture, command, cookie: browser.token, csrf: browser.principal.csrfToken, origin: "https://portal.example.test")
        XCTAssertEqual(denied.status, .unauthorized)
    }
}
