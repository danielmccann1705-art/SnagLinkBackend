import Vapor
import Fluent
import FluentSQL

/// Server-authoritative product funnel events added for replacement 2.0.1
/// (`outputs/measurement-2026-10-07/FUNNELS-OCT9.md`). They reuse the outcome contract in
/// `MeasurementRelayService`: product permission must already be active at occurrence, it
/// is rechecked when the event is recorded and again at dispatch, every lock is tried and
/// never awaited, an analytics failure never changes or delays the business result beyond
/// a few nonblocking statements, and a later grant never backfills. Provider properties are
/// fixed enums only: no identifiers, recipients, tokens, free text or content.
enum ProductFunnelMeasurement {
    enum SignInProvider: String, CaseIterable, Sendable { case apple, google, email }
    /// `ios`: the native app's bearer session. `web`: the portal's cookie session.
    enum SignInSurface: String, CaseIterable, Sendable { case ios, web }

    /// Fixed reasons for a failed authenticated canonical v2 Contractor-link create
    /// (`links/prepare` or `links/:id/activate`). Derived from the refused status only.
    enum ContractorLinkFailure: String, CaseIterable, Sendable {
        /// 400 and any other unlisted 4xx: the request itself was refused.
        case invalidRequest = "invalid_request"
        /// 401, 403 or 404: no right to share this project, or the target is not visible.
        case notPermitted = "not_permitted"
        /// 422: a selected snag or photo was not ready to share.
        case notReady = "not_ready"
        /// 409 or 410: the request changed, expired, was reused, or the project was archived.
        case conflict
        /// 503: Contractor sharing is not configured or is temporarily unavailable.
        case unavailable
        /// Anything else.
        case serverError = "server_error"
    }

    /// Fixed reasons for a genuine report-issue attempt that failed after the actor's
    /// `.review` right was confirmed and the operation was new (not a replay).
    enum ReportFailure: String, CaseIterable, Sendable {
        /// 400 and other 4xx refusals of the title or filters.
        case invalidRequest = "invalid_request"
        /// 422 `report_scope_too_large`.
        case scopeTooLarge = "scope_too_large"
        /// 403, 404, 409 or 410: the project changed during the attempt.
        case conflict
        /// Anything else, including database failures.
        case serverError = "server_error"
    }

    enum Stage: Sendable { case signIn, failure }
    /// Test-only seam, consulted only in `.testing`: runs inside the optional candidate
    /// savepoint so tests can force a real SQL failure there.
    struct HookKey: StorageKey { typealias Value = @Sendable (Stage, SQLDatabase) async throws -> Void }

    private static func hook(_ stage: Stage, _ app: Application) -> (@Sendable (SQLDatabase) async throws -> Void)? {
        guard app.environment == .testing, let hook = app.storage[HookKey.self] else { return nil }
        return { sql in try await hook(stage, sql) }
    }

    // MARK: - Sign-in

    /// Call inside the transaction that issues the session, after the account was resolved
    /// and any pre-auth signup choices were settled, so a genuinely new account whose
    /// product choice was adopted in that same transaction is eligible. A nil surface
    /// (a browser-origin request reaching a native route) records nothing.
    static func signInCandidate(account: User, sessionID: UUID, provider: SignInProvider,
                                surface: SignInSurface?, app: Application,
                                on db: Database) async -> MeasurementRelayService.OutcomeCandidate? {
        guard let surface, let accountID = try? account.requireID() else { return nil }
        return await MeasurementRelayService.outcomeCandidate(
            accountID: accountID, operationID: sessionID, installationID: nil,
            event: .signInSucceeded, properties: ["provider": provider.rawValue, "surface": surface.rawValue],
            occurredAt: Date(), beforeLookup: hook(.signIn, app), on: db)
    }

    /// Call only once the session credential exists: the signed bearer token, or the
    /// committed portal session row. Best-effort; never throws.
    static func record(_ candidate: MeasurementRelayService.OutcomeCandidate?, app: Application,
                       on db: Database) async {
        guard let candidate else { return }
        await MeasurementRelayService.recordOutcome(candidate, app: app, logger: app.logger, on: db)
    }

    // MARK: - Failures

    static func contractorLinkCreateFailed(_ error: Error, accountID: UUID, operationID: UUID, receivedAt: Date,
                                           app: Application, on db: Database) async {
        // A retry of an operation that was already applied is not a failed create.
        guard (error as? Abort)?.identifier != "already_applied_refresh_required" else { return }
        await failure(.contractorLinkCreateFailed, reason: contractorLinkReason(error).rawValue, accountID: accountID,
                      operationID: operationID, receivedAt: receivedAt, app: app, on: db)
    }

    static func reportFailed(_ error: Error, accountID: UUID, operationID: UUID, receivedAt: Date,
                             app: Application, on db: Database) async {
        await failure(.reportFailed, reason: reportReason(error).rawValue, accountID: accountID,
                      operationID: operationID, receivedAt: receivedAt, app: app, on: db)
    }

    /// The business transaction has already rolled back, so the candidate is captured in
    /// its own short transaction with the same savepoint and tried locks. The event ID is
    /// derived from the client operation ID: retrying the same failed operation records
    /// at most one failure. The occurrence time is the original request receipt time.
    private static func failure(_ event: MeasurementRelayService.ServerOutcome, reason: String, accountID: UUID,
                                operationID: UUID, receivedAt: Date, app: Application, on db: Database) async {
        let candidate: MeasurementRelayService.OutcomeCandidate?
        do {
            candidate = try await db.transaction { tx in
                await MeasurementRelayService.outcomeCandidate(
                    accountID: accountID, operationID: operationID, installationID: nil, event: event,
                    properties: ["reason": reason], occurredAt: receivedAt, beforeLookup: hook(.failure, app), on: tx)
            }
        } catch { return }
        await record(candidate, app: app, on: db)
    }

    static func contractorLinkReason(_ error: Error) -> ContractorLinkFailure {
        switch status(error).code {
        case 401, 403, 404: return .notPermitted
        case 409, 410: return .conflict
        case 422: return .notReady
        case 503: return .unavailable
        case 400..<500: return .invalidRequest
        default: return .serverError
        }
    }

    static func reportReason(_ error: Error) -> ReportFailure {
        let code = status(error).code
        if code == 422, (error as? Abort)?.identifier == "report_scope_too_large" { return .scopeTooLarge }
        switch code {
        case 403, 404, 409, 410: return .conflict
        case 400..<500: return .invalidRequest
        default: return .serverError
        }
    }

    private static func status(_ error: Error) -> HTTPResponseStatus {
        if let abort = error as? AbortError { return abort.status }
        if error is DecodingError { return .badRequest }
        return .internalServerError
    }
}
