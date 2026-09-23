import Vapor
import Fluent
import FluentSQL

/// The owner-visible check on account deletion: which deletion jobs are blocked, and
/// which have been open long enough that a person must look, with the count for each
/// reason. It sends nothing anywhere. It is read three ways:
///
/// * every maintenance pass writes the compact `Flag` into that pass's
///   `cleanup_runs.removed_json` (`accountDeletionHealth`) and writes one log line;
/// * `GET /internal/maintenance/account-deletion-health` returns the full `Report`
///   to a caller holding the maintenance secret;
/// * the operator runbook's read-only SQL reads the same columns directly.
///
/// **Thresholds.** Open 7 days: attention. Open 25 days: escalation, which leaves five
/// days before the 30-day target. Any `blocked` job: attention at once, because a
/// blocked job retries for ever and progresses only when someone acts. No successful
/// pass for 2 hours (the cron is hourly): attention, because nothing below runs.
///
/// **Nothing identifying.** Counts, reason words from the closed `DeletionReasonKind`
/// vocabulary, ages and times. Never a job or user ID, a receipt, an address, an object
/// key or a provider's message. A reason column that holds anything outside the
/// vocabulary is counted as `other`, never echoed.
enum AccountDeletionHealth {
    static let attentionDays = 7
    static let escalationDays = 25
    static let targetDays = 30
    static let schedulerStaleHours = 2

    enum Status: String, Codable, Sendable, Equatable {
        case ok, attention, escalate
    }

    /// One `(blocked?, reason)` group of open jobs, as SQL returns it.
    struct Group: Sendable, Equatable {
        var blocked: Bool
        var reason: String?
        var open: Int
        var olderThanAttention: Int
        var olderThanEscalation: Int
        var oldestRequestedAt: Date?
    }

    struct Thresholds: Content, Equatable {
        var attentionDays = AccountDeletionHealth.attentionDays
        var escalationDays = AccountDeletionHealth.escalationDays
        var targetDays = AccountDeletionHealth.targetDays
        var schedulerStaleHours = AccountDeletionHealth.schedulerStaleHours
    }

    /// The on-demand readout.
    struct Report: Content, Equatable {
        var status: Status
        var checkedAt: Date
        /// Jobs not yet `completed`, whatever their state.
        var openJobs: Int
        var blocked: Int
        var olderThan7Days: Int
        var olderThan25Days: Int
        var oldestOpenAgeDays: Int?
        /// Blocked jobs by reason.
        var blockedByReason: [String: Int]
        /// Jobs that need a person (blocked, or open longer than 7 days) by reason.
        var attentionByReason: [String: Int]
        var lastSuccessfulPassAt: Date?
        var schedulerStale: Bool
        var thresholds: Thresholds
    }

    /// What each maintenance pass records. No timestamps and no identifiers, so it
    /// stays a count record like the rest of `removed_json`, and small enough for the
    /// scheduler's 4,096-byte response cap.
    struct Flag: Codable, Sendable, Equatable {
        var status: Status
        var open: Int
        var blocked: Int
        var olderThan7Days: Int
        var olderThan25Days: Int
        var oldestOpenAgeDays: Int?
        /// Jobs that need a person, by reason.
        var reasons: [String: Int]
        /// Whole hours since the previous successful pass, when there was one. More
        /// than two means at least one hourly firing produced no successful pass.
        var previousPassGapHours: Int?
    }

    /// A reason as the readout may show it: a word from the closed vocabulary,
    /// `unspecified` for none, `other` for anything else.
    static func reasonName(_ raw: String?) -> String {
        guard let raw else { return "unspecified" }
        return DeletionReasonKind(rawValue: raw)?.rawValue ?? "other"
    }

    static func status(blocked: Int, olderThan7Days: Int, olderThan25Days: Int, schedulerStale: Bool) -> Status {
        if olderThan25Days > 0 { return .escalate }
        if blocked > 0 || olderThan7Days > 0 || schedulerStale { return .attention }
        return .ok
    }

    static func groups(on db: Database, now: Date) async throws -> [Group] {
        let attention = now.addingTimeInterval(-Double(attentionDays) * 86_400)
        let escalation = now.addingTimeInterval(-Double(escalationDays) * 86_400)
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            SELECT state='blocked' AS blocked, last_error_kind AS reason, count(*) AS open,
                count(*) FILTER (WHERE requested_at < \(bind: attention)) AS older_than_attention,
                count(*) FILTER (WHERE requested_at < \(bind: escalation)) AS older_than_escalation,
                min(requested_at) AS oldest
            FROM account_deletion_jobs WHERE state <> 'completed'
            GROUP BY state='blocked', last_error_kind
            """).all()
        return try rows.map { row in
            try Group(blocked: row.decode(column: "blocked", as: Bool.self),
                      reason: row.decode(column: "reason", as: String?.self),
                      open: row.decode(column: "open", as: Int.self),
                      olderThanAttention: row.decode(column: "older_than_attention", as: Int.self),
                      olderThanEscalation: row.decode(column: "older_than_escalation", as: Int.self),
                      oldestRequestedAt: row.decode(column: "oldest", as: Date?.self))
        }
    }

    /// Pure: the same groups always give the same readout.
    static func summarise(_ groups: [Group], now: Date, lastSuccessfulPass: Date?) -> Report {
        var report = Report(status: .ok, checkedAt: now, openJobs: 0, blocked: 0, olderThan7Days: 0, olderThan25Days: 0,
                            oldestOpenAgeDays: nil, blockedByReason: [:], attentionByReason: [:],
                            lastSuccessfulPassAt: lastSuccessfulPass, schedulerStale: false, thresholds: .init())
        var oldest: Date?
        for group in groups {
            let name = reasonName(group.reason)
            report.openJobs += group.open
            report.olderThan7Days += group.olderThanAttention
            report.olderThan25Days += group.olderThanEscalation
            if group.blocked {
                report.blocked += group.open
                report.blockedByReason[name, default: 0] += group.open
            }
            // Every blocked job needs a person; an unblocked one only once it is old.
            let needing = group.blocked ? group.open : group.olderThanAttention
            if needing > 0 { report.attentionByReason[name, default: 0] += needing }
            if let candidate = group.oldestRequestedAt { oldest = min(oldest ?? candidate, candidate) }
        }
        report.oldestOpenAgeDays = oldest.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
        report.schedulerStale = lastSuccessfulPass.map { now.timeIntervalSince($0) > Double(schedulerStaleHours) * 3_600 } ?? true
        report.status = status(blocked: report.blocked, olderThan7Days: report.olderThan7Days,
                               olderThan25Days: report.olderThan25Days, schedulerStale: report.schedulerStale)
        return report
    }

    static func report(on db: Database, now: Date = Date()) async throws -> Report {
        let last = try await CleanupService.lastSuccessfulRun(on: db)
        return summarise(try await groups(on: db, now: now), now: now, lastSuccessfulPass: last)
    }

    /// The pass's own record. `previousPass` is the last successful pass before this
    /// one; this pass is itself proof the scheduler is running now, so only a gap
    /// longer than the threshold counts against it, and a first-ever pass does not.
    static func flag(_ groups: [Group], now: Date, previousPass: Date?) -> Flag {
        let report = summarise(groups, now: now, lastSuccessfulPass: nil)
        let gap = previousPass.map { max(0, Int(now.timeIntervalSince($0) / 3_600)) }
        let stale = previousPass.map { now.timeIntervalSince($0) > Double(schedulerStaleHours) * 3_600 } ?? false
        return Flag(status: status(blocked: report.blocked, olderThan7Days: report.olderThan7Days,
                                   olderThan25Days: report.olderThan25Days, schedulerStale: stale),
                    open: report.openJobs, blocked: report.blocked, olderThan7Days: report.olderThan7Days,
                    olderThan25Days: report.olderThan25Days, oldestOpenAgeDays: report.oldestOpenAgeDays,
                    reasons: report.attentionByReason, previousPassGapHours: gap)
    }

    /// One line, the same shape every pass: a fixed prefix, `key=value` pairs of
    /// counts, and reasons from the closed vocabulary in a stable order.
    static func logLine(_ flag: Flag) -> String {
        let reasons = flag.reasons.keys.sorted().map { "\($0):\(flag.reasons[$0] ?? 0)" }.joined(separator: ",")
        var line = "Account deletion health: status=\(flag.status.rawValue) open=\(flag.open) blocked=\(flag.blocked)"
        line += " older_than_7d=\(flag.olderThan7Days) older_than_25d=\(flag.olderThan25Days)"
        line += " oldest_open_days=\(flag.oldestOpenAgeDays.map(String.init) ?? "none")"
        line += " previous_pass_gap_h=\(flag.previousPassGapHours.map(String.init) ?? "none")"
        line += " reasons=\(reasons.isEmpty ? "none" : reasons)"
        return line
    }

    static func log(_ flag: Flag, logger: Logger) {
        let line = logLine(flag)
        switch flag.status {
        case .ok: logger.info("\(line)")
        case .attention: logger.warning("\(line)")
        case .escalate: logger.error("\(line)")
        }
    }
}
