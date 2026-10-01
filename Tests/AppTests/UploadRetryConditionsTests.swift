@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Lane A, Dan's 503 directive (1 Oct 16:00Z), through the Contractor-link upload route.
///
/// Part 1 — fault injection: which faults produce exactly the observed answer (HTTP 503 with the envelope
/// "Snaglist is temporarily unavailable. Please try again shortly."), and what the staging failure record says for each.
/// Part 2 — the conditions any retry must meet, each proven: same identity; a landed write whose acknowledgement was
/// lost is detected and not repeated; no duplicate evidence; never past a deletion or fence; permission, expiry,
/// revocation and integrity failures never retried.
final class UploadRetryConditionsTests: XCTestCase {
    var app: Application!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    static let envelope = "Snaglist is temporarily unavailable. Please try again shortly."
    var store: InMemoryPrivateContentStore!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[LinkGrantTokenKey.self] = Data(repeating: 7, count: 32)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        let configuration = try InMemoryPrivateContentStore.syntheticConfiguration()
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration
        store = InMemoryPrivateContentStore(configuration: configuration)
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = store
    }
    override func tearDown() async throws { unsetenv(RuntimeDiagnostics.variable); if let app { try await app.asyncShutdown() } }

    // MARK: fixture (a Contractor link on one assigned, logged snag)

    struct Link { let owner: User; let project: PlatformProjectResponse; let snag: PlatformSnagResponse; let grantID: UUID; let token: String }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:], bytes: Data? = nil, cookie: String? = nil) async throws -> XCTHTTPResponse {
        let jwt: String? = try user.map { u in let id = try u.requireID(); return try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id)) }
        let payload = try bytes ?? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            req.headers.replaceOrAdd(name: "X-Snaglist-Contractor", value: "1")
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
            if method != .GET { req.headers.replaceOrAdd(name: .contentType, value: bytes == nil ? "application/json" : "image/png"); req.body = .init(data: payload) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func ok<T: Decodable>(_ response: XCTHTTPResponse, _ type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertEqual(response.status, .ok, response.body.string, file: file, line: line); return try response.content.decode(type)
    }
    private func link(pin: String? = nil) async throws -> Link {
        let owner = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("retry-\(UUID())@example.test", name: "Synthetic retry tester", on: db) }
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Retry Construction", actorID: owner.requireID(), on: db) }
        let project = try ok(try await call(.POST, "api/v2/projects", owner, body: ["mutation": meta(), "workspaceId": try workspace.requireID().uuidString, "project": ["id": UUID().uuidString, "name": "Plot 7", "reference": "RT7"]]), PlatformProjectResponse.self)
        let contractorID = UUID()
        _ = try await call(.POST, "api/v2/workspaces/\(project.workspaceId)/contractors", owner, body: ["mutation": meta(), "id": contractorID.uuidString, "expectedRevision": 0, "fields": ["companyName": "Synthetic Glazing"]])
        let draft = try ok(try await call(.POST, "api/v2/projects/\(project.project.id)/snags", owner, body: ["mutation": meta(), "id": UUID().uuidString, "fields": ["title": "Reseal window", "location": "Plot 7 · Kitchen"]]), PlatformSnagResponse.self)
        let logged = try ok(try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(draft.snag.id)/publish", owner, body: ["mutation": meta(), "expectedRevision": draft.revision]), PlatformSnagResponse.self)
        let snag = try ok(try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(logged.snag.id)/assignment", owner, body: ["mutation": meta(), "expectedRevision": logged.revision, "fields": ["contractorId": contractorID.uuidString]]), PlatformSnagResponse.self)
        let grant = try ok(try await call(.POST, "api/v2/projects/\(project.project.id)/links/prepare", owner, body: ["mutation": meta(), "id": UUID().uuidString, "mode": "completion", "snagIds": [snag.snag.id.uuidString], "assetIds": [String](), "contractorId": contractorID.uuidString].merging(pin.map { ["pin": $0] as [String: Any] } ?? [:]) { a, _ in a }), LinkGrantResponse.self)
        let activation = try ok(try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(grant.id)/activate", owner, body: ["mutation": meta(), "expectedRevision": grant.revision]), LinkActivationResponse.self)
        return Link(owner: owner, project: project, snag: snag, grantID: grant.id, token: String(try XCTUnwrap(activation.contractorPath).dropFirst(3)))
    }
    private func media(_ link: Link) -> String { "api/v2/contractor/\(link.token)/snags/\(link.snag.snag.id)/media" }
    private func allocate(_ link: Link, intent: UUID, bytes: Data = png, cookie: String? = nil) async throws -> UUID {
        let body: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": link.snag.revision, "purpose": "completion", "intentId": intent.uuidString,
                                   "sha256": PrivateImageProcessor.digest(bytes), "byteCount": bytes.count, "mimeType": "image/png"]
        return try ok(try await call(.POST, media(link), nil, body: body, cookie: cookie), ContractorGrantController.PhotoResult.self).id
    }
    private func put(_ link: Link, _ asset: UUID, bytes: Data = png, cookie: String? = nil) async throws -> XCTHTTPResponse { try await call(.PUT, media(link) + "/\(asset)/content", nil, bytes: bytes, cookie: cookie) }
    private func putsAfter(_ mark: Int) async -> Int { await store.recordedCalls().dropFirst(mark).filter { if case .put = $0 { return true } else { return false } }.count }
    /// Holds this workspace's lock (exclusive, as a deletion or a command would) on a connection of its own.
    private func holdWorkspace(_ workspace: UUID, seconds: Double, then work: (@Sendable (SQLDatabase) async throws -> Void)? = nil) -> Task<Void, Error> {
        let db = app.db
        return Task {
            try await db.transaction { tx in
                let sql = tx as! SQLDatabase
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "workspace:" + workspace.uuidString), 0))").run()
                if let work { try await work(sql) }
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
    private var sql: SQLDatabase { app.db as! SQLDatabase }
    private func originalKey(_ asset: UUID) async throws -> String? { try await sql.raw("SELECT original_key FROM media_assets WHERE id = \(bind: asset)").first()?.decode(column: "original_key", as: String?.self) }
    private func puts(to key: String) async -> Int { await store.recordedCalls().filter { if case .put(let k, _, _) = $0 { return k == key } else { return false } }.count }
    private func intents(_ key: String) async throws -> [String] {
        try await sql.raw("SELECT id::text || ':' || state AS line FROM object_write_intents WHERE object_key = \(bind: key) ORDER BY created_at").all().map { try $0.decode(column: "line", as: String.self) }
    }
    private func failureRecords(_ route: String = "content") async throws -> [(String, String, String, String)] {
        for _ in 0..<20 {
            let rows = try await sql.raw("SELECT identifier, cause, notes, phases FROM diagnostic_request_failures WHERE route LIKE \(bind: "%" + route + "%") ORDER BY occurred_at").all()
            if !rows.isEmpty { return try rows.map { (try $0.decode(column: "identifier", as: String.self), try $0.decode(column: "cause", as: String.self), try $0.decode(column: "notes", as: String.self), try $0.decode(column: "phases", as: String.self)) } }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return []
    }
    private func clearRecords() async throws { try await sql.raw("DELETE FROM diagnostic_request_failures").run() }

    // MARK: - Part 1: fault injection against the observed answer

    /// Each fault through the real route, with the staging record on. "Observed" = HTTP 503 + the generic envelope.
    func testWhichFaultsProduceTheObservedAnswerAndWhatTheRecordSays() async throws {
        setenv(RuntimeDiagnostics.variable, "enabled", 1)
        let link = try await link()
        struct Row { let fault: String; let status: UInt; let reason: String; let identifier: String; let notes: String; let phases: String }
        var table: [Row] = []
        func run(_ fault: String, arrange: () async throws -> Void) async throws -> Row {
            try await clearRecords()
            let asset = try await allocate(link, intent: UUID())
            try await arrange()
            let response = try await put(link, asset)
            let body = (try? JSONSerialization.jsonObject(with: Data(response.body.string.utf8))) as? [String: Any]
            let record = try await failureRecords().first
            let row = Row(fault: fault, status: response.status.code, reason: body?["reason"] as? String ?? "", identifier: body?["identifier"] as? String ?? "",
                          notes: record?.2 ?? "", phases: record?.3 ?? "")
            table.append(row); return row
        }
        // The R2 PUT fails in transport once (any fast failure: reset, refused, TLS; a real R2 timeout is 30 s): WP1's one retry carries it.
        let once = try await run("R2 PUT transport failure x1") { await self.store.failNextPut() }
        XCTAssertEqual(once.status, 200)
        XCTAssertTrue(once.notes.contains("media_write.retry_after_not_landed"), "a recovered retry is still recorded: " + once.notes)
        // Twice in a row (= one failure before WP1): the observed answer, recorded as row 14a.
        let twice = try await run("R2 PUT transport failure x2 (pre-WP1: x1)") { await self.store.failNextPut(); await self.store.failNextPut() }
        XCTAssertEqual([twice.status], [503]); XCTAssertEqual(twice.reason, Self.envelope); XCTAssertEqual(twice.identifier, "media_unavailable")
        XCTAssertTrue(twice.notes.contains("media_write.retry_after_not_landed") && twice.notes.contains("media_write.unavailable(not_landed)"), twice.notes)
        XCTAssertTrue(twice.phases.contains("put_original:"), twice.phases)
        // The PUT landed but its acknowledgement was lost: detected by the readback, answered 200, never a 503.
        let lost = try await run("R2 PUT landed, response lost") { await self.store.dropNextPutResponse() }
        XCTAssertEqual(lost.status, 200)
        // The PUT and the readback both fail: the observed answer, recorded as row 14b; not retried.
        let unreachable = try await run("R2 PUT + readback failure") { await self.store.failNextPut(); await self.store.failNextRead() }
        XCTAssertEqual(unreachable.status, 503); XCTAssertEqual(unreachable.reason, Self.envelope); XCTAssertEqual(unreachable.identifier, "media_unavailable")
        XCTAssertTrue(unreachable.notes.contains("media_write.unavailable(storage_unreachable)"), unreachable.notes)
        XCTAssertFalse(unreachable.notes.contains("retry"), unreachable.notes)
        // The rendition's PUT fails twice: the same answer, but the record names the rendition phase.
        let rendition = try await run("R2 rendition PUT failure x2") { await self.store.passNextPut(); await self.store.failNextPut(); await self.store.failNextPut() }
        XCTAssertEqual(rendition.status, 503); XCTAssertEqual(rendition.reason, Self.envelope); XCTAssertEqual(rendition.identifier, "media_unavailable")
        XCTAssertTrue(rendition.phases.contains("put_rendition:"), rendition.phases)
        // A cancelled write (row 15): the observed answer, recorded as cancelled.
        let cancelled = try await run("write cancelled") { await self.store.failNextPut(with: CancellationError()) }
        XCTAssertEqual(cancelled.status, 503); XCTAssertEqual(cancelled.reason, Self.envelope); XCTAssertEqual(cancelled.identifier, "media_unavailable")
        XCTAssertTrue(cancelled.notes.contains("media_write.cancelled_put"), cancelled.notes)
        for row in table { print("FAULT-MATRIX \(row.fault) | \(row.status) | \(row.reason == Self.envelope ? "observed envelope" : row.reason) | \(row.identifier) | notes=\(row.notes) | phases=\(row.phases)") }
    }

    /// A database connection-pool timeout (AsyncKit, after `connectionPoolTimeout`, 10 s by default) and an unclassified
    /// error are answered **500** `request_failed` by the same middleware — not the observed 503 — and recorded.
    func testAPoolTimeoutIsA500NotTheObserved503() async throws {
        setenv(RuntimeDiagnostics.variable, "enabled", 1)
        app.grouped("api", "v2", "contractor", "fault-injection").get("pool") { _ -> String in throw ConnectionPoolTimeoutError.connectionRequestTimeout }
        let response = try await call(.GET, "api/v2/contractor/fault-injection/pool", nil)
        XCTAssertEqual(response.status, .internalServerError, response.body.string)
        XCTAssertTrue(response.body.string.contains("request_failed"), response.body.string)
        let record = try await failureRecords("fault-injection").first
        XCTAssertEqual(record?.0, "request_failed"); XCTAssertEqual(record?.1, "AsyncKit.ConnectionPoolTimeoutError")
        print("FAULT-MATRIX DB pool timeout | 500 | observed envelope text, status 500 | request_failed | cause=\(record?.1 ?? "")")
    }

    /// Off by default: without RUNTIME_DIAGNOSTICS nothing is recorded (production refuses the variable).
    func testTheFailureRecordIsStagingOnly() async throws {
        unsetenv(RuntimeDiagnostics.variable)
        let link = try await link()
        try await clearRecords()
        let asset = try await allocate(link, intent: UUID())
        await store.failNextPut(); await store.failNextPut()
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .serviceUnavailable)
        try await Task.sleep(nanoseconds: 300_000_000)
        let n = try await sql.raw("SELECT count(*) AS n FROM diagnostic_request_failures").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(n, 0)
    }

    // MARK: - Part 2: the conditions any retry must meet

    /// (1) Same identity: the retry is the same asset, the same key, the same bytes and the same intent (one row,
    /// one ticket), settled once.
    func testTheRetryReusesTheSameUploadIdentity() async throws {
        let link = try await link()
        let asset = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let keyFound = try await originalKey(asset); let key = try XCTUnwrap(keyFound)
        let count = await puts(to: key)
        XCTAssertEqual(count, 2, "the first attempt and the one retry, to the same key")
        let calls = await store.recordedCalls().filter { if case .put(let k, _, _) = $0 { return k == key } else { return false } }
        XCTAssertTrue(calls.allSatisfy { $0 == calls[0] }, "same key, same byte count, same type: \(calls)")
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1, "one intent, one ticket for the original: \(rows)"); XCTAssertTrue(rows[0].hasSuffix(":settled"))
    }

    /// (2) A write that landed but lost its acknowledgement is detected by the readback and settled — no second PUT.
    func testALandedWriteWithALostAcknowledgementIsNotRepeated() async throws {
        let link = try await link()
        let asset = try await allocate(link, intent: UUID())
        await store.dropNextPutResponse()
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let keyFound = try await originalKey(asset); let key = try XCTUnwrap(keyFound)
        let count = await puts(to: key)
        XCTAssertEqual(count, 1, "readback found our bytes: no retry")
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].hasSuffix(":settled"))
    }

    /// (3) No duplicate evidence: a retried upload, a repeated PUT of the same photo and a repeated submission still
    /// attach the photo exactly once.
    func testRetriesNeverDuplicateEvidence() async throws {
        let link = try await link()
        let intent = UUID()
        let asset = try await allocate(link, intent: intent)
        await store.failNextPut()
        let firstPut = try await put(link, asset), secondPut = try await put(link, asset)
        XCTAssertEqual(firstPut.status, .ok, firstPut.body.string)
        XCTAssertEqual(secondPut.status, .ok, "the same command again is answered from what is stored: " + secondPut.body.string)
        let body: [String: Any] = ["mutation": meta(), "expectedRevision": link.snag.revision, "expectedWorkflowRevision": link.snag.workflowRevision,
                                   "attemptId": intent.uuidString, "evidenceIds": [asset.uuidString], "notes": "Resealed"]
        let path = "api/v2/contractor/\(link.token)/snags/\(link.snag.snag.id)/workflow/submit"
        let submitted = try await call(.POST, path, nil, body: body), replayed = try await call(.POST, path, nil, body: body)
        XCTAssertEqual(submitted.status, .ok, submitted.body.string)
        XCTAssertEqual(replayed.status, .ok, "replayed, not applied again: " + replayed.body.string)
        let evidence = try await sql.raw("SELECT count(*) AS n FROM completion_evidence WHERE asset_id = \(bind: asset)").first()!.decode(column: "n", as: Int.self)
        let assets = try await sql.raw("SELECT count(*) AS n FROM media_assets WHERE snag_id = \(bind: link.snag.snag.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual([evidence, assets], [1, 1])
    }

    /// (4) Never past a deletion or a fence. A deletion's fence written between the readback and the retry: the retry's
    /// create-only PUT is refused, the readback finds the fence, the answer is 410 `media_erased` and the fence still
    /// holds the address. The upload's row deleted in that window: the re-check refuses and no second PUT is made.
    func testTheRetryNeverRacesADeletionOrAFence() async throws {
        let link = try await link()
        let fenced = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let store = self.store!
        await store.afterNextRead {
            guard case .read(let key, _)? = await store.recordedCalls().last else { return }
            try await store.fenceNow(key: key)
        }
        let first = try await put(link, fenced)
        XCTAssertEqual(first.status, .gone, first.body.string); XCTAssertTrue(first.body.string.contains("media_erased"), first.body.string)
        let fencedKeyFound = try await originalKey(fenced); let fencedKey = try XCTUnwrap(fencedKeyFound)
        let stillFenced = await store.isFenced(fencedKey)
        XCTAssertTrue(stillFenced, "nothing resurrected")

        let deleted = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let db = app.db
        await store.afterNextRead { try await (db as! SQLDatabase).raw("DELETE FROM media_assets WHERE id = \(bind: deleted)").run() }
        let mark = await store.recordedCalls().count
        let second = try await put(link, deleted)
        XCTAssertTrue([.notFound, .gone].contains(second.status), second.body.string)
        let putsAfter = await store.recordedCalls().dropFirst(mark).filter { if case .put = $0 { return true } else { return false } }.count
        XCTAssertEqual(putsAfter, 1, "the first attempt only; the re-check refused the retry")
    }

    // MARK: - Fable RF-1 additions (FABLE-DESIGN-A-AMENDMENT §7 condition 1)

    /// (a) The rendition's address gets the same one retry, re-checked through `confirmation`: original created,
    /// rendition PUT lost in transport and absent → one retry → settled; one intent for the rendition key.
    func testTheRenditionPathRetriesOnceAndSettles() async throws {
        let link = try await link()
        let asset = try await allocate(link, intent: UUID())
        await store.passNextPut(); await store.failNextPut()
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let rendition = try await sql.raw("SELECT rendition_key FROM media_assets WHERE id = \(bind: asset)").first()?.decode(column: "rendition_key", as: String?.self)
        let key = try XCTUnwrap(rendition)
        let count = await puts(to: key)
        XCTAssertEqual(count, 2)
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1, "\(rows)"); XCTAssertTrue(rows[0].hasSuffix(":settled"))
    }

    /// (b) The PIN session expires in the window before the retry: 403 `pin_required`, one PUT, no retry recorded.
    func testAPINSessionExpiringBeforeTheRetryStopsIt() async throws {
        setenv(RuntimeDiagnostics.variable, "enabled", 1)
        let link = try await link(pin: "4826")
        let verified = try await call(.POST, "api/v2/contractor/\(link.token)/verify-pin", nil, body: ["pin": "4826"])
        XCTAssertEqual(verified.status, .ok, verified.body.string)
        let cookie = String(try XCTUnwrap(verified.headers[.setCookie].first).split(separator: ";")[0])
        let asset = try await allocate(link, intent: UUID(), cookie: cookie)
        try await clearRecords()
        await store.failNextPut()
        let db = app.db, grant = link.grantID
        await store.afterNextRead { try await (db as! SQLDatabase).raw("UPDATE link_sessions SET expires_at = now() - interval '1 second' WHERE grant_id = \(bind: grant)").run() }
        let mark = await store.recordedCalls().count
        let response = try await put(link, asset, cookie: cookie)
        XCTAssertEqual(response.status, .forbidden, response.body.string); XCTAssertTrue(response.body.string.contains("pin_required"), response.body.string)
        let count = await putsAfter(mark)
        XCTAssertEqual(count, 1)
        let records = try await failureRecords()
        XCTAssertTrue(records.allSatisfy { !$0.2.contains("retry_after") }, "no retry was made: \(records)")
        let keyFound = try await originalKey(asset); let key = try XCTUnwrap(keyFound)
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].hasSuffix(":uncertain"), "re-check refusal leaves the intent uncertain: \(rows)")
    }

    /// (c) A cancelled first PUT: one PUT, no retry, the intent `uncertain`.
    func testACancelledFirstPutIsNotRetried() async throws {
        setenv(RuntimeDiagnostics.variable, "enabled", 1)
        let link = try await link()
        let asset = try await allocate(link, intent: UUID())
        try await clearRecords()
        await store.failNextPut(with: CancellationError())
        let mark = await store.recordedCalls().count
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .serviceUnavailable, response.body.string)
        let count = await putsAfter(mark)
        XCTAssertEqual(count, 1)
        let notes = try await failureRecords().first?.2 ?? ""
        XCTAssertFalse(notes.contains("retry_after"), notes); XCTAssertTrue(notes.contains("cancelled_put"), notes)
        let keyFound = try await originalKey(asset); let key = try XCTUnwrap(keyFound)
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].hasSuffix(":uncertain"), "\(rows)")
    }

    /// (d) A deletion holds the workspace lock while the re-check runs: the re-check waits for it, finds the row gone and
    /// refuses — one PUT. And when the lock is held past the 15 s command bound: 503 `workspace_busy`, the intent
    /// `uncertain`, one PUT.
    func testTheRecheckWaitsForADeletionAndIsBoundedByTheLockTimeout() async throws {
        let link = try await link()
        let workspace = link.project.workspaceId
        // A deletion that commits after 1 s.
        let gone = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let box = TaskBox()
        await store.afterNextRead {
            box.task = self.holdWorkspace(workspace, seconds: 1) { sql in try await sql.raw("DELETE FROM media_assets WHERE id = \(bind: gone)").run() }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        var mark = await store.recordedCalls().count
        let refused = try await put(link, gone)
        try await box.task?.value
        XCTAssertTrue([.notFound, .gone].contains(refused.status), refused.body.string)
        var count = await putsAfter(mark)
        XCTAssertEqual(count, 1)
        // A holder that outlasts the 15 s command lock bound.
        let busy = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let longBox = TaskBox()
        await store.afterNextRead {
            longBox.task = self.holdWorkspace(workspace, seconds: 17)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        mark = await store.recordedCalls().count
        let timedOut = try await put(link, busy)
        try await longBox.task?.value
        XCTAssertEqual(timedOut.status, .serviceUnavailable, timedOut.body.string); XCTAssertTrue(timedOut.body.string.contains("workspace_busy"), timedOut.body.string)
        count = await putsAfter(mark)
        XCTAssertEqual(count, 1)
        let keyFound = try await originalKey(busy); let key = try XCTUnwrap(keyFound)
        let rows = try await intents(key)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].hasSuffix(":uncertain"), "\(rows)")
    }

    /// Fable §8.3: a rendition that settled while readiness never committed is known only to the intent table; retiring
    /// the upload queues both addresses and the hourly pass fences both.
    func testARenditionKnownOnlyToItsIntentIsQueuedAndFenced() async throws {
        let link = try await link()
        let asset = try await allocate(link, intent: UUID())
        await store.passNextPut(); await store.loseResponseOfQueuedPut()
        let db = app.db
        // The rendition landed; its readback verifies it; then, before readiness, the upload expires.
        await store.afterNextRead { try await (db as! SQLDatabase).raw("UPDATE media_assets SET expires_at = now() - interval '1 second' WHERE id = \(bind: asset)").run() }
        let response = try await put(link, asset)
        XCTAssertEqual(response.status, .gone, "readiness refused: " + response.body.string)
        let row = try await sql.raw("SELECT original_key, rendition_key, state FROM media_assets WHERE id = \(bind: asset)").first()!
        XCTAssertNil(try row.decode(column: "rendition_key", as: String?.self), "the rendition's key is not on the row")
        let renditionKeys = try await sql.raw("SELECT object_key FROM object_write_intents WHERE source_id = \(bind: asset) AND object_key NOT LIKE '%/original' AND state = 'settled'").all().map { try $0.decode(column: "object_key", as: String.self) }
        XCTAssertEqual(renditionKeys.count, 1)
        let retired = try await call(.DELETE, media(link) + "/\(asset)", nil)
        XCTAssertEqual(retired.status, .ok, retired.body.string)
        let queued = try await sql.raw("SELECT role || ':' || state AS line FROM upload_retirements WHERE asset_id = \(bind: asset) ORDER BY role").all().map { try $0.decode(column: "line", as: String.self) }
        XCTAssertEqual(queued, ["original:pending", "rendition:pending"])
        let counts = try await RetentionMaintenanceService.run(on: app.db, fenceStore: store)
        XCTAssertEqual(counts.failed, [])
        let originalAddress = try row.decode(column: "original_key", as: String.self)
        let fencedOriginal = await store.isFenced(originalAddress)
        let fencedRendition = await store.isFenced(renditionKeys[0])
        XCTAssertTrue(fencedOriginal); XCTAssertTrue(fencedRendition)
    }

    /// (5) Permission, expiry, revocation and integrity failures are never retried. Revocation or expiry in the window
    /// before the retry stops it (one PUT, answered 4xx); bytes that differ from the allocation are refused before any
    /// intent or PUT; a key holding somebody else's object is a terminal conflict after one PUT.
    func testPermissionExpiryRevocationAndIntegrityFailuresAreNeverRetried() async throws {
        let link = try await link()
        let db = app.db, store = self.store!
        // Expiry in the window.
        let expiring = try await allocate(link, intent: UUID())
        await store.failNextPut()
        await store.afterNextRead { try await (db as! SQLDatabase).raw("UPDATE media_assets SET expires_at = now() - interval '1 second' WHERE id = \(bind: expiring)").run() }
        var mark = await store.recordedCalls().count
        let expired = try await put(link, expiring)
        XCTAssertEqual(expired.status, .gone, expired.body.string)
        var count = await store.recordedCalls().dropFirst(mark).filter { if case .put = $0 { return true } else { return false } }.count
        XCTAssertEqual(count, 1, "expiry stops the retry")
        // Integrity: different bytes from the allocation — refused before any intent or PUT.
        let declared = try await allocate(link, intent: UUID())
        mark = await store.recordedCalls().count
        var other = Self.png; other.append(contentsOf: [0])
        let mismatch = try await put(link, declared, bytes: other)
        XCTAssertTrue([.unprocessableEntity, .badRequest].contains(mismatch.status), mismatch.body.string)
        count = await store.recordedCalls().dropFirst(mark).count
        XCTAssertEqual(count, 0, "an integrity failure reaches no storage call at all")
        // Somebody else's object at the address: one PUT, terminal 409.
        let taken = try await allocate(link, intent: UUID())
        await store.failNextPut(); await store.failNextPut()
        _ = try await put(link, taken)                       // binds the key, nothing lands (row 14a twice)
        let takenKeyFound = try await originalKey(taken); let takenKey = try XCTUnwrap(takenKeyFound)
        try await store.seedContent(key: takenKey, data: Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data("not this photo".utf8), contentType: "image/png")
        mark = await store.recordedCalls().count
        let conflict = try await put(link, taken)
        XCTAssertEqual(conflict.status, .conflict, conflict.body.string)
        count = await store.recordedCalls().dropFirst(mark).filter { if case .put = $0 { return true } else { return false } }.count
        XCTAssertEqual(count, 1)
        // Revocation in the window (last: it ends the link).
        let revoking = try await allocate(link, intent: UUID())
        await store.failNextPut()
        let owner = try link.owner.requireID(), workspace = link.project.workspaceId, grant = link.grantID
        await store.afterNextRead { try await db.transaction { tx in try await LinkGrantController.revoke(grant, workspaceID: workspace, actorID: owner, on: tx) } }
        mark = await store.recordedCalls().count
        let revoked = try await put(link, revoking)
        XCTAssertTrue([.gone, .notFound, .forbidden].contains(revoked.status), revoked.body.string)
        count = await store.recordedCalls().dropFirst(mark).filter { if case .put = $0 { return true } else { return false } }.count
        XCTAssertEqual(count, 1, "revocation stops the retry")
    }
}

/// Carries a task started inside a store hook out to the test.
private final class TaskBox: @unchecked Sendable { var task: Task<Void, Error>? }
