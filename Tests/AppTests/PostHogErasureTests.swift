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
        // A row created before this round's request is the earlier request's receipt.
        let earlier = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        if case .stale(let created, let verified) = try status(["created_at": earlier]) {
            XCTAssertLessThan(created, now.addingTimeInterval(-5))
            XCTAssertNotNil(verified)
        } else { XCTFail("Expected a stale receipt") }
        if case .stale(_, let verified) = try status(["created_at": earlier, "status": "pending", "delete_verified_at": NSNull()]) {
            XCTAssertNil(verified)
        } else { XCTFail("A pending earlier row is stale too") }
        XCTAssertEqual(try status(["delete_verified_at": NSNull()]), .invalid)
        XCTAssertEqual(try status(["status": "pending", "delete_verified_at": NSNull()]), .pending)
        if case .verified = try status([:]) {} else { XCTFail("Expected explicit verified receipt") }
    }

    func testEventCountNeedsOneFreshIntegerAndQueryEmbedsOnlyACanonicalUUID() throws {
        XCTAssertEqual(PostHogErasureService.eventCount(try data(["results": [[0]], "is_cached": false])), .count(0))
        XCTAssertEqual(PostHogErasureService.eventCount(try data(["results": [[3]]])), .count(3))
        XCTAssertEqual(PostHogErasureService.eventCount(try data(["results": [[0]], "is_cached": true])), .cached)
        for invalid: [String: Any] in [["results": []], ["results": [[0, 1]]], ["results": [[true]]],
                                       ["results": [["0"]]], ["results": [[-1]]], ["query_status": ["complete": false]],
                                       ["results": [[0]], "is_cached": "no"]] {
            XCTAssertEqual(PostHogErasureService.eventCount(try data(invalid)), .invalid)
        }
        let id = UUID().uuidString.lowercased()
        let body = try XCTUnwrap(PostHogErasureService.eventCountQuery(distinctID: id))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["refresh"] as? String, "force_blocking")
        let query = try XCTUnwrap(object["query"] as? [String: Any])
        XCTAssertEqual(query["kind"] as? String, "HogQLQuery")
        XCTAssertEqual(query["query"] as? String, "SELECT count() FROM events WHERE distinct_id = '\(id)'")
        XCTAssertNil(PostHogErasureService.eventCountQuery(distinctID: id.uppercased()))
        XCTAssertNil(PostHogErasureService.eventCountQuery(distinctID: "x' OR 1=1 --"))
        let key = String(repeating: "x", count: 25)
        XCTAssertFalse(PostHogErasureService.Configuration(projectID: "123", apiKey: key, ingestionLagWindow: 60).valid)
        XCTAssertFalse(PostHogErasureService.Configuration(projectID: "123", apiKey: key, ingestionLagWindow: .nan).valid)
        XCTAssertTrue(PostHogErasureService.Configuration(projectID: "123", apiKey: key).valid)
        XCTAssertEqual(PostHogErasureService.Configuration(projectID: "123", apiKey: key).ingestionLagWindow, 86_400)
    }

    /// Durable reason spellings, written out by hand: POSTHOG-MANUAL-REMEDIATION.md
    /// and the receipt check are keyed by them.
    func testManualReasonSpellingsArePinned() {
        let pinned: [PostHogErasureService.ManualReason: String] = [
            .staleReceipt: "posthog_stale_receipt",
            .profilelessLateEvents: "posthog_profileless_late_events",
            .unverifiable: "posthog_unverifiable",
            .roundsExhausted: "posthog_rounds_exhausted",
            .profileUnresolved: "posthog_profile_unresolved",
            .responseInvalid: "posthog_response_invalid",
            .requestRefused: "posthog_request_refused",
            .observationWindowExpired: "posthog_observation_window_expired",
            .receiptInconsistent: "posthog_receipt_inconsistent",
            .subjectIneligible: "posthog_subject_ineligible",
            .configuration: "provider_configuration_required",
        ]
        for (reason, spelling) in pinned { XCTAssertEqual(reason.rawValue, spelling) }
        XCTAssertEqual(pinned.count, PostHogErasureService.ManualReason.allCases.count,
                       "a reason was added or removed without being written down here")
        XCTAssertEqual(Set(pinned.values).count, pinned.count)
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
    private func noEvents() throws -> PostHogErasureService.Reply {
        try reply(["results": [[0]], "columns": ["count()"], "is_cached": false])
    }
    /// Ends the ingestion-lag quiet period; only the clock moves.
    private func endQuietPeriod() async throws {
        try await sql.raw("""
            UPDATE measurement_posthog_erasure_receipts SET quiet_until=NOW()-INTERVAL '1 second'
            WHERE job_id=\(bind:job) AND phase='quiet'
            """).run()
    }
    private func runDue() async throws -> MeasurementErasureService.Counts {
        try await sql.raw("UPDATE measurement_erasure_jobs SET available_at=NOW() WHERE id=\(bind:job)").run()
        return await MeasurementErasureService.run(app: app, limit: 1, on: app.db)
    }
    private func jobState() async throws -> String {
        try await sql.raw("SELECT state FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!.decode(column: "state", as: String.self)
    }
    private func lastErrorKind() async throws -> String? {
        try await sql.raw("SELECT last_error_kind FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!
            .decode(column: "last_error_kind", as: String?.self)
    }

    func testProfilelessExposureRequiresManualHandlingAndIsNeverErasedBy202() async throws {
        let recorder = PostHogErasureRecorder([try reply(["results": [], "next": NSNull()])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        let counts = try await runDue(); XCTAssertEqual(counts.manualRequired, 1); XCTAssertEqual(counts.completed, 0)
        let calls = await recorder.calls(); XCTAssertEqual(calls.map(\.method), ["GET"])
        let state = try await jobState(); XCTAssertEqual(state, "manual_required")
        let reason = try await lastErrorKind(); XCTAssertEqual(reason, "posthog_profile_unresolved")
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
            try reply(["results": [], "next": NSNull()]), try noEvents(), try reply(["results": [], "next": NSNull()])])
        app.storage[PostHogErasureService.TransportKey.self] = resumed.transport
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1)
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        // Verified events plus an absent profile only start the quiet period.
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        let waitingCalls = await resumed.calls(); XCTAssertEqual(waitingCalls.count, 3, "no provider call inside the window")
        try await endQuietPeriod()
        counts = try await runDue(); XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        counts = try await runDue(); XCTAssertEqual(counts.completed, 1)
        let state = try await jobState(); XCTAssertEqual(state, "completed")
        let firstCalls = await first.calls(), resumedCalls = await resumed.calls()
        XCTAssertEqual(firstCalls.map(\.method), ["GET", "POST"])
        XCTAssertEqual(resumedCalls.map(\.method), ["GET", "GET", "GET", "POST", "GET"])
        let query = "https://eu.posthog.com/api/projects/123456/query/"
        XCTAssertEqual(resumedCalls[3].uri, query)
        XCTAssertTrue(resumedCalls[3].body?.contains("force_blocking") == true)
        XCTAssertTrue(resumedCalls[3].body?.contains(opaque.uuidString.lowercased()) == true)
        XCTAssertTrue((firstCalls + resumedCalls).allSatisfy {
            $0.uri.hasPrefix("https://eu.posthog.com/api/projects/123456/persons/") || $0.uri == query })
        let completed = try await sql.raw("SELECT completed_at,quiet_until FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()!
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(completed.decode(column: "completed_at", as: Date?.self)),
                                    try XCTUnwrap(completed.decode(column: "quiet_until", as: Date?.self)))
        let body = try XCTUnwrap(firstCalls.last?.body).data(using: .utf8)!
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["distinct_ids"] as? [String], [opaque.uuidString.lowercased()])
        XCTAssertEqual(payload["delete_events"] as? Bool, true)
        XCTAssertEqual(payload["keep_person"] as? Bool, false)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("example.test"))
    }

    func testAmbiguousPostAndExpiredLeaseResumePollingWithoutSecondDelete() async throws {
        let recorder = PostHogErasureRecorder([try profile(), nil, try status(complete: true),
            try reply(["results": []]), try noEvents(), try reply(["results": []])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); let ambiguous = try await runDue()
        XCTAssertEqual(ambiguous.completed, 0); XCTAssertEqual(ambiguous.pending, 1)
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='leased',lease_token=\(bind:UUID()),lease_expires_at=NOW()-INTERVAL '1 minute'
            WHERE id=\(bind:job)
            """).run()
        let recovered = try await runDue(); XCTAssertEqual(recovered.pending, 1)
        let quiet = try await runDue(); XCTAssertEqual(quiet.pending, 1); XCTAssertEqual(quiet.completed, 0)
        try await endQuietPeriod()
        let events = try await runDue(); XCTAssertEqual(events.pending, 1)
        let completed = try await runDue(); XCTAssertEqual(completed.completed, 1)
        // The Query API check is also a POST; only one deletion request may exist.
        let calls = await recorder.calls()
        XCTAssertEqual(calls.filter { $0.method == "POST" && $0.uri.hasSuffix("/persons/bulk_delete/") }.count, 1)
        XCTAssertEqual(calls.filter { $0.method == "POST" }.map(\.uri),
            ["https://eu.posthog.com/api/projects/123456/persons/bulk_delete/", "https://eu.posthog.com/api/projects/123456/query/"])
    }

    func testEmptyStatusAndMissingVerificationNeverComplete() async throws {
        let recorder = PostHogErasureRecorder([try profile(), try queued(), try reply(["results": []]),
            try reply(["results": [["person_uuid": person.uuidString,
                "created_at": ISO8601DateFormatter().string(from: Date()), "status": "completed", "delete_verified_at": NSNull()]]])])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue(); _ = try await runDue()
        let empty = try await runDue(); XCTAssertEqual(empty.pending, 1); XCTAssertEqual(empty.completed, 0)
        let malformed = try await runDue(); XCTAssertEqual(malformed.manualRequired, 1); XCTAssertEqual(malformed.completed, 0)
        let reason = try await lastErrorKind(); XCTAssertEqual(reason, "posthog_response_invalid")
        let manual = try await sql.raw("SELECT manual_reason FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        XCTAssertEqual(try manual?.decode(column: "manual_reason", as: String?.self), "posthog_response_invalid")
    }

    func testProjectChangeCannotRedirectPersistedDeletionReceipt() async throws {
        let recorder = PostHogErasureRecorder([try profile()])
        app.storage[PostHogErasureService.TransportKey.self] = recorder.transport
        _ = try await runDue()
        app.storage[PostHogErasureService.ConfigurationKey.self] = .init(projectID: "999", apiKey: config.apiKey)
        let counts = try await runDue(); XCTAssertEqual(counts.manualRequired, 1)
        let calls = await recorder.calls(); XCTAssertEqual(calls.count, 1)
        let reason = try await lastErrorKind(); XCTAssertEqual(reason, "provider_configuration_required")
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
        let reason = try await lastErrorKind(); XCTAssertEqual(reason, "posthog_observation_window_expired")
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
        let reason = try await lastErrorKind(); XCTAssertEqual(reason, "posthog_request_refused")
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
