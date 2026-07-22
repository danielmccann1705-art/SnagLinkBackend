import Vapor
import Fluent

/// Schedules periodic cleanup of expired rate limit entries and old audit logs
struct CleanupService {

    /// Starts background cleanup task that runs every 6 hours
    static func scheduleCleanup(app: Application) {
        app.lifecycle.use(CleanupLifecycleHandler())
    }

    /// Runs one full cleanup pass. Exposed (vs. buried in the lifecycle handler) so it can be
    /// invoked directly from tests.
    static func runCleanup(app: Application) async throws {
        let db = app.db

        // Clean up expired rate limit entries
        try await RateLimitService.cleanup(on: db)

        // Clean up audit logs older than 90 days
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        try await AuditLog.query(on: db)
            .filter(\.$createdAt < cutoffDate)
            .delete()

        // B1: purge magic-link auth tokens older than 24h (covers consumed + expired both —
        // TTL is 15 min so anything past 24h is well dead).
        let tokenCutoff = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        try await MagicLinkAuthToken.query(on: db)
            .filter(\.$createdAt < tokenCutoff)
            .delete()

        // B2: purge expired preview links + their staging data (synced report/photos/drawings).
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
            app.logger.info("Cleanup: removed \(expiredPreviews.count) expired preview link(s) + staging data")
        }

        app.logger.info("Cleanup completed: removed expired rate limits, old audit logs, stale magic-link auth tokens, and expired preview links")
    }
}

private struct CleanupLifecycleHandler: LifecycleHandler {
    func didBoot(_ app: Application) throws {
        app.logger.info("Scheduling periodic cleanup task (every 6 hours)")

        Task {
            while !Task.isCancelled {
                // Wait 6 hours between cleanups
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)

                do {
                    try await CleanupService.runCleanup(app: app)
                } catch {
                    app.logger.error("Cleanup task failed: \(error)")
                }
            }
        }
    }
}
