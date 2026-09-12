@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class StagedLegacyImportTests: XCTestCase {
    var app: Application!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55480")
    var bytes: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json")) } }
    override func setUp() async throws {
        guard let url = Environment.get("DATABASE_URL"), let parts = URLComponents(string: url),
              parts.host == "127.0.0.1", parts.port == 55439,
              parts.path == "/snaglist_release_staged_import_0913" else { throw XCTSkip("Explicit owned local synthetic database required") }
        try await start()
    }
    private func start() async throws {
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture(company: Bool = false) async throws -> (StagedLegacyImportActor, UUID, StagedLegacyImportCommand) {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("stage-\(UUID())@example.test", name: "Synthetic manager", on: db) }
        let actor = try StagedLegacyImportActor(id: user.requireID(), authVersion: user.authVersion)
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: actor.id, on: db) }
            return try await WorkspaceAccessService.personal(for: actor.id, on: db)
        }
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: bytes)
        return (actor, try workspace.requireID(), try .init(formatVersion: 1, sessionId: UUID(), mutation: .init(operationId: UUID(), deviceId: UUID()), expectedActorId: actor.id,
            expectedAuthVersion: actor.authVersion, expectedWorkspaceKind: company ? "company" : "personal", destination: binding.destination,
            selectedProjectId: source.project.id, sourceFingerprint: source.source.sourceFingerprint, exportSHA256: LegacyProjectImportDecoder.digest(bytes),
            exportByteCount: bytes.count, acknowledgement: .init(version: StagedLegacyImportCommand.Acknowledgement.supportedVersion,
                wording: StagedLegacyImportCommand.Acknowledgement.supportedWording, accepted: true)))
    }
    private func changed(_ command: StagedLegacyImportCommand, _ change: (inout [String: Any]) -> Void) throws -> StagedLegacyImportCommand {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        change(&object)
        return try JSONDecoder().decode(StagedLegacyImportCommand.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func create(_ command: StagedLegacyImportCommand, _ actor: StagedLegacyImportActor, _ workspace: UUID, data: Data? = nil) async throws -> StagedLegacyImportReceipt {
        try await StagedLegacyImportService.create(command, descriptor: data ?? bytes, workspaceID: workspace, actor: actor, binding: binding, on: app.db)
    }
    private func count(_ table: String, session: UUID? = nil) async throws -> Int {
        let sql = try VerifiedIdentityService.sql(app.db)
        if let session { return try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE session_id = \(bind: session)").first()!.decode(column: "n", as: Int.self) }
        return try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table)").first()!.decode(column: "n", as: Int.self)
    }
    private func rejected(_ status: HTTPResponseStatus? = nil, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { if let status { XCTAssertEqual((error as? Abort)?.status, status, file: file, line: line) } }
    }

    func testExactDescriptorEveryRecordEdgeFileRoleAndHistoryRemainPrivate() async throws {
        let (actor, workspace, command) = try await fixture()
        let tables = ["projects", "snags", "contractors", "trades", "media_assets", "drawings", "drawing_assets", "platform_changes", "workspace_activity", "completion_attempts", "review_decisions", "project_comments", "assignment_history", "snag_deletions"]
        var before: [String: Int] = [:]; for table in tables { before[table] = try await count(table) }
        let result = try await create(command, actor, workspace)
        XCTAssertEqual(result.state, "staged_incomplete"); XCTAssertEqual(result.revision, 1); XCTAssertFalse(result.importExecutable)
        XCTAssertEqual(result.recordCounts.values.reduce(0,+), 16); XCTAssertEqual(result.edgeCount, 40)
        XCTAssertEqual(result.fileRoleCounts.values.reduce(0,+), 14); XCTAssertEqual(result.declaredFileCount, 12)
        XCTAssertEqual(result.journalEventUpperBound, 135); XCTAssertEqual(result.snapshotRowUpperBound, 135)
        for table in tables { let n = try await count(table); XCTAssertEqual(n, before[table], table) }
        let sql = try VerifiedIdentityService.sql(app.db)
        let raw = try await sql.raw("SELECT encode(descriptor,'base64') AS bytes FROM staged_legacy_import_sources WHERE session_id = \(bind: result.sessionId)").first()!.decode(column: "bytes", as: String.self)
        XCTAssertEqual(Data(base64Encoded: raw, options: .ignoreUnknownCharacters), try bytes)
        let records = try await sql.raw("SELECT kind,source_id,proposed_target_id,source_json,source_sha256,mapping_state FROM staged_legacy_import_records WHERE session_id = \(bind: result.sessionId)").all()
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for row in records {
            let kind = try row.decode(column: "kind", as: String.self), id = try row.decode(column: "source_id", as: UUID.self)
            let json = try row.decode(column: "source_json", as: String.self)
            XCTAssertEqual(SHA256Hasher.hash(token: json), try row.decode(column: "source_sha256", as: String.self))
            XCTAssertEqual(id, try row.decode(column: "proposed_target_id", as: UUID.self))
            XCTAssertEqual(try row.decode(column: "mapping_state", as: String.self), "unreserved_source_id")
            let candidates = kind == "projects" ? [object["project"] as! [String: Any]] : object[kind] as! [[String: Any]]
            let source = candidates.first { UUID(uuidString: $0[kind == "deletionReceipts" ? "deletedSnagID" : "id"] as! String) == id }!
            let retained = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
            XCTAssertEqual(retained, source as NSDictionary, kind)
        }
        let edgeCount = try await count("staged_legacy_import_edges", session: result.sessionId)
        let fileCount = try await count("staged_legacy_import_files", session: result.sessionId)
        let useCount = try await count("staged_legacy_import_file_uses", session: result.sessionId)
        XCTAssertEqual(edgeCount, 40); XCTAssertEqual(fileCount, 12); XCTAssertEqual(useCount, 14)
        let ack = try await sql.raw("SELECT acknowledgement_version,acknowledgement_wording FROM staged_legacy_imports WHERE id = \(bind: result.sessionId)").first()!
        XCTAssertEqual(try ack.decode(column: "acknowledgement_wording", as: String.self), command.acknowledgement.wording)
        XCTAssertEqual(try ack.decode(column: "acknowledgement_version", as: String.self), command.acknowledgement.version)
        let graph = try await StagedLegacyImportService.loadVerifiedGraph(StagedLegacyImportService.scope(command, workspaceID: workspace), actor: actor, binding: binding, on: app.db)
        XCTAssertEqual(graph.decoded.bytes, try bytes); XCTAssertEqual(graph.historicalAcceptance, "unverified_no_canonical_decisions_created")
        XCTAssertFalse(try PlatformMutationService.encode(result).contains("Willow"))
    }

    func testRetryRestartAndConcurrentFirstWriteKeepExactlyOneMapping() async throws {
        let (actor, workspace, command) = try await fixture()
        async let first = create(command, actor, workspace)
        async let second = create(command, actor, workspace)
        let results = try await [first, second]
        XCTAssertEqual(try PlatformMutationService.encode(results[0]), try PlatformMutationService.encode(results[1]))
        let mappingBefore = try await VerifiedIdentityService.sql(app.db).raw("SELECT mapping_id FROM staged_legacy_import_records WHERE session_id = \(bind: command.sessionId) ORDER BY mapping_id").all().map { try $0.decode(column: "mapping_id", as: UUID.self) }
        try await app.asyncShutdown(); app = nil; try await start()
        let replay = try await create(command, actor, workspace)
        XCTAssertEqual(try PlatformMutationService.encode(replay), try PlatformMutationService.encode(results[0]))
        let mappingAfter = try await VerifiedIdentityService.sql(app.db).raw("SELECT mapping_id FROM staged_legacy_import_records WHERE session_id = \(bind: command.sessionId) ORDER BY mapping_id").all().map { try $0.decode(column: "mapping_id", as: UUID.self) }
        XCTAssertEqual(mappingBefore, mappingAfter)
        let actions = try await count("staged_legacy_import_actions", session: command.sessionId); XCTAssertEqual(actions, 1)
    }

    func testAcknowledgementExactBytesAndOperationDestinationCannotChange() async throws {
        let (actor, workspace, command) = try await fixture()
        for field in ["version", "wording", "accepted"] {
            let invalid = try changed(command) { body in var ack = body["acknowledgement"] as! [String: Any]; ack[field] = field == "accepted" ? false : "different"; body["acknowledgement"] = ack }
            await rejected(.badRequest) { _ = try await self.create(invalid, actor, workspace) }
        }
        await rejected { _ = try await self.create(command, actor, workspace, data: self.bytes + Data([32])) }
        _ = try await create(command, actor, workspace)
        let differentDevice = try changed(command) { body in var mutation = body["mutation"] as! [String: Any]; mutation["deviceId"] = UUID().uuidString; body["mutation"] = mutation }
        await rejected(.conflict) { _ = try await self.create(differentDevice, actor, workspace) }
        let differentBytes = try bytes + Data([32])
        let differentSource = try changed(command) { $0["exportByteCount"] = differentBytes.count; $0["exportSHA256"] = LegacyProjectImportDecoder.digest(differentBytes) }
        await rejected(.conflict) { _ = try await self.create(differentSource, actor, workspace, data: differentBytes) }
        let differentOperation = try changed(command) { body in body["sessionId"] = UUID().uuidString; body["mutation"] = ["deviceId": command.mutation.deviceId.uuidString, "operationId": UUID().uuidString] }
        await rejected(.conflict) { _ = try await self.create(differentOperation, actor, workspace) }
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Another explicit destination", actorID: actor.id, on: db) }
        let differentDestination = try changed(command) { $0["expectedWorkspaceKind"] = "company" }
        await rejected(.conflict) { _ = try await self.create(differentDestination, actor, company.requireID()) }
    }

    func testAbortRetainsSourceDoesNotReactivateAndUsesRevisionAndIdempotency() async throws {
        let (actor, workspace, command) = try await fixture(), scope = StagedLegacyImportService.scope(command, workspaceID: workspace)
        _ = try await create(command, actor, workspace)
        let stale = AbortStagedLegacyImportCommand(scope: scope, mutation: .init(operationId: UUID(), deviceId: scope.deviceId), expectedRevision: 9)
        await rejected(.conflict) { _ = try await StagedLegacyImportService.abort(stale, actor: actor, binding: self.binding, on: self.app.db) }
        let abort = AbortStagedLegacyImportCommand(scope: scope, mutation: .init(operationId: UUID(), deviceId: scope.deviceId), expectedRevision: 1)
        let stopped = try await StagedLegacyImportService.abort(abort, actor: actor, binding: binding, on: app.db)
        XCTAssertEqual(stopped.state, "aborted"); XCTAssertEqual(stopped.revision, 2)
        let replay = try await StagedLegacyImportService.abort(abort, actor: actor, binding: binding, on: app.db)
        XCTAssertEqual(try PlatformMutationService.encode(stopped), try PlatformMutationService.encode(replay))
        let retryCreate = try await create(command, actor, workspace); XCTAssertEqual(retryCreate.state, "aborted")
        await rejected(.gone) { _ = try await StagedLegacyImportService.loadVerifiedGraph(scope, actor: actor, binding: self.binding, on: self.app.db) }
        let records = try await count("staged_legacy_import_records", session: command.sessionId); XCTAssertEqual(records, 16)
        let actions = try await count("staged_legacy_import_actions", session: command.sessionId); XCTAssertEqual(actions, 2)
    }

    func testOtherAccountDeviceAPISourceAndAuthGenerationCannotReadOrResume() async throws {
        let (actor, workspace, command) = try await fixture(), scope = StagedLegacyImportService.scope(command, workspaceID: workspace)
        _ = try await create(command, actor, workspace)
        let (other, _, _) = try await fixture()
        await rejected(.notFound) { _ = try await StagedLegacyImportService.read(scope, actor: other, binding: self.binding, on: self.app.db) }
        for key in ["deviceId", "selectedProjectId", "exportSHA256", "sourceFingerprint"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as! [String: Any]
            object[key] = key.hasSuffix("Id") ? UUID().uuidString : String(repeating: "d", count: 64)
            let changed = try JSONDecoder().decode(StagedLegacyImportScope.self, from: JSONSerialization.data(withJSONObject: object))
            await rejected(.conflict) { _ = try await StagedLegacyImportService.read(changed, actor: actor, binding: self.binding, on: self.app.db) }
        }
        let anotherAPI = try ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55481")
        await rejected(.conflict) { _ = try await StagedLegacyImportService.read(scope, actor: actor, binding: anotherAPI, on: self.app.db) }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET auth_version = auth_version + 1 WHERE id = \(bind: actor.id)").run()
        await rejected(.unauthorized) { _ = try await self.create(command, actor, workspace) }
        let refreshed = StagedLegacyImportActor(id: actor.id, authVersion: actor.authVersion + 1)
        await rejected(.conflict) { _ = try await StagedLegacyImportService.read(scope, actor: refreshed, binding: self.binding, on: self.app.db) }
    }

    func testCompanyAdminCanStageButMemberRemovalAndRejoinInvalidatesOldPreparation() async throws {
        let (_, workspace, _) = try await fixture(company: true)
        let (actor, _, personalCommand) = try await fixture()
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO workspace_memberships (workspace_id,user_id,role,state,revision,created_at,updated_at) VALUES (\(bind: workspace),\(bind: actor.id),'member','active',1,now(),now())").run()
        let command = try changed(personalCommand) { $0["expectedWorkspaceKind"] = "company" }
        await rejected(.forbidden) { _ = try await self.create(command, actor, workspace) }
        try await sql.raw("UPDATE workspace_memberships SET role = 'admin', revision = revision + 1 WHERE workspace_id = \(bind: workspace) AND user_id = \(bind: actor.id)").run()
        _ = try await create(command, actor, workspace)
        try await sql.raw("UPDATE workspace_memberships SET state = 'removed', revision = revision + 1 WHERE workspace_id = \(bind: workspace) AND user_id = \(bind: actor.id)").run()
        await rejected(.notFound) { _ = try await self.create(command, actor, workspace) }
        try await sql.raw("UPDATE workspace_memberships SET state = 'active', revision = revision + 1 WHERE workspace_id = \(bind: workspace) AND user_id = \(bind: actor.id)").run()
        await rejected(.conflict) { _ = try await self.create(command, actor, workspace) }
    }

    func testImmutableSourceTablesRejectOverwriteOrDeletion() async throws {
        let (actor, workspace, command) = try await fixture(); _ = try await create(command, actor, workspace)
        for table in ["staged_legacy_import_sources", "staged_legacy_import_records", "staged_legacy_import_edges", "staged_legacy_import_files", "staged_legacy_import_file_uses", "staged_legacy_import_actions"] {
            await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("DELETE FROM \(unsafeRaw: table) WHERE session_id = \(bind: command.sessionId)").run() }
        }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE staged_legacy_import_sources SET descriptor = decode('e30=','base64') WHERE session_id = \(bind: command.sessionId)").run() }
        let graph = try await StagedLegacyImportService.loadVerifiedGraph(StagedLegacyImportService.scope(command, workspaceID: workspace), actor: actor, binding: binding, on: app.db)
        XCTAssertEqual(graph.decoded.bytes, try bytes)
    }

    func testDirectoryCapacityIsCountedFromCurrentManagedWorkspaceRows() async throws {
        let (actor, workspace, command) = try await fixture()
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("INSERT INTO trades (id,name,color_hex,owner_id,sort_order,workspace_id,platform_managed) SELECT gen_random_uuid(),'Capacity fixture','#FF0000',\(bind: actor.id),n,\(bind: workspace),true FROM generate_series(1,9866) n").run()
        do { _ = try await create(command, actor, workspace); XCTFail("Oversized whole graph must fail") }
        catch { XCTAssertEqual(error as? LegacyProjectImportError, .publicationLimit) }
        let rows = try await count("staged_legacy_import_sources", session: command.sessionId); XCTAssertEqual(rows, 0)
    }
    func testMissingOriginalIsRetainedAsMissingWithoutVerifiedMediaClaim() async throws {
        let (actor, workspace, original) = try await fixture()
        var source = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var photos = source["photos"] as! [[String: Any]], photo = photos[0], file = photo["original"] as! [String: Any]
        file["availability"] = "missing"; file.removeValue(forKey: "archivePath"); file.removeValue(forKey: "bytes"); file.removeValue(forKey: "sha256")
        photo["original"] = file; photos[0] = photo; source["photos"] = photos
        let descriptor = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        let command = try changed(original) { $0["exportSHA256"] = LegacyProjectImportDecoder.digest(descriptor); $0["exportByteCount"] = descriptor.count }
        let result = try await create(command, actor, workspace, data: descriptor)
        XCTAssertFalse(result.importExecutable); XCTAssertEqual(result.mediaVerification, "source_declarations_only")
        XCTAssertEqual(result.fileRoleCounts.values.reduce(0,+), 14)
        let rows = try await VerifiedIdentityService.sql(app.db).raw("SELECT source_json FROM staged_legacy_import_file_uses WHERE session_id = \(bind: command.sessionId) AND role = 'photoOriginal'").all()
        let references = try rows.map { try JSONDecoder().decode(LegacyProjectImportSource.FileReference.self, from: Data($0.decode(column: "source_json", as: String.self).utf8)) }
        XCTAssertEqual(references.filter { $0.availability == .missing }.count, 1)
        XCTAssertGreaterThan(result.sourceIssueCounts.values.reduce(0,+), 0)
        let graph = try await StagedLegacyImportService.loadVerifiedGraph(StagedLegacyImportService.scope(command, workspaceID: workspace), actor: actor, binding: binding, on: app.db)
        XCTAssertEqual(graph.decoded.bytes, descriptor)
    }

    func testCancelledAfterSourceWritesRollsBackEveryNamespaceAndReceipt() async throws {
        try await cancellationAtWrite("staged_legacy_import_actions")
    }
    func testCancelledDuringRetryReceiptInsertionAlsoRollsBackSourceAndAction() async throws {
        try await cancellationAtWrite("mutation_receipts")
    }
    private func cancellationAtWrite(_ table: String) async throws {
        let (actor, workspace, command) = try await fixture()
        let sql = try VerifiedIdentityService.sql(app.db)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let function = "synthetic_stage_cancel_" + suffix, trigger = "synthetic_stage_pause_" + suffix
        let condition = table == "mutation_receipts" ? "NEW.actor_id = '\(actor.id)'::uuid AND NEW.operation_id = '\(command.mutation.operationId)'::uuid" : "NEW.session_id = '\(command.sessionId)'::uuid"
        // The session ID/name are generated fixture UUIDs, never source/customer text.
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: function)() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF \(unsafeRaw: condition) THEN PERFORM pg_sleep(1); END IF; RETURN NEW; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE INSERT ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: function)()").run()
        let task = Task { try await self.create(command, actor, workspace) }
        var observed = false
        for _ in 0..<150 {
            let waiting = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND wait_event = 'PgSleep' AND query LIKE \(bind: "INSERT INTO " + table + "%")").first()!.decode(column: "n", as: Int.self)
            if waiting > 0 { observed = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled source must not commit") }
        catch { XCTAssertTrue(error is CancellationError, "Cancellation must reach the transaction boundary") }
        try await sql.raw("DROP TRIGGER \(unsafeRaw: trigger) ON \(unsafeRaw: table)").run()
        try await sql.raw("DROP FUNCTION \(unsafeRaw: function)()").run()
        XCTAssertTrue(observed, "Observed the real DB action after source writes and before commit")
        for table in ["staged_legacy_import_sources", "staged_legacy_import_records", "staged_legacy_import_edges", "staged_legacy_import_files", "staged_legacy_import_file_uses", "staged_legacy_import_actions"] {
            let n = try await count(table, session: command.sessionId); XCTAssertEqual(n, 0, table)
        }
        let sessionCount = try await sql.raw("SELECT count(*) AS n FROM staged_legacy_imports WHERE id = \(bind: command.sessionId)").first()!.decode(column: "n", as: Int.self)
        let receipts = try await sql.raw("SELECT count(*) AS n FROM mutation_receipts WHERE actor_id = \(bind: actor.id) AND operation_id = \(bind: command.mutation.operationId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(sessionCount, 0); XCTAssertEqual(receipts, 0)
        // The exact original action can be resumed after cancellation.
        let retry = try await create(command, actor, workspace); XCTAssertEqual(retry.revision, 1)
    }

    func testWorkspaceAndAccountDepartureBlockReadAndStorageLease() async throws {
        let (actor, workspace, command) = try await fixture(company: true), scope = StagedLegacyImportService.scope(command, workspaceID: workspace)
        _ = try await create(command, actor, workspace)
        let value = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: app.db) { receipt, _ in receipt.sessionId }
        XCTAssertEqual(value, command.sessionId)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE teams SET lifecycle_state = 'archived', revision = revision + 1 WHERE id = \(bind: workspace)").run()
        await rejected(.notFound) { _ = try await StagedLegacyImportService.read(scope, actor: actor, binding: self.binding, on: self.app.db) }
        await rejected(.notFound) { _ = try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: self.binding, on: self.app.db) { _, _ in XCTFail("No lease after departure") } }
        try await sql.raw("UPDATE teams SET lifecycle_state = 'active', revision = revision + 1 WHERE id = \(bind: workspace)").run()
        await rejected(.conflict) { _ = try await self.create(command, actor, workspace) }
        try await sql.raw("UPDATE users SET lifecycle_state = 'deleted', auth_version = auth_version + 1 WHERE id = \(bind: actor.id)").run()
        await rejected(.unauthorized) { _ = try await StagedLegacyImportService.read(scope, actor: actor, binding: self.binding, on: self.app.db) }
    }

    func testBindingColumnsCannotBeRewrittenAndLegacyProjectIsNeverAdopted() async throws {
        let (actor, workspace, original) = try await fixture()
        let projectID = UUID()
        // Replace only complete UUID values/relationship entries. Filenames that
        // contain the UUID are independent source text with their own path hashes.
        func rebind(_ value: Any) -> Any {
            if let text = value as? String { return text == original.selectedProjectId.uuidString ? projectID.uuidString : text }
            if let values = value as? [Any] { return values.map(rebind) }
            if let fields = value as? [String: Any] { return fields.mapValues(rebind) }
            return value
        }
        let descriptor = try JSONSerialization.data(withJSONObject: rebind(JSONSerialization.jsonObject(with: bytes)), options: [.sortedKeys])
        let command = try changed(original) {
            $0["selectedProjectId"] = projectID.uuidString; $0["exportSHA256"] = LegacyProjectImportDecoder.digest(descriptor); $0["exportByteCount"] = descriptor.count
        }
        let legacy = Project(id: command.selectedProjectId, name: "Existing unrelated local-era row", reference: "KEEP", ownerId: actor.id)
        // Scope-free legacy row with the same UUID: preparation preserves evidence,
        // but does not claim that this is a canonical ID reservation or collision pass.
        try await legacy.save(on: app.db)
        _ = try await create(command, actor, workspace, data: descriptor)
        let stored = try await Project.find(command.selectedProjectId, on: app.db)
        XCTAssertNil(stored?.workspaceId); XCTAssertFalse(stored!.platformManaged); XCTAssertEqual(stored?.reference, "KEEP")
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE staged_legacy_imports SET device_id = \(bind: UUID()) WHERE id = \(bind: command.sessionId)").run() }
        await rejected { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE staged_legacy_imports SET state = 'aborted', revision = 2, actor_id = \(bind: UUID()) WHERE id = \(bind: command.sessionId)").run() }
    }

}
