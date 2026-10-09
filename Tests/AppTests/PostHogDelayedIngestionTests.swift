@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// Delayed ingestion after withdrawal or account deletion, against a stateful
/// synthetic PostHog (`FakePostHog`, no network). The fake models what PostHog's
/// source showed on 9 October 2026: capture acceptance precedes storage; person
/// deletion removes only events written before its request; a person's event
/// deletion verifies only those rows. In `sourceSemantics` mode the person UUID is
/// derived from the distinct ID and a person's event deletion is queued once only.
final class PostHogDelayedIngestionTests: XCTestCase {
    private var app: Application!
    private var user: User!
    private var jwt: String!
    private var deletionJobs: [UUID] = []
    private var userID: UUID { try! user.requireID() }
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let window: TimeInterval = 3_600
    private var erasureConfig: PostHogErasureService.Configuration {
        .init(projectID: "123456", apiKey: "synthetic-erasure-key-only", ingestionLagWindow: window)
    }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        try await boot()
        user = User(appleUserId: nil, email: "delayed-\(UUID().uuidString.lowercased())@example.test",
                    name: nil, authProvider: .magicLink)
        try await user.save(on: app.db)
        jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: userID,
            authVersion: user.authVersion, authenticatedAt: Date()))
        try await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
        try await FeatureFlag(key: "productAnalyticsEnabled", enabled: true).save(on: app.db)
    }

    override func tearDown() async throws {
        if let app {
            try? await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").run()
            try? await sql.raw("DELETE FROM measurement_product_events WHERE account_id=\(bind:userID)").run()
            try? await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_id=\(bind:userID)").run()
            for job in deletionJobs {
                try? await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind:job)").run()
            }
            try? await sql.raw("DELETE FROM measurement_permission_current WHERE account_id=\(bind:userID)").run()
            try? await sql.raw("DELETE FROM measurement_consent_events WHERE account_id=\(bind:userID)").run()
            try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:userID)").run()
            try? await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
            try? await User.query(on: app.db).filter(\.$id == userID).delete()
            try await app.asyncShutdown()
        }
        app = nil; user = nil; jwt = nil; deletionJobs = []
    }

    // MARK: - Harness

    private func boot() async throws {
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        app.storage[PostHogErasureService.ConfigurationKey.self] = erasureConfig
    }

    private func restart(_ fake: FakePostHog) async throws {
        try await app.asyncShutdown()
        try await boot()
        wire(fake)
    }

    private func wire(_ fake: FakePostHog) {
        app.storage[MeasurementDispatchService.TransportKey.self] = fake.captureTransport
        app.storage[PostHogErasureService.TransportKey.self] = fake.apiTransport
    }

    private func request(_ method: HTTPMethod, _ path: String, object: [String: Any]) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.jwt)
            req.headers.contentType = .json
            req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func grant() async throws -> UUID {
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": iso(Date())])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try await currentRevision()
    }

    private func currentRevision() async throws -> UUID {
        try await sql.raw("""
            SELECT revision FROM measurement_permission_current
            WHERE account_id=\(bind:userID) AND purpose='productAnalytics'
            """).first()!.decode(column: "revision", as: UUID.self)
    }

    private func withdraw(_ revision: UUID) async throws -> XCTHTTPResponse {
        try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", object: [
            "requestId": UUID().uuidString, "expectedRevision": revision.uuidString,
            "decision": "withdrawn", "occurredAt": iso(Date())])
    }

    private func queueEvent(_ revision: UUID) async throws {
        let response = try await request(.POST, "api/v2/measurement/events", object: [
            "eventId": UUID().uuidString, "occurredAt": iso(Date().addingTimeInterval(1)),
            "consentRevision": revision.uuidString, "installationId": UUID().uuidString,
            "event": ["schemaVersion": 1, "name": "first_project_created", "properties": [:]]])
        XCTAssertEqual(response.status, .accepted, response.body.string)
    }

    private func subject() async throws -> (id: UUID, opaque: String) {
        let row = try await sql.raw("""
            SELECT id,opaque_subject FROM measurement_subjects
            WHERE account_id=\(bind:userID) AND purpose='productAnalytics' ORDER BY created_at DESC LIMIT 1
            """).first()!
        return (try row.decode(column: "id", as: UUID.self),
                try row.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased())
    }

    private func erasureJob(_ subject: UUID) async throws -> UUID {
        try await sql.raw("""
            SELECT id FROM measurement_erasure_jobs WHERE subject_id=\(bind:subject) AND destination='posthog'
            """).first()!.decode(column: "id", as: UUID.self)
    }

    @discardableResult
    private func run(_ job: UUID) async throws -> MeasurementErasureService.Counts {
        try await sql.raw("UPDATE measurement_erasure_jobs SET available_at=NOW() WHERE id=\(bind:job)").run()
        return await MeasurementErasureService.run(app: app, limit: 1, on: app.db)
    }

    private func jobState(_ job: UUID) async throws -> String {
        try await sql.raw("SELECT state FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!
            .decode(column: "state", as: String.self)
    }

    private func receipt(_ job: UUID) async throws -> SQLRow {
        try await sql.raw("SELECT * FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()!
    }

    private func phase(_ job: UUID) async throws -> String {
        try await receipt(job).decode(column: "phase", as: String.self)
    }

    private func assertPhase(_ job: UUID, _ expected: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await phase(job)
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private func assertRound(_ job: UUID, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await receipt(job).decode(column: "round", as: Int.self)
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private func assertState(_ job: UUID, _ expected: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await jobState(job)
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private struct Pass: Equatable { let round: Int; let stage, check, outcome: String; let count: Int? }
    private func passes(_ job: UUID) async throws -> [Pass] {
        try await sql.raw("""
            SELECT round,stage,check_kind,outcome,event_count FROM measurement_posthog_erasure_passes
            WHERE job_id=\(bind:job) ORDER BY sequence
            """).all().map {
            Pass(round: try $0.decode(column: "round", as: Int.self),
                 stage: try $0.decode(column: "stage", as: String.self),
                 check: try $0.decode(column: "check_kind", as: String.self),
                 outcome: try $0.decode(column: "outcome", as: String.self),
                 count: try $0.decode(column: "event_count", as: Int?.self))
        }
    }

    /// Ends the configured ingestion-lag window for the current round. The window
    /// itself is asserted before each use; only the clock is advanced here.
    private func endQuietPeriod(_ job: UUID) async throws {
        try await sql.raw("""
            UPDATE measurement_posthog_erasure_receipts SET quiet_until=NOW()-INTERVAL '1 second'
            WHERE job_id=\(bind:job) AND phase='quiet'
            """).run()
    }

    /// Ends the settle period before the first deletion request by moving the
    /// subject's in-flight bound back past one window; only the clock moves.
    private func endSettlePeriod(_ subjectID: UUID) async throws {
        try await sql.raw("""
            UPDATE measurement_subjects SET send_in_flight_until=send_in_flight_until-make_interval(secs => \(bind:window + 120))
            WHERE id=\(bind:subjectID) AND send_in_flight_until IS NOT NULL
            """).run()
    }

    /// The barrier recorded the send that started before it and its lease bound.
    private func assertBarrierRecordedInFlightSend(_ subjectID: UUID) async throws {
        let row = try await sql.raw("""
            SELECT revoked_at,last_send_started_at,send_in_flight_until FROM measurement_subjects WHERE id=\(bind:subjectID)
            """).first()!
        let revoked = try XCTUnwrap(row.decode(column: "revoked_at", as: Date?.self))
        let lastSend = try XCTUnwrap(row.decode(column: "last_send_started_at", as: Date?.self))
        let inFlight = try XCTUnwrap(row.decode(column: "send_in_flight_until", as: Date?.self))
        XCTAssertLessThan(lastSend, revoked)
        XCTAssertGreaterThanOrEqual(inFlight.timeIntervalSince(lastSend),
            MeasurementDispatchService.sendDeadline + MeasurementDispatchService.sendStartMargin)
    }

    /// One deletion round up to the quiet period: resolve, request, provider
    /// processing, verified status, absent profile.
    private func driveRoundToQuiet(_ job: UUID, _ fake: FakePostHog,
                                   afterRequest: (() async -> Void)? = nil) async throws {
        let existing = try await sql.raw("SELECT phase FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        var counts: MeasurementErasureService.Counts
        if existing == nil {
            counts = try await run(job)
            XCTAssertEqual(counts.pending, 1, "resolve")
        }
        try await assertPhase(job, "resolved")
        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1, "queued request")
        try await assertPhase(job, "polling")
        await afterRequest?()
        await fake.processDeletions()
        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1, "verified status")
        try await assertPhase(job, "events_verified")
        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1, "profile absent starts quiet period, never completion")
        XCTAssertEqual(counts.completed, 0)
        try await assertPhase(job, "quiet")
    }

    /// Asserts quiet_until = max(this round's request, in-flight bound) + window.
    private func assertQuietWindow(_ job: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let row = try await receipt(job)
        let requested = try XCTUnwrap(row.decode(column: "requested_at", as: Date?.self))
        let inFlight = try row.decode(column: "in_flight_until", as: Date?.self)
        let quietUntil = try XCTUnwrap(row.decode(column: "quiet_until", as: Date?.self))
        let expected = max(requested, inFlight ?? requested).addingTimeInterval(window)
        XCTAssertEqual(quietUntil.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001,
                       file: file, line: line)
    }

    /// Grant, deliver and store one event so the subject has a real profile.
    private func exposedSubject(_ fake: FakePostHog) async throws -> UUID {
        let revision = try await grant()
        try await queueEvent(revision)
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 1)
        await fake.ingest()
        return revision
    }

    /// A second capture is held in flight while the withdrawal is requested. The
    /// withdrawal waits on the purpose barrier; the capture is accepted by the
    /// provider but not yet stored.
    private func withdrawDuringInFlightCapture(_ fake: FakePostHog, revision: UUID) async throws {
        try await queueEvent(revision)
        await fake.holdCaptures()
        let dispatch = Task { await MeasurementDispatchService.run(app: self.app, on: self.app.db) }
        await fake.waitForHeldCapture()
        let probe = DelayedIngestionProbe()
        let withdrawal = Task { () -> HTTPStatus in
            let response = try await self.withdraw(revision)
            await probe.finish()
            return response.status
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let finishedEarly = await probe.finished
        XCTAssertFalse(finishedEarly, "the withdrawal must wait for the in-flight send's purpose barrier")
        await fake.releaseCaptures()
        let counts = await dispatch.value
        XCTAssertEqual(counts.delivered, 1)
        let status = try await withdrawal.value
        XCTAssertEqual(status, .ok)
    }

    // MARK: - Tests

    func testInFlightCaptureIsWaitedForThenCoveredByTheSingleDeletionAndVerifiedAfterTheQuietPeriod() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await grant()
        // The only exposure is a capture still in flight when withdrawal is requested.
        try await withdrawDuringInFlightCapture(fake, revision: revision)
        let (subjectID, opaque) = try await subject()
        try await assertBarrierRecordedInFlightSend(subjectID)
        let accepted = await fake.acceptedButNotStored()
        XCTAssertEqual(accepted, 1, "accepted before the barrier, not yet stored, no profile yet")

        let job = try await erasureJob(subjectID)
        let callsBefore = await fake.callCount()
        var counts = try await run(job)
        XCTAssertEqual(counts.pending, 1)
        let callsSettling = await fake.callCount()
        XCTAssertEqual(callsSettling, callsBefore, "no provider call before in-flight bound + window")
        let early = try await sql.raw("SELECT job_id FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        XCTAssertNil(early, "nothing is resolved while a capture may still be unwritten")

        // PostHog writes the capture within the window; that creates the profile.
        await fake.ingest()
        try await endSettlePeriod(subjectID)
        try await driveRoundToQuiet(job, fake)
        let survivors = await fake.storedCount(opaque)
        XCTAssertEqual(survivors, 0, "written before the one request, so inside PostHog's deletion")
        try await assertQuietWindow(job)
        let bound = try await sql.raw("SELECT send_in_flight_until FROM measurement_subjects WHERE id=\(bind:subjectID)")
            .first()!.decode(column: "send_in_flight_until", as: Date?.self)
        let recordedBound = try await receipt(job).decode(column: "in_flight_until", as: Date?.self)
        XCTAssertEqual(try XCTUnwrap(recordedBound).timeIntervalSince1970,
                       try XCTUnwrap(bound).timeIntervalSince1970, accuracy: 0.001)
        try await endQuietPeriod(job)
        counts = try await run(job)
        try await assertPhase(job, "quiet_events_absent")
        counts = try await run(job)
        XCTAssertEqual(counts.completed, 1)
        try await assertState(job, "completed")
        let recorded = try await passes(job)
        XCTAssertEqual(recorded, [
            Pass(round: 1, stage: "deletion", check: "deletion_status", outcome: "absent", count: nil),
            Pass(round: 1, stage: "deletion", check: "profile", outcome: "absent", count: nil),
            Pass(round: 1, stage: "quiet", check: "events", outcome: "absent", count: 0),
            Pass(round: 1, stage: "quiet", check: "profile", outcome: "absent", count: nil)])
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, 1)
    }

    func testDataStoredLaterThanTheWindowIsFoundByQuietCheckRedeletedAndThenCompleted() async throws {
        let fake = FakePostHog(sourceSemantics: false)
        wire(fake)
        let revision = try await exposedSubject(fake)
        try await withdrawDuringInFlightCapture(fake, revision: revision)
        let (subjectID, opaque) = try await subject()
        try await assertBarrierRecordedInFlightSend(subjectID)
        let pendingCaptures = await fake.acceptedButNotStored()
        XCTAssertEqual(pendingCaptures, 1, "accepted before the barrier, not yet stored")

        let job = try await erasureJob(subjectID)
        try await endSettlePeriod(subjectID)
        try await driveRoundToQuiet(job, fake)
        try await assertQuietWindow(job)

        // Ingestion lag longer than the window: stored only after the deletion completed.
        await fake.ingest()
        let stored = await fake.storedCount(opaque)
        XCTAssertEqual(stored, 1)

        let callsBefore = await fake.callCount()
        var counts = try await run(job)
        XCTAssertEqual(counts.pending, 1)
        let callsDuringWindow = await fake.callCount()
        XCTAssertEqual(callsDuringWindow, callsBefore, "no provider call inside the quiet period")

        try await endQuietPeriod(job)
        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1)
        try await assertPhase(job, "reresolving", "late data starts another round")

        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1)
        try await assertPhase(job, "resolved")
        try await assertRound(job, 2)
        try await driveRoundToQuiet(job, fake)
        try await assertQuietWindow(job)
        try await endQuietPeriod(job)
        counts = try await run(job)
        try await assertPhase(job, "quiet_events_absent")
        counts = try await run(job)
        XCTAssertEqual(counts.completed, 1)
        try await assertState(job, "completed")

        let final = try await receipt(job)
        let completedAt = try XCTUnwrap(final.decode(column: "completed_at", as: Date?.self))
        let quietUntil = try XCTUnwrap(final.decode(column: "quiet_until", as: Date?.self))
        XCTAssertGreaterThanOrEqual(completedAt, quietUntil)
        let recorded = try await passes(job)
        XCTAssertEqual(recorded, [
            Pass(round: 1, stage: "deletion", check: "deletion_status", outcome: "absent", count: nil),
            Pass(round: 1, stage: "deletion", check: "profile", outcome: "absent", count: nil),
            Pass(round: 1, stage: "quiet", check: "events", outcome: "present", count: 1),
            Pass(round: 2, stage: "deletion", check: "deletion_status", outcome: "absent", count: nil),
            Pass(round: 2, stage: "deletion", check: "profile", outcome: "absent", count: nil),
            Pass(round: 2, stage: "quiet", check: "events", outcome: "absent", count: 0),
            Pass(round: 2, stage: "quiet", check: "profile", outcome: "absent", count: nil)])
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, 2)
        let remaining = await fake.storedCount(opaque)
        XCTAssertEqual(remaining, 0)
    }

    func testSourceSemanticsLateEventsWithoutProfileEscalateWherePersonAbsenceAloneWouldComplete() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await exposedSubject(fake)
        try await withdrawDuringInFlightCapture(fake, revision: revision)
        let (subjectID, opaque) = try await subject()
        let job = try await erasureJob(subjectID)
        try await endSettlePeriod(subjectID)
        // Ingestion lag longer than the window. Stored after the request but before
        // PostHog removes the queued person:
        // attached to that person, outside the `_timestamp <= created_at` predicate.
        try await driveRoundToQuiet(job, fake, afterRequest: { await fake.ingest() })
        let survivors = await fake.storedCount(opaque)
        XCTAssertEqual(survivors, 1, "verified status and absent profile, yet one event survives")

        try await endQuietPeriod(job)
        var counts = try await run(job)
        XCTAssertEqual(counts.pending, 1)
        try await assertPhase(job, "reresolving")
        counts = try await run(job)
        XCTAssertEqual(counts.manualRequired, 1, "late events without a resolvable profile cannot be person-deleted")
        XCTAssertEqual(counts.completed, 0)
        try await assertState(job, "manual_required")
        let lastPass = try await passes(job).last
        XCTAssertEqual(lastPass, Pass(round: 1, stage: "quiet", check: "events", outcome: "present", count: 1))
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, 1)
    }

    func testSourceSemanticsRecreatedProfileIsRedeletedButStaleStatusEscalates() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await exposedSubject(fake)
        try await withdrawDuringInFlightCapture(fake, revision: revision)
        let (subjectID, opaque) = try await subject()
        let job = try await erasureJob(subjectID)
        try await endSettlePeriod(subjectID)
        try await driveRoundToQuiet(job, fake)
        let firstPerson = try await receipt(job).decode(column: "person_uuid", as: UUID.self)
        // Rounds are at least one ingestion-lag window (>= 1 h) apart in reality.
        await fake.ageDeletions(by: window)
        // Stored after the person was removed: the same derived person UUID returns.
        await fake.ingest()
        try await endQuietPeriod(job)
        try await run(job)
        try await assertPhase(job, "reresolving")
        try await run(job)
        try await assertRound(job, 2)
        let secondPerson = try await receipt(job).decode(column: "person_uuid", as: UUID.self)
        XCTAssertEqual(secondPerson, firstPerson, "the person UUID is derived from the distinct ID")
        try await run(job) // re-issued request; PostHog keeps the first deletion row
        try await assertPhase(job, "polling")
        await fake.processDeletions()
        let counts = try await run(job)
        XCTAssertEqual(counts.manualRequired, 1, "a status row from an earlier request cannot verify this round")
        try await assertState(job, "manual_required")
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, 2)
        let survivors = await fake.storedCount(opaque)
        XCTAssertEqual(survivors, 1)
    }

    func testRestartDuringQuietPeriodMakesNoProviderCallAndCompletesOnlyAfterTheWindow() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await exposedSubject(fake)
        let withdrawn = try await withdraw(revision)
        XCTAssertEqual(withdrawn.status, .ok)
        let (subjectID, _) = try await subject()
        let job = try await erasureJob(subjectID)
        let settling = await fake.callCount()
        try await run(job)
        try await restart(fake)
        let settled = try await run(job)
        XCTAssertEqual(settled.pending, 1)
        let afterSettleRestart = await fake.callCount()
        XCTAssertEqual(afterSettleRestart, settling, "no provider call while settling, across a restart")
        try await endSettlePeriod(subjectID)
        try await driveRoundToQuiet(job, fake)
        try await assertQuietWindow(job)
        let calls = await fake.callCount()

        try await restart(fake)
        var counts = try await run(job)
        XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        // A worker that died holding the lease mid-window resumes the same receipt.
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='leased',lease_token=\(bind:UUID()),
                lease_expires_at=NOW()-INTERVAL '1 minute' WHERE id=\(bind:job)
            """).run()
        try await restart(fake)
        counts = try await run(job)
        XCTAssertEqual(counts.pending, 1); XCTAssertEqual(counts.completed, 0)
        try await assertPhase(job, "quiet")
        let callsAfterRestarts = await fake.callCount()
        XCTAssertEqual(callsAfterRestarts, calls, "no provider call and no completion inside the window")

        try await endQuietPeriod(job)
        try await run(job)
        counts = try await run(job)
        XCTAssertEqual(counts.completed, 1)
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, 1, "restart never repeats the deletion request")
    }

    func testWithdrawalAfterClaimSuppressesTheSendAndKeepsTheLeaseBound() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await exposedSubject(fake)
        try await queueEvent(revision)
        // Claimed but not yet performing: the claim-time lease end is committed.
        let token = UUID()
        let expiry = Date().addingTimeInterval(MeasurementDispatchService.leaseDuration)
        try await sql.raw("""
            UPDATE measurement_dispatch_jobs SET state='leased',attempts=attempts+1,lease_token=\(bind:token),
                lease_expires_at=\(bind:expiry),send_window_until=\(bind:expiry)
            WHERE account_id=\(bind:userID) AND state='pending'
            """).run()
        let withdrawn = try await withdraw(revision)
        XCTAssertEqual(withdrawn.status, .ok)
        let captures = await fake.callCount("POST capture")
        let counts = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(counts.delivered, 0)
        let capturesAfter = await fake.callCount("POST capture")
        XCTAssertEqual(capturesAfter, captures, "no send starts after the barrier")
        let (subjectID, _) = try await subject()
        let bound = try await sql.raw("SELECT send_in_flight_until FROM measurement_subjects WHERE id=\(bind:subjectID)")
            .first()!.decode(column: "send_in_flight_until", as: Date?.self)
        XCTAssertEqual(try XCTUnwrap(bound).timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 0.001,
                       "a claimed attempt that might be in flight keeps its lease end as the bound")
        let state = try await sql.raw("""
            SELECT state FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID) AND delivered_at IS NULL
            """).first()?.decode(column: "state", as: String.self)
        XCTAssertEqual(state, "uncertain")
    }

    func testBoundedRoundsEscalateToManualWithEveryPassRetained() async throws {
        let fake = FakePostHog(sourceSemantics: false)
        wire(fake)
        let revision = try await exposedSubject(fake)
        let withdrawn = try await withdraw(revision)
        XCTAssertEqual(withdrawn.status, .ok)
        let (subjectID, opaque) = try await subject()
        let job = try await erasureJob(subjectID)
        try await endSettlePeriod(subjectID)
        for round in 1...PostHogErasureService.maximumRounds {
            if round > 1 {
                try await run(job)
                try await assertRound(job, round)
            }
            try await driveRoundToQuiet(job, fake)
            await fake.storeLateEvent(distinctID: opaque)
            try await endQuietPeriod(job)
            let counts = try await run(job)
            if round < PostHogErasureService.maximumRounds {
                XCTAssertEqual(counts.pending, 1)
                try await assertPhase(job, "reresolving")
            } else {
                XCTAssertEqual(counts.manualRequired, 1)
                XCTAssertEqual(counts.completed, 0)
            }
        }
        try await assertState(job, "manual_required")
        let recorded = try await passes(job)
        XCTAssertEqual(recorded.count, 3 * PostHogErasureService.maximumRounds)
        XCTAssertEqual(recorded.filter { $0.outcome == "present" }.count, PostHogErasureService.maximumRounds)
        let deletes = await fake.callCount("POST bulk_delete")
        XCTAssertEqual(deletes, PostHogErasureService.maximumRounds)
        let later = try await run(job)
        XCTAssertEqual(later.completed + later.pending + later.manualRequired, 0, "manual_required is never re-claimed")
    }

    func testQueuedResponseAndVerifiedStatusNeverCompleteAndUnverifiableEventsEscalate() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        let revision = try await exposedSubject(fake)
        let withdrawn = try await withdraw(revision)
        XCTAssertEqual(withdrawn.status, .ok)
        let (subjectID, _) = try await subject()
        let job = try await erasureJob(subjectID)
        try await endSettlePeriod(subjectID)
        try await run(job)
        let queued = try await run(job)
        XCTAssertEqual(queued.completed, 0, "a 202 queued response is not a completed deletion")
        let acknowledged = try await receipt(job).decode(column: "queue_acknowledged_at", as: Date?.self)
        XCTAssertNotNil(acknowledged)
        await fake.processDeletions()
        try await run(job)
        let profile = try await run(job)
        XCTAssertEqual(profile.completed, 0, "verified status plus absent profile only starts the quiet period")
        try await assertState(job, "pending")

        await fake.setQueryStatus(403) // key without query access
        try await endQuietPeriod(job)
        let refused = try await run(job)
        XCTAssertEqual(refused.manualRequired, 1)
        XCTAssertEqual(refused.completed, 0)
        let lastPass = try await passes(job).last
        XCTAssertEqual(lastPass,
                       Pass(round: 1, stage: "quiet", check: "events", outcome: "unverifiable", count: nil))
    }

    func testAccountDeletionStaysPendingThroughTheQuietPeriodAndSettlesAfterIt() async throws {
        let fake = FakePostHog(sourceSemantics: true)
        wire(fake)
        _ = try await exposedSubject(fake)
        let (subjectID, opaque) = try await subject()
        let deletionJob = UUID()
        deletionJobs.append(deletionJob)
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:deletionJob),\(bind:userID),\(bind:SHA256Hasher.hash(token: "delayed-\(deletionJob)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable')
            """).run()
        try await app.db.transaction { tx in
            let txSQL = try VerifiedIdentityService.sql(tx)
            _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:self.userID) FOR UPDATE").first()
            try await MeasurementPrivacyService.eraseAccount(self.userID, accountDeletionJobID: deletionJob,
                                                             now: Date(), on: tx)
        }
        // The outbox is gone, but the subject kept its in-flight bound.
        let outbox = try await sql.raw("SELECT id FROM measurement_dispatch_jobs WHERE account_id=\(bind:userID)").first()
        XCTAssertNil(outbox)
        let bound = try await sql.raw("SELECT send_in_flight_until FROM measurement_subjects WHERE id=\(bind:subjectID)")
            .first()!.decode(column: "send_in_flight_until", as: Date?.self)
        XCTAssertNotNil(bound)

        func deletionState() async throws -> String {
            try await sql.raw("SELECT measurement_erasure_state FROM account_deletion_jobs WHERE id=\(bind:deletionJob)")
                .first()!.decode(column: "measurement_erasure_state", as: String.self)
        }
        let job = try await erasureJob(subjectID)
        let settling = try await run(job)
        XCTAssertEqual(settling.pending, 1)
        var settled = try await deletionState()
        XCTAssertEqual(settled, "pending", "account deletion cannot settle before the deletion request")
        try await endSettlePeriod(subjectID)
        try await driveRoundToQuiet(job, fake)
        try await assertQuietWindow(job)
        settled = try await deletionState()
        XCTAssertEqual(settled, "pending", "account deletion cannot settle inside the quiet period")
        try await endQuietPeriod(job)
        try await run(job)
        settled = try await deletionState()
        XCTAssertEqual(settled, "pending")
        let counts = try await run(job)
        XCTAssertEqual(counts.completed, 1)
        settled = try await deletionState()
        XCTAssertEqual(settled, "completed")
        let remaining = await fake.storedCount(opaque)
        XCTAssertEqual(remaining, 0)
    }

    func testMigrationNamesReceiptChecksRequiresAQuietPeriodAndRefusesRollback() async throws {
        let names = try await sql.raw("""
            SELECT conname FROM pg_constraint
            WHERE conrelid='measurement_posthog_erasure_receipts'::regclass AND contype='c' ORDER BY conname
            """).all().map { try $0.decode(column: "conname", as: String.self) }
        XCTAssertEqual(names, ["posthog_erasure_receipt_completed", "posthog_erasure_receipt_completed_after_quiet",
                               "posthog_erasure_receipt_events_verified", "posthog_erasure_receipt_phase",
                               "posthog_erasure_receipt_project", "posthog_erasure_receipt_quiet",
                               "posthog_erasure_receipt_requested", "posthog_erasure_receipt_round"])
        let subjectID = UUID(), job = UUID()
        try await sql.raw("""
            INSERT INTO measurement_subjects(id,account_id,purpose,opaque_subject,state,created_at,revoked_at)
            VALUES (\(bind:subjectID),\(bind:userID),'productAnalytics',\(bind:UUID()),'revoked',NOW(),NOW())
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_erasure_jobs(id,account_id,subject_id,destination,state,available_at,created_at)
            VALUES (\(bind:job),\(bind:userID),\(bind:subjectID),'posthog','pending',NOW(),NOW())
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_posthog_erasure_receipts(job_id,project_id,person_uuid,phase,resolved_at,requested_at,
                provider_created_at,events_verified_at)
            VALUES (\(bind:job),'123456',\(bind:UUID()),'events_verified',NOW(),NOW(),NOW(),NOW())
            """).run()
        for change in ["phase='completed',completed_at=NOW(),profile_absent_at=NOW()",
                       "phase='quiet',profile_absent_at=NOW()",
                       "phase='completed',completed_at=NOW()-INTERVAL '1 hour',profile_absent_at=NOW(),quiet_until=NOW()",
                       "round=11"] {
            do {
                try await sql.raw("UPDATE measurement_posthog_erasure_receipts SET \(unsafeRaw: change) WHERE job_id=\(bind:job)").run()
                XCTFail("constraint accepted: \(change)")
            } catch {}
        }
        try await sql.raw("""
            UPDATE measurement_posthog_erasure_receipts SET phase='completed',completed_at=NOW(),
                profile_absent_at=NOW()-INTERVAL '2 hours',quiet_until=NOW()-INTERVAL '1 hour' WHERE job_id=\(bind:job)
            """).run()
        do {
            try await AddPostHogDelayedIngestionControls().revert(on: app.db)
            XCTFail("rollback must be refused")
        } catch {}
    }
}

private actor DelayedIngestionProbe {
    private(set) var finished = false
    func finish() { finished = true }
}

/// Stateful synthetic PostHog. Only the request paths the adapter uses exist; every
/// other request is a 404. No network, credentials or customer data.
private actor FakePostHog {
    private struct Accepted { let distinctID: String }
    private struct Stored { let distinctID: String; let personID: UUID; let writtenAt: Date }
    private struct Person { let uuid: UUID; let distinctID: String; var queued: Bool }
    private struct Deletion { let person: UUID; let createdAt: Date; var verifiedAt: Date? }

    let sourceSemantics: Bool
    private var accepted: [Accepted] = []
    private var stored: [Stored] = []
    private var persons: [Person] = []
    private var deletions: [Deletion] = []
    private var log: [String] = []
    private var holding = false
    private var held = 0
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var queryStatus = 200

    init(sourceSemantics: Bool) { self.sourceSemantics = sourceSemantics }

    nonisolated var captureTransport: MeasurementDispatchService.Transport {
        { uri, _, body in await self.capture(uri, body) }
    }
    nonisolated var apiTransport: PostHogErasureService.Transport {
        { method, uri, _, body in await self.api(method, uri, body) }
    }

    func callCount(_ prefix: String = "") -> Int { log.filter { $0.hasPrefix(prefix) }.count }
    func storedCount(_ distinctID: String) -> Int { stored.filter { $0.distinctID == distinctID }.count }
    func acceptedButNotStored() -> Int { accepted.count }
    func setQueryStatus(_ status: Int) { queryStatus = status }

    func holdCaptures() { holding = true }
    func waitForHeldCapture() async {
        if held > 0 { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
    func releaseCaptures() {
        holding = false
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }

    private func capture(_ uri: URI, _ body: Data) async -> MeasurementDispatchService.Reply {
        log.append("POST capture")
        guard uri.string == "https://eu.i.posthog.com/capture/",
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let properties = object["properties"] as? [String: Any],
              let distinctID = properties["distinct_id"] as? String,
              properties["$process_person_profile"] as? Bool == true else { return .init(status: 400, retryAfter: nil) }
        // The provider has the bytes; storage happens later, in `ingest`.
        accepted.append(.init(distinctID: distinctID))
        if holding {
            held += 1
            heldWaiters.forEach { $0.resume() }; heldWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .init(status: 200, retryAfter: nil)
    }

    /// The ingestion pipeline catching up: accepted captures are stored now,
    /// attached to the distinct ID's current person, or to a new one.
    func ingest() {
        let now = Date()
        for event in accepted {
            let person = persons.first { $0.distinctID == event.distinctID } ?? createPerson(event.distinctID)
            stored.append(.init(distinctID: event.distinctID, personID: person.uuid, writtenAt: now))
        }
        accepted.removeAll()
    }

    func storeLateEvent(distinctID: String) {
        accepted.append(.init(distinctID: distinctID))
        ingest()
    }

    private func createPerson(_ distinctID: String) -> Person {
        let person = Person(uuid: sourceSemantics ? Self.derived(distinctID) : UUID(), distinctID: distinctID, queued: false)
        persons.append(person)
        return person
    }

    private static func derived(_ distinctID: String) -> UUID {
        let hex = Array(SHA256Hasher.hash(token: "synthetic-posthog-person:" + distinctID).prefix(32))
        let text = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16]) + "-"
            + String(hex[16..<20]) + "-" + String(hex[20..<32])
        return UUID(uuidString: text)!
    }

    func ageDeletions(by seconds: TimeInterval) {
        deletions = deletions.map { .init(person: $0.person, createdAt: $0.createdAt.addingTimeInterval(-seconds),
                                          verifiedAt: $0.verifiedAt?.addingTimeInterval(-seconds)) }
        stored = stored.map { .init(distinctID: $0.distinctID, personID: $0.personID,
                                    writtenAt: $0.writtenAt.addingTimeInterval(-seconds)) }
    }

    /// PostHog's queued person removal and its event-deletion job, run to completion.
    func processDeletions() {
        let now = Date()
        persons.removeAll { $0.queued }
        for index in deletions.indices where deletions[index].verifiedAt == nil {
            let deletion = deletions[index]
            stored.removeAll { $0.personID == deletion.person && $0.writtenAt <= deletion.createdAt }
            deletions[index].verifiedAt = now
        }
    }

    private func reply(_ status: Int, _ object: [String: Any]) -> PostHogErasureService.Reply {
        .init(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func parameter(_ name: String, _ uri: URI) -> String? {
        (uri.query ?? "").split(separator: "&").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0] == name ? String(parts[1]) : nil
        }.first
    }

    private func api(_ method: HTTPMethod, _ uri: URI, _ body: Data?) -> PostHogErasureService.Reply {
        let prefix = "https://eu.posthog.com/api/projects/123456/"
        guard uri.string.hasPrefix(prefix) else { log.append("\(method.rawValue) other"); return reply(404, [:]) }
        let path = String(uri.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        switch (method, path) {
        case (.GET, "/api/projects/123456/persons/deletion_status/"):
            log.append("GET deletion_status")
            let person = parameter("person_uuid", uri)
            let rows: [[String: Any]] = deletions.filter { $0.person.uuidString.lowercased() == person }.map {
                ["person_uuid": $0.person.uuidString.lowercased(), "created_at": formatter.string(from: $0.createdAt),
                 "status": $0.verifiedAt == nil ? "pending" : "completed",
                 "delete_verified_at": $0.verifiedAt.map { formatter.string(from: $0) } ?? NSNull()]
            }
            return reply(200, ["results": rows, "next": NSNull()])
        case (.GET, "/api/projects/123456/persons/"):
            log.append("GET persons")
            let distinctID = parameter("distinct_id", uri)
            let rows: [[String: Any]] = persons.filter { $0.distinctID == distinctID }.map {
                ["uuid": $0.uuid.uuidString.lowercased(), "distinct_ids": [$0.distinctID]]
            }
            return reply(200, ["results": rows, "next": NSNull()])
        case (.POST, "/api/projects/123456/persons/bulk_delete/"):
            log.append("POST bulk_delete")
            guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let ids = object["distinct_ids"] as? [String], object["delete_events"] as? Bool == true
            else { return reply(400, [:]) }
            let matched = persons.indices.filter { ids.contains(persons[$0].distinctID) }
            let now = Date()
            for index in matched {
                persons[index].queued = true
                let uuid = persons[index].uuid
                // PostHog keeps one person event deletion per UUID (ignore_conflicts).
                if !deletions.contains(where: { $0.person == uuid }) {
                    deletions.append(.init(person: uuid, createdAt: now, verifiedAt: nil))
                } else if !sourceSemantics {
                    deletions.removeAll { $0.person == uuid }
                    deletions.append(.init(person: uuid, createdAt: now, verifiedAt: nil))
                }
            }
            return reply(202, ["persons_found": matched.count, "persons_deleted": 0,
                               "persons_queued_for_deletion": matched.count,
                               "events_queued_for_deletion": !matched.isEmpty,
                               "recordings_queued_for_deletion": false, "deletion_errors": []])
        case (.POST, "/api/projects/123456/query/"):
            log.append("POST query")
            guard queryStatus == 200 else { return reply(queryStatus, ["detail": "synthetic refusal"]) }
            guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  object["refresh"] as? String == "force_blocking",
                  let query = object["query"] as? [String: Any], query["kind"] as? String == "HogQLQuery",
                  let text = query["query"] as? String,
                  text.hasPrefix("SELECT count() FROM events WHERE distinct_id = '"), text.hasSuffix("'")
            else { return reply(400, [:]) }
            let distinctID = String(text.dropFirst("SELECT count() FROM events WHERE distinct_id = '".count).dropLast())
            return reply(200, ["results": [[storedCount(distinctID)]], "columns": ["count()"], "is_cached": false])
        default:
            log.append("\(method.rawValue) other")
            return reply(404, [:])
        }
    }
}
