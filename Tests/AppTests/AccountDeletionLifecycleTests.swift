@testable import App
import XCTVapor
import Fluent
import FluentSQL
import PostgresNIO

/// All identities and credentials are synthetic; no provider or object-store IO.
final class AccountDeletionLifecycleTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> UUID {
        try await app.db.transaction { db in
            let user = try await VerifiedIdentityService.resolveEmail("deletion-\(UUID())@example.test", name: "Synthetic owner", on: db)
            return try user.requireID()
        }
    }
    private func reference() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    }
    private func job(apple: String = "not_applicable", database: String = "completed", objects: String = "completed") async throws -> (UUID, UUID, String) {
        let userID = try await user(), id = UUID(), reference = reference()
        let ciphertext: String? = ["pending", "misconfigured", "failing"].contains(apple) ? "synthetic-ciphertext" : nil
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state,apple_credential_ciphertext,apple_client_id)
            VALUES(\(bind: id),\(bind: userID),\(bind: AccountDeletionService.receiptHash(reference)),NOW(),'ready',NOW(),
                \(bind: database),\(bind: objects),\(bind: apple),\(bind: ciphertext),\(bind: ciphertext == nil ? nil : "com.snaglist.app.staging"))
            """).run()
        return (id, userID, reference)
    }
    /// The lease window is stamped in the database's clock, because that is the
    /// only clock the predicates under test consult. A fixture that stamped it from
    /// this process would be asserting that two machines agree about the time.
    private func lease(_ id: UUID, user: UUID, expired: Bool = false) async throws -> AccountDeletionWorker.Lease {
        let token = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),
                lease_expires_at=clock_timestamp()+make_interval(secs => \(bind: expired ? -60.0 : 300.0)) WHERE id=\(bind: id)
            """).run()
        return .init(id: id, userID: user, token: token, attempt: 1)
    }

    func testExpiredLeaseCannotRenewOrCompleteBeforeAnotherWorkerClaimsIt() async throws {
        let (id, user, _) = try await job()
        let old = try await lease(id, user: user, expired: true)
        let renewed = try await AccountDeletionWorker.renew(old, on: app.db)
        let finished = try await AccountDeletionWorker.finish(old, on: app.db)
        XCTAssertFalse(renewed)
        XCTAssertNil(finished)
    }
    func testReplacedLeaseCannotCompleteAnotherWorkersJob() async throws {
        let (id, user, _) = try await job()
        let old = try await lease(id, user: user)
        let replacement = try await lease(id, user: user)
        let stale = try await AccountDeletionWorker.finish(old, on: app.db)
        XCTAssertNil(stale)
        let current = try await AccountDeletionWorker.finish(replacement, on: app.db)
        XCTAssertEqual(current, "completed")
    }
    func testMissingAppleCredentialRemainsBlockedAndCannotClaimCompletion() async throws {
        let (id, user, reference) = try await job(apple: "unavailable")
        let owned = try await lease(id, user: user)
        let finished = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(finished, "blocked")
        let status = try await AccountDeletionService.status(reference: reference, on: app.db)
        XCTAssertEqual(status.state, "blocked")
        XCTAssertNil(status.completedAt)
    }
    func testIncompleteGraphCannotClaimCompletion() async throws {
        let (id, user, _) = try await job(database: "blocked", objects: "blocked")
        let owned = try await lease(id, user: user)
        let finished = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(finished, "blocked")
    }
    func testReceiptStoredOnlyAsHashAndStatusMapsInternalLeaseToPending() async throws {
        let (id, user, reference) = try await job()
        _ = try await lease(id, user: user)
        let status = try await AccountDeletionService.status(reference: reference, on: app.db)
        XCTAssertEqual(status.state, "pending")
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT receipt_hash FROM account_deletion_jobs WHERE id=\(bind: id)").first()
        let hash = try row?.decode(column: "receipt_hash", as: String.self)
        XCTAssertNotEqual(hash, reference)
        XCTAssertEqual(hash, try AccountDeletionService.receiptHash(reference))
    }
    func testStatusIsUnauthenticatedAndPrivateEvenForUnknownReferences() async throws {
        let (_, _, saved) = try await job()
        for (reference, expected) in [(saved, HTTPResponseStatus.ok), (reference(), .notFound)] {
            try await app.test(.POST, "api/v1/account-deletion/status", beforeRequest: { req in
                try req.content.encode(AccountDeletionStatusRequest(receiptReference: reference))
            }, afterResponse: { response async in
                XCTAssertEqual(response.status, expected)
                XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
                XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
                XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
            })
        }
    }
    func testWeakOrURLShapedReceiptIsRejected() throws {
        for value in ["short", "https://example.test/" + String(repeating: "x", count: 50), String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try AccountDeletionService.receiptHash(value))
        }
    }
    func testCompanyOwnerMustTransferBeforeAnyIdentityIsErased() async throws {
        let userID = try await user()
        _ = try await app.db.transaction { db in
            try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic company", actorID: userID, on: db)
        }
        do {
            _ = try await AccountDeletionService.request(userID: userID, body: .init(confirmation: "DELETE", receiptReference: reference()), app: app)
            XCTFail("Company owner deletion must fail before modifying account")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .conflict)
            XCTAssertEqual(abort.identifier, "company_owner_action_required")
        }
        let user = try await VerifiedIdentityService.activeUser(userID, on: app.db)
        XCTAssertNotNil(user.email)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS total FROM account_deletion_jobs WHERE user_id=\(bind: userID)").first()
        XCTAssertEqual(try count?.decode(column: "total", as: Int.self), 0)
    }
    func testDeletedUserCannotAcquireCredentialsOrWorkspaceAuthority() async throws {
        let userID = try await user()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET lifecycle_state='deleted' WHERE id=\(bind: userID)").run()
        do {
            try await VerifiedIdentityService.sql(app.db).raw("""
                INSERT INTO apple_credentials(user_id,refresh_token_ciphertext,client_id,created_at,updated_at)
                VALUES(\(bind: userID),'synthetic','com.snaglist.app',NOW(),NOW())
                """).run()
            XCTFail("A late credential write must be refused")
        } catch { }
        do {
            try await Team(name: "Synthetic late workspace", ownerUserId: userID).save(on: app.db)
            XCTFail("A late ownership assignment must be refused")
        } catch { }
    }
    actor Operations {
        var revoked = 0
        var deleted = 0
        func revocation() { revoked += 1 }
        func deletion() { deleted += 1 }
        func counts() -> (Int, Int) { (revoked, deleted) }
    }
    private func object(jobID: UUID) async throws -> String {
        let key = "platform/\(UUID())/\(UUID())/\(UUID())/original"
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key) VALUES(\(bind: jobID),'private_media',\(bind: key))
            """).run()
        return key
    }
    func testWorkerRevokesAppleAndOnlyThenClearsEncryptedCredential() async throws {
        let operations = Operations()
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, ciphertext, client in
                XCTAssertEqual(ciphertext, "synthetic-ciphertext")
                XCTAssertEqual(client, "com.snaglist.app.staging")
                await operations.revocation()
                return .revoked
            }, deleteObject: { _, _ in await operations.deletion() })
        let (id, user, _) = try await job(apple: "pending")
        let owned = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let state = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(state, "completed")
        let counts = await operations.counts()
        XCTAssertEqual(counts.0, 1)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT apple_credential_ciphertext,apple_client_id FROM account_deletion_jobs WHERE id=\(bind: id)").first()
        XCTAssertNil(try row?.decode(column: "apple_credential_ciphertext", as: String?.self))
        XCTAssertNil(try row?.decode(column: "apple_client_id", as: String?.self))
    }
    func testAppleConfigurationFailureRetainsCredentialAndBlocksCompletion() async throws {
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .misconfigured }, deleteObject: { _, _ in })
        let (id, user, _) = try await job(apple: "pending")
        let owned = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let state = try await AccountDeletionWorker.finish(owned, on: app.db)
        XCTAssertEqual(state, "blocked")
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT apple_credential_ciphertext FROM account_deletion_jobs WHERE id=\(bind: id)").first()
        XCTAssertEqual(try row?.decode(column: "apple_credential_ciphertext", as: String?.self), "synthetic-ciphertext")
    }
    func testGraphMustCompleteBeforeAnyObjectIsDeleted() async throws {
        let operations = Operations()
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in await operations.deletion() })
        let (id, user, _) = try await job(database: "blocked", objects: "blocked")
        _ = try await object(jobID: id)
        let owned = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(owned, app: app, on: app.db)
        let counts = await operations.counts()
        XCTAssertEqual(counts.1, 0)
    }
    func testTransientObjectFailureKeepsManifestForSuccessfulRetry() async throws {
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in throw Abort(.serviceUnavailable) })
        let (id, user, _) = try await job(objects: "pending")
        _ = try await object(jobID: id)
        let first = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(first, app: app, on: app.db)
        let pending = try await AccountDeletionWorker.finish(first, on: app.db)
        XCTAssertEqual(pending, "ready")
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
        let retry = try await lease(id, user: user)
        try await AccountDeletionWorker.perform(retry, app: app, on: app.db)
        let completed = try await AccountDeletionWorker.finish(retry, on: app.db)
        XCTAssertEqual(completed, "completed")
    }
    func testMaintenanceConnectionHoldsParentLockAndRollsBackChildProgress() async throws {
        let (id, user, _) = try await job(objects: "pending")
        _ = try await object(jobID: id)
        let owned = try await lease(id, user: user)
        // A distinct pool guarantees a competing backend even when each pool
        // allows only one connection per event loop.
        let rival = try IsolatedMigrationDatabase.pool(app: app, schema: "public")
        enum InjectedFailure: Error { case rollback }
        try await app.db.withConnection { pinned in
            do {
                try await AccountDeletionWorker.writeIfCurrent(owned, on: pinned,
                                                               transactionMode: .maintenanceConnection) { sql in
                    do {
                        try await rival.transaction { other in
                            let competing = try VerifiedIdentityService.sql(other)
                            try await competing.raw("SET LOCAL lock_timeout='100ms'").run()
                            try await competing.raw("UPDATE account_deletion_jobs SET lease_token=\(bind: UUID()) WHERE id=\(bind: id)").run()
                        }
                        XCTFail("Replacement lease must wait for the parent lock")
                    } catch let error as PSQLError {
                        XCTAssertEqual(error.serverInfo?[.sqlState], "55P03", "Only the competing row-lock timeout proves the fence")
                    }
                    try await sql.raw("UPDATE account_deletion_objects SET attempts=attempts+1 WHERE job_id=\(bind: id)").run()
                    throw InjectedFailure.rollback
                }
                XCTFail("Injected failure must propagate")
            } catch InjectedFailure.rollback { }
            let row = try await VerifiedIdentityService.sql(pinned).raw("SELECT attempts FROM account_deletion_objects WHERE job_id=\(bind: id)").first()
            XCTAssertEqual(try row?.decode(column: "attempts", as: Int.self), 0)
            // The connection returns to autocommit after rollback and can be
            // reused by the next job without retaining any transaction locks.
            let changed = try await AccountDeletionWorker.writeIfCurrent(owned, on: pinned,
                                                                          transactionMode: .maintenanceConnection) { sql in
                try await sql.raw("UPDATE account_deletion_objects SET attempts=attempts+1 WHERE job_id=\(bind: id)").run()
            }
            XCTAssertTrue(changed)
        }
    }
    func testFailedMigrationLeavesNoPartialJobOrManifestTables() async throws {
        let schema = "deletion_migration_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await IsolatedMigrationDatabase.withSchema(app: app, schema: schema) { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("CREATE TABLE users(id UUID PRIMARY KEY)").run()
            do {
                try await CreateAccountDeletionJobs().prepare(on: db)
                XCTFail("The deliberately missing credential tables must fail migration")
            } catch { }
            let row = try await sql.raw("SELECT COUNT(*) AS total FROM information_schema.tables WHERE table_schema=\(bind: schema) AND table_name IN ('account_deletion_jobs','account_deletion_objects')").first()
            XCTAssertEqual(try row?.decode(column: "total", as: Int.self), 0, "Failure must roll back both durable tables, indexes and functions")
        }
    }
    func testDeletedProfileCannotBeResurrectedByAStaleUpdate() async throws {
        let userID = try await user()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET lifecycle_state='deleted',name=NULL,email=NULL,apple_user_id=NULL,auth_version=auth_version+1 WHERE id=\(bind: userID)").run()
        do {
            try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET email='stale@example.test',name='Stale name' WHERE id=\(bind: userID)").run()
            XCTFail("A stale profile update must not restore erased identity")
        } catch { }
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT email,name,lifecycle_state FROM users WHERE id=\(bind: userID)").first()
        XCTAssertNil(try row?.decode(column: "email", as: String?.self))
        XCTAssertNil(try row?.decode(column: "name", as: String?.self))
        XCTAssertEqual(try row?.decode(column: "lifecycle_state", as: String.self), "deleted")
    }
    func testDeletionActivationCannotBeEnabledInDevelopmentEnvironment() async throws {
        let development = try await Application.make(.development)
        development.storage[AccountDeletionTestActivation.self] = true
        XCTAssertThrowsError(try AccountDeletionService.requireAvailable(development))
        try await development.asyncShutdown()
    }

    // MARK: - the pass budget

    /// Makes every job that already existed undue. `run` claims by a global
    /// predicate, so a job another test left behind would be claimed by this pass
    /// too and the counts below would be measuring someone else's work.
    private func parkExistingJobs() async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET available_at=clock_timestamp()+INTERVAL '1 day',
                lease_expires_at=CASE WHEN state='leased' THEN clock_timestamp()+INTERVAL '1 day' ELSE lease_expires_at END
            WHERE state IN ('ready','blocked','leased')
            """).run()
    }

    /// One job's fence budget is the ceiling or whatever the pass has left,
    /// whichever is smaller, and never below zero — an overrun hands the next fence
    /// pass nothing rather than a deadline already behind it.
    func testTheFenceBudgetIsTheSmallerOfTheCeilingAndWhatThePassHasLeft() {
        let budget = AccountDeletionWorker.PassBudget()
        XCTAssertEqual(budget.total, 480)
        XCTAssertEqual(budget.minimumPerJob, 30)
        XCTAssertEqual(budget.fenceCeiling, AccountDeletionObjectFenceService.Budget.default.pass)
        XCTAssertEqual(AccountDeletionWorker.fencePass(remaining: 600, budget: budget), 120)
        XCTAssertEqual(AccountDeletionWorker.fencePass(remaining: 45, budget: budget), 45)
        XCTAssertEqual(AccountDeletionWorker.fencePass(remaining: -5, budget: budget), 0)
    }

    /// A pass is bounded in wall clock because the cron handler that awaits it is:
    /// eight jobs times a two-minute fence pass outlives the scheduled handler, and
    /// a pass cut off part-way leaves its advisory lock to die with the request.
    ///
    /// Three jobs, a five-second budget, four seconds of work each. The pass starts
    /// one, refuses to start a second it has no room to finish, and records how many
    /// it left. The two it did not start are still due — not failed, not backed off
    /// and not charged an attempt — so the next pass simply takes them.
    func testAPassSpendsAtMostItsBudgetAndLeavesTheRestForTheNextPass() async throws {
        try await parkExistingJobs()
        var ids: [UUID] = []
        for _ in 0..<3 {
            let (id, _, _) = try await job(objects: "pending")
            _ = try await object(jobID: id)
            ids.append(id)
        }
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked },
            deleteObject: { _, _ in try await Task.sleep(nanoseconds: 4 * 1_000_000_000) })

        let started = Date()
        let counts = try await AccountDeletionWorker.run(app: app, budget: .init(total: 5, minimumPerJob: 2))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(counts.processed, 1, "four seconds of work leaves less than the floor, so no second job is claimed")
        XCTAssertEqual(counts.deferredByBudget, 2, "what the budget stopped is recorded, not silently dropped")
        XCTAssertLessThan(elapsed, 9, "unbounded, three four-second jobs would be twelve")
        let due = try await AccountDeletionWorker.dueCount(on: app.db, limit: 8)
        XCTAssertEqual(due, 2, "the deferred jobs are still due rather than pushed down the backoff curve")

        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
        let next = try await AccountDeletionWorker.run(app: app)
        XCTAssertEqual(next.processed, 2, "the jobs that waited are taken by the next pass")
        XCTAssertEqual(next.deferredByBudget, 0)
        for id in ids {
            let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state,attempts FROM account_deletion_jobs WHERE id=\(bind: id)").first()
            XCTAssertEqual(try row?.decode(column: "state", as: String.self), "completed")
            XCTAssertEqual(try row?.decode(column: "attempts", as: Int.self), 1,
                           "a job the budget deferred was never claimed, so it never spent an attempt")
        }
    }
}
