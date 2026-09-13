@testable import App
import XCTVapor
import Fluent
import FluentSQL
import SotoS3

final class StagedImportOriginalServiceTests: XCTestCase {
    var app: Application!
    var http: StagedOriginalHTTPStub!
    var client: AWSClient!
    var store: SotoStagedImportOriginalStore!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55480")
    struct Fixture {
        let actor: StagedLegacyImportActor
        let stage: StagedLegacyImportCommand
        let command: StagedImportOriginalCommand
        let data: Data
    }
    override func setUp() async throws {
        guard let value = Environment.get("DATABASE_URL"), let url = URLComponents(string: value),
              url.host == "127.0.0.1", url.port == 55439, url.path == "/snaglist_release_staged_files_0913" else {
            throw XCTSkip("Explicit owned local synthetic original-file test database required")
        }
        app = try await Application.make(.testing); try await configure(app)
        http = StagedOriginalHTTPStub()
        client = AWSClient(credentialProvider: .static(accessKeyId: "synthetic", secretAccessKey: "synthetic"), retryPolicy: .noRetry, httpClient: http)
        store = .init(s3: S3(client: client, endpoint: "https://synthetic.invalid"), privateBucket: "synthetic-private")
    }
    override func tearDown() async throws {
        if let client { try await client.shutdown() }
        if let app { try await app.asyncShutdown() }
    }
    private func fixture(data: Data = Data("opaque historical original; no image validation".utf8), companyAdmin: Bool = false) async throws -> Fixture {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("original-\(UUID())@example.test", name: "Synthetic import manager", on: db) }
        let actor = try StagedLegacyImportActor(id: user.requireID(), authVersion: user.authVersion)
        let workspaceID: UUID
        if companyAdmin {
            let owner = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("owner-\(UUID())@example.test", name: "Synthetic company owner", on: db) }
            let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic construction team", actorID: owner.requireID(), on: db) }
            workspaceID = try company.requireID()
            try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO workspace_memberships(workspace_id,user_id,role,state,revision,created_at,updated_at) VALUES (\(bind: workspaceID),\(bind: actor.id),'admin','active',1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)").run()
        } else {
            workspaceID = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: actor.id, on: db).requireID() }
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json"))
        // Keep every typed role/edge and source handle; substitute synthetic bytes
        // declarations. No fixture content is claimed as an actual validated image.
        func rewrite(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["availability"] as? String == "verifiedBytes" { object["bytes"] = data.count; object["sha256"] = LegacyProjectImportDecoder.digest(data) }
                return object.mapValues(rewrite)
            }
            if let values = value as? [Any] { return values.map(rewrite) }
            return value
        }
        let descriptor = try JSONSerialization.data(withJSONObject: rewrite(JSONSerialization.jsonObject(with: raw)), options: [.sortedKeys])
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: descriptor)
        let stage = StagedLegacyImportCommand(formatVersion: 1, sessionId: UUID(), mutation: .init(operationId: UUID(), deviceId: UUID()),
            expectedActorId: actor.id, expectedAuthVersion: actor.authVersion, expectedWorkspaceKind: companyAdmin ? "company" : "personal",
            destination: binding.destination, selectedProjectId: source.project.id, sourceFingerprint: source.source.sourceFingerprint,
            exportSHA256: LegacyProjectImportDecoder.digest(descriptor), exportByteCount: descriptor.count,
            acknowledgement: .init(version: StagedLegacyImportCommand.Acknowledgement.supportedVersion, wording: StagedLegacyImportCommand.Acknowledgement.supportedWording, accepted: true))
        _ = try await StagedLegacyImportService.create(stage, descriptor: descriptor, workspaceID: workspaceID, actor: actor, binding: binding, on: app.db)
        let declaration = try await VerifiedIdentityService.sql(app.db).raw("SELECT declaration_id FROM staged_legacy_import_files WHERE session_id = \(bind: stage.sessionId) ORDER BY declaration_id LIMIT 1").first()!.decode(column: "declaration_id", as: UUID.self)
        return .init(actor: actor, stage: stage, command: .init(scope: StagedLegacyImportService.scope(stage, workspaceID: workspaceID), declarationId: declaration,
            operationId: UUID(), expectedSessionRevision: 1), data: data)
    }
    private func retain(_ fixture: Fixture, command: StagedImportOriginalCommand? = nil, actor: StagedLegacyImportActor? = nil, data: Data? = nil) async throws -> StagedImportOriginalReceipt {
        try await StagedImportOriginalService.retain(command ?? fixture.command, actor: actor ?? fixture.actor, binding: binding,
            body: stagedTestBody(data ?? fixture.data), store: store, on: app.db)
    }
    private func count(_ table: String, session: UUID) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE session_id = \(bind: session)").first()!.decode(column: "n", as: Int.self)
    }
    private func rejected(_ status: HTTPResponseStatus? = nil, _ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected rejection", file: file, line: line) }
        catch { if let status { XCTAssertEqual((error as? Abort)?.status, status, file: file, line: line) } }
    }
    private func changed(_ command: StagedImportOriginalCommand, _ change: (inout [String: Any]) -> Void) throws -> StagedImportOriginalCommand {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        change(&object)
        return try JSONDecoder().decode(StagedImportOriginalCommand.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testMeasuredOriginalReceiptAndExactRetryDoNotPublishOrRewriteDeclarations() async throws {
        let fixture = try await fixture()
        let first = try await retain(fixture), retry = try await retain(fixture)
        XCTAssertEqual(first, retry); XCTAssertEqual(first.measuredBytes, Int64(fixture.data.count)); XCTAssertEqual(first.measuredSHA256, LegacyProjectImportDecoder.digest(fixture.data))
        XCTAssertEqual(first.verification, "persisted_original_bytes_v1"); XCTAssertEqual(first.contentValidation, "opaque_not_decoded"); XCTAssertFalse(first.canonicalReady)
        let state = try await StagedLegacyImportService.read(fixture.command.scope, actor: fixture.actor, binding: binding, on: app.db)
        XCTAssertEqual(state.state, "staged_incomplete"); XCTAssertEqual(state.revision, 1); XCTAssertFalse(state.importExecutable)
        let counts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId)
        let operations = try await count("staged_import_file_operations", session: fixture.stage.sessionId)
        XCTAssertEqual(counts, 1); XCTAssertEqual(operations, 1)
        let declarationStates = try await VerifiedIdentityService.sql(app.db).raw("SELECT DISTINCT verification_state FROM staged_legacy_import_files WHERE session_id = \(bind: fixture.stage.sessionId)").all()
        XCTAssertEqual(declarationStates.count, 1); XCTAssertEqual(try declarationStates[0].decode(column: "verification_state", as: String.self), "unverified_declaration")
        let canonical = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM projects WHERE id = \(bind: fixture.stage.selectedProjectId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(canonical, 0)
        let global = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM mutation_receipts WHERE actor_id = \(bind: fixture.actor.id) AND operation_id = \(bind: fixture.command.operationId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(global, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 1); XCTAssertEqual(transport.gets, 2)
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(encoded.contains("archivePath")); XCTAssertFalse(encoded.contains("staged-import/")); XCTAssertFalse(encoded.contains("sourcePath"))
    }
    func testZeroByteOpaqueHistoricOriginalCanReceiveItsOwnMeasuredReceipt() async throws {
        let fixture = try await fixture(data: Data())
        let receipt = try await retain(fixture)
        XCTAssertEqual(receipt.measuredBytes, 0); XCTAssertEqual(receipt.measuredSHA256, LegacyProjectImportDecoder.digest(Data())); XCTAssertFalse(receipt.canonicalReady)
    }
    func testByteFailureKeepsReservationAndSameOperationCanRecover() async throws {
        let fixture = try await fixture()
        await rejected(.unprocessableEntity) { _ = try await self.retain(fixture, data: Data("wrong".utf8)) }
        let empty = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(empty, 0)
        let receipt = try await retain(fixture); XCTAssertEqual(receipt.firstOperationId, fixture.command.operationId)
        let operations = try await count("staged_import_file_operations", session: fixture.stage.sessionId); XCTAssertEqual(operations, 1)
    }
    func testLostPUTResponseKeepsOriginalAndRecoversWithoutNewOperationOrOverwrite() async throws {
        let fixture = try await fixture(); await http.configure(lost: true)
        await rejected(.serviceUnavailable) { _ = try await self.retain(fixture) }
        let receipt = try await retain(fixture); XCTAssertEqual(receipt.firstOperationId, fixture.command.operationId)
        let transport = await http.snapshot(); XCTAssertEqual(transport.objects, 1); XCTAssertEqual(transport.puts, 2); XCTAssertEqual(transport.yielded, fixture.data.count)
    }
    func testReadbackFailureProducesNoReceiptAndExistingReceiptStillRequiresRealReadback() async throws {
        let fixture = try await fixture(); await http.configure(corrupt: true)
        await rejected(.unprocessableEntity) { _ = try await self.retain(fixture) }
        let empty = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(empty, 0)
        await http.configure(); let receipt = try await retain(fixture)
        await http.configure(corrupt: true)
        await rejected(.unprocessableEntity) { _ = try await self.retain(fixture) }
        let stillOne = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(stillOne, 1)
        await http.configure(); let replay = try await retain(fixture); XCTAssertEqual(receipt, replay)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 2); XCTAssertEqual(transport.objects, 1)
    }
    func testOperationCannotChangeFileOrBeReplacedAfterInterruptedTransfer() async throws {
        let fixture = try await fixture(); await http.configure(fail: true)
        await rejected(.serviceUnavailable) { _ = try await self.retain(fixture) }
        let another = try await VerifiedIdentityService.sql(app.db).raw("SELECT declaration_id FROM staged_legacy_import_files WHERE session_id = \(bind: fixture.stage.sessionId) AND declaration_id <> \(bind: fixture.command.declarationId) LIMIT 1").first()!.decode(column: "declaration_id", as: UUID.self)
        let otherFile = try changed(fixture.command) { $0["declarationId"] = another.uuidString }
        let otherOperation = try changed(fixture.command) { $0["operationId"] = UUID().uuidString }
        await rejected(.conflict) { _ = try await self.retain(fixture, command: otherFile) }
        await rejected(.conflict) { _ = try await self.retain(fixture, command: otherOperation) }
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 1)
    }
    func testWrongActorDeviceSourceRevisionAndForeignDeclarationAreRejectedBeforeIO() async throws {
        let fixture = try await fixture(), other = try await self.fixture()
        await rejected { _ = try await self.retain(fixture, actor: other.actor) }
        for field in ["deviceId", "sourceFingerprint"] {
            let command = try changed(fixture.command) { object in
                var scope = object["scope"] as! [String: Any]; scope[field] = field == "deviceId" ? UUID().uuidString : String(repeating: "f", count: 64); object["scope"] = scope
            }
            await rejected { _ = try await self.retain(fixture, command: command) }
        }
        let stale = try changed(fixture.command) { $0["expectedSessionRevision"] = 2 }
        let foreign = try changed(fixture.command) { $0["declarationId"] = other.command.declarationId.uuidString }
        await rejected(.conflict) { _ = try await self.retain(fixture, command: stale) }
        await rejected(.notFound) { _ = try await self.retain(fixture, command: foreign) }
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 0); XCTAssertEqual(transport.gets, 0)
    }
    func testAuthVersionChangeDuringIOCannotPublishMeasuredReceipt() async throws {
        let fixture = try await fixture(), database = app.db
        await http.configure(afterPut: {
            try await VerifiedIdentityService.sql(database).raw("UPDATE users SET auth_version = auth_version + 1 WHERE id = \(bind: fixture.actor.id)").run()
        })
        await rejected(.unauthorized) { _ = try await self.retain(fixture) }
        let receipts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(receipts, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.objects, 1)
    }
    func testAbortDuringIOPreventsReceiptAndNeverReactivatesPreparation() async throws {
        let fixture = try await fixture(), database = app.db, binding = self.binding
        await http.configure(afterPut: {
            _ = try await StagedLegacyImportService.abort(.init(scope: fixture.command.scope, mutation: .init(operationId: UUID(), deviceId: fixture.command.scope.deviceId), expectedRevision: 1), actor: fixture.actor, binding: binding, on: database)
        })
        await rejected(.gone) { _ = try await self.retain(fixture) }
        await rejected(.gone) { _ = try await self.retain(fixture) }
        let receipts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(receipts, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 1)
    }
    func testAdminRemovedDuringIOAndRejoinedCannotResumeOldAuthority() async throws {
        let fixture = try await fixture(companyAdmin: true), database = app.db
        await http.configure(afterPut: {
            try await VerifiedIdentityService.sql(database).raw("UPDATE workspace_memberships SET state = 'removed', revision = revision + 1 WHERE workspace_id = \(bind: fixture.command.scope.workspaceId) AND user_id = \(bind: fixture.actor.id)").run()
        })
        await rejected { _ = try await self.retain(fixture) }
        try await VerifiedIdentityService.sql(database).raw("UPDATE workspace_memberships SET state = 'active', revision = revision + 1 WHERE workspace_id = \(bind: fixture.command.scope.workspaceId) AND user_id = \(bind: fixture.actor.id)").run()
        await rejected { _ = try await self.retain(fixture) }
        let receipts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId); XCTAssertEqual(receipts, 0)
        let transport = await http.snapshot(); XCTAssertEqual(transport.puts, 1)
    }
    func testConcurrentSameOperationKeepsExactlyOneOriginalAndReceipt() async throws {
        let fixture = try await fixture()
        async let a = retain(fixture); async let b = retain(fixture)
        let (first, second) = try await (a, b); XCTAssertEqual(first, second)
        let receipts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId)
        let operations = try await count("staged_import_file_operations", session: fixture.stage.sessionId)
        XCTAssertEqual(receipts, 1); XCTAssertEqual(operations, 1)
        let transport = await http.snapshot(); XCTAssertEqual(transport.objects, 1)
    }
    func testImmutableReceiptsAndOperationBindingsRejectMutationOrRemoval() async throws {
        let fixture = try await fixture(); _ = try await retain(fixture)
        for table in ["staged_import_original_receipts", "staged_import_file_operations"] {
            await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("DELETE FROM \(unsafeRaw: table) WHERE session_id = \(bind: fixture.stage.sessionId)").run() }
        }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE staged_import_original_receipts SET measured_bytes = 0 WHERE session_id = \(bind: fixture.stage.sessionId)").run() }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE staged_import_file_operations SET device_id = \(bind: UUID()) WHERE session_id = \(bind: fixture.stage.sessionId)").run() }
    }

    func testCancellationObservedInsideReceiptInsertRetainsOriginalForSameOperationRecovery() async throws {
        let fixture = try await fixture(), sql = try VerifiedIdentityService.sql(app.db)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let function = "synthetic_original_cancel_" + suffix, trigger = "synthetic_original_pause_" + suffix
        // Own synthetic identifiers only. Pause precisely after object readback,
        // while the real receipt transaction has not yet reached its commit fence.
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: function)() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF NEW.session_id = '\(unsafeRaw: fixture.stage.sessionId.uuidString)'::uuid THEN PERFORM pg_sleep(1); END IF; RETURN NEW; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE INSERT ON staged_import_original_receipts FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: function)()").run()
        let task = Task { try await self.retain(fixture) }
        var observed = false
        for _ in 0..<150 {
            let waiting = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND wait_event = 'PgSleep' AND query LIKE \(bind: "INSERT INTO staged_import_original_receipts%")").first()!.decode(column: "n", as: Int.self)
            if waiting > 0 { observed = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Observed pre-commit cancellation should reach the fence") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await sql.raw("DROP TRIGGER \(unsafeRaw: trigger) ON staged_import_original_receipts").run()
        try await sql.raw("DROP FUNCTION \(unsafeRaw: function)()").run()
        XCTAssertTrue(observed)
        let receipts = try await count("staged_import_original_receipts", session: fixture.stage.sessionId)
        let operations = try await count("staged_import_file_operations", session: fixture.stage.sessionId)
        XCTAssertEqual(receipts, 0); XCTAssertEqual(operations, 1)
        let retained = await http.snapshot(); XCTAssertEqual(retained.objects, 1)
        let recovered = try await retain(fixture)
        XCTAssertEqual(recovered.firstOperationId, fixture.command.operationId)
        let after = await http.snapshot(); XCTAssertEqual(after.objects, 1); XCTAssertEqual(after.yielded, fixture.data.count)
        // This observed pre-commit rollback does not promise rollback for a
        // cancellation that arrives after the last fence/COMMIT is underway.
    }
}
