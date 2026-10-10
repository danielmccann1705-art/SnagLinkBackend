@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// LinkedIn erasure resolution (outputs/measurement-2026-10-07/LINKEDIN-ERASURE-RESOLUTION.md).
/// LinkedIn documents no deletion of a conversion once sent, so withdrawal or account deletion must end in
/// the named terminal state `provider_retention_bound` (never `completed`, never an indefinite
/// `manual_required`): sends stopped, our copies gone, the basis and the age-out date recorded. Production
/// LinkedIn dispatch stays refused without the accepted resolution. Real PostgreSQL; synthetic accounts;
/// injected transports only, and no LinkedIn request is ever made.
final class LinkedInErasureResolutionTests: XCTestCase {
    private var app: Application!
    private var accounts: [UUID] = []
    private var dispatch: LinkedInErasureHTTPRecorder!
    private var erasure: LinkedInErasureHTTPRecorder!
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let day: TimeInterval = 86_400
    private static let flags = ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]
    private static let receiptTables = ["measurement_consent_events", "measurement_permission_current", "measurement_subjects",
                                        "measurement_erasure_jobs", "measurement_product_events", "measurement_device_bindings"]

    private struct Granted { let id: UUID; let token: String; let installation: UUID; let revision: UUID; let subject: UUID }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        app.storage[AccountDeletionTestActivation.self] = true
        // Synthetic LinkedIn settings, so a job that were eligible would really reach the (recording) transport.
        configureDispatch(environment: .sandbox, accepted: nil)
        dispatch = LinkedInErasureHTTPRecorder()
        erasure = LinkedInErasureHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = dispatch.dispatchTransport
        app.storage[MeasurementErasureService.TransportKey.self] = erasure.erasureTransport
        accounts = []
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
        try await FeatureFlag(key: "crossCompanyAdsEnabled", enabled: true).save(on: app.db)
        try await FeatureFlag(key: "linkedInConversionsEnabled", enabled: true).save(on: app.db)
    }

    override func tearDown() async throws {
        if let app {
            let sql = try VerifiedIdentityService.sql(app.db)
            for account in accounts {
                for statement in [
                    "DELETE FROM measurement_dispatch_jobs WHERE account_id=$1",
                    "DELETE FROM measurement_product_events WHERE account_id=$1",
                    "DELETE FROM measurement_device_bindings WHERE account_id=$1",
                    "DELETE FROM measurement_erasure_jobs WHERE account_id=$1",
                    "DELETE FROM measurement_att_assertions WHERE account_id=$1",
                    "DELETE FROM measurement_permission_current WHERE account_id=$1",
                    "DELETE FROM measurement_consent_events WHERE account_id=$1",
                    "DELETE FROM measurement_subjects WHERE account_id=$1",
                    "DELETE FROM user_identities WHERE user_id=$1"] {
                    try? await sql.raw("\(unsafeRaw: statement.replacingOccurrences(of: "$1", with: "'\(account.uuidString.lowercased())'"))").run()
                }
            }
            try? await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
            try await app.asyncShutdown()
        }
        app = nil; dispatch = nil; erasure = nil; accounts = []
    }

    // MARK: - Helpers

    private func configureDispatch(environment: LinkedInConversion.Environment, accepted: String?) {
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: nil, postHogEnvironment: nil, singularURL: nil, singularAPIKey: nil,
            linkedInAccessToken: "synthetic-linkedin-token", linkedInSignupRule: "31231706",
            linkedInSubscriptionRule: "31231714", linkedInEnvironment: environment,
            linkedInErasureResolutionAccepted: accepted)
    }

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }

    private func request(_ method: HTTPMethod, _ path: String, token: String,
                         object: [String: Any]) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.contentType = .json
            req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func put(_ token: String, decision: String, expected: UUID?, installation: UUID) async throws -> [String: Any] {
        var body: [String: Any] = ["requestId": UUID().uuidString, "decision": decision, "occurredAt": date(),
                                   "noticeVersion": MeasurementNotice.current]
        if let expected { body["expectedRevision"] = expected.uuidString }
        if decision == "granted" {
            body["installationId"] = installation.uuidString
            body["attStatus"] = "authorized"
            body["attAssertedAt"] = date()
        }
        let response = try await request(.PUT, "api/v2/measurement/permissions/crossCompanyAds", token: token, object: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        return try XCTUnwrap((values["permissions"] as? [[String: Any]])?.first { $0["purpose"] as? String == "crossCompanyAds" })
    }

    /// An account with an active cross-company subject (consent + authorised ATT on one installation).
    private func granted(_ label: String) async throws -> Granted {
        let user = User(appleUserId: nil, email: "\(label)-\(UUID().uuidString.lowercased())@example.test",
                        name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        let id = try user.requireID()
        accounts.append(id)
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: id,
            authVersion: user.authVersion, authenticatedAt: Date()))
        let installation = UUID()
        let entry = try await put(token, decision: "granted", expected: nil, installation: installation)
        let revision = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(entry["revision"] as? String)))
        let subject = try await sql.raw("""
            SELECT subject_id FROM measurement_permission_current WHERE account_id=\(bind:id) AND purpose='crossCompanyAds'
            """).first()!.decode(column: "subject_id", as: UUID.self)
        return .init(id: id, token: token, installation: installation, revision: revision, subject: subject)
    }

    /// A synthetic SHA-256 standing for a verified email hash (64 lowercase hex characters).
    private func syntheticHash() -> String { SHA256Hasher.hash(token: "linkedin-erasure-\(UUID().uuidString)") }

    /// One LinkedIn conversion already received by LinkedIn (HTTP 201 recorded as delivered, payload
    /// cleared as dispatch does), sent an hour ago.
    @discardableResult
    private func delivered(_ account: Granted, sentAt: Date) async throws -> UUID {
        let id = UUID()
        try await sql.raw("""
            INSERT INTO measurement_dispatch_jobs
                (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,installation_id,state,attempts,
                 available_at,payload,created_at,delivered_at,last_send_started_at,send_window_until)
            VALUES (\(bind:id),'linkedin','signupFact',\(bind:UUID()),\(bind:account.id),\(bind:account.subject),
                    \(bind:account.revision),\(bind:account.installation),'delivered',1,\(bind:sentAt.addingTimeInterval(-60)),NULL,
                    \(bind:sentAt.addingTimeInterval(-60)),\(bind:sentAt),\(bind:sentAt.addingTimeInterval(-5)),
                    \(bind:sentAt.addingTimeInterval(50)))
            """).run()
        return id
    }

    /// One LinkedIn conversion still queued, holding our copy of the hashed email and the amount.
    @discardableResult
    private func queued(_ account: Granted, hash: String, sourceKind: String = "revenueCatLifecycle",
                        availableAt: Date = Date().addingTimeInterval(86_400)) async throws -> UUID {
        let id = UUID()
        let payload = sourceKind == "signupFact"
            ? "{\"event\":\"account_created\",\"emailSha256\":\"\(hash)\"}"
            : "{\"emailSha256\":\"\(hash)\",\"attContinuityId\":\"\(UUID().uuidString)\",\"amount\":\"14.99\",\"currency\":\"GBP\"}"
        try await sql.raw("""
            INSERT INTO measurement_dispatch_jobs
                (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,installation_id,state,attempts,
                 available_at,payload,created_at)
            VALUES (\(bind:id),'linkedin',\(bind:sourceKind),\(bind:UUID()),\(bind:account.id),\(bind:account.subject),
                    \(bind:account.revision),\(bind:account.installation),'pending',0,\(bind:availableAt),
                    CAST(\(bind:payload) AS jsonb),NOW())
            """).run()
        return id
    }

    private func deleteThroughTheService(_ account: UUID) async throws {
        let reference = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        _ = try await AccountDeletionService.request(userID: account,
            body: .init(confirmation: "DELETE", receiptReference: reference), app: app)
    }

    private func linkedInJob(_ subject: UUID) async throws -> UUID {
        try await sql.raw("""
            SELECT id FROM measurement_erasure_jobs WHERE subject_id=\(bind:subject) AND destination='linkedin'
            """).first()!.decode(column: "id", as: UUID.self)
    }

    private func state(_ job: UUID) async throws -> String {
        try await sql.raw("SELECT state FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!
            .decode(column: "state", as: String.self)
    }

    /// Runs the erasure worker until this job leaves the open states, claiming this job first (other suites'
    /// leftovers in the shared disposable database are not this test's business).
    @discardableResult
    private func runErasure(_ job: UUID) async throws -> MeasurementErasureService.Counts {
        var total = MeasurementErasureService.Counts()
        for _ in 0..<4 {
            try await sql.raw("""
                UPDATE measurement_erasure_jobs SET available_at='2000-01-01T00:00:00Z'
                WHERE id=\(bind:job) AND state IN ('pending','failing')
                """).run()
            let counts = await MeasurementErasureService.run(app: app, limit: 1, on: app.db)
            total.completed += counts.completed; total.retrying += counts.retrying
            total.manualRequired += counts.manualRequired; total.pending += counts.pending
            total.providerRetentionBound += counts.providerRetentionBound
            if !["pending", "failing", "leased", "manual_required"].contains(try await state(job)) { break }
        }
        return total
    }

    private func count(_ query: String, _ account: UUID) async throws -> Int {
        let clause = query.hasSuffix(" AND") ? query + " account_id=" : query + " WHERE account_id="
        return try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: clause)\(bind:account)").first()!
            .decode(column: "n", as: Int.self)
    }

    private func receipts(_ account: UUID) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for table in Self.receiptTables { result[table] = try await count(table, account) }
        return result
    }

    private func sentWith(_ hash: String) -> Int { dispatch.bodies.filter { $0.contains(hash) }.count }

    // MARK: - Account deletion with sent conversions reaches the terminal state

    func testAccountDeletionWithSentLinkedInConversionsEndsProviderRetentionBoundNotCompletedOrManual() async throws {
        let account = try await granted("li-erasure-delete")
        let sentAt = Date().addingTimeInterval(-3600)
        try await delivered(account, sentAt: sentAt)
        let hash = syntheticHash()
        try await queued(account, hash: hash)

        try await deleteThroughTheService(account.id)
        // Future sends stopped and our own copies gone, at once.
        let outbox = try await count("measurement_dispatch_jobs", account.id)
        XCTAssertEqual(outbox, 0, "deletion removes every outbox row, including the hashed email and amount")
        let active = try await count("measurement_subjects WHERE state='active' AND", account.id)
        XCTAssertEqual(active, 0)
        let job = try await linkedInJob(account.subject)
        let initial = try await state(job)
        XCTAssertEqual(initial, "pending", "a delivered LinkedIn conversion needs a provider decision")
        let deletionJob = try await sql.raw("SELECT id,measurement_erasure_state FROM account_deletion_jobs WHERE user_id=\(bind:account.id)").first()!
        let deletionID = try deletionJob.decode(column: "id", as: UUID.self)
        XCTAssertEqual(try deletionJob.decode(column: "measurement_erasure_state", as: String.self), "pending")

        let counts = try await runErasure(job)
        XCTAssertEqual(counts.providerRetentionBound, 1)
        XCTAssertEqual(counts.manualRequired, 0)
        let row = try await sql.raw("""
            SELECT state,completed_at,last_error_kind,provider_retention_basis,provider_last_send_by,
                   provider_copy_expires_at,retention_bound_at FROM measurement_erasure_jobs WHERE id=\(bind:job)
            """).first()!
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "provider_retention_bound")
        XCTAssertNil(try row.decode(column: "completed_at", as: Date?.self), "never recorded as a completed deletion")
        XCTAssertNil(try row.decode(column: "last_error_kind", as: String?.self))
        XCTAssertEqual(try row.decode(column: "provider_retention_basis", as: String?.self), LinkedInErasureResolution.version)
        let lastSendBy = try XCTUnwrap(try row.decode(column: "provider_last_send_by", as: Date?.self))
        let expires = try XCTUnwrap(try row.decode(column: "provider_copy_expires_at", as: Date?.self))
        XCTAssertNotNil(try row.decode(column: "retention_bound_at", as: Date?.self))
        XCTAssertGreaterThanOrEqual(lastSendBy.timeIntervalSince1970, sentAt.addingTimeInterval(50).timeIntervalSince1970 - 1,
                                    "the bound covers the delivered send's whole window")
        XCTAssertEqual(expires.timeIntervalSince(lastSendBy), LinkedInErasureResolution.providerRetention, accuracy: 1)
        XCTAssertNotEqual(LinkedInErasureResolution.terminalState, "completed")

        let calls = erasure.bodies.count + dispatch.bodies.filter { $0.contains(hash) }.count
        XCTAssertEqual(calls, 0, "no LinkedIn (or other provider) request was made for this erasure")
        let deletionState = try await sql.raw("SELECT measurement_erasure_state FROM account_deletion_jobs WHERE id=\(bind:deletionID)")
            .first()!.decode(column: "measurement_erasure_state", as: String.self)
        XCTAssertEqual(deletionState, "provider_retention_bound")
        let report = try await MeasurementReconciliation.report(on: app.db)
        XCTAssertNil(report.openErasureJobs.first { $0.erasureJobId == job }, "nothing for a person to do")

        // The core deletion can now finish; its measurement state stays honestly labelled.
        let token = UUID()
        try await sql.raw("""
            UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:token),
                lease_expires_at=clock_timestamp()+INTERVAL '300 seconds',database_cleanup_state='completed',
                object_cleanup_state='completed',apple_revocation_state='not_applicable',revenuecat_state='not_requested'
            WHERE id=\(bind:deletionID)
            """).run()
        let finished = try await AccountDeletionWorker.finish(
            .init(id: deletionID, userID: account.id, token: token, attempt: 1), on: app.db)
        XCTAssertEqual(finished, "completed")
        let after = try await sql.raw("SELECT measurement_erasure_state,last_error_kind FROM account_deletion_jobs WHERE id=\(bind:deletionID)").first()!
        XCTAssertEqual(try after.decode(column: "measurement_erasure_state", as: String.self), "provider_retention_bound")
        XCTAssertNil(try after.decode(column: "last_error_kind", as: String?.self))
    }

    func testTheOldIndefiniteStatesNoLongerHoldALinkedInJob() async throws {
        // A LinkedIn job an earlier image left manual_required, and one whose lease expired, both reach the
        // terminal state without a person: the step never calls LinkedIn, so neither was an ambiguous request.
        let first = try await granted("li-erasure-legacy")
        try await delivered(first, sentAt: Date().addingTimeInterval(-7200))
        try await deleteThroughTheService(first.id)
        let manual = try await linkedInJob(first.subject)
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='manual_required',last_error_kind='provider_configuration_required'
            WHERE id=\(bind:manual)
            """).run()
        try await sql.raw("UPDATE account_deletion_jobs SET measurement_erasure_state='manual_required' WHERE user_id=\(bind:first.id)").run()
        let second = try await granted("li-erasure-lease")
        try await delivered(second, sentAt: Date().addingTimeInterval(-7200))
        try await deleteThroughTheService(second.id)
        let leased = try await linkedInJob(second.subject)
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='leased',lease_token=\(bind:UUID()),
                lease_expires_at=NOW()-INTERVAL '1 minute' WHERE id=\(bind:leased)
            """).run()

        try await runErasure(manual)
        try await runErasure(leased)
        for job in [manual, leased] {
            let value = try await state(job)
            XCTAssertEqual(value, "provider_retention_bound")
        }
        let open = try await sql.raw("""
            SELECT count(*) AS n FROM measurement_erasure_jobs
            WHERE account_id IN (\(bind:first.id),\(bind:second.id)) AND state IN ('manual_required','failing','pending','leased')
            """).first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(open, 0)
        let deletion = try await sql.raw("SELECT measurement_erasure_state FROM account_deletion_jobs WHERE user_id=\(bind:first.id)")
            .first()!.decode(column: "measurement_erasure_state", as: String.self)
        XCTAssertEqual(deletion, "provider_retention_bound")
    }

    // MARK: - Withdrawal suppresses future sends and removes our copies

    func testWithdrawalSuppressesQueuedSendsScrubsOurCopiesAndDoesNotBlockARegrant() async throws {
        let account = try await granted("li-erasure-withdraw")
        let sent = try await delivered(account, sentAt: Date().addingTimeInterval(-600))
        let hash = syntheticHash()
        let pending = try await queued(account, hash: hash, sourceKind: "signupFact", availableAt: Date())
        try await sql.raw("UPDATE measurement_dispatch_jobs SET payload='{\"emailSha256\":\"\(unsafeRaw: hash)\"}'::jsonb WHERE id=\(bind:sent)").run()

        let withdrawn = try await put(account.token, decision: "withdrawn", expected: account.revision, installation: account.installation)
        XCTAssertEqual(withdrawn["effective"] as? Bool, false)
        let rows = try await sql.raw("""
            SELECT id,state,payload::text AS payload FROM measurement_dispatch_jobs WHERE account_id=\(bind:account.id)
            """).all()
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(try row.decode(column: "payload", as: String?.self), "no copy of the hashed email or amount remains")
            let id = try row.decode(column: "id", as: UUID.self)
            XCTAssertEqual(try row.decode(column: "state", as: String.self), id == pending ? "suppressed" : "delivered")
        }
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertEqual(sentWith(hash), 0, "nothing queued before the withdrawal is sent afterwards")

        let job = try await linkedInJob(account.subject)
        try await runErasure(job)
        let value = try await state(job)
        XCTAssertEqual(value, "provider_retention_bound")

        // A settled LinkedIn erasure is not "erasure pending": the person can turn the choice on again,
        // under a new subject; the old job keeps its terminal record.
        let withdrawnRevision = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(withdrawn["revision"] as? String)))
        let regrant = try await put(account.token, decision: "granted", expected: withdrawnRevision, installation: account.installation)
        XCTAssertEqual(regrant["erasurePending"] as? Bool, false)
        let newSubject = try await sql.raw("""
            SELECT id FROM measurement_subjects WHERE account_id=\(bind:account.id) AND purpose='crossCompanyAds' AND state='active'
            """).first()?.decode(column: "id", as: UUID.self)
        XCTAssertNotNil(newSubject)
        XCTAssertNotEqual(newSubject, account.subject)
        let kept = try await state(job)
        XCTAssertEqual(kept, "provider_retention_bound")
    }

    // MARK: - Consent cleanup

    func testReceiptsStayUntilTheLinkedInCopyIsDueToAgeOutThenThirtyDays() async throws {
        let account = try await granted("li-erasure-cleanup")
        try await delivered(account, sentAt: Date().addingTimeInterval(-3600))
        try await deleteThroughTheService(account.id)
        let job = try await linkedInJob(account.subject)
        try await runErasure(job)
        let expires = try await sql.raw("SELECT provider_copy_expires_at FROM measurement_erasure_jobs WHERE id=\(bind:job)")
            .first()!.decode(column: "provider_copy_expires_at", as: Date.self)
        let kept = try await receipts(account.id)
        XCTAssertGreaterThan(kept["measurement_consent_events"] ?? 0, 0)

        let month = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(31 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(month.providerRetentionBound, 1, "kept, counted, and not blocked")
        let afterMonth = try await receipts(account.id)
        XCTAssertEqual(afterMonth, kept, "the consent receipt stays while LinkedIn may still hold the conversion")
        _ = try await MeasurementConsentRetention.cleanup(now: expires.addingTimeInterval(29 * day), limit: 5_000, on: app.db)
        let early = try await receipts(account.id)
        XCTAssertEqual(early, kept, "the 30 days run from the age-out date")

        let due = try await MeasurementConsentRetention.cleanup(now: expires.addingTimeInterval(31 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(due.accounts, 1)
        let gone = try await receipts(account.id)
        XCTAssertEqual(Set(gone.values), [0], "\(gone)")
        let core = try await sql.raw("SELECT count(*) AS n FROM account_deletion_jobs WHERE user_id=\(bind:account.id)")
            .first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(core, 1, "the core deletion record is not part of this lifecycle")
    }

    func testAManualRequiredPostHogJobStillBlocksCleanupBesideASettledLinkedInJob() async throws {
        let account = try await granted("li-erasure-mixed")
        try await delivered(account, sentAt: Date().addingTimeInterval(-3600))
        try await deleteThroughTheService(account.id)
        let job = try await linkedInJob(account.subject)
        try await runErasure(job)
        let expires = try await sql.raw("SELECT provider_copy_expires_at FROM measurement_erasure_jobs WHERE id=\(bind:job)")
            .first()!.decode(column: "provider_copy_expires_at", as: Date.self)
        // A product-analytics subject whose PostHog erasure needs a person.
        let subject = UUID()
        try await sql.raw("""
            INSERT INTO measurement_subjects(id,account_id,purpose,opaque_subject,state,created_at,revoked_at)
            VALUES (\(bind:subject),\(bind:account.id),'productAnalytics',\(bind:UUID()),'revoked',NOW(),NOW())
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_erasure_jobs(id,account_id,subject_id,destination,state,available_at,created_at,last_error_kind)
            VALUES (\(bind:UUID()),\(bind:account.id),\(bind:subject),'posthog','manual_required',NOW(),NOW(),'provider_configuration_required')
            """).run()
        let kept = try await receipts(account.id)
        let counts = try await MeasurementConsentRetention.cleanup(now: expires.addingTimeInterval(400 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(counts.blocked, 1)
        let still = try await receipts(account.id)
        XCTAssertEqual(still, kept)
    }

    // MARK: - Release gate

    func testProductionLinkedInSwitchResolvesOffWithoutTheAcceptedResolution() async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
        func resolve(_ values: [String: String]) async throws -> [String: Bool] {
            try await FeatureFlagService.resolve(on: app.db, lookup: { values[$0] })
        }
        let on = ["FEATURE_LINKEDIN_CONVERSIONS_ENABLED": "true", "FEATURE_CROSS_COMPANY_ADS_ENABLED": "true"]
        var production = on; production["PLATFORM_ENVIRONMENT"] = "production"
        let refused = try await resolve(production)
        XCTAssertEqual(refused["linkedInConversionsEnabled"], false, "the environment switch alone cannot enable production")
        XCTAssertEqual(refused["crossCompanyAdsEnabled"], true, "only LinkedIn is gated")
        var wrong = production; wrong[LinkedInErasureResolution.acceptanceVariable] = "linkedin-erasure-2026-10-09"
        let wrongVersion = try await resolve(wrong)
        XCTAssertEqual(wrongVersion["linkedInConversionsEnabled"], false, "acceptance names the exact reviewed version")
        var empty = production; empty[LinkedInErasureResolution.acceptanceVariable] = ""
        let emptyAcceptance = try await resolve(empty)
        XCTAssertEqual(emptyAcceptance["linkedInConversionsEnabled"], false)
        var accepted = production; accepted[LinkedInErasureResolution.acceptanceVariable] = LinkedInErasureResolution.version
        let enabled = try await resolve(accepted)
        XCTAssertEqual(enabled["linkedInConversionsEnabled"], true)
        var staging = on; staging["PLATFORM_ENVIRONMENT"] = "staging"
        let synthetic = try await resolve(staging)
        XCTAssertEqual(synthetic["linkedInConversionsEnabled"], true, "staging synthetic test rules are not gated here")

        // An override row cannot bypass the gate either.
        try await FeatureFlag(key: "linkedInConversionsEnabled", enabled: true).save(on: app.db)
        let overridden = try await resolve(["PLATFORM_ENVIRONMENT": "production"])
        XCTAssertEqual(overridden["linkedInConversionsEnabled"], false)
        let overriddenAccepted = try await resolve(["PLATFORM_ENVIRONMENT": "production",
                                                    LinkedInErasureResolution.acceptanceVariable: LinkedInErasureResolution.version])
        XCTAssertEqual(overriddenAccepted["linkedInConversionsEnabled"], true)
        // Off stays off whatever the acceptance says.
        try await FeatureFlag.query(on: app.db).filter(\.$key == "linkedInConversionsEnabled").delete()
        let off = try await resolve(["PLATFORM_ENVIRONMENT": "production",
                                     LinkedInErasureResolution.acceptanceVariable: LinkedInErasureResolution.version])
        XCTAssertEqual(off["linkedInConversionsEnabled"], false)
    }

    func testProductionDispatchSuppressesALinkedInSendWithoutTheAcceptedResolution() async throws {
        let account = try await granted("li-erasure-gate")
        configureDispatch(environment: .production, accepted: nil)
        let hash = syntheticHash()
        let job = try await queued(account, hash: hash, sourceKind: "signupFact",
                                   availableAt: Date(timeIntervalSince1970: 946_684_800))
        _ = await MeasurementDispatchService.run(app: app, limit: 1, on: app.db)
        let row = try await sql.raw("SELECT state,payload::text AS payload FROM measurement_dispatch_jobs WHERE id=\(bind:job)").first()!
        XCTAssertEqual(try row.decode(column: "state", as: String.self), "suppressed")
        XCTAssertNil(try row.decode(column: "payload", as: String?.self))
        XCTAssertEqual(sentWith(hash), 0, "no production LinkedIn request without the accepted resolution")
        XCTAssertFalse(LinkedInErasureResolution.productionDispatchPermitted(environment: .production, accepted: nil))
        XCTAssertFalse(LinkedInErasureResolution.productionDispatchPermitted(environment: .production, accepted: "accepted"))
        XCTAssertTrue(LinkedInErasureResolution.productionDispatchPermitted(environment: .production,
                                                                             accepted: LinkedInErasureResolution.version))
        XCTAssertTrue(LinkedInErasureResolution.productionDispatchPermitted(environment: .sandbox, accepted: nil))
    }
}

final class LinkedInErasureHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var bodies: [String] { lock.lock(); defer { lock.unlock() }; return values }
    private func record(_ body: Data) { lock.lock(); values.append(String(decoding: body, as: UTF8.self)); lock.unlock() }
    var dispatchTransport: MeasurementDispatchService.Transport {
        { [self] _, _, body in self.record(body); return .init(status: 201, retryAfter: nil) }
    }
    var erasureTransport: MeasurementErasureService.Transport {
        { [self] _, _, body in self.record(body); return .init(status: 204) }
    }
}
