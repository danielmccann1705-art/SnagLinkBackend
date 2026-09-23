import Vapor
import Fluent

/// The scheduler's way in.
///
/// Not part of the public API and not discoverable: with no `MAINTENANCE_SECRET`
/// configured, and for any caller without it, every route here is a 404. It exists
/// because a container that sleeps after ten minutes cannot run its own timer — only
/// something outside it can wake it.
struct MaintenanceController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let maintenance = routes.grouped("internal", "maintenance")
        maintenance.post("cleanup", use: cleanup)
        maintenance.get("cleanup", use: status)
        maintenance.get("account-deletion-health", use: deletionHealth)
    }

    /// Runs one pass. Returns counts, never rows. Safe to call more often than needed:
    /// a pass already in flight is skipped rather than queued, and every operation
    /// deletes by predicate, so a repeat is a no-op.
    @Sendable
    func cleanup(req: Request) async throws -> MaintenanceCleanupResponse {
        try MaintenanceAuthority.authorise(req)
        let removed = try await CleanupService.runCleanup(app: req.application, trigger: .schedule)
        return MaintenanceCleanupResponse(
            ran: removed != nil,
            removed: removed ?? .init(),
            lastSuccessfulRun: try await CleanupService.lastSuccessfulRun(on: req.db)
        )
    }

    /// Readout for checking the scheduler is alive without running anything.
    @Sendable
    func status(req: Request) async throws -> MaintenanceStatusResponse {
        try MaintenanceAuthority.authorise(req)
        let last = try await CleanupService.lastSuccessfulRun(on: req.db)
        return MaintenanceStatusResponse(
            lastSuccessfulRun: last,
            hoursSinceLastRun: last.map { Int(Date().timeIntervalSince($0) / 3600) },
            overdue: last.map { Date().timeIntervalSince($0) > 26 * 3600 } ?? true
        )
    }

    /// Blocked and overdue account deletions, by reason, read on demand without
    /// running a pass. Counts and closed-vocabulary reasons only
    /// (`AccountDeletionHealth.Report`); the same secret and the same 404 as above.
    @Sendable
    func deletionHealth(req: Request) async throws -> AccountDeletionHealth.Report {
        try MaintenanceAuthority.authorise(req)
        return try await AccountDeletionHealth.report(on: req.db)
    }
}

struct MaintenanceCleanupResponse: Content {
    let ran: Bool
    let removed: CleanupService.Removed
    let lastSuccessfulRun: Date?
}

struct MaintenanceStatusResponse: Content {
    let lastSuccessfulRun: Date?
    let hoursSinceLastRun: Int?
    /// True when no pass has succeeded within a day and a bit — the state that went
    /// unnoticed for the whole life of the previous implementation.
    let overdue: Bool
}
