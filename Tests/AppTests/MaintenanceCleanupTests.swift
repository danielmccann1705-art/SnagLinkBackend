@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// The cleanup substrate.
///
/// These test that a pass *does something and says it did*, not that a trigger is
/// declared somewhere. Asserting the cron entry exists would repeat the gap that let
/// the original defect through: the old suite proved `runCleanup` worked when called,
/// which was never the problem. The remaining half — a slept container woken by cron —
/// can only be shown in staging, and is recorded there.
final class MaintenanceCleanupTests: XCTestCase {
    var app: Application!
    let secret = String(repeating: "m", count: 48)
    var lock: Int64 = 0

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[MaintenanceSecretKey.self] = secret
        // Own lock, so a pass here never blocks or is blocked by another suite's.
        lock = Int64.random(in: 1_000_000...9_000_000)
        app.storage[CleanupLockKeyStorage.self] = lock
    }

    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func owner() async throws -> UUID {
        let user = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("maintenance-\(UUID())@example.test", name: "Synthetic owner", on: db)
        }
        return try user.requireID()
    }

    // MARK: - The pass does the work and leaves a trace

    func testAPassRemovesExpiredDataAndRecordsThatItRan() async throws {
        let ownerID = try await owner()
        let deadToken = "expired-\(UUID().uuidString)"
        try await MagicLink(token: deadToken, accessLevel: .update, expiresAt: Date().addingTimeInterval(3600),
                            snagIds: [UUID()], projectId: UUID(), createdById: ownerID,
                            previewMode: true, previewExpiresAt: Date().addingTimeInterval(-3600)).save(on: app.db)
        try await SyncedReport(magicLinkToken: deadToken, reportJSON: "{}").save(on: app.db)

        try await VerifiedIdentityService.sql(app.db).raw("UPDATE magic_links SET expires_at=NOW()-INTERVAL '1 hour' WHERE token=\(bind: deadToken)").run()

        let removed = try await CleanupService.runCleanup(app: app, trigger: .test)

        XCTAssertNotNil(removed)
        XCTAssertGreaterThanOrEqual(removed?.expiredPreviewLinks ?? 0, 1)
        let survivor = try await MagicLink.query(on: app.db).filter(\.$token == deadToken).first()
        XCTAssertNil(survivor)
        let lastRun = try await CleanupService.lastSuccessfulRun(on: app.db)
        XCTAssertNotNil(lastRun, "a pass that leaves no record is why the original defect was unanswerable")
    }

    func testTheRecordNamesCountsAndNothingElse() async throws {
        try await CleanupService.runCleanup(app: app, trigger: .test)
        let row = try await (app.db as! SQLDatabase)
            .raw("SELECT removed_json, state, duration_ms FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        let json = try XCTUnwrap(try row?.decode(column: "removed_json", as: String?.self))
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "succeeded")
        XCTAssertNotNil(try row?.decode(column: "duration_ms", as: Int?.self))
        let decoded = try JSONDecoder().decode(CleanupService.Removed.self, from: Data(json.utf8))
        XCTAssertGreaterThanOrEqual(decoded.auditLogs, 0)
        // Counts only. Nothing in the record should resemble an address or an identifier.
        XCTAssertFalse(json.contains("@"), "the run record must never carry an address")
        XCTAssertFalse(json.contains("-4"), "the run record must never carry a UUID")
    }

    /// A pass already in flight is skipped, not queued behind the first. Cron fires on a
    /// schedule that knows nothing about how long a pass takes.
    func testASecondPassIsSkippedWhileOneIsRunning() async throws {
        let lockDatabase = try IsolatedMigrationDatabase.pool(app: app, schema: "public")
        let removed = try await lockDatabase.withConnection { connection in
            let lockSQL = try VerifiedIdentityService.sql(connection)
            try await lockSQL.raw("SELECT pg_advisory_lock(\(bind: self.lock))").run()
            do {
                let result = try await CleanupService.runCleanup(app: self.app, trigger: .test)
                try await lockSQL.raw("SELECT pg_advisory_unlock(\(bind: self.lock))").run()
                return result
            } catch {
                try? await lockSQL.raw("SELECT pg_advisory_unlock(\(bind: self.lock))").run()
                throw error
            }
        }
        XCTAssertNil(removed, "a concurrent pass must be skipped rather than run twice")
        let sql = try VerifiedIdentityService.sql(app.db)

        let row = try await sql.raw("SELECT state, error_kind FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "skipped")
        XCTAssertEqual(try row?.decode(column: "error_kind", as: String?.self), "already_running")
    }

    /// Repeating a pass must be a no-op rather than an error, because that is what a
    /// crashed pass leaves the next firing to do.
    func testRepeatingAPassIsSafe() async throws {
        let first = try await CleanupService.runCleanup(app: app, trigger: .test)
        let second = try await CleanupService.runCleanup(app: app, trigger: .test)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "the lock must be released when a pass finishes")
        XCTAssertEqual(second?.expiredPreviewLinks, 0, "the second pass has nothing left to remove")
    }

    /// The budget belongs in the record. A pass that quietly leaves deletion work
    /// behind every hour looks exactly like a pass that had nothing to do, and that
    /// indistinguishability is the whole reason `cleanup_runs` exists.
    func testTheRecordSaysHowManyJobsTheBudgetDeferred() async throws {
        let ownerID = try await owner()
        let sql = try VerifiedIdentityService.sql(app.db)
        // Everything that already existed is made undue, so the count below is this
        // test's one job and nothing another suite happened to leave behind.
        try await sql.raw("""
            UPDATE account_deletion_jobs SET available_at=clock_timestamp()+INTERVAL '1 day',
                lease_expires_at=CASE WHEN state='leased' THEN clock_timestamp()+INTERVAL '1 day' ELSE lease_expires_at END
            WHERE state IN ('ready','blocked','leased')
            """).run()
        let jobID = UUID(), reference = UUID().uuidString + UUID().uuidString
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind: jobID),\(bind: ownerID),\(bind: AccountDeletionService.receiptHash(reference)),NOW(),'ready',NOW(),
                'completed','completed','not_applicable')
            """).run()

        // A budget with nothing left in it: the pass claims no deletion job at all,
        // does the rest of its work, and says what it did not get to.
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test,
                                                          budget: .init(total: 0, minimumPerJob: 30))
        XCTAssertEqual(removed?.accountDeletionJobs.processed, 0, "a job is not claimed with no budget to run it")
        XCTAssertEqual(removed?.accountDeletionJobs.deferredByBudget, 1)

        let row = try await sql.raw("SELECT removed_json FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        let json = try XCTUnwrap(try row?.decode(column: "removed_json", as: String?.self))
        let decoded = try JSONDecoder().decode(CleanupService.Removed.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.accountDeletionJobs.deferredByBudget, 1,
                       "the durable record, not just the return value, carries what the budget deferred")
        XCTAssertFalse(json.contains("@"), "the run record must never carry an address")

        // The job was only ever a stand-in for a backlog; leaving it due would hand
        // it to the next test's pass.
        try await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind: jobID)").run()
    }

    // MARK: - The route

    func testTheRouteIsInvisibleWithoutTheSecret() async throws {
        try await app.test(.POST, "internal/maintenance/cleanup", afterResponse: { response async in
            XCTAssertEqual(response.status, .notFound, "an unauthenticated caller learns nothing")
        })
    }

    func testAWrongSecretIsAlsoInvisible() async throws {
        try await app.test(.POST, "internal/maintenance/cleanup", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: String(repeating: "x", count: 48))
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .notFound, "a wrong secret must not get a different answer from no secret")
        })
    }

    func testTheRouteDoesNotExistAtAllWhenNoSecretIsConfigured() async throws {
        app.storage[MaintenanceSecretKey.self] = nil
        try await app.test(.POST, "internal/maintenance/cleanup", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.secret)
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .notFound)
        })
    }

    func testTheSchedulerCanRunAPassAndReadTheResult() async throws {
        let ownerID = try await owner()
        let deadToken = "expired-\(UUID().uuidString)"
        try await MagicLink(token: deadToken, accessLevel: .update, expiresAt: Date().addingTimeInterval(-3600),
                            snagIds: [UUID()], projectId: UUID(), createdById: ownerID,
                            previewMode: true, previewExpiresAt: Date().addingTimeInterval(-3600)).save(on: app.db)

        try await app.test(.POST, "internal/maintenance/cleanup", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.secret)
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
            let body = try? response.content.decode(MaintenanceCleanupResponse.self)
            XCTAssertEqual(body?.ran, true)
            XCTAssertNotNil(body?.lastSuccessfulRun)
        })
        let remaining = try await MagicLink.query(on: app.db).filter(\.$token == deadToken).first()
        XCTAssertNil(remaining)
    }

    /// The readout that would have answered "has this ever run?" in the first place.
    func testTheStatusReadoutReportsOverdueWhenNothingHasRun() async throws {
        try await (app.db as! SQLDatabase).raw("DELETE FROM cleanup_runs").run()
        try await app.test(.GET, "internal/maintenance/cleanup", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.secret)
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
            let body = try? response.content.decode(MaintenanceStatusResponse.self)
            XCTAssertEqual(body?.overdue, true)
            XCTAssertNil(body?.lastSuccessfulRun)
        })
    }

    func testTheStatusReadoutStopsBeingOverdueAfterAPass() async throws {
        try await CleanupService.runCleanup(app: app, trigger: .test)
        try await app.test(.GET, "internal/maintenance/cleanup", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.secret)
        }, afterResponse: { response async in
            let body = try? response.content.decode(MaintenanceStatusResponse.self)
            XCTAssertEqual(body?.overdue, false)
            XCTAssertEqual(body?.hoursSinceLastRun, 0)
        })
    }

    /// The record has to say whether the *scheduler* reached us, which it cannot do if
    /// the fallback loop files itself under the same name.
    func testTheFallbackLoopIsRecordedApartFromTheScheduler() async throws {
        try await CleanupService.runCleanup(app: app, trigger: .fallback)
        let row = try await (app.db as! SQLDatabase)
            .raw("SELECT trigger FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        XCTAssertEqual(try row?.decode(column: "trigger", as: String.self), "fallback")
        XCTAssertNotEqual(CleanupService.Trigger.fallback.rawValue, CleanupService.Trigger.schedule.rawValue)
    }

    func testAConstantTimeComparisonStillCompares() {
        XCTAssertTrue(MaintenanceAuthority.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(MaintenanceAuthority.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(MaintenanceAuthority.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(MaintenanceAuthority.constantTimeEqual("", "a"))
    }
}
