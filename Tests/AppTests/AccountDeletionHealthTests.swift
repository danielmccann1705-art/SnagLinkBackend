@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// The deletion health rules, without a database: the same groups always give the
/// same readout.
final class AccountDeletionHealthRulesTests: XCTestCase {
    typealias Health = AccountDeletionHealth
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func group(blocked: Bool = false, reason: String?, open: Int = 1, days: Double = 0) -> Health.Group {
        .init(blocked: blocked, reason: reason, open: open,
              olderThanAttention: days > 7 ? open : 0, olderThanEscalation: days > 25 ? open : 0,
              oldestRequestedAt: now.addingTimeInterval(-days * 86_400 - 60))
    }
    private var recentPass: Date { now.addingTimeInterval(-1_800) }

    /// Astra §3.2's proof, as a rule: a blocked job reaches the operator; a healthy
    /// one does not.
    func testABlockedJobIsReportedAndAHealthyOneIsNot() {
        let healthy = group(reason: "object_cleanup_pending")
        let onlyHealthy = Health.summarise([healthy], now: now, lastSuccessfulPass: recentPass)
        XCTAssertEqual(onlyHealthy.status, .ok)
        XCTAssertEqual(onlyHealthy.openJobs, 1)
        XCTAssertEqual(onlyHealthy.blocked, 0)
        XCTAssertEqual(onlyHealthy.blockedByReason, [:])
        XCTAssertEqual(onlyHealthy.attentionByReason, [:], "a healthy job is not reported")

        let blocked = group(blocked: true, reason: "apple_configuration")
        let both = Health.summarise([healthy, blocked], now: now, lastSuccessfulPass: recentPass)
        XCTAssertEqual(both.status, .attention)
        XCTAssertEqual(both.openJobs, 2)
        XCTAssertEqual(both.blocked, 1)
        XCTAssertEqual(both.blockedByReason, ["apple_configuration": 1])
        XCTAssertEqual(both.attentionByReason, ["apple_configuration": 1], "only the blocked job is reported, under its reason")

        let flag = Health.flag([healthy, blocked], now: now, previousPass: recentPass)
        XCTAssertEqual(flag.status, .attention)
        XCTAssertEqual(flag.reasons, ["apple_configuration": 1])
        XCTAssertEqual(Health.flag([healthy], now: now, previousPass: recentPass).status, .ok)
    }

    /// Seven days open is attention; twenty-five is escalation, five days before the
    /// thirty-day target. Every reason is counted.
    func testSevenDaysIsAttentionAndTwentyFiveIsEscalation() {
        let week = Health.summarise([group(reason: "object_cleanup_pending", days: 8)], now: now, lastSuccessfulPass: recentPass)
        XCTAssertEqual(week.status, .attention)
        XCTAssertEqual(week.olderThan7Days, 1)
        XCTAssertEqual(week.olderThan25Days, 0)
        XCTAssertEqual(week.attentionByReason, ["object_cleanup_pending": 1])
        XCTAssertEqual(week.oldestOpenAgeDays, 8)

        let late = Health.summarise([group(reason: "revenuecat_unavailable", open: 2, days: 26),
                                     group(blocked: true, reason: "object_target_ambiguous", days: 1),
                                     group(reason: "object_cleanup_pending", days: 2)],
                                    now: now, lastSuccessfulPass: recentPass)
        XCTAssertEqual(late.status, .escalate)
        XCTAssertEqual(late.olderThan25Days, 2)
        XCTAssertEqual(late.olderThan7Days, 2)
        XCTAssertEqual(late.blocked, 1)
        XCTAssertEqual(late.attentionByReason, ["revenuecat_unavailable": 2, "object_target_ambiguous": 1])
        XCTAssertEqual(late.oldestOpenAgeDays, 26)
        XCTAssertEqual(late.thresholds, .init(attentionDays: 7, escalationDays: 25, targetDays: 30, schedulerStaleHours: 2))
    }

    /// A stopped scheduler stops every deletion, so the on-demand readout says so
    /// even with no job open. The pass's own flag does not count its first run, or a
    /// normal hourly gap, against itself.
    func testAStoppedSchedulerIsAttention() {
        XCTAssertEqual(Health.summarise([], now: now, lastSuccessfulPass: now.addingTimeInterval(-3 * 3_600)).status, .attention)
        XCTAssertEqual(Health.summarise([], now: now, lastSuccessfulPass: nil).status, .attention, "never run is not healthy")
        XCTAssertEqual(Health.summarise([], now: now, lastSuccessfulPass: recentPass).status, .ok)
        XCTAssertEqual(Health.flag([], now: now, previousPass: nil).status, .ok)
        XCTAssertNil(Health.flag([], now: now, previousPass: nil).previousPassGapHours)
        let hourly = Health.flag([], now: now, previousPass: now.addingTimeInterval(-3_700))
        XCTAssertEqual(hourly.status, .ok)
        XCTAssertEqual(hourly.previousPassGapHours, 1)
        let missed = Health.flag([], now: now, previousPass: now.addingTimeInterval(-3 * 3_600 - 60))
        XCTAssertEqual(missed.status, .attention)
        XCTAssertEqual(missed.previousPassGapHours, 3)
    }

    /// A reason column is text. Anything outside the closed vocabulary is counted as
    /// `other` and never echoed into the readout or the log.
    func testUnknownReasonTextIsCountedAndNeverEchoed() {
        let odd = group(blocked: true, reason: "bucket snaglist-private key private-v1/abc token=xyz")
        let none = group(blocked: true, reason: nil)
        let report = Health.summarise([odd, none], now: now, lastSuccessfulPass: recentPass)
        XCTAssertEqual(report.blockedByReason, ["other": 1, "unspecified": 1])
        let line = Health.logLine(Health.flag([odd, none], now: now, previousPass: recentPass))
        XCTAssertFalse(line.contains("bucket") || line.contains("private-v1") || line.contains("token"), line)
        for kind in DeletionReasonKind.allCases { XCTAssertEqual(Health.reasonName(kind.rawValue), kind.rawValue) }
    }

    /// One line, one shape, counts and vocabulary words only.
    func testTheLogLineIsStable() {
        let flag = Health.Flag(status: .attention, open: 3, blocked: 1, olderThan7Days: 1, olderThan25Days: 0,
                               oldestOpenAgeDays: 8, reasons: ["object_cleanup_pending": 1, "apple_configuration": 1],
                               previousPassGapHours: 1)
        XCTAssertEqual(Health.logLine(flag),
                       "Account deletion health: status=attention open=3 blocked=1 older_than_7d=1 older_than_25d=0 oldest_open_days=8 previous_pass_gap_h=1 reasons=apple_configuration:1,object_cleanup_pending:1")
        let quiet = Health.Flag(status: .ok, open: 0, blocked: 0, olderThan7Days: 0, olderThan25Days: 0,
                                oldestOpenAgeDays: nil, reasons: [:], previousPassGapHours: nil)
        XCTAssertEqual(Health.logLine(quiet),
                       "Account deletion health: status=ok open=0 blocked=0 older_than_7d=0 older_than_25d=0 oldest_open_days=none previous_pass_gap_h=none reasons=none")
    }

    /// The scheduler refuses a maintenance response over 4,096 bytes
    /// (`production-backend.mjs`). With every reason at once and seven-digit counts,
    /// the response that now carries the flag still fits.
    func testTheFlagFitsTheSchedulerResponseCapWithEveryReason() throws {
        var reasons = Dictionary(uniqueKeysWithValues: DeletionReasonKind.allCases.map { ($0.rawValue, 9_999_999) })
        reasons["unspecified"] = 9_999_999; reasons["other"] = 9_999_999
        var removed = CleanupService.Removed()
        removed.rateLimits = 9_999_999; removed.auditLogs = 9_999_999
        removed.magicLinkAuthTokens = 9_999_999; removed.expiredPreviewLinks = 9_999_999
        removed.accountDeletionJobs = .init(processed: 32, completed: 32, blocked: 32, retrying: 32, deferredByBudget: 32)
        removed.accountDeletionHealth = .init(status: .escalate, open: 9_999_999, blocked: 9_999_999, olderThan7Days: 9_999_999,
                                              olderThan25Days: 9_999_999, oldestOpenAgeDays: 99_999, reasons: reasons,
                                              previousPassGapHours: 99_999)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(MaintenanceCleanupResponse(ran: true, removed: removed, lastSuccessfulRun: now))
        XCTAssertLessThan(body.count, 4_096, "\(body.count) bytes")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("@"))
    }
}

/// The deletion health check against PostgreSQL, the scheduled pass and the route.
/// Other suites leave their own jobs behind, so every count here is a difference
/// this test caused, and the jobs it inserts are never due and are removed after.
final class AccountDeletionHealthTests: XCTestCase {
    typealias Health = AccountDeletionHealth
    var app: Application!
    let secret = String(repeating: "h", count: 48)
    var inserted: [UUID] = []

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[MaintenanceSecretKey.self] = secret
        app.storage[CleanupLockKeyStorage.self] = Int64.random(in: 1_000_000...9_000_000)
        inserted = []
    }
    override func tearDown() async throws {
        if let app {
            for id in inserted { try? await VerifiedIdentityService.sql(app.db).raw("DELETE FROM account_deletion_jobs WHERE id=\(bind: id)").run() }
            try await app.asyncShutdown()
        }
    }

    /// A synthetic job, never due, `days` old.
    @discardableResult
    private func job(state: String, reason: String?, days: Int) async throws -> (UUID, UUID) {
        let userID = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("health-\(UUID())@example.test", name: "Synthetic health", on: db).requireID()
        }
        let id = UUID(), reference = UUID().uuidString + UUID().uuidString
        let completed = state == "completed"
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,completed_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state,revenuecat_state,last_error_kind)
            VALUES(\(bind: id),\(bind: userID),\(bind: AccountDeletionService.receiptHash(reference)),
                NOW()-make_interval(secs => \(bind: Double(days) * 86_400)),\(bind: completed ? Date() : nil),\(bind: state),
                clock_timestamp()+INTERVAL '1 day',\(bind: completed ? "completed" : "pending"),\(bind: completed ? "completed" : "pending"),
                'not_applicable',\(bind: completed ? "deleted" : "pending"),\(bind: reason))
            """).run()
        inserted.append(id)
        return (id, userID)
    }
    private func delta(_ after: [String: Int], _ before: [String: Int], _ key: String) -> Int {
        (after[key] ?? 0) - (before[key] ?? 0)
    }

    /// Astra §3.2 / DT2: a synthetic blocked job reaches the operator's readout under
    /// its reason; a healthy one does not; age thresholds are applied to the rows.
    func testASyntheticBlockedJobIsReportedAndAHealthyOneIsNot() async throws {
        let before = try await Health.report(on: app.db)
        try await job(state: "blocked", reason: "apple_configuration", days: 0)
        try await job(state: "ready", reason: "database_erasure_pending", days: 0)
        let after = try await Health.report(on: app.db)
        XCTAssertEqual(after.openJobs - before.openJobs, 2)
        XCTAssertEqual(after.blocked - before.blocked, 1)
        XCTAssertEqual(delta(after.blockedByReason, before.blockedByReason, "apple_configuration"), 1)
        XCTAssertEqual(delta(after.attentionByReason, before.attentionByReason, "apple_configuration"), 1)
        XCTAssertEqual(delta(after.attentionByReason, before.attentionByReason, "database_erasure_pending"), 0,
                       "the healthy job is not reported")
        XCTAssertEqual(delta(after.blockedByReason, before.blockedByReason, "database_erasure_pending"), 0)
        XCTAssertEqual(after.olderThan7Days - before.olderThan7Days, 0)
        XCTAssertNotEqual(after.status, .ok)

        try await job(state: "ready", reason: "object_cleanup_pending", days: 8)
        try await job(state: "ready", reason: "revenuecat_unavailable", days: 26)
        try await job(state: "completed", reason: nil, days: 40)
        let aged = try await Health.report(on: app.db)
        XCTAssertEqual(aged.openJobs - before.openJobs, 4, "a completed job is not open, however old")
        XCTAssertEqual(aged.olderThan7Days - before.olderThan7Days, 2)
        XCTAssertEqual(aged.olderThan25Days - before.olderThan25Days, 1)
        XCTAssertEqual(delta(aged.attentionByReason, before.attentionByReason, "object_cleanup_pending"), 1)
        XCTAssertEqual(delta(aged.attentionByReason, before.attentionByReason, "revenuecat_unavailable"), 1)
        XCTAssertEqual(aged.status, .escalate)
        XCTAssertGreaterThanOrEqual(aged.oldestOpenAgeDays ?? 0, 26)
    }

    /// The scheduled pass writes the flag into its own durable record and writes one
    /// log line, and neither carries anything that identifies a person or a job.
    func testTheScheduledPassRecordsTheFlagAndOneSecretFreeLine() async throws {
        let box = DeletionHealthLogBox()
        app.logger = Logger(label: "deletion-health-test") { _ in DeletionHealthLogHandler(box: box) }
        let (jobID, userID) = try await job(state: "blocked", reason: "apple_configuration", days: 0)
        // No deletion budget: the pass claims nothing another suite left, and still
        // reads health after its work.
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test, budget: .init(total: 0, minimumPerJob: 30))
        let flag = try XCTUnwrap(removed?.accountDeletionHealth)
        XCTAssertNotEqual(flag.status, .ok)
        XCTAssertGreaterThanOrEqual(flag.blocked, 1)
        XCTAssertGreaterThanOrEqual(flag.reasons["apple_configuration"] ?? 0, 1)

        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT removed_json FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        let json = try XCTUnwrap(try row?.decode(column: "removed_json", as: String?.self))
        let recorded = try JSONDecoder().decode(CleanupService.Removed.self, from: Data(json.utf8))
        XCTAssertEqual(recorded.accountDeletionHealth, flag, "the durable record carries the flag, not just the return value")
        for secretFree in [json, box.lines().map(\.message).joined(separator: "\n")] {
            XCTAssertFalse(secretFree.contains("@"))
            XCTAssertFalse(secretFree.uppercased().contains(jobID.uuidString))
            XCTAssertFalse(secretFree.uppercased().contains(userID.uuidString))
        }
        let lines = box.lines().filter { $0.message.hasPrefix("Account deletion health: ") }
        XCTAssertEqual(lines.count, 1, "one line per pass")
        XCTAssertEqual(lines.first?.message, Health.logLine(flag))
        XCTAssertTrue([Logger.Level.warning, .error].contains(lines.first?.level ?? .trace), "a job needing a person is not an info line")
    }

    /// Readable on demand without running a pass, behind the maintenance secret and
    /// invisible without it.
    func testTheReadoutIsMaintenanceOnly() async throws {
        let (jobID, _) = try await job(state: "blocked", reason: "revenuecat_configuration", days: 0)
        try await app.test(.GET, "internal/maintenance/account-deletion-health", afterResponse: { response async in
            XCTAssertEqual(response.status, .notFound)
        })
        try await app.test(.GET, "internal/maintenance/account-deletion-health", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: String(repeating: "x", count: 48))
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .notFound, "a wrong secret gets the same answer as none")
        })
        try await app.test(.GET, "internal/maintenance/account-deletion-health", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: self.secret)
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .ok)
            let report = try? response.content.decode(Health.Report.self)
            XCTAssertGreaterThanOrEqual(report?.blockedByReason["revenuecat_configuration"] ?? 0, 1)
            XCTAssertNotEqual(report?.status, .ok)
            XCTAssertFalse(response.body.string.uppercased().contains(jobID.uuidString))
        })
    }
}

private final class DeletionHealthLogBox: @unchecked Sendable {
    struct Line { let level: Logger.Level; let message: String }
    private let mutex = NSLock()
    private var stored: [Line] = []
    func append(_ line: Line) { mutex.lock(); stored.append(line); mutex.unlock() }
    func lines() -> [Line] { mutex.lock(); defer { mutex.unlock() }; return stored }
}

private struct DeletionHealthLogHandler: LogHandler {
    let box: DeletionHealthLogBox
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        box.append(.init(level: level, message: message.description))
    }
}
