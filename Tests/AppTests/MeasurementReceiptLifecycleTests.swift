@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// The finite lifecycle of a deleted account's measurement consent, withdrawal and erasure receipts
/// (CONSENT-RETENTION-LIFECYCLE.md) and rollback reconciliation (ROLLBACK-RECONCILIATION.md).
/// Real PostgreSQL; providers are stubbed and every provider-erasure outcome is set directly, because
/// the PostHog worker has its own suites. Synthetic accounts only.
final class MeasurementReceiptLifecycleTests: XCTestCase {
    private var app: Application!
    private var accounts: [UUID] = []
    private var recorder: ReceiptHTTPRecorder!
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }
    private let day: TimeInterval = 86_400
    private static let flags = ["productAnalyticsEnabled", "crossCompanyAdsEnabled", "linkedInConversionsEnabled", "adMeasurementEnabled"]
    /// What the lifecycle keeps until its trigger plus 30 days, then removes.
    private static let receiptTables = ["measurement_consent_events", "measurement_permission_current", "measurement_subjects",
                                        "measurement_erasure_jobs", "measurement_product_events", "measurement_device_bindings"]

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x42, count: 32)
        app.storage[RevenueCatMeasurementService.ConfigurationKey.self] = .init(
            authorization: "Bearer synthetic-webhook-secret", appID: "synthetic-rc-app")
        app.storage[PurchaseOriginService.ConfigurationKey.self] = .init(
            hmacKey: Data(repeating: 0x71, count: 32), environment: .sandbox)
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: "phc_synthetic", postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        recorder = ReceiptHTTPRecorder()
        app.storage[MeasurementDispatchService.TransportKey.self] = recorder.transport
        app.storage[AccountDeletionTestActivation.self] = true
        accounts = []
        try await FeatureFlag.query(on: app.db).filter(\.$key ~~ Self.flags).delete()
        try await FeatureFlag(key: "productAnalyticsEnabled", enabled: true).save(on: app.db)
    }

    override func tearDown() async throws {
        if let app {
            let sql = try VerifiedIdentityService.sql(app.db)
            for account in accounts {
                for statement in [
                    "DELETE FROM measurement_purchase_charge_links WHERE charge_id IN (SELECT id FROM measurement_revenuecat_events WHERE account_id=$1)",
                    "DELETE FROM measurement_purchase_intents WHERE account_id=$1",
                    "UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE account_id=$1",
                    "DELETE FROM measurement_purchase_acquisitions WHERE account_id=$1",
                    "DELETE FROM measurement_dispatch_jobs WHERE account_id=$1",
                    "DELETE FROM measurement_revenuecat_adjustments WHERE account_id=$1",
                    "DELETE FROM measurement_revenuecat_lifecycle_events WHERE account_id=$1",
                    "DELETE FROM measurement_revenuecat_events WHERE account_id=$1",
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
        app = nil; recorder = nil; accounts = []
    }

    // MARK: - Helpers

    private func makeUser(_ label: String) async throws -> (id: UUID, token: String) {
        let user = User(appleUserId: nil, email: "\(label)-\(UUID().uuidString.lowercased())@example.test",
                        name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        let id = try user.requireID()
        accounts.append(id)
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: id,
            authVersion: user.authVersion, authenticatedAt: Date()))
        return (id, token)
    }

    private func date(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }

    private func request(_ method: HTTPMethod, _ path: String, token: String? = nil,
                         object: [String: Any]? = nil) async throws -> XCTHTTPResponse {
        var answer: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if let object {
                req.headers.contentType = .json
                req.body = .init(data: try JSONSerialization.data(withJSONObject: object))
            }
        }, afterResponse: { answer = $0 })
        return answer
    }

    private func grantProduct(_ account: UUID, _ token: String) async throws -> UUID {
        let response = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", token: token, object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date(),
            "noticeVersion": MeasurementNotice.current])
        XCTAssertEqual(response.status, .ok, response.body.string)
        try await sql.raw("""
            UPDATE measurement_permission_current SET updated_at=updated_at - INTERVAL '1 day'
            WHERE account_id=\(bind:account) AND purpose='productAnalytics'
            """).run()
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        let entry = try XCTUnwrap((values["permissions"] as? [[String: Any]])?.first { $0["purpose"] as? String == "productAnalytics" })
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(entry["revision"] as? String)))
    }

    private func event(_ token: String, revision: UUID) async throws -> HTTPStatus {
        try await request(.POST, "api/v2/measurement/events", token: token, object: [
            "eventId": UUID().uuidString, "occurredAt": date(), "consentRevision": revision.uuidString,
            "installationId": UUID().uuidString,
            "event": ["schemaVersion": 1, "name": "session_started", "properties": [:] as [String: String]]]).status
    }

    /// A measured account: one product event delivered to PostHog (so its provider erasure is needed)
    /// and one still queued.
    private func measured(_ label: String) async throws -> (id: UUID, token: String, revision: UUID) {
        let (id, token) = try await makeUser(label)
        let revision = try await grantProduct(id, token)
        let first = try await event(token, revision: revision)
        XCTAssertEqual(first, .accepted)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let delivered = try await sends(id)
        XCTAssertEqual(delivered, 1, "the first event reached the PostHog stub")
        let second = try await event(token, revision: revision)
        XCTAssertEqual(second, .accepted)
        let queued = try await count("measurement_dispatch_jobs WHERE state='pending' AND", id)
        XCTAssertEqual(queued, 1)
        return (id, token, revision)
    }

    private func deleteThroughTheService(_ account: UUID) async throws {
        let reference = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        _ = try await AccountDeletionService.request(userID: account,
            body: .init(confirmation: "DELETE", receiptReference: reference), app: app)
    }

    /// What the rollback image (`4d04a16`, no measurement code) does to the measurement tables when it
    /// deletes an account: nothing. It tombstones the `users` row, removes identities and records its own
    /// deletion job, whose measurement state keeps the column default.
    private func deleteAsTheRollbackImage(_ account: UUID, jobState: String) async throws -> UUID {
        let job = UUID()
        let completed = jobState == "completed"
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,completed_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind:job),\(bind:account),\(bind:SHA256Hasher.hash(token: "rollback-deletion-\(job)")),NOW(),
                   \(bind:jobState),NOW(),\(bind:completed ? Date() : nil),\(bind:completed ? "completed" : "pending"),
                   'completed','not_applicable')
            """).run()
        try await sql.raw("""
            UPDATE users SET lifecycle_state='deleted',auth_version=auth_version+1,email=NULL,name=NULL WHERE id=\(bind:account)
            """).run()
        try await sql.raw("DELETE FROM user_identities WHERE user_id=\(bind:account)").run()
        return job
    }

    private func count(_ query: String, _ account: UUID) async throws -> Int {
        let clause = query.hasSuffix(" AND") ? query + " account_id=" : query + " WHERE account_id="
        return try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: clause)\(bind:account)").first()!
            .decode(column: "n", as: Int.self)
    }

    /// Provider requests that carried this account's opaque subjects (other suites' leftovers in the shared
    /// disposable database may be dispatched by the same pass and are ignored).
    private func sends(_ account: UUID) async throws -> Int {
        let subjects = try await sql.raw("SELECT opaque_subject FROM measurement_subjects WHERE account_id=\(bind:account)").all()
            .map { try $0.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased() }
        return recorder.all.filter { body in subjects.contains { body.contains($0) } }.count
    }

    private func receipts(_ account: UUID) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for table in Self.receiptTables { result[table] = try await count(table, account) }
        return result
    }

    private func snapshot(_ account: UUID) async throws -> [String: Int] {
        var result = try await receipts(account)
        for table in ["measurement_dispatch_jobs", "measurement_att_assertions", "measurement_revenuecat_events"] {
            result[table] = try await count(table, account)
        }
        result["users"] = try await sql.raw("SELECT count(*) AS n FROM users WHERE id=\(bind:account)").first()!.decode(column: "n", as: Int.self)
        result["account_deletion_jobs"] = try await sql.raw("SELECT count(*) AS n FROM account_deletion_jobs WHERE user_id=\(bind:account)")
            .first()!.decode(column: "n", as: Int.self)
        return result
    }

    private func erasureJob(_ account: UUID) async throws -> UUID {
        try await sql.raw("""
            SELECT id FROM measurement_erasure_jobs WHERE account_id=\(bind:account) AND destination='posthog' AND state<>'completed'
            """).first()!.decode(column: "id", as: UUID.self)
    }

    private func complete(_ job: UUID, at moment: Date) async throws {
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='completed',completed_at=\(bind:moment),lease_token=NULL,
                lease_expires_at=NULL,last_error_kind=NULL WHERE id=\(bind:job)
            """).run()
    }

    private func webhook(_ transaction: String, _ appUser: UUID, purchasedAt: Date) async throws -> HTTPStatus {
        let event: [String: Any] = [
            "id": UUID().uuidString, "app_id": "synthetic-rc-app", "app_user_id": appUser.uuidString, "type": "INITIAL_PURCHASE",
            "environment": "SANDBOX", "store": "APP_STORE", "period_type": "NORMAL", "is_family_share": false,
            "product_id": "com.snaglist.pro.monthly", "entitlement_ids": ["Snaglist Pro"],
            "event_timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "purchased_at_ms": Int64(purchasedAt.timeIntervalSince1970 * 1000),
            "expiration_at_ms": Int64(purchasedAt.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000),
            "price_in_purchased_currency": 14.99, "currency": "GBP", "transaction_id": transaction,
            "original_transaction_id": "original-\(transaction)"]
        var status = HTTPStatus.internalServerError
        try await app.test(.POST, "api/v2/measurement/webhooks/revenuecat", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .authorization, value: "Bearer synthetic-webhook-secret")
            req.headers.contentType = .json
            req.body = .init(data: try JSONSerialization.data(withJSONObject: ["api_version": "1.0", "event": event]))
        }, afterResponse: { status = $0.status })
        return status
    }

    // MARK: - Deletion stops processing and removes payloads at once

    func testDeletionStopsOptionalProcessingAndRemovesPayloadsAtOnce() async throws {
        let account = try await measured("receipt-stop")
        try await deleteThroughTheService(account.id)
        for (query, expected) in [("measurement_subjects WHERE state='active' AND", 0),
                                  ("measurement_permission_current WHERE decision='granted' AND", 0),
                                  ("measurement_dispatch_jobs", 0), ("measurement_product_events", 0),
                                  ("measurement_att_assertions", 0),
                                  ("measurement_erasure_jobs WHERE destination='posthog' AND state='pending' AND", 1)] {
            let value = try await count(query, account.id)
            XCTAssertEqual(value, expected, query)
        }
        let withdrawals = try await count("measurement_consent_events WHERE decision='withdrawn' AND", account.id)
        XCTAssertEqual(withdrawals, 1, "the deletion is recorded as the withdrawal receipt")
        let late = try await event(account.token, revision: account.revision)
        XCTAssertEqual(late, .unauthorized, "a deleted account can no longer upload")
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let sent = try await sends(account.id)
        XCTAssertEqual(sent, 1, "nothing queued before the deletion is sent")
        let state = try await sql.raw("SELECT measurement_erasure_state FROM account_deletion_jobs WHERE user_id=\(bind:account.id)")
            .first()!.decode(column: "measurement_erasure_state", as: String.self)
        XCTAssertEqual(state, "pending")
    }

    // MARK: - The trigger

    func testReceiptsStayUntilEveryErasureCompletesThenGoThirtyDaysLater() async throws {
        let account = try await measured("receipt-trigger")
        try await deleteThroughTheService(account.id)
        let job = try await erasureJob(account.id)
        // The PostHog evidence goes with its job (cascade).
        try await sql.raw("""
            INSERT INTO measurement_posthog_erasure_receipts(job_id,posthog_project_id,person_uuid,phase,resolved_at)
            VALUES (\(bind:job),'298161',\(bind:UUID()),'resolved',NOW())
            """).run()
        let kept = try await receipts(account.id)
        XCTAssertGreaterThan(kept["measurement_consent_events"] ?? 0, 0)
        XCTAssertGreaterThan(kept["measurement_subjects"] ?? 0, 0)
        let now = Date()
        _ = try await MeasurementConsentRetention.cleanup(now: now.addingTimeInterval(400 * day), limit: 5_000, on: app.db)
        let pending = try await receipts(account.id)
        XCTAssertEqual(pending, kept, "nothing goes while provider erasure is pending, however long")

        let completedAt = now.addingTimeInterval(10 * day)
        try await complete(job, at: completedAt)
        _ = try await MeasurementConsentRetention.cleanup(now: completedAt.addingTimeInterval(29 * day), limit: 5_000, on: app.db)
        let early = try await receipts(account.id)
        XCTAssertEqual(early, kept, "the 30 days run from the last erasure completion, not from the deletion")

        let counts = try await MeasurementConsentRetention.cleanup(now: completedAt.addingTimeInterval(31 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(counts.accounts, 1)
        let gone = try await receipts(account.id)
        XCTAssertEqual(Set(gone.values), [0], "\(gone)")
        let receipt = try await sql.raw("SELECT count(*) AS n FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)")
            .first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(receipt, 0)
        let user = try await sql.raw("SELECT lifecycle_state FROM users WHERE id=\(bind:account.id)").first()!
            .decode(column: "lifecycle_state", as: String.self)
        XCTAssertEqual(user, "deleted", "the core account tombstone is not part of this lifecycle")
        let deletion = try await sql.raw("SELECT count(*) AS n FROM account_deletion_jobs WHERE user_id=\(bind:account.id)")
            .first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(deletion, 1, "the core deletion record is not part of this lifecycle")
    }

    func testManualRequiredOrFailingErasureBlocksCleanupAndKeepsItsEvidence() async throws {
        let account = try await measured("receipt-manual")
        try await deleteThroughTheService(account.id)
        let job = try await erasureJob(account.id)
        let kept = try await receipts(account.id)
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='manual_required',last_error_kind='provider_configuration_required'
            WHERE id=\(bind:job)
            """).run()
        let counts = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(5 * 365 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(counts.blocked, 1)
        let manual = try await receipts(account.id)
        XCTAssertEqual(manual, kept, "manual_required keeps everything needed to finish the erasure")
        let report = try await MeasurementReconciliation.report(on: app.db)
        let listed = try XCTUnwrap(report.openErasureJobs.first { $0.erasureJobId == job })
        XCTAssertEqual(listed.state, "manual_required")
        XCTAssertEqual(listed.reason, "provider_configuration_required")
        XCTAssertTrue(listed.accountDeleted)

        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET state='failing',last_error_kind='provider_unavailable' WHERE id=\(bind:job)
            """).run()
        _ = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(5 * 365 * day), limit: 5_000, on: app.db)
        let failing = try await receipts(account.id)
        XCTAssertEqual(failing, kept)
    }

    func testCleanupRemovesExactlyTheDueAccountsReceipts() async throws {
        let now = Date()
        let due = try await measured("receipt-due")
        try await deleteThroughTheService(due.id)
        try await complete(try await erasureJob(due.id), at: now)
        let young = try await measured("receipt-young")
        try await deleteThroughTheService(young.id)
        try await complete(try await erasureJob(young.id), at: now.addingTimeInterval(20 * day))
        // A live account with a withdrawn, fully erased history keeps it while the account exists.
        let live = try await measured("receipt-live")
        let withdrawn = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", token: live.token, object: [
            "requestId": UUID().uuidString, "expectedRevision": live.revision.uuidString, "decision": "withdrawn",
            "occurredAt": date()])
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        try await complete(try await erasureJob(live.id), at: now)
        // An account the rollback image deleted is evidence for reconciliation, never cleaned up first.
        let rollback = try await measured("receipt-rollback")
        _ = try await deleteAsTheRollbackImage(rollback.id, jobState: "completed")

        let dueBefore = try await snapshot(due.id)
        var before: [UUID: [String: Int]] = [:]
        for account in [young.id, live.id, rollback.id] { before[account] = try await snapshot(account) }
        _ = try await MeasurementConsentRetention.cleanup(now: now.addingTimeInterval(31 * day), limit: 5_000, on: app.db)

        let dueAfter = try await snapshot(due.id)
        for table in Self.receiptTables {
            XCTAssertEqual(dueAfter[table], 0, table)
        }
        for (table, value) in dueBefore where !Self.receiptTables.contains(table) {
            XCTAssertEqual(dueAfter[table], value, "\(table) is outside this lifecycle")
        }
        for account in [young.id, live.id, rollback.id] {
            let after = try await snapshot(account)
            XCTAssertEqual(after, before[account], "\(account) must be untouched")
        }
    }

    func testDeduplicationAndSuppressionStillHoldAfterCleanup() async throws {
        let (first, firstToken) = try await makeUser("receipt-dedup-first")
        let revision = try await grantProduct(first, firstToken)
        let firstSubjects = try await sql.raw("SELECT opaque_subject FROM measurement_subjects WHERE account_id=\(bind:first)").all()
            .map { try $0.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased() }
        XCTAssertEqual(firstSubjects.count, 1)
        let transaction = "receipt-dedup-\(UUID().uuidString.lowercased())"
        let purchasedAt = Date().addingTimeInterval(-3600)
        let initial = try await webhook(transaction, first, purchasedAt: purchasedAt)
        XCTAssertEqual(initial, .ok)
        try await deleteThroughTheService(first)
        let unlinked = try await count("measurement_revenuecat_events", first)
        XCTAssertEqual(unlinked, 0, "deletion unlinks the money ledger")
        // Nothing was delivered for this account, so its PostHog erasure completed with the deletion.
        let open = try await count("measurement_erasure_jobs WHERE state<>'completed' AND", first)
        XCTAssertEqual(open, 0)
        let ledger = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events").first()!.decode(column: "n", as: Int.self)
        let counts = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(31 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(counts.accounts, 1)
        let gone = try await receipts(first)
        XCTAssertEqual(Set(gone.values), [0])
        let ledgerAfter = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(ledgerAfter, ledger, "the unlinked money ledger is outside this lifecycle")

        // Deduplication: the same verified charge delivered for another account is never new money.
        let (second, secondToken) = try await makeUser("receipt-dedup-second")
        _ = try await grantProduct(second, secondToken)
        let aliased = try await webhook(transaction, second, purchasedAt: purchasedAt)
        XCTAssertEqual(aliased, .ok)
        let ledgerAlias = try await sql.raw("SELECT count(*) AS n FROM measurement_revenuecat_events").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(ledgerAlias, ledger, "no second charge")
        let secondJobs = try await count("measurement_dispatch_jobs WHERE destination='posthog' AND", second)
        XCTAssertEqual(secondJobs, 0, "no second paid event")

        // Suppression: the deleted account cannot be measured again, and nothing old is sent.
        let regrant = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", token: firstToken, object: [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": date()])
        XCTAssertEqual(regrant.status, .unauthorized)
        let upload = try await event(firstToken, revision: revision)
        XCTAssertEqual(upload, .unauthorized)
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        XCTAssertFalse(recorder.all.contains { body in firstSubjects.contains { body.contains($0) } },
                       "nothing was ever sent for the deleted account")
        let recreated = try await receipts(first)
        XCTAssertEqual(Set(recreated.values), [0])
    }

    // MARK: - Rollback reconciliation

    func testReconciliationAfterARollbackDeletionCreatesErasureWorkAndSendsNothing() async throws {
        let account = try await measured("reconcile-completed")
        let job = try await deleteAsTheRollbackImage(account.id, jobState: "completed")

        let listed = try await MeasurementReconciliation.execute(apply: false, on: app.db)
        let entry = try XCTUnwrap(listed.unreconciledDeletedAccounts.first { $0.accountId == account.id })
        XCTAssertEqual(entry.deletionJobId, job)
        XCTAssertEqual(entry.deletionJobState, "completed")
        XCTAssertTrue(Set(entry.residue).isSuperset(of: ["active_subjects", "granted_permissions", "dispatch_jobs",
                                                         "product_event_content"]), "\(entry.residue)")
        XCTAssertEqual(listed.switches["productAnalyticsEnabled"], true)
        XCTAssertEqual(listed.switches["measurementChoicesEnabled"], false)
        let unchanged = try await count("measurement_subjects WHERE state='active' AND", account.id)
        XCTAssertEqual(unchanged, 1, "listing changes nothing")

        // Receipt cleanup never removes what reconciliation needs, however late.
        let evidence = try await receipts(account.id)
        let cleanup = try await MeasurementConsentRetention.cleanup(now: Date().addingTimeInterval(400 * day), limit: 5_000, on: app.db)
        XCTAssertGreaterThanOrEqual(cleanup.unreconciled, 1)
        let stillThere = try await receipts(account.id)
        XCTAssertEqual(stillThere, evidence)

        // Even before reconciliation, the resumed image sends nothing for the deleted account.
        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let beforeReconciliation = try await sends(account.id)
        XCTAssertEqual(beforeReconciliation, 1, "only the event delivered before the deletion")
        let suppressed = try await count("measurement_dispatch_jobs WHERE state='suppressed' AND payload IS NULL AND", account.id)
        XCTAssertEqual(suppressed, 1)

        // Scoped to this account: applying the whole command would also reconcile other suites' leftovers in
        // the shared test database. The whole command, --apply included, runs in the cross-image rehearsal.
        let reconciled = try await MeasurementReconciliation.reconcile(accountID: account.id, on: app.db)
        XCTAssertTrue(reconciled)
        let applied = try await MeasurementReconciliation.report(on: app.db)
        XCTAssertFalse(applied.unreconciledDeletedAccounts.contains { $0.accountId == account.id })
        for (query, expected) in [("measurement_subjects WHERE state='active' AND", 0),
                                  ("measurement_permission_current WHERE decision='granted' AND", 0),
                                  ("measurement_dispatch_jobs", 0), ("measurement_product_events", 0),
                                  ("measurement_consent_events WHERE decision='withdrawn' AND", 1)] {
            let value = try await count(query, account.id)
            XCTAssertEqual(value, expected, query)
        }
        // The missing provider-erasure work now exists: the delivered event needs a PostHog deletion.
        let erasure = try await sql.raw("""
            SELECT state,account_deletion_job_id FROM measurement_erasure_jobs WHERE account_id=\(bind:account.id) AND destination='posthog'
            """).first()
        XCTAssertEqual(try erasure?.decode(column: "state", as: String.self), "pending")
        XCTAssertNil(try erasure?.decode(column: "account_deletion_job_id", as: UUID?.self),
                     "a completed deletion job is never reopened; the erasure runs unlinked")
        let deletion = try await sql.raw("SELECT state,measurement_erasure_state FROM account_deletion_jobs WHERE id=\(bind:job)").first()
        XCTAssertEqual(try deletion?.decode(column: "state", as: String.self), "completed")
        XCTAssertEqual(try deletion?.decode(column: "measurement_erasure_state", as: String.self), "not_requested")

        _ = await MeasurementDispatchService.run(app: app, on: app.db)
        let afterReconciliation = try await sends(account.id)
        XCTAssertEqual(afterReconciliation, 1, "the resumed system cannot send the account's old events")
        let again = try await MeasurementReconciliation.reconcile(accountID: account.id, on: app.db)
        XCTAssertFalse(again, "reconciliation is idempotent")
        let withdrawals = try await count("measurement_consent_events WHERE decision='withdrawn' AND", account.id)
        XCTAssertEqual(withdrawals, 1)
    }

    func testReconciliationLinksAnUnfinishedRollbackDeletionAndRearmsIt() async throws {
        let account = try await measured("reconcile-unfinished")
        let job = try await deleteAsTheRollbackImage(account.id, jobState: "ready")
        let reconciled = try await MeasurementReconciliation.reconcile(accountID: account.id, on: app.db)
        XCTAssertTrue(reconciled)
        let erasure = try await sql.raw("""
            SELECT state,account_deletion_job_id FROM measurement_erasure_jobs WHERE account_id=\(bind:account.id) AND destination='posthog'
            """).first()
        XCTAssertEqual(try erasure?.decode(column: "state", as: String.self), "pending")
        XCTAssertEqual(try erasure?.decode(column: "account_deletion_job_id", as: UUID?.self), job)
        let listed = try await MeasurementReconciliation.report(on: app.db)
        let pending = try XCTUnwrap(listed.pendingMeasurementDeletions.first { $0.deletionJobId == job })
        XCTAssertEqual(pending.measurementErasureState, "pending")
        XCTAssertEqual(pending.erasureJobs, ["posthog:pending"])
        try await sql.raw("UPDATE account_deletion_jobs SET available_at=NOW() + INTERVAL '1 hour' WHERE id=\(bind:job)").run()
        try await MeasurementReconciliation.rearm(deletionJobID: job, accountID: account.id, on: app.db)
        let due = try await sql.raw("SELECT available_at<=NOW() AS due,measurement_erasure_state FROM account_deletion_jobs WHERE id=\(bind:job)").first()
        XCTAssertEqual(try due?.decode(column: "due", as: Bool.self), true, "re-armed for the next deletion-worker pass")
        XCTAssertEqual(try due?.decode(column: "measurement_erasure_state", as: String.self), "pending")
        do {
            try await sql.raw("UPDATE account_deletion_jobs SET state='completed',completed_at=NOW(),database_cleanup_state='completed' WHERE id=\(bind:job)").run()
            XCTFail("a deletion with pending measurement erasure must not complete")
        } catch {}
    }
}

final class ReceiptHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    var transport: MeasurementDispatchService.Transport {
        { [self] _, _, body in
            self.lock.lock(); self.bodies.append(String(decoding: body, as: UTF8.self)); self.lock.unlock()
            return .init(status: 200, retryAfter: nil)
        }
    }
}
