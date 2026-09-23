import Vapor
import Fluent
import FluentSQL

/// Account deletion's RevenueCat step: the deleted account's RevenueCat customer is
/// deleted with RevenueCat REST v1 `DELETE /v1/subscribers/{app_user_id}` and the
/// project's secret key (`REVENUECAT_SECRET_API_KEY`, the same key
/// `SubscriptionVerificationService` already reads).
///
/// **Whose customer.** Only the job's own account, named by the job row's
/// `user_id`, and only once that account's `lifecycle_state` is `deleted`. The App
/// User ID is that UUID's `uuidString` (uppercase), exactly as the app passes it to
/// `Purchases.logIn` and as `SubscriptionVerificationService` reads it. Nothing a
/// client sends, and nothing another row names, can reach the URL.
///
/// **Shaped like the Apple revocation child.** It runs after the account's own graph
/// is erased, the call happens outside any transaction, and its outcome is written
/// only under the job's current lease. The call is idempotent: RevenueCat documents
/// "treat both 200 and 404 as successful 'ensure deleted' completion", so a delayed
/// worker that repeats it finds `not_found`, which is also done.
///
/// **What each outcome means for the job.** `deleted` and `not_found` are done.
/// `skipped_environment` is recorded, never counted as a deletion: it means this
/// deployment has no purchase provider by design (staging refuses the key in
/// `Infrastructure/cloudflare/src/config.mjs`). `misconfigured` (no key where one is
/// required, or RevenueCat refused the key or the request) blocks the job, like
/// Apple's `misconfigured`, and is retried every pass until someone fixes it.
/// `failing` (network, 5xx, 429) leaves the job `ready` and is retried on the backoff
/// curve. Missing configuration is therefore never success.
///
/// RevenueCat queues the deletion and processes it asynchronously. It does not cancel
/// the Apple subscription, which keeps billing until the person cancels it with Apple
/// (the deletion screen says so). Once the customer is gone the Apple receipt no
/// longer belongs to the deleted account, so the person can restore it onto a new
/// Snaglist account.
enum RevenueCatCustomerDeletionService {
    /// Durable words in `account_deletion_jobs.revenuecat_state`.
    enum Outcome: String, Sendable, CaseIterable {
        case deleted
        case notFound = "not_found"
        case skippedEnvironment = "skipped_environment"
        case misconfigured
        case failing

        /// Whether the job may complete on this outcome. `skipped_environment` may,
        /// because the deployment has no provider to delete from; it is still recorded
        /// under its own name so nobody can read it as a deletion.
        var settles: Bool { self == .deleted || self == .notFound || self == .skippedEnvironment }
    }

    /// Where the decision comes from: the platform's declared environment and the key.
    struct Configuration: Sendable, Equatable {
        var platformEnvironment: String?
        var secretKey: String?
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }

    /// Replaces the HTTP call under `.testing` only, never as a production fallback.
    typealias Transport = @Sendable (_ method: HTTPMethod, _ uri: URI, _ headers: HTTPHeaders) async throws -> HTTPStatus
    struct TransportKey: StorageKey { typealias Value = Transport }

    enum Decision: Equatable {
        case call(secretKey: String)
        case skipEnvironment
        case misconfigured
    }

    static let base = "https://api.revenuecat.com/v1/subscribers/"

    static func configuration(_ app: Application) -> Configuration {
        if app.environment == .testing, let configured = app.storage[ConfigurationKey.self] { return configured }
        return .init(platformEnvironment: Environment.get("PLATFORM_ENVIRONMENT"),
                     secretKey: Environment.get("REVENUECAT_SECRET_API_KEY"))
    }

    /// RevenueCat is called only by a deployment that declares itself production.
    ///
    /// * `production`: the key must be present, or the step is `misconfigured`. The
    ///   production adapter already refuses to start without it
    ///   (`production-config.mjs`, `required('REVENUECAT_SECRET_API_KEY')`), so this is
    ///   the second line, not the first.
    /// * `staging` and `local`: skipped by environment, even if a key were somehow
    ///   present. Staging accounts are not the production project's customers, and the
    ///   staging adapter refuses the key outright.
    /// * Anything else: a process running as production that does not declare its
    ///   platform cannot claim a skip, so it is `misconfigured`. A development or test
    ///   process with no platform is skipped by environment.
    static func decide(_ configuration: Configuration, productionProcess: Bool) -> Decision {
        let key = configuration.secretKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch configuration.platformEnvironment {
        case "production":
            return key.isEmpty ? .misconfigured : .call(secretKey: key)
        case "staging", "local":
            return .skipEnvironment
        default:
            return productionProcess ? .misconfigured : .skipEnvironment
        }
    }

    /// RevenueCat's answer, reduced to what the job needs. The response body is never
    /// read: it is not needed, and nothing from it may reach a durable row or a log.
    static func classify(_ status: HTTPStatus) -> Outcome {
        switch status.code {
        case 200...299: return .deleted
        case 404: return .notFound
        // Transient: timeouts, conflicts, locks and rate limits settle by waiting.
        case 408, 409, 423, 425, 429: return .failing
        // The key is wrong or lacks permission, or the request itself is refused.
        // Waiting will not fix any of these; a person has to look.
        case 400...499: return .misconfigured
        default: return .failing
        }
    }

    static func uri(appUserID: String) -> URI {
        URI(string: base + appUserID)
    }

    /// One attempt for the job this lease holds. A no-op when the step is already
    /// settled, when the job carries no RevenueCat step (`not_requested`), or when the
    /// account is not deleted.
    static func perform(_ lease: AccountDeletionWorker.Lease, app: Application, on db: Database,
                        transactionMode: AccountDeletionWorker.TransactionMode = .managed) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        guard try await sql.raw("""
            SELECT j.id FROM account_deletion_jobs j JOIN users u ON u.id=j.user_id
            WHERE j.id=\(bind: lease.id) AND j.user_id=\(bind: lease.userID) AND u.lifecycle_state='deleted'
                AND j.lease_token=\(bind: lease.token) AND j.state='leased' AND j.lease_expires_at>clock_timestamp()
                AND j.revenuecat_state IN ('pending','failing','misconfigured')
            """).first() != nil else { return }
        let outcome: Outcome
        switch decide(configuration(app), productionProcess: app.environment == .production) {
        case .skipEnvironment:
            outcome = .skippedEnvironment
        case .misconfigured:
            outcome = .misconfigured
        case .call(let secretKey):
            guard try await AccountDeletionWorker.renew(lease, on: db) else { return }
            outcome = await deleteCustomer(appUserID: lease.userID.uuidString, secretKey: secretKey, app: app)
        }
        let recorded = outcome.rawValue
        let completed = outcome == .deleted || outcome == .notFound
        try await AccountDeletionWorker.writeIfCurrent(lease, on: db, transactionMode: transactionMode) { sql in
            try await sql.raw("""
                UPDATE account_deletion_jobs SET revenuecat_state=\(bind: recorded),revenuecat_attempts=revenuecat_attempts+1,
                    revenuecat_last_attempt_at=NOW(),
                    revenuecat_completed_at=CASE WHEN \(bind: completed) THEN NOW() ELSE NULL END
                WHERE id=\(bind: lease.id) AND user_id=\(bind: lease.userID)
                    AND revenuecat_state IN ('pending','failing','misconfigured')
                """).run()
        }
    }

    /// Never throws, never logs the key, the App User ID or the response body.
    static func deleteCustomer(appUserID: String, secretKey: String, app: Application) async -> Outcome {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: secretKey)
        headers.add(name: .accept, value: "application/json")
        let target = uri(appUserID: appUserID)
        do {
            let status: HTTPStatus
            if app.environment == .testing {
                // A test never reaches the real service. No transport, no call.
                guard let transport = app.storage[TransportKey.self] else { return .failing }
                status = try await transport(.DELETE, target, headers)
            } else {
                status = try await app.client.delete(target, headers: headers) { request in
                    request.timeout = .seconds(20)
                }.status
            }
            return classify(status)
        } catch {
            return .failing
        }
    }
}
