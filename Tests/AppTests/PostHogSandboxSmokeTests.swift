@testable import App
import Fluent
import FluentSQL
import JWT
import XCTVapor

final class PostHogSandboxSmokeTests: XCTestCase {
    private struct PrivateConfiguration: Decodable {
        let host: String
        let projectId: Int
        let environment: String
        let publicWriteToken: String
    }

    fileprivate struct ExpectedEvent: Codable, Sendable {
        let name: String
        let sourceEventId: UUID
        let providerUuid: UUID
        let occurredAt: String
        let opaqueSubject: UUID
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let receiver: String
        let projectId: Int
        let environment: String
        let runId: UUID
        let completedAt: String
        let expectedDeliveredCount: Int
        let opaqueSubject: UUID
        let events: [ExpectedEvent]
        let duplicateSourceEventId: UUID
        let duplicateCreatedOneJob: Bool
        let deniedEventId: UUID
        let deniedCreatedNoJob: Bool
        let withdrawnEventId: UUID
        let withdrawnJobState: String
        let withdrawnSent: Bool
        let personProfilesRequested: Bool
        let geoIpEnrichmentDisabled: Bool
        let scope: String
    }

    func testRealProductOutboxReachesGuardedEUSandbox() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["POSTHOG_SANDBOX_SMOKE_CONFIG"] == nil,
                      "Run only through scripts/run-posthog-sandbox-smoke.sh")
        let configurationPath = try XCTUnwrap(environment["POSTHOG_SANDBOX_SMOKE_CONFIG"],
            "Opt in through scripts/run-posthog-sandbox-smoke.sh")
        let outputPath = try XCTUnwrap(environment["POSTHOG_SANDBOX_SMOKE_OUTPUT"])
        guard let databaseURL = environment["DATABASE_URL"],
              let database = URLComponents(string: databaseURL),
              ["postgres", "postgresql"].contains(database.scheme ?? ""),
              ["127.0.0.1", "localhost", "::1"].contains(database.host ?? ""),
              database.path == "/snaglist_test", database.port != nil else {
            throw Abort(.preconditionFailed, reason: "Smoke database must be disposable loopback snaglist_test")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: configurationPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard permissions.map({ $0 & 0o077 }) == 0 else {
            throw Abort(.preconditionFailed, reason: "Private smoke configuration is not private")
        }
        let privateConfiguration = try JSONDecoder().decode(
            PrivateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: configurationPath)))
        guard privateConfiguration.host == "https://eu.i.posthog.com",
              privateConfiguration.projectId == 298_161,
              privateConfiguration.environment == "sandbox",
              privateConfiguration.publicWriteToken.hasPrefix("phc_"),
              privateConfiguration.publicWriteToken.utf8.count <= 4096 else {
            XCTFail("PostHog smoke configuration is not the exact guarded EU sandbox")
            return
        }

        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        try await configure(app)
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: privateConfiguration.publicWriteToken, postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        let direct = MeasurementDirectHTTPClient(eventLoopGroup: app.eventLoopGroup, logger: app.logger)
        app.lifecycle.use(direct)
        let receiver = PostHogSandboxReceiver(client: direct, expectedToken: privateConfiguration.publicWriteToken)
        app.storage[MeasurementDispatchService.TransportKey.self] = receiver.transport

        let user = User(appleUserId: nil, email: "posthog-smoke-\(UUID())@example.test",
                        name: nil, authProvider: .magicLink)
        try await user.save(on: app.db)
        let accountID = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(
            subject: .init(value: accountID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3_600)), userId: accountID,
            authVersion: user.authVersion, authenticatedAt: Date()))
        try await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
        try await FeatureFlag(key: "productAnalyticsEnabled", enabled: true).save(on: app.db)

        func request(_ method: HTTPMethod, _ path: String, _ object: [String: Any]) async throws -> XCTHTTPResponse {
            let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            var result: XCTHTTPResponse!
            try await app.test(method, path, beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: jwt)
                request.headers.contentType = .json
                request.body = .init(data: body)
            }, afterResponse: { result = $0 })
            return result
        }
        func permission(_ decision: String, expected: UUID? = nil) async throws -> MeasurementPermissionResponse {
            var body: [String: Any] = ["requestId": UUID().uuidString, "decision": decision,
                                       "occurredAt": ISO8601DateFormatter().string(from: Date())]
            if let expected { body["expectedRevision"] = expected.uuidString }
            let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", body)
            XCTAssertEqual(response.status, .ok, response.body.string)
            return try XCTUnwrap(try response.content.decode(MeasurementPermissionsEnvelope.self).permissions
                .first { $0.purpose == .productAnalytics })
        }
        func event(_ eventID: UUID, revision: UUID, installation: UUID, occurredAt: Date,
                   name: String, properties: [String: String]) async throws -> XCTHTTPResponse {
            try await request(.POST, "api/v2/measurement/events", [
                "eventId": eventID.uuidString, "occurredAt": ISO8601DateFormatter().string(from: occurredAt),
                "consentRevision": revision.uuidString, "installationId": installation.uuidString,
                "event": ["schemaVersion": 1, "name": name, "properties": properties]
            ])
        }

        let denied = try await permission("denied")
        let deniedRevision = try XCTUnwrap(denied.revision)
        let deniedEventID = UUID(), installation = UUID(), deniedOccurredAt = Date()
        let deniedResponse = try await event(deniedEventID, revision: deniedRevision,
            installation: installation, occurredAt: deniedOccurredAt, name: "session_started", properties: [:])
        XCTAssertEqual(deniedResponse.status, .forbidden)
        let sql = try VerifiedIdentityService.sql(app.db)
        var jobCount = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:accountID)")
            .first()!.decode(column: "n", as: Int.self)
        let deniedCreatedNoJob = jobCount == 0
        XCTAssertTrue(deniedCreatedNoJob)

        let granted = try await permission("granted", expected: deniedRevision)
        let revision = try XCTUnwrap(granted.revision)
        let baseTime = Date().addingTimeInterval(1)
        let subject = try await sql.raw("""
            SELECT opaque_subject FROM measurement_subjects
            WHERE account_id=\(bind:accountID) AND purpose='productAnalytics' AND state='active'
            """).first()!.decode(column: "opaque_subject", as: UUID.self)
        let fixtures: [(String, [String: String])] = [
            ("session_started", [:]),
            ("project_created", ["creation_source": "fresh", "workspace_kind": "personal"]),
            ("snag_created", ["photo_count": "1", "offline": "false"]),
            ("contractor_link_create_started", [:]),
            ("contractor_link_activated", [:]),
            ("portal_open_requested", [:])
        ]
        var sourceEvents: [(UUID, String, Date)] = []
        for (offset, fixture) in fixtures.enumerated() {
            let sourceID = UUID(), occurredAt = baseTime.addingTimeInterval(Double(offset))
            let response = try await event(sourceID, revision: revision, installation: installation,
                occurredAt: occurredAt, name: fixture.0, properties: fixture.1)
            XCTAssertEqual(response.status, .accepted, response.body.string)
            sourceEvents.append((sourceID, fixture.0, occurredAt))
        }
        let duplicate = sourceEvents[1]
        let duplicateResponse = try await event(duplicate.0, revision: revision, installation: installation,
            occurredAt: duplicate.2, name: fixtures[1].0, properties: fixtures[1].1)
        XCTAssertEqual(duplicateResponse.status, .accepted)
        jobCount = try await sql.raw("SELECT count(*) AS n FROM measurement_dispatch_jobs WHERE account_id=\(bind:accountID)")
            .first()!.decode(column: "n", as: Int.self)
        let duplicateCreatedOneJob = jobCount == fixtures.count
        XCTAssertTrue(duplicateCreatedOneJob)

        let delivered = await MeasurementDispatchService.run(app: app, limit: 20, on: app.db)
        XCTAssertEqual(delivered.delivered, fixtures.count)
        XCTAssertEqual(delivered.suppressed, 0)
        let received = await receiver.events()
        XCTAssertEqual(received.count, fixtures.count)
        XCTAssertEqual(Set(received.map(\.sourceEventId)), Set(sourceEvents.map(\.0)))
        XCTAssertTrue(received.allSatisfy { $0.opaqueSubject == subject })

        let withdrawnEventID = UUID()
        let queued = try await event(withdrawnEventID, revision: revision,
            installation: installation, occurredAt: Date().addingTimeInterval(1),
            name: "first_project_created", properties: [:])
        XCTAssertEqual(queued.status, .accepted)
        _ = try await permission("withdrawn", expected: revision)
        let afterWithdrawal = await MeasurementDispatchService.run(app: app, limit: 20, on: app.db)
        XCTAssertEqual(afterWithdrawal.delivered, 0)
        let finalReceivedCount = await receiver.events().count
        XCTAssertEqual(finalReceivedCount, fixtures.count)
        let withdrawnState = try await sql.raw("""
            SELECT state FROM measurement_dispatch_jobs
            WHERE account_id=\(bind:accountID) AND source_id=\(bind:withdrawnEventID)
            """).first()!.decode(column: "state", as: String.self)
        XCTAssertEqual(withdrawnState, "suppressed")

        guard deniedResponse.status == .forbidden, deniedCreatedNoJob,
              duplicateResponse.status == .accepted, duplicateCreatedOneJob,
              delivered.delivered == fixtures.count, delivered.suppressed == 0,
              received.count == fixtures.count,
              Set(received.map(\.sourceEventId)) == Set(sourceEvents.map(\.0)),
              received.allSatisfy({ $0.opaqueSubject == subject }),
              queued.status == .accepted, afterWithdrawal.delivered == 0,
              finalReceivedCount == fixtures.count, withdrawnState == "suppressed" else {
            throw Abort(.internalServerError, reason: "PostHog smoke invariants were not established")
        }

        let expected = received.sorted { $0.sourceEventId.uuidString < $1.sourceEventId.uuidString }
        let manifest = Manifest(schemaVersion: 1, receiver: privateConfiguration.host,
            projectId: privateConfiguration.projectId, environment: privateConfiguration.environment,
            runId: UUID(), completedAt: ISO8601DateFormatter().string(from: Date()),
            expectedDeliveredCount: expected.count, opaqueSubject: subject, events: expected,
            duplicateSourceEventId: duplicate.0, duplicateCreatedOneJob: duplicateCreatedOneJob,
            deniedEventId: deniedEventID, deniedCreatedNoJob: deniedCreatedNoJob,
            withdrawnEventId: withdrawnEventID, withdrawnJobState: withdrawnState,
            withdrawnSent: false, personProfilesRequested: false,
            geoIpEnrichmentDisabled: true,
            scope: "Outbound capture acknowledgements only; stored-event receipt requires an independent PostHog query")
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder.postHogSmoke.encode(manifest)
        try data.write(to: output, options: .atomic)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(privateConfiguration.publicWriteToken))
    }

    func testPinnedMeasurementTransportReturnsRedirectWithoutRepostingBody() async throws {
        let hits = RedirectHitCounter()
        let sink = try await Application.make(.testing)
        sink.http.server.configuration.hostname = "127.0.0.1"
        sink.http.server.configuration.port = 0
        sink.on(.POST, "sink") { _ async -> HTTPStatus in
            await hits.record()
            return .ok
        }
        try await sink.startup()
        let sinkPort = try XCTUnwrap(sink.http.server.shared.localAddress?.port)

        let redirector = try await Application.make(.testing)
        redirector.http.server.configuration.hostname = "127.0.0.1"
        redirector.http.server.configuration.port = 0
        redirector.on(.POST, "capture") { _ -> Response in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .location, value: "http://127.0.0.1:\(sinkPort)/sink")
            return Response(status: .temporaryRedirect, headers: headers)
        }
        try await redirector.startup()
        let redirectPort = try XCTUnwrap(redirector.http.server.shared.localAddress?.port)
        let direct = MeasurementDirectHTTPClient(eventLoopGroup: redirector.eventLoopGroup,
                                                  logger: redirector.logger)
        do {
            var headers = HTTPHeaders()
            headers.contentType = .json
            let reply = try await direct.post(URI(string: "http://127.0.0.1:\(redirectPort)/capture"),
                                              headers: headers, body: Data("synthetic-private-body".utf8))
            XCTAssertEqual(reply.status, Int(HTTPStatus.temporaryRedirect.code))
            let redirectedBodyCount = await hits.count()
            XCTAssertEqual(redirectedBodyCount, 0, "a redirect must not receive the credential-bearing body")
            try await direct.close()
            try await redirector.asyncShutdown()
            try await sink.asyncShutdown()
        } catch {
            try? await direct.close()
            try? await redirector.asyncShutdown()
            try? await sink.asyncShutdown()
            throw error
        }
    }
}

private actor PostHogSandboxReceiver {
    private let client: MeasurementDirectHTTPClient
    private let expectedToken: String
    private var values: [PostHogSandboxSmokeTests.ExpectedEvent] = []

    init(client: MeasurementDirectHTTPClient, expectedToken: String) {
        self.client = client
        self.expectedToken = expectedToken
    }

    nonisolated var transport: MeasurementDispatchService.Transport {
        { uri, headers, body in try await self.send(uri: uri, headers: headers, body: body) }
    }

    private func send(uri: URI, headers: HTTPHeaders, body: Data) async throws -> MeasurementDispatchService.Reply {
        guard uri.string == "https://eu.i.posthog.com/capture/", headers.bearerAuthorization == nil,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["api_key"] as? String == expectedToken,
              let name = object["event"] as? String,
              let providerUUIDText = object["uuid"] as? String,
              let providerUUID = UUID(uuidString: providerUUIDText),
              let occurredAt = object["timestamp"] as? String,
              let properties = object["properties"] as? [String: Any],
              properties["$process_person_profile"] as? Bool == false,
              properties["$geoip_disable"] as? Bool == true,
              let sourceText = properties["source_event_id"] as? String,
              let sourceID = UUID(uuidString: sourceText),
              let subjectText = properties["distinct_id"] as? String,
              let subject = UUID(uuidString: subjectText) else {
            throw Abort(.internalServerError, reason: "Guarded PostHog smoke payload mismatch")
        }
        let reply = try await client.post(uri, headers: headers, body: body)
        if (200..<300).contains(reply.status) {
            values.append(.init(name: name, sourceEventId: sourceID, providerUuid: providerUUID,
                                occurredAt: occurredAt, opaqueSubject: subject))
        }
        return reply
    }

    func events() -> [PostHogSandboxSmokeTests.ExpectedEvent] { values }
}

private extension JSONEncoder {
    static var postHogSmoke: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private actor RedirectHitCounter {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}
