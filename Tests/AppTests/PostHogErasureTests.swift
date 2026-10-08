@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class PostHogErasureContractTests: XCTestCase {
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testEmptyPartialOrFalseQueueAcknowledgementsCannotComplete() throws {
        for object: [String: Any] in [[:], ["persons_found": 0, "persons_deleted": 0,
            "persons_queued_for_deletion": 0, "events_queued_for_deletion": false, "deletion_errors": []],
            ["persons_found": 1, "persons_deleted": 0, "persons_queued_for_deletion": 1,
             "events_queued_for_deletion": 1, "deletion_errors": []],
            ["persons_found": 1, "persons_deleted": 0, "persons_queued_for_deletion": 1,
             "events_queued_for_deletion": true, "deletion_errors": [["step": "synthetic"]]]] {
            XCTAssertFalse(PostHogErasureService.queuedOnePerson(try data(object)))
        }
        XCTAssertTrue(PostHogErasureService.queuedOnePerson(try data(["persons_found": 1,
            "persons_deleted": 0, "persons_queued_for_deletion": 1,
            "events_queued_for_deletion": true, "deletion_errors": []])))
    }

    func testPersonlessAndAliasExpandedSubjectsAreNotDeletionAuthority() throws {
        let subject = UUID().uuidString.lowercased(), person = UUID()
        XCTAssertNil(PostHogErasureService.matchedPerson(try data(["results": []]), distinctID: subject))
        XCTAssertNil(PostHogErasureService.matchedPerson(try data(["results": [["uuid": person.uuidString,
            "distinct_ids": [subject, "another-person"]]]]), distinctID: subject))
        XCTAssertNil(PostHogErasureService.matchedPerson(try data(["results": [["uuid": person.uuidString,
            "distinct_ids": [subject]]], "next": "https://other.example.test"]), distinctID: subject))
        XCTAssertEqual(PostHogErasureService.matchedPerson(try data(["results": [["uuid": person.uuidString,
            "distinct_ids": [subject]]], "next": NSNull()]), distinctID: subject), person)
    }

    func testDeletionStatusRequiresMatchingFreshVerifiedReceipt() throws {
        let now = Date(), person = UUID()
        func status(_ changes: [String: Any]) throws -> PostHogErasureService.DeletionStatus {
            let row: [String: Any] = ["person_uuid": person.uuidString,
                "created_at": ISO8601DateFormatter().string(from: now),
                "status": "completed", "delete_verified_at": ISO8601DateFormatter().string(from: now)]
            return PostHogErasureService.deletionStatus(try data(["results": [row.merging(changes) { _, new in new }]]),
                person: person, requestedAt: now, now: now)
        }
        XCTAssertEqual(PostHogErasureService.deletionStatus(try data(["results": []]),
            person: person, requestedAt: now, now: now), .pending)
        XCTAssertEqual(try status(["person_uuid": UUID().uuidString]), .invalid)
        XCTAssertEqual(try status(["created_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))]), .invalid)
        XCTAssertEqual(try status(["delete_verified_at": NSNull()]), .invalid)
        XCTAssertEqual(try status(["status": "pending", "delete_verified_at": NSNull()]), .pending)
        if case .verified = try status([:]) {} else { XCTFail("Expected explicit verified receipt") }
    }

    func testConfigCannotRedirectProjectOrIncludeMalformedCredential() {
        XCTAssertFalse(PostHogErasureService.Configuration(projectID: "1/../../other", apiKey: String(repeating: "x", count: 25)).valid)
        XCTAssertFalse(PostHogErasureService.Configuration(projectID: "012", apiKey: String(repeating: "x", count: 25)).valid)
        XCTAssertFalse(PostHogErasureService.Configuration(projectID: "123", apiKey: "synthetic\nheader-injection").valid)
        XCTAssertFalse(PostHogErasureService.liveReceiverAccepted)
        XCTAssertEqual(PostHogErasureService.host, "https://eu.posthog.com")
    }

    func testDirectTransportRefusesRedirectWithoutLeakingAuthorizationOrBody() async throws {
        let hits = PostHogErasureRecorder([])
        let sink = try await Application.make(.testing)
        sink.http.server.configuration.hostname = "127.0.0.1"; sink.http.server.configuration.port = 0
        sink.on(.POST, "sink") { _ async -> HTTPStatus in await hits.hit(); return .ok }
        try await sink.startup()
        let port = try XCTUnwrap(sink.http.server.shared.localAddress?.port)
        let redirector = try await Application.make(.testing)
        redirector.http.server.configuration.hostname = "127.0.0.1"; redirector.http.server.configuration.port = 0
        redirector.on(.POST, "erase") { _ -> Response in
            var headers = HTTPHeaders(); headers.replaceOrAdd(name: .location, value: "http://127.0.0.1:\(port)/sink")
            return Response(status: .temporaryRedirect, headers: headers)
        }
        try await redirector.startup()
        let redirectPort = try XCTUnwrap(redirector.http.server.shared.localAddress?.port)
        let client = PostHogErasureHTTPClient(eventLoopGroup: redirector.eventLoopGroup, logger: redirector.logger)
        do {
            var headers = HTTPHeaders(); headers.bearerAuthorization = .init(token: "synthetic-only-credential")
            let reply = try await client.request(.POST, URI(string: "http://127.0.0.1:\(redirectPort)/erase"),
                headers: headers, body: Data("synthetic-only-body".utf8))
            XCTAssertEqual(reply.status, 307)
            let count = await hits.hitCount(); XCTAssertEqual(count, 0)
            try await client.close(); try await redirector.asyncShutdown(); try await sink.asyncShutdown()
        } catch {
            try? await client.close(); try? await redirector.asyncShutdown(); try? await sink.asyncShutdown(); throw error
        }
    }
}

final class PostHogErasureTests: XCTestCase {
    private var app: Application!
    private var account = UUID(), subject = UUID(), opaque = UUID(), job = UUID(), person = UUID()
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let config = PostHogErasureService.Configuration(projectID: "123456", apiKey: "synthetic-erasure-key-only")

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        account = UUID(); subject = UUID(); opaque = UUID(); job = UUID(); person = UUID()
        let user = User(appleUserId: nil, email: "erasure-\(account)@example.test", name: nil, authProvider: .magicLink)
        user.id = account; try await user.save(on: app.db)
        try await sql.raw("""
            INSERT INTO measurement_subjects(id,account_id,purpose,opaque_subject,state,created_at,revoked_at)
            VALUES (\(bind:subject),\(bind:account),'productAnalytics',\(bind:opaque),'revoked',NOW(),NOW())
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_erasure_jobs(id,account_id,subject_id,destination,state,available_at,created_at)
            VALUES (\(bind:job),\(bind:account),\(bind:subject),'posthog','pending',NOW(),NOW())
            """).run()
        app.storage[PostHogErasureService.ConfigurationKey.self] = config
    }
    override func tearDown() async throws {
        if let app {
            try? await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_id=\(bind:account)").run()
            try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:account)").run()
            try? await User.query(on: app.db).filter(\.$id == account).delete()
            try await app.asyncShutdown()
        }
        app = nil
    }
    private func reply(_ object: [String: Any], status: Int = 200) throws -> PostHogErasureService.Reply {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: object))
    }
    private func profile() throws -> PostHogErasureService.Reply {
        try reply(["results": [["uuid": person.uuidString, "distinct_ids": [opaque.uuidString.lowercased()]]], "next": NSNull()])
    }
    private func queued() throws -> PostHogErasureService.Reply {
        try reply(["persons_found": 1, "persons_deleted": 0, "persons_queued_for_deletion": 1,
            "events_queued_for_deletion": true, "deletion_errors": []], status: 202)
    }
    private func status(complete: Bool) throws -> PostHogErasureService.Reply {
        let date = ISO8601DateFormatter().string(from: Date())
        return try reply(["results": [["person_uuid": person.uuidString, "created_at": date,
            "status": complete ? "completed" : "pending", "delete_verified_at": complete ? date as Any : NSNull()]],
            "next": NSNull()])
    }
    private func runDue() async throws -> MeasurementErasureService.Counts {
        try await sql.raw("UPDATE measurement_erasure_jobs SET available_at=NOW() WHERE id=\(bind:job)").run()
        return await MeasurementErasureService.run(app: app, limit: 1, on: app.db)
    }
    private func jobState() async throws -> String {
        try await sql.raw("SELECT state FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!.decode(column: "state", as: String.self)
    }

    func testProfilelessExposureRequiresManualHandlingAndIsNeverErasedBy202() async throws {
        let recorder = PostHogErasureRecorder([try reply(["results": [], "next": NSNull()])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        let counts = try await runDue(); XCTAssertEqual(counts.manualRequired, 1); XCTAssertEqual(counts.completed, 0)
        let calls = await recorder.calls(); XCTAssertEqual(calls.map(\.method), ["GET"])
        let state = try await jobState(); XCTAssertEqual(state, "manual_required")
    }

    func testAcceptedDeleteNeedsVerifiedEventsAndAbsentProfileAcrossRestart() async throws {
        let first = PostHogErasureRecorder([try profile(), try queued()])
        app.storage[PostHogErasureService.TransportKey.self] = first.transport
        var counts = try await runDue(); XCTAssertEqual(counts.pending, 1)
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        let stored = try await sql.raw("SELECT phase,person_uuid FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()!
        XCTAssertEqual(try stored.decode(column: "phase", as: String.self), "polling")
        XCTAssertEqual(try stored.decode(column: "person_uuid", as: UUID.self), person)
        try await app.asyncShutdown()
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PostHogErasureService.ConfigurationKey.self] = config
        let resumed = PostHogErasureRecorder([try status(complete: false), try status(complete: true),
            try reply(["results": [], "next": NSNull()])])
        app.storage[PostHogErasureService.TransportKey.self] = resumed.transport
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1)
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        counts = try await runDue(); XCTAssertEqual(counts.completed, 1)
        let state = try await jobState(); XCTAssertEqual(state, "completed")
        let firstCalls = await first.calls(), resumedCalls = await resumed.calls()
        XCTAssertEqual(firstCalls.map(\.method), ["GET", "POST"])
        XCTAssertEqual(resumedCalls.map(\.method), ["GET", "GET", "GET"])
        XCTAssertTrue((firstCalls + resumedCalls).allSatisfy { $0.uri.hasPrefix("https://eu.posthog.com/api/projects/123456/persons/") })
        let body = try XCTUnwrap(firstCalls.last?.body).data(using: .utf8)!
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["distinct_ids"] as? [String], [opaque.uuidString.lowercased()])
        XCTAssertEqual(payload["delete_events"] as? Bool, true)
        XCTAssertEqual(payload["keep_person"] as? Bool, false)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("example.test"))
    }

    func testAmbiguousPostAndExpiredLeaseResumePollingWithoutSecondDelete() async throws {
        let recorder = PostHogErasureRecorder([try profile(), nil, try status(complete: true),
            try reply(["results": []])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); let ambiguous = try await runDue()
        XCTAssertEqual(ambiguous.completed, 0); XCTAssertEqual(ambiguous.pending, 1)
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='leased',lease_token=\(bind:UUID()),lease_expires_at=NOW()-INTERVAL '1 minute'
            WHERE id=\(bind:job)
            """).run()
        let recovered = try await runDue(); XCTAssertEqual(recovered.pending, 1)
        let completed = try await runDue(); XCTAssertEqual(completed.completed, 1)
        let calls = await recorder.calls(); XCTAssertEqual(calls.filter { $0.method == "POST" }.count, 1)
    }

    func testEmptyStatusAndMissingVerificationNeverComplete() async throws {
        let recorder = PostHogErasureRecorder([try profile(), try queued(), try reply(["results": []]),
            try reply(["results": [["person_uuid": person.uuidString,
                "created_at": ISO8601DateFormatter().string(from: Date()), "status": "completed", "delete_verified_at": NSNull()]]])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); _ = try await runDue()
        let empty = try await runDue(); XCTAssertEqual(empty.pending, 1); XCTAssertEqual(empty.completed, 0)
        let malformed = try await runDue(); XCTAssertEqual(malformed.manualRequired, 1); XCTAssertEqual(malformed.completed, 0)
    }

    func testProjectChangeCannotRedirectPersistedDeletionReceipt() async throws {
        let recorder = PostHogErasureRecorder([try profile()])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue()
        app.storage[PostHogErasureService.ConfigurationKey.self] = .init(projectID: "999", apiKey: config.apiKey)
        let counts = try await runDue(); XCTAssertEqual(counts.manualRequired, 1)
        let calls = await recorder.calls(); XCTAssertEqual(calls.count, 1)
    }

    func testMissingStatusAfterSevenDaysEscalatesWithoutLosingReceiptOrRepeatingDelete() async throws {
        let recorder = PostHogErasureRecorder([try profile(), nil, try reply(["results": []])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); _ = try await runDue()
        try await sql.raw("""
            UPDATE measurement_posthog_erasure_receipts SET requested_at=NOW()-INTERVAL '8 days'
            WHERE job_id=\(bind:job)
            """).run()
        let counts = try await runDue()
        XCTAssertEqual(counts.manualRequired, 1); XCTAssertEqual(counts.completed, 0)
        let receipt = try await sql.raw("SELECT phase,person_uuid FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        XCTAssertEqual(try receipt?.decode(column: "phase", as: String.self), "submitting")
        XCTAssertEqual(try receipt?.decode(column: "person_uuid", as: UUID.self), person)
        let calls = await recorder.calls(); XCTAssertEqual(calls.filter { $0.method == "POST" }.count, 1)
    }

    func testAuthenticationFailureCannotCompleteOrEraseReceipt() async throws {
        let recorder = PostHogErasureRecorder([try profile(), try reply([:], status: 403)])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); let counts = try await runDue()
        XCTAssertEqual(counts.manualRequired, 1); XCTAssertEqual(counts.completed, 0)
        let receipt = try await sql.raw("SELECT phase FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        XCTAssertEqual(try receipt?.decode(column: "phase", as: String.self), "submitting")
        let later = try await runDue()
        XCTAssertEqual(later.completed, 0); XCTAssertEqual(later.pending, 0); XCTAssertEqual(later.manualRequired, 0)
        let calls = await recorder.calls(); XCTAssertEqual(calls.count, 2, "manual_required cannot automatically re-enter the worker")
    }
}

private actor PostHogErasureRecorder {
    struct Call: Sendable { let method, uri: String; let body: String? }
    private var replies: [PostHogErasureService.Reply?]
    private var recorded: [Call] = []
    private var hits = 0
    init(_ replies: [PostHogErasureService.Reply?]) { self.replies = replies }
    func hit() { hits += 1 }
    func hitCount() -> Int { hits }
    func calls() -> [Call] { recorded }
    func record(_ method: HTTPMethod, _ uri: URI, _ body: Data?) throws -> PostHogErasureService.Reply {
        recorded.append(.init(method: method.string, uri: uri.string, body: body.map { String(decoding: $0, as: UTF8.self) }))
        guard !replies.isEmpty, let reply = replies.removeFirst() else { throw Abort(.gatewayTimeout, reason: "Synthetic timeout") }
        return reply
    }
    nonisolated var transport: PostHogErasureService.Transport {
        { method, uri, _, body in try await self.record(method, uri, body) }
    }
}
