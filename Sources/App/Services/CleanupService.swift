import Vapor
import Fluent
import FluentSQL

/// Periodic removal of expired rate limits, old audit logs, spent magic-link tokens,
/// expired preview links, the sign-out rows of expired app sessions and spent
/// sign-in challenges.
///
/// The work here was always correct. What was missing was anything that ran it: the
/// lifecycle loop below waits before its first pass, inside a container that sleeps
/// after ten minutes of quiet, so a pass needed the container to stay awake for the
/// whole interval. It is kept as a fallback for deployments with no scheduler, at an
/// interval it might actually reach — but the cron trigger calling
/// `/internal/maintenance/cleanup` is the mechanism this depends on, because cron
/// wakes a sleeping container and a sleep inside one does not.
///
/// Every pass is recorded in `cleanup_runs`. Without that, "has this ever run?" has no
/// answer, which is how the original defect stayed invisible.
struct CleanupService {
    /// Counts only. Naming what was removed, never which rows.
    struct Removed: Codable, Sendable {
        var rateLimits = 0
        var auditLogs = 0
        var magicLinkAuthTokens = 0
        var expiredPreviewLinks = 0
        var accountDeletionJobs = AccountDeletionWorker.Counts()
        var appleWebCredentials = AppleWebCredentialEscrowService.Counts()
        /// The deletion health flag this pass computed after its work: blocked and
        /// overdue jobs by reason, counts only (`AccountDeletionHealth.Flag`).
        /// Optional so that records written before it existed still decode.
        var accountDeletionHealth: AccountDeletionHealth.Flag? = nil
        /// Signed-out app sessions whose tokens have expired
        /// (`AppSessionRevocationService.removeExpired`). Optional for the same reason.
        var appSessionRevocations: Int? = nil
        /// Sign-in challenges removed a day after they expired
        /// (`removeSpentSignInChallenges`). Optional for the same reason.
        var signInChallenges: SignInChallengeCounts? = nil
    }

    /// Counts only, by table.
    struct SignInChallengeCounts: Codable, Sendable, Equatable {
        /// `apple_web_challenges`.
        var appleWeb = 0
        /// Finished `apple_web_credential_escrow` records (adopted or revoked, so no
        /// credential left in them) removed so their challenge could go too.
        var appleWebEscrow = 0
        /// `google_identity_challenges`, both surfaces and both purposes.
        var google = 0
        /// `identity_challenges`: the email-link browser sign-in, verify and
        /// reauthenticate challenges, the only ones that carry an address.
        var emailLink = 0
    }

    /// How long a sign-in challenge is kept after `expires_at`. Every consume path
    /// requires `expires_at > now`, so once a challenge has expired nothing reads it
    /// again: a replayed state, nonce or link finds no usable row whether or not the
    /// row still exists, and removing it changes no answer. The day is slack for
    /// clock skew and for anyone reading a recent failure, not a requirement.
    static let signInChallengeRetentionAfterExpiry: TimeInterval = 24 * 60 * 60

    /// Rows per table per pass. The scheduler awaits the whole pass; a backlog
    /// drains over successive hours instead of making one pass long.
    static let signInChallengeBatch = 5_000

    /// `schedule` is the external scheduler reaching us through the maintenance route.
    /// `fallback` is the in-process loop, which cannot be relied on in a container that
    /// sleeps. Keeping them apart is the difference between the record answering
    /// "is the scheduler working?" and merely saying something ran.
    enum Trigger: String, Sendable { case schedule, fallback, manual, test }

    /// Postgres advisory lock key. One pass at a time across every instance; the lock
    /// is released when the session ends, so a pass killed mid-way unlocks by itself
    /// and the next firing simply redoes it. Every operation below deletes by predicate,
    /// so redoing a partial pass is safe.
    ///
    /// Overridable under test only, so two suites that both run a pass do not contend
    /// for one global lock and mistake that for a failure.
    static let defaultLockKey: Int64 = 0x5C1EA_1

    static func lockKey(_ app: Application) -> Int64 {
        if app.environment == .testing, let key = app.storage[CleanupLockKeyStorage.self] { return key }
        return defaultLockKey
    }

    static func scheduleCleanup(app: Application) {
        app.lifecycle.use(CleanupLifecycleHandler())
    }

    /// `budget` bounds the deletion worker's share of the pass. The scheduler that
    /// calls this awaits the whole thing and is cut off at fifteen minutes, so the
    /// bound is what keeps a long fence pass from taking the advisory lock down with
    /// the request and turning the next hour into a "skipped" record.
    @discardableResult
    static func runCleanup(app: Application, trigger: Trigger = .manual,
                           budget: AccountDeletionWorker.PassBudget = .default) async throws -> Removed? {
        try await app.db.withConnection { db in
            try await runCleanup(app: app, trigger: trigger, budget: budget, on: db)
        }
    }

    /// The session advisory lock and unlock must use this same pinned connection.
    private static func runCleanup(app: Application, trigger: Trigger,
                                   budget: AccountDeletionWorker.PassBudget, on db: Database) async throws -> Removed? {
        let sql = try VerifiedIdentityService.sql(db)

        // Refuse to pile up behind a pass already in flight rather than queueing.
        let key = lockKey(app)
        let acquired = try await sql.raw("SELECT pg_try_advisory_lock(\(bind: key)) AS locked").first()?
            .decode(column: "locked", as: Bool.self) ?? false
        guard acquired else {
            try await record(trigger: trigger, started: Date(), state: "skipped", removed: nil, errorKind: "already_running", on: sql)
            app.logger.info("Cleanup skipped: a pass is already running")
            return nil
        }

        // Released before returning, on both paths. A detached unlock would let the
        // next firing find the lock still held and skip a pass it should have run.
        let started = Date()
        do {
            let removed = try await perform(app: app, budget: budget, on: db)
            try await record(trigger: trigger, started: started, state: "succeeded", removed: removed, errorKind: nil, on: sql)
            try await unlock(key, on: sql)
            app.logger.info("Cleanup completed: \(removed.auditLogs) audit logs, \(removed.magicLinkAuthTokens) auth tokens, \(removed.expiredPreviewLinks) preview links")
            return removed
        } catch {
            // Classification, not the message: an error body is where a stray address
            // ends up in a log.
            try? await record(trigger: trigger, started: started, state: "failed", removed: nil, errorKind: "\(type(of: error))", on: sql)
            try? await unlock(key, on: sql)
            throw error
        }
    }

    private static func unlock(_ key: Int64, on sql: SQLDatabase) async throws {
        try await sql.raw("SELECT pg_advisory_unlock(\(bind: key))").run()
    }

    private static func perform(app: Application, budget: AccountDeletionWorker.PassBudget, on db: Database) async throws -> Removed {
        var removed = Removed()

        removed.appleWebCredentials = try await AppleWebCredentialEscrowService.run(app: app, on: db)
        removed.accountDeletionJobs = try await AccountDeletionWorker.run(app: app, on: db, transactionMode: .maintenanceConnection,
                                                                          budget: budget)
        try await SnagDeletionService.cleanupFiles(app: app, on: db)
        try await RateLimitService.cleanup(on: db)

        // Audit logs older than 90 days.
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let staleLogs = try await AuditLog.query(on: db).filter(\.$createdAt < cutoffDate).all()
        removed.auditLogs = staleLogs.count
        try await AuditLog.query(on: db).filter(\.$createdAt < cutoffDate).delete()

        // B1: magic-link auth tokens older than 24h — TTL is 15 minutes, so anything
        // past a day is well dead whether it was consumed or expired.
        let tokenCutoff = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        let staleTokens = try await MagicLinkAuthToken.query(on: db).filter(\.$createdAt < tokenCutoff).all()
        removed.magicLinkAuthTokens = staleTokens.count
        try await MagicLinkAuthToken.query(on: db).filter(\.$createdAt < tokenCutoff).delete()

        // B2: expired preview links and the report, photo and drawing rows staged for them.
        let expiredPreviews = try await MagicLink.query(on: db)
            .filter(\.$previewMode == true)
            .filter(\.$previewExpiresAt < Date())
            .all()
        if !expiredPreviews.isEmpty {
            let tokens = expiredPreviews.map { $0.token }
            let ids = expiredPreviews.compactMap { $0.id }
            try await SyncedReport.query(on: db).filter(\.$magicLinkToken ~~ tokens).delete()
            try await SyncedPhoto.query(on: db).filter(\.$magicLinkToken ~~ tokens).delete()
            try await SyncedDrawing.query(on: db).filter(\.$magicLinkToken ~~ tokens).delete()
            try await MagicLink.query(on: db).filter(\.$id ~~ ids).delete()
            removed.expiredPreviewLinks = expiredPreviews.count
        }

        // Per-device sign-out rows, once the token each one names has expired.
        removed.appSessionRevocations = try await AppSessionRevocationService.removeExpired(on: db)

        // Spent sign-in challenges, a day after they expired. After the escrow worker
        // above, so an Apple credential it has just finished with is already terminal.
        removed.signInChallenges = try await removeSpentSignInChallenges(on: db)

        // Last, after every piece of work above, so reading health can never stop
        // that work. A pass that cannot read it records `failed`, which is itself
        // the signal. The previous successful pass is read before this one is
        // recorded, so the gap says whether hourly firings were lost.
        let now = Date()
        let groups = try await AccountDeletionHealth.groups(on: db, now: now)
        let previousPass = try await lastSuccessfulRun(on: db)
        let health = AccountDeletionHealth.flag(groups, now: now, previousPass: previousPass)
        removed.accountDeletionHealth = health
        AccountDeletionHealth.log(health, logger: app.logger)

        return removed
    }

    /// Removes Apple web, Google and email-link sign-in challenges whose `expires_at`
    /// is more than `signInChallengeRetentionAfterExpiry` ago, consumed or not. Each
    /// statement deletes by predicate on its own, so a pass stopped part-way is simply
    /// finished by the next one.
    ///
    /// An Apple challenge whose credential escrow record is still in flight (`held`,
    /// `ready`, `leased` or `blocked`, i.e. it may still hold a refresh token awaiting
    /// revocation) is never touched, however old. A finished escrow record (`adopted`
    /// or `revoked`, which by constraint holds no credential) is removed first, a day
    /// after it finished, because it references its challenge and would otherwise
    /// keep every successful Apple web sign-in's challenge forever.
    ///
    /// New escrow records are only written after `AppleWebChallengeService.consume`,
    /// which refuses an expired challenge, so none can appear for a row this removes.
    static func removeSpentSignInChallenges(on db: Database, now: Date = Date(),
                                            limit: Int = signInChallengeBatch) async throws -> SignInChallengeCounts {
        let sql = try VerifiedIdentityService.sql(db)
        let cutoff = now.addingTimeInterval(-signInChallengeRetentionAfterExpiry)
        let batch = max(0, limit)
        var counts = SignInChallengeCounts()

        func total(_ query: SQLQueryString) async throws -> Int {
            try await sql.raw(query).first()?.decode(column: "total", as: Int.self) ?? 0
        }

        counts.appleWebEscrow = try await total("""
            WITH removed AS (
                DELETE FROM apple_web_credential_escrow WHERE challenge_id IN (
                    SELECT e.challenge_id FROM apple_web_credential_escrow e
                    JOIN apple_web_challenges c ON c.id = e.challenge_id
                    WHERE e.state IN ('adopted','revoked') AND e.completed_at < \(bind: cutoff)
                      AND c.expires_at < \(bind: cutoff)
                    ORDER BY c.expires_at LIMIT \(bind: batch))
                  AND state IN ('adopted','revoked')
                RETURNING 1)
            SELECT count(*) AS total FROM removed
            """)
        counts.appleWeb = try await total("""
            WITH removed AS (
                DELETE FROM apple_web_challenges WHERE id IN (
                    SELECT c.id FROM apple_web_challenges c
                    WHERE c.expires_at < \(bind: cutoff)
                      AND NOT EXISTS (SELECT 1 FROM apple_web_credential_escrow e WHERE e.challenge_id = c.id)
                    ORDER BY c.expires_at LIMIT \(bind: batch))
                RETURNING 1)
            SELECT count(*) AS total FROM removed
            """)
        counts.google = try await total("""
            WITH removed AS (
                DELETE FROM google_identity_challenges WHERE id IN (
                    SELECT id FROM google_identity_challenges WHERE expires_at < \(bind: cutoff)
                    ORDER BY expires_at LIMIT \(bind: batch))
                RETURNING 1)
            SELECT count(*) AS total FROM removed
            """)
        counts.emailLink = try await total("""
            WITH removed AS (
                DELETE FROM identity_challenges WHERE id IN (
                    SELECT id FROM identity_challenges WHERE expires_at < \(bind: cutoff)
                    ORDER BY expires_at LIMIT \(bind: batch))
                RETURNING 1)
            SELECT count(*) AS total FROM removed
            """)
        return counts
    }

    private static func record(trigger: Trigger, started: Date, state: String, removed: Removed?, errorKind: String?, on sql: SQLDatabase) async throws {
        let finished = Date()
        let json = try removed.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await sql.raw("""
            INSERT INTO cleanup_runs (id, trigger, started_at, finished_at, state, duration_ms, removed_json, error_kind)
            VALUES (\(bind: UUID()), \(bind: trigger.rawValue), \(bind: started), \(bind: finished), \(bind: state),
                    \(bind: Int(finished.timeIntervalSince(started) * 1000)), \(bind: json), \(bind: errorKind))
            """).run()
    }

    /// The most recent successful pass, for the maintenance readout. Nothing here
    /// identifies a person.
    static func lastSuccessfulRun(on db: Database) async throws -> Date? {
        try await (db as! SQLDatabase)
            .raw("SELECT started_at FROM cleanup_runs WHERE state = 'succeeded' ORDER BY started_at DESC LIMIT 1")
            .first()?.decode(column: "started_at", as: Date.self)
    }
}

private struct CleanupLifecycleHandler: LifecycleHandler {
    func didBoot(_ app: Application) throws {
        app.logger.info("Scheduling in-process cleanup fallback (hourly); the scheduler calls /internal/maintenance/cleanup")

        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                do {
                    try await CleanupService.runCleanup(app: app, trigger: .fallback)
                } catch {
                    app.logger.error("Cleanup task failed; consult the classified maintenance run record")
                }
            }
        }
    }
}

struct CleanupLockKeyStorage: StorageKey { typealias Value = Int64 }
