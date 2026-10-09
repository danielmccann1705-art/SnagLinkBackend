@testable import App
import XCTVapor

/// Script-only entry point of the L7 harness (scripts/run-posthog-l7-harness.sh).
final class PostHogL7HarnessTests: XCTestCase {
    func testL7RealTransportErasureAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["POSTHOG_L7_HARNESS"] == nil, "Run only through scripts/run-posthog-l7-harness.sh")
        let guardrail: PostHogL7Guard
        let secrets: PostHogL7Guard.Secrets
        do {
            guardrail = try PostHogL7Guard.parse(environment)
            secrets = try guardrail.loadSecrets()
        } catch {
            print("POSTHOG-L7 REFUSED before any request: \(error)")
            XCTFail("L7 harness refused before any request: \(error)")
            return
        }
        let run = try PostHogL7Run(guardrail: guardrail, secrets: secrets)
        let status: String
        do {
            status = try await run.execute()
        } catch {
            try? await run.writeReport(status: "failed", error: String(describing: error))
            await run.close()
            throw error
        }
        await run.close()
        print("POSTHOG-L7 STATUS: \(status)")
        XCTAssertTrue(["finished", "waiting"].contains(status), "harness status \(status)")
        if guardrail.mode == .dryRun, status == "finished", let report = run.lastReport {
            for expectation in report.expectations {
                XCTAssertTrue(expectation.matches,
                              "\(expectation.id): expected \(expectation.expected); observed \(expectation.observed)")
            }
        }
    }
}

/// Guard and router refusals. Pure: no database and no request leaves the process.
final class PostHogL7GuardTests: XCTestCase {
    private let base: [String: String] = [
        "POSTHOG_L7_HARNESS": "1", "POSTHOG_L7_PROJECT_ID": "298161", "POSTHOG_L7_SUBJECT_PREFIX": "7e57da7a",
        "POSTHOG_L7_ERASURE_KEY_FILE": "/tmp/posthog-l7-guard/erasure.json",
        "POSTHOG_L7_CAPTURE_CONFIG": "/tmp/posthog-l7-guard/capture.json",
        "POSTHOG_L7_FAKE_BASE": "http://127.0.0.1:54321", "POSTHOG_L7_OUTPUT_DIR": "/tmp/posthog-l7-guard/out",
        "POSTHOG_L7_REPORT_NAME": "posthog-l7-guard-test",
        "DATABASE_URL": "postgresql://synthetic:synthetic@127.0.0.1:5432/snaglist_test"]
    private let secrets = PostHogL7Guard.Secrets(captureToken: "synthetic-l7-project-token-test",
                                                 apiKey: "synthetic-l7-personal-key-test")

    private func env(_ changes: [String: String?]) -> [String: String] {
        var value = base
        for (key, change) in changes { value[key] = change }
        return value
    }

    private func refused(_ changes: [String: String?], _ fragment: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try PostHogL7Guard.parse(env(changes))
            XCTFail("accepted; expected a refusal containing \"\(fragment)\"", file: file, line: line)
        } catch let refusal as PostHogL7Guard.Refusal {
            XCTAssertTrue(refusal.description.contains(fragment), refusal.description, file: file, line: line)
        } catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    func testDryRunIsTheDefaultAndReachesOnlyTheLocalFake() throws {
        let guardrail = try PostHogL7Guard.parse(base)
        XCTAssertEqual(guardrail.mode, .dryRun)
        XCTAssertEqual(guardrail.window, 3_600)
        XCTAssertEqual(guardrail.lateCapture, .afterPassOne)
        refused(["POSTHOG_L7_FAKE_BASE": nil], "local fake PostHog")
        refused(["POSTHOG_L7_FAKE_BASE": "http://10.0.0.5:8000"], "local fake PostHog")
        refused(["POSTHOG_L7_FAKE_BASE": "https://eu.posthog.com"], "local fake PostHog")
        refused(["POSTHOG_L7_ERASURE_KEY_FILE": "/Users/someone/.config/snaglist/measurement/posthog-erasure-sandbox.json"],
                "synthetic key files")
        refused(["POSTHOG_L7_LIVE_APPROVAL": "DAN-APPROVAL-2026-10-10"], "dry run")
    }

    func testNonSandboxProjectProductionConfigurationAndMissingGuardsAreRefused() {
        refused(["POSTHOG_L7_HARNESS": nil], "POSTHOG_L7_HARNESS=1")
        refused(["POSTHOG_L7_PROJECT_ID": "123456"], "sandbox project")
        refused(["POSTHOG_L7_PROJECT_ID": nil], "sandbox project")
        refused(["POSTHOG_L7_MODE": "production"], "dry-run or live")
        refused(["PLATFORM_ENVIRONMENT": "production"], "production configuration")
        refused(["POSTHOG_MEASUREMENT_ENVIRONMENT": "production"], "production configuration")
        refused(["POSTHOG_ERASURE_PROJECT_ID": "111111"], "non-sandbox project")
        refused(["POSTHOG_ERASURE_API_KEY": "anything-at-all"], "private files")
        refused(["DATABASE_URL": "postgresql://u:p@db.example.com:5432/snaglist_test"], "disposable loopback")
        refused(["DATABASE_URL": "postgresql://u:p@127.0.0.1:5432/snaglist"], "disposable loopback")
        refused(["POSTHOG_L7_SUBJECT_PREFIX": nil], "8 lower-case hex")
        refused(["POSTHOG_L7_SUBJECT_PREFIX": "L7TEST00"], "8 lower-case hex")
        refused(["POSTHOG_L7_SUBJECT_PREFIX": "00000000"], "8 lower-case hex")
        refused(["POSTHOG_L7_ERASURE_KEY_FILE": nil], "POSTHOG_L7_ERASURE_KEY_FILE")
        refused(["POSTHOG_L7_CAPTURE_CONFIG": "relative.json"], "POSTHOG_L7_CAPTURE_CONFIG")
        refused(["POSTHOG_L7_WINDOW_SECONDS": "60"], "POSTHOG_L7_WINDOW_SECONDS")
        refused(["POSTHOG_L7_LATE_CAPTURE": "never"], "POSTHOG_L7_LATE_CAPTURE")
    }

    func testLiveModeNeedsDansApprovalReferenceAnOperatorAndNeverTheFake() throws {
        let live: [String: String?] = ["POSTHOG_L7_MODE": "live", "POSTHOG_L7_FAKE_BASE": nil,
                                       "POSTHOG_L7_OPERATOR": "codex",
                                       "POSTHOG_L7_LIVE_APPROVAL": "DAN-APPROVAL-2026-10-10 L7 sandbox 298161"]
        let guardrail = try PostHogL7Guard.parse(env(live))
        XCTAssertEqual(guardrail.mode, .live)
        XCTAssertEqual(guardrail.poll, 60)
        XCTAssertEqual(guardrail.realWait, 900)
        refused(live.merging(["POSTHOG_L7_LIVE_APPROVAL": nil]) { $1 }, "Dan's concrete approval")
        refused(live.merging(["POSTHOG_L7_FAKE_BASE": "http://127.0.0.1:54321"]) { $1 }, "live mode")
        refused(live.merging(["POSTHOG_L7_OPERATOR": nil]) { $1 }, "lower-case handle")
        refused(live.merging(["POSTHOG_L7_POLL_SECONDS": "1"]) { $1 }, "POSTHOG_L7_POLL_SECONDS")
    }

    func testKeyFilesMustBePrivateScopedToTheSandboxAndMatchTheMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("posthog-l7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let erasure = directory.appendingPathComponent("erasure.json"), capture = directory.appendingPathComponent("capture.json")
        func write(_ url: URL, _ object: [String: Any], mode: Int = 0o600) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let goodErasure: [String: Any] = ["apiKey": secrets.apiKey, "host": "https://eu.posthog.com", "projectID": "298161",
                                          "purpose": "synthetic", "synthetic": true]
        let goodCapture: [String: Any] = ["publicWriteToken": secrets.captureToken, "host": "https://eu.i.posthog.com",
                                          "projectId": 298161, "environment": "sandbox", "synthetic": true]
        try write(erasure, goodErasure)
        try write(capture, goodCapture)
        let files: [String: String?] = ["POSTHOG_L7_ERASURE_KEY_FILE": erasure.path, "POSTHOG_L7_CAPTURE_CONFIG": capture.path]
        let guardrail = try PostHogL7Guard.parse(env(files))
        let loaded = try guardrail.loadSecrets()
        XCTAssertEqual(loaded.apiKey, secrets.apiKey)
        func refusedLoad(_ fragment: String, _ guardrail: PostHogL7Guard, file: StaticString = #filePath, line: UInt = #line) {
            do { _ = try guardrail.loadSecrets(); XCTFail("loaded; expected \(fragment)", file: file, line: line) }
            catch let refusal as PostHogL7Guard.Refusal {
                XCTAssertTrue(refusal.description.contains(fragment), refusal.description, file: file, line: line)
            } catch { XCTFail("unexpected \(error)", file: file, line: line) }
        }
        try write(erasure, goodErasure, mode: 0o644)
        refusedLoad("not private", guardrail)
        try write(erasure, goodErasure.merging(["projectID": "123456"]) { $1 })
        refusedLoad("sandbox project", guardrail)
        try write(erasure, goodErasure.merging(["host": "https://us.posthog.com"]) { $1 })
        refusedLoad("is not for", guardrail)
        try write(erasure, goodErasure.merging(["synthetic": false]) { $1 })
        refusedLoad("not marked synthetic", guardrail)
        try write(erasure, goodErasure)
        try write(capture, goodCapture.merging(["environment": "production"]) { $1 })
        refusedLoad("EU sandbox project", guardrail)
        try write(capture, goodCapture)
        let live = try PostHogL7Guard.parse(env(files.merging(["POSTHOG_L7_MODE": "live", "POSTHOG_L7_FAKE_BASE": nil,
            "POSTHOG_L7_OPERATOR": "codex", "POSTHOG_L7_LIVE_APPROVAL": "DAN-APPROVAL-2026-10-10 L7"]) { $1 }))
        refusedLoad("is synthetic", live)
    }

    func testRouterRefusesEverythingOutsideTheSandboxAllowlistBeforeSending() async throws {
        let guardrail = try PostHogL7Guard.parse(base)
        let logger = Logger(label: "posthog-l7-guard-test")
        let captureClient = MeasurementDirectHTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, logger: logger)
        let apiClient = PostHogErasureHTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, logger: logger)
        let router = PostHogL7Router(guardrail: guardrail, secrets: secrets, captureClient: captureClient,
                                     apiClient: apiClient, previous: [])
        let subject = "7e57da7a" + String(UUID().uuidString.lowercased().dropFirst(8))
        await router.setSubject(subject)
        func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: secrets.apiKey)
        let other = UUID().uuidString.lowercased()
        let requests: [(HTTPMethod, String, Data?)] = [
            (.GET, "https://us.posthog.com/api/projects/298161/persons/?distinct_id=\(subject)", nil),
            (.GET, "https://eu.posthog.com/api/projects/123456/persons/?distinct_id=\(subject)", nil),
            (.GET, "https://eu.posthog.com/api/projects/298161/persons/?distinct_id=\(other)", nil),
            (.POST, "https://eu.posthog.com/api/projects/298161/persons/bulk_delete/",
             json(["distinct_ids": [subject, other], "delete_events": true, "keep_person": false, "delete_recordings": false])),
            (.POST, "https://eu.posthog.com/api/projects/298161/persons/bulk_delete/",
             json(["distinct_ids": [subject], "delete_events": true, "keep_person": true, "delete_recordings": false])),
            (.GET, "https://eu.posthog.com/api/projects/298161/persons/deletion_status/?person_uuid=\(other)&status=all", nil),
            (.POST, "https://eu.posthog.com/api/projects/298161/query/",
             json(["query": ["kind": "HogQLQuery", "query": "SELECT * FROM events"], "refresh": "force_blocking"])),
            (.DELETE, "https://eu.posthog.com/api/projects/298161/", nil),
            (.GET, "https://eu.posthog.com/api/projects/298161/events/", nil),
        ]
        for (method, uri, body) in requests {
            do {
                _ = try await router.api(method, URI(string: uri), headers, body, origin: "test")
                XCTFail("sent: \(method.rawValue) \(uri)")
            } catch is PostHogL7Guard.Refusal {}
        }
        var otherKey = HTTPHeaders()
        otherKey.bearerAuthorization = .init(token: "another-credential-0000000000")
        do {
            _ = try await router.api(.GET, URI(string: PostHogL7Guard.apiPrefix + "persons/?distinct_id=" + subject),
                                     otherKey, nil, origin: "test")
            XCTFail("sent with another credential")
        } catch is PostHogL7Guard.Refusal {}
        var jsonHeaders = HTTPHeaders()
        jsonHeaders.contentType = .json
        func capture(_ distinct: String, token: String? = nil, profile: Bool = true) -> Data {
            json(["api_key": token ?? secrets.captureToken, "event": "session_started",
                  "properties": ["distinct_id": distinct, "$process_person_profile": profile, "$geoip_disable": true]])
        }
        let captures: [(String, Data)] = [
            ("https://us.i.posthog.com/capture/", capture(subject)),
            (PostHogL7Guard.captureURL, capture(other)),
            (PostHogL7Guard.captureURL, capture(subject, token: "another-project-token-000000")),
            (PostHogL7Guard.captureURL, capture(subject, profile: false)),
        ]
        for (uri, body) in captures {
            do {
                _ = try await router.capture(URI(string: uri), jsonHeaders, body, origin: "test")
                XCTFail("captured: \(uri)")
            } catch is PostHogL7Guard.Refusal {}
        }
        let calls = await router.allCalls()
        XCTAssertEqual(calls.count, requests.count + 1 + captures.count)
        XCTAssertTrue(calls.allSatisfy { $0.refused != nil && $0.status == nil }, "nothing was sent")
        try await captureClient.close()
        try await apiClient.close()
    }

    func testReportSecretScanCatchesKeyMaterial() {
        XCTAssertFalse(PostHogL7Guard.containsSecret("{\"status\":\"finished\"}", secrets))
        XCTAssertTrue(PostHogL7Guard.containsSecret("x synthetic-l7-personal-key-test x", secrets))
        XCTAssertTrue(PostHogL7Guard.containsSecret("synthetic-l7-project-token-test", secrets))
        XCTAssertTrue(PostHogL7Guard.containsSecret("phx_0123", secrets))
        XCTAssertTrue(PostHogL7Guard.containsSecret("phc_0123", secrets))
        XCTAssertTrue(PostHogL7Guard.containsSecret("Authorization: Bearer abc", secrets))
    }
}
