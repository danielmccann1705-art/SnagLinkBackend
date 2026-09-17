import Vapor
import Fluent
import FluentSQL

/// Periodic removal of expired rate limits, old audit logs, spent magic-link tokens
/// and expired preview links.
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
    }

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

    @discardableResult
    static func runCleanup(app: Application, trigger: Trigger = .manual) async throws -> Removed? {
        let db = app.db
        let sql = db as! SQLDatabase

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
            let removed = try await perform(app: app, on: db)
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

    private static func perform(app: Application, on db: Database) async throws -> Removed {
        var removed = Removed()

        try await SnagDeletionService.cleanupFiles(app: app)
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

        return removed
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
                    app.logger.error("Cleanup task failed: \(error)")
                }
            }
        }
    }
}

struct CleanupLockKeyStorage: StorageKey { typealias Value = Int64 }
