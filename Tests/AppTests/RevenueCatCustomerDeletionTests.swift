@testable import App
import XCTVapor
import Fluent
import FluentSQL
import PostgresNIO

/// The rules the RevenueCat step decides by. No database, no network.
final class RevenueCatCustomerDeletionRulesTests: XCTestCase {
    typealias Service = RevenueCatCustomerDeletionService

    /// RevenueCat is called only by a deployment that declares itself production and
    /// holds the key. Staging is skipped by environment even if a key appeared, and a
    /// production process that cannot say what it is never claims a skip.
    func testOnlyADeclaredProductionDeploymentWithAKeyCallsRevenueCat() {
        let key = "synthetic-revenuecat-key"
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "production", secretKey: key), productionProcess: true), .call(secretKey: key))
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "production", secretKey: nil), productionProcess: true), .misconfigured)
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "production", secretKey: "  \n"), productionProcess: true), .misconfigured)
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "staging", secretKey: nil), productionProcess: true), .skipEnvironment)
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "staging", secretKey: key), productionProcess: true), .skipEnvironment,
                       "a staging deployment never names a customer, even with a key")
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "local", secretKey: key), productionProcess: false), .skipEnvironment)
        XCTAssertEqual(Service.decide(.init(platformEnvironment: nil, secretKey: key), productionProcess: true), .misconfigured,
                       "a production process with no declared platform cannot claim a skip")
        XCTAssertEqual(Service.decide(.init(platformEnvironment: "preview", secretKey: key), productionProcess: true), .misconfigured)
        XCTAssertEqual(Service.decide(.init(platformEnvironment: nil, secretKey: nil), productionProcess: false), .skipEnvironment)
    }

    /// RevenueCat: "treat both 200 and 404 as successful 'ensure deleted' completion".
    /// A refused key is a person's problem, not a completion and not a retry.
    func testA404IsDoneARefusedKeyIsNotAndOutagesAreRetried() {
        XCTAssertEqual(Service.classify(.ok), .deleted)
        XCTAssertEqual(Service.classify(.noContent), .deleted)
        XCTAssertEqual(Service.classify(.notFound), .notFound)
        for refused in [HTTPStatus.unauthorized, .forbidden, .badRequest, .unprocessableEntity] {
            XCTAssertEqual(Service.classify(refused), .misconfigured, "\(refused.code)")
        }
        for transient in [HTTPStatus.tooManyRequests, .requestTimeout, .conflict, .internalServerError, .badGateway, .serviceUnavailable, .gatewayTimeout] {
            XCTAssertEqual(Service.classify(transient), .failing, "\(transient.code)")
        }
        XCTAssertEqual(Set(Service.Outcome.allCases.filter(\.settles)), [.deleted, .notFound, .skippedEnvironment])
        XCTAssertEqual(Service.Outcome.allCases.map(\.rawValue).sorted(),
                       ["deleted", "failing", "misconfigured", "not_found", "skipped_environment"])
    }

    /// The v1 path, the account's UUID exactly as the app logs in with it.
    func testTheAddressIsTheV1SubscriberPathForTheUppercaseUUID() {
        let id = UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!
        XCTAssertEqual(Service.uri(appUserID: id.uuidString).string,
                       "https://api.revenuecat.com/v1/subscribers/0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")
    }
}

/// Account deletion's RevenueCat step through the worker. All identities and keys are
/// synthetic, and no request leaves the process: the transport is a recorder.
final class RevenueCatCustomerDeletionTests: XCTestCase {
    typealias Service = RevenueCatCustomerDeletionService
    var app: Application!
    let key = "synthetic-revenuecat-key-for-tests-only"

    actor Calls {
        struct Call: Sendable, Equatable { let method: HTTPMethod; let url: String; let authorization: String? }
        private var calls: [Call] = []
        func record(_ call: Call) { calls.append(call) }
        func all() -> [Call] { calls }
    }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func setRevenueCat(platform: String?, key: String?) {
        app.storage[Service.ConfigurationKey.self] = .init(platformEnvironment: platform, secretKey: key)
    }
    private func answer(_ calls: Calls, _ reply: @escaping @Sendable () async throws -> HTTPStatus) {
        app.storage[Service.TransportKey.self] = { method, uri, headers in
            await calls.record(.init(method: method, url: uri.string, authorization: headers.bearerAuthorization?.token))
            return try await reply()
        }
    }
    private func user(_ label: String) async throws -> UUID {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("revenuecat-\(label)-\(UUID())@example.test", name: "Synthetic \(label)", on: db).requireID()
        }
    }
    private func reference() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }
    /// The request path exactly as the app reaches it.
    private func deleteAccount(_ userID: UUID) async throws -> UUID {
        _ = try await AccountDeletionService.request(userID: userID, body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT id FROM account_deletion_jobs WHERE user_id=\(bind: userID)").first()
        return try XCTUnwrap(row).decode(column: "id", as: UUID.self)
    }
    /// A job written directly, for the states the request path cannot produce on its own.
    private func fixture(deleted: Bool = true, database: String = "completed", objects: String = "completed",
                         revenuecat: String = "pending") async throws -> (UUID, UUID) {
        let userID = try await user("fixture"), id = UUID()
        let sql = try VerifiedIdentityService.sql(app.db)
        if deleted {
            try await sql.raw("UPDATE users SET lifecycle_state='deleted',email=NULL,name=NULL,auth_version=auth_version+1 WHERE id=\(bind: userID)").run()
        }
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state,revenuecat_state)
            VALUES(\(bind: id),\(bind: userID),\(bind: AccountDeletionService.receiptHash(reference())),NOW(),'ready',
                clock_timestamp()+INTERVAL '1 day',\(bind: database),\(bind: objects),'not_applicable',\(bind: revenuecat))
            """).run()
        return (id, userID)
    }
    private func lease(_ id: UUID, user: UUID) async throws -> AccountDeletionWorker.Lease {
        let token = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),
                lease_expires_at=clock_timestamp()+INTERVAL '300 seconds' WHERE id=\(bind: id)
            """).run()
        return .init(id: id, userID: user, token: token, attempt: 1)
    }
    private func pass(_ id: UUID, user: UUID) async throws -> String? {
        let owned = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        return try await AccountDeletionWorker.finish(owned, on: app.db)
    }
    struct Row { let state: String; let revenuecat: String; let attempts: Int; let completedAt: Date?; let jobCompletedAt: Date?; let reason: String? }
    private func row(_ id: UUID) async throws -> Row {
        let fetched = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT state,revenuecat_state,revenuecat_attempts,revenuecat_completed_at,completed_at,last_error_kind
            FROM account_deletion_jobs WHERE id=\(bind: id)
            """).first()
        let row = try XCTUnwrap(fetched)
        return try Row(state: row.decode(column: "state", as: String.self), revenuecat: row.decode(column: "revenuecat_state", as: String.self),
                       attempts: row.decode(column: "revenuecat_attempts", as: Int.self),
                       completedAt: row.decode(column: "revenuecat_completed_at", as: Date?.self),
                       jobCompletedAt: row.decode(column: "completed_at", as: Date?.self),
                       reason: row.decode(column: "last_error_kind", as: String?.self))
    }

    /// The whole path: a person deletes their account; the worker deletes exactly that
    /// account's RevenueCat customer, once, with the secret key, and completes. A second
    /// account that exists alongside it is never named.
    func testDeletionRemovesThatAccountsRevenueCatCustomerAndNoOneElses() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        answer(calls) { .ok }
        let target = try await user("target"), bystander = try await user("bystander")
        let job = try await deleteAccount(target)
        let created = try await row(job)
        XCTAssertEqual(created.revenuecat, "pending", "every job the request path creates carries the step")

        let state = try await pass(job, user: target)
        XCTAssertEqual(state, "completed")
        let recorded = await calls.all()
        XCTAssertEqual(recorded, [.init(method: .DELETE, url: "https://api.revenuecat.com/v1/subscribers/\(target.uuidString)", authorization: key)])
        XCTAssertFalse(recorded.contains { $0.url.uppercased().contains(bystander.uuidString) }, "no other account is ever named")
        let done = try await row(job)
        XCTAssertEqual(done.revenuecat, "deleted")
        XCTAssertEqual(done.attempts, 1)
        XCTAssertNotNil(done.completedAt)
        let survivor = try await VerifiedIdentityService.activeUser(bystander, on: app.db)
        XCTAssertNotNil(survivor.email, "the bystander account is untouched")
    }

    /// Never before the account's own graph is erased: the external record follows the
    /// committed database state, as the Apple child and the object manifest do.
    func testTheStepWaitsForGraphErasure() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        answer(calls) { .ok }
        let (job, userID) = try await fixture(database: "blocked", objects: "blocked")
        _ = try await pass(job, user: userID)
        let early = await calls.all()
        XCTAssertTrue(early.isEmpty, "no call while the database side is unfinished")
        let current1 = try await row(job)
        XCTAssertEqual(current1.revenuecat, "pending")

        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed',object_cleanup_state='completed' WHERE id=\(bind: job)").run()
        let state = try await pass(job, user: userID)
        XCTAssertEqual(state, "completed")
        let recorded = await calls.all()
        XCTAssertEqual(recorded.count, 1)
    }

    /// Staging refuses the key by design. The step is recorded as skipped by
    /// environment, under its own name and with no completion time, never as a
    /// deletion — and nothing is called even if a key were present.
    func testStagingRecordsSkippedByEnvironmentAndNeverCalls() async throws {
        let calls = Calls()
        setRevenueCat(platform: "staging", key: key)
        answer(calls) { XCTFail("staging must never call RevenueCat"); return .ok }
        let target = try await user("staging")
        let job = try await deleteAccount(target)
        let state = try await pass(job, user: target)
        XCTAssertEqual(state, "completed", "a deployment with no purchase provider does not strand deletions")
        let recorded = await calls.all()
        XCTAssertTrue(recorded.isEmpty)
        let done = try await row(job)
        XCTAssertEqual(done.revenuecat, "skipped_environment")
        XCTAssertNil(done.completedAt, "a skip is not a deletion and carries no deletion time")
    }

    /// Missing configuration where it is required is recorded as not done, blocks the
    /// job, surfaces its own reason, and is retried until someone fixes it. Then a 404
    /// counts as done.
    func testAMissingKeyInProductionBlocksAndThenA404Completes() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: nil)
        answer(calls) { .notFound }
        let target = try await user("unconfigured")
        let job = try await deleteAccount(target)
        let blocked = try await pass(job, user: target)
        XCTAssertEqual(blocked, "blocked")
        let first = try await row(job)
        XCTAssertEqual(first.revenuecat, "misconfigured")
        XCTAssertEqual(first.reason, "revenuecat_configuration")
        XCTAssertNil(first.jobCompletedAt)
        XCTAssertNil(first.completedAt)
        let noCalls = await calls.all()
        XCTAssertTrue(noCalls.isEmpty, "no key, no call")

        setRevenueCat(platform: "production", key: key)
        let state = try await pass(job, user: target)
        XCTAssertEqual(state, "completed")
        let second = try await row(job)
        XCTAssertEqual(second.revenuecat, "not_found", "RevenueCat has no such customer: that is done")
        XCTAssertEqual(second.attempts, 2)
        XCTAssertNotNil(second.completedAt)
        let recorded = await calls.all()
        XCTAssertEqual(recorded.count, 1)
    }

    /// A key RevenueCat refuses is a configuration block, never a completion.
    func testARefusedKeyBlocksTheJob() async throws {
        for refusal in [HTTPStatus.unauthorized, .forbidden] {
            let calls = Calls()
            setRevenueCat(platform: "production", key: key)
            answer(calls) { refusal }
            let target = try await user("refused")
            let job = try await deleteAccount(target)
            let state = try await pass(job, user: target)
            XCTAssertEqual(state, "blocked", "\(refusal.code)")
            let done = try await row(job)
            XCTAssertEqual(done.revenuecat, "misconfigured")
            XCTAssertEqual(done.reason, "revenuecat_configuration")
        }
    }

    /// An outage is retried on the backoff curve: the job stays ready, says why, and
    /// never completes on a failure.
    func testTransientFailuresAreRetriedAndNeverComplete() async throws {
        struct Unreachable: Error {}
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        let target = try await user("transient")
        let job = try await deleteAccount(target)
        let replies: [@Sendable () async throws -> HTTPStatus] = [{ .serviceUnavailable }, { .tooManyRequests }, { throw Unreachable() }]
        for (index, reply) in replies.enumerated() {
            answer(calls, reply)
            let state = try await pass(job, user: target)
            XCTAssertEqual(state, "ready")
            let current = try await row(job)
            XCTAssertEqual(current.revenuecat, "failing")
            XCTAssertEqual(current.reason, "revenuecat_unavailable")
            XCTAssertEqual(current.attempts, index + 1)
            XCTAssertNil(current.jobCompletedAt)
        }
        answer(calls) { .ok }
        let state = try await pass(job, user: target)
        XCTAssertEqual(state, "completed")
        let recorded = await calls.all()
        XCTAssertEqual(recorded.count, 4)
        XCTAssertTrue(recorded.allSatisfy { $0.url.hasSuffix("/v1/subscribers/\(target.uuidString)") })
    }

    /// A worker that loses its lease mid-call writes nothing; the next worker repeats
    /// the call, RevenueCat answers 404, and that is done. Idempotent by construction.
    func testALostLeaseWritesNothingAndTheRepeatIsIdempotent() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        let target = try await user("lease")
        let job = try await deleteAccount(target)
        let app = self.app!
        answer(calls) {
            try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET lease_expires_at=clock_timestamp()-INTERVAL '1 second' WHERE id=\(bind: job)").run()
            return .ok
        }
        let owned = try await lease(job, user: target)
        try await RevenueCatCustomerDeletionService.perform(owned, app: app, on: app.db)
        let stale = try await row(job)
        XCTAssertEqual(stale.revenuecat, "pending", "an expired lease cannot record an outcome")
        XCTAssertEqual(stale.attempts, 0)

        answer(calls) { .notFound }
        let state = try await pass(job, user: target)
        XCTAssertEqual(state, "completed")
        let current2 = try await row(job)
        XCTAssertEqual(current2.revenuecat, "not_found")
        let recorded = await calls.all()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(Set(recorded.map(\.url)).count, 1, "both attempts named the same, one account")
    }

    /// Once settled, never repeated; a job that carries no step is left alone.
    func testASettledOrAbsentStepIsNeverCalled() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        answer(calls) { XCTFail("a settled step must not call again"); return .ok }
        for settled in ["deleted", "not_found", "skipped_environment", "not_requested"] {
            let (job, userID) = try await fixture(objects: "pending", revenuecat: settled)
            let owned = try await lease(job, user: userID)
            try await RevenueCatCustomerDeletionService.perform(owned, app: app, on: app.db)
            let current3 = try await row(job)
            XCTAssertEqual(current3.revenuecat, settled)
        }
        let recorded = await calls.all()
        XCTAssertTrue(recorded.isEmpty)
    }

    /// The URL can only ever carry this job's own, deleted account. A live account, or
    /// a lease that names a different user from the job's row, reaches nothing.
    func testALiveAccountOrAMismatchedLeaseIsNeverNamed() async throws {
        let calls = Calls()
        setRevenueCat(platform: "production", key: key)
        answer(calls) { XCTFail("no customer may be named here"); return .ok }
        let (live, liveUser) = try await fixture(deleted: false)
        let liveLease = try await lease(live, user: liveUser)
        try await RevenueCatCustomerDeletionService.perform(liveLease, app: app, on: app.db)
        let current4 = try await row(live)
        XCTAssertEqual(current4.revenuecat, "pending")

        let (job, _) = try await fixture()
        let other = try await user("other")
        let mismatched = try await lease(job, user: other)
        try await RevenueCatCustomerDeletionService.perform(mismatched, app: app, on: app.db)
        let current5 = try await row(job)
        XCTAssertEqual(current5.revenuecat, "pending")
        let recorded = await calls.all()
        XCTAssertTrue(recorded.isEmpty)
    }

    /// Completion is refused by the schema itself while the step is outstanding, and
    /// `finish` does not claim it either.
    func testANewJobCannotCompleteWhileTheStepIsOutstanding() async throws {
        let target = try await user("constraint")
        let job = try await deleteAccount(target)
        let owned = try await lease(job, user: target)
        let state = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertNotEqual(state, "completed", "finish without the step cannot complete")
        for outstanding in ["pending", "failing", "misconfigured"] {
            do {
                try await VerifiedIdentityService.sql(app.db).raw("""
                    UPDATE account_deletion_jobs SET state='completed',completed_at=NOW(),database_cleanup_state='completed',
                        object_cleanup_state='completed',apple_revocation_state='not_applicable',apple_credential_ciphertext=NULL,
                        lease_token=NULL,lease_expires_at=NULL,revenuecat_state=\(bind: outstanding)
                    WHERE id=\(bind: job)
                    """).run()
                XCTFail("completion with the RevenueCat step \(outstanding) must be refused")
            } catch let error as PSQLError {
                XCTAssertEqual(error.serverInfo?[.sqlState], "23514", outstanding)
                XCTAssertEqual(error.serverInfo?[.constraintName], "account_deletion_completion_settles_revenuecat", outstanding)
            }
        }
        // The control: the same write with the step settled is accepted, so the
        // constraint above is the only thing that refused it.
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET state='completed',completed_at=NOW(),database_cleanup_state='completed',
                object_cleanup_state='completed',apple_revocation_state='not_applicable',apple_credential_ciphertext=NULL,
                lease_token=NULL,lease_expires_at=NULL,revenuecat_state='skipped_environment'
            WHERE id=\(bind: job)
            """).run()
        let settled = try await row(job)
        XCTAssertEqual(settled.state, "completed")
    }

    /// A test never reaches the real service: without a transport there is no call.
    func testNoTransportUnderTestIsAFailureNotACall() async throws {
        app.storage[Service.TransportKey.self] = nil
        let outcome = await Service.deleteCustomer(appUserID: UUID().uuidString, secretKey: key, app: app)
        XCTAssertEqual(outcome, .failing)
    }
}
