import Vapor
import Fluent

/// 2.0.2 Apple ads measurement, server side: every rule and number the module decides by, in one place.
///
/// Specification: MEASUREMENT-DECISION.md §3.0 ¶7 and §3.4, EVENT-CONTRACT.md rule 8 and row 1, PRIVACY-DELTA.md
/// §A6–§A7 (all in `outputs/ads-readiness-2026-10-04/`). The module is self-contained — this folder, the migration
/// `CreateAdAttributionRecords`, and one line each in `routes.swift`, `configure.swift`, `CleanupService` and
/// `AccountDeletionService` — so it can be replayed onto another base without the rest of a package.
///
/// The flow: the app posts Apple's AdServices token once per installation (`AdMeasurementController`); the row is
/// `pending`; the hourly maintenance pass exchanges the token with Apple (`AppleAttributionExchangeService`), keeps
/// the Standard fields and drops the token; withdrawal is a `DELETE` by reference that erases the row; account
/// deletion erases rows keyed by the account; the same pass deletes every row at the end of retention.
/// RevenueCat receives nothing from any of this.
enum AdMeasurementPolicy {
    /// The server switch, served to the app in `GET /api/v1/config/feature-flags` (`FeatureFlagService.registry`,
    /// hard default `false`) and mirrored here: `POST` answers 503 and the exchange makes no call to Apple unless
    /// it resolves to `true`.
    static let flagKey = "adMeasurementEnabled"
    static let flagEnvironmentVariable = "FEATURE_AD_MEASUREMENT_ENABLED"

    /// How long a record is kept: 180 days from `created_at`, then the maintenance pass deletes it.
    ///
    /// **PROPOSED — pending Dan's decision D6** (PRIVACY-DELTA.md D6, MEASUREMENT-DECISION.md §3.4: "180 days is a
    /// proposed value for Dan"). This is the only place the number is written; the sweep, its tests and the policy
    /// text all follow it. If D6 settles on another value, change it here and in the policy wording together.
    static let retentionDays = 180
    static var retention: TimeInterval { TimeInterval(retentionDays) * 24 * 60 * 60 }

    /// Apple's token is valid for 24 hours after the device generates it (AdServices API). A row whose token was not
    /// exchanged inside that window is `expired` and its token is dropped, whether or not the switch is on.
    static let tokenValidity: TimeInterval = 24 * 60 * 60

    /// Apple's documented handling of `404` (attribution not yet available): "retry every 5 seconds, max 3
    /// attempts". Inside one pass; a row still answered `404` stays `pending` for the next pass.
    static let appleAttemptsPerPass = 3
    static let appleRetryDelaySeconds = 5
    /// One request to Apple; generous for a small JSON answer, small enough to keep a pass bounded.
    static let appleRequestTimeoutSeconds: Int64 = 10
    /// Apple's answer is a small JSON object; anything larger is not read.
    static let appleResponseMaxBytes = 16 * 1024

    /// The exchange's share of one maintenance pass: at most this many rows, and no new row once the budget is
    /// spent (a row already started finishes its at most three attempts). Rows left over wait for the next pass
    /// and are counted as `deferred`.
    static let exchangeBatch = 20
    static let exchangeBudgetSeconds: TimeInterval = 120
    /// Rows deleted per retention-sweep statement; a backlog drains over successive passes.
    static let sweepBatch = 5_000

    /// Fail closed. `true` only when the flag resolves to the boolean `true`. A missing key, `false`, or a
    /// resolution that fails (database unreachable, query error) is `false`. Malformed environment values never
    /// reach here as `true`: `FeatureFlagService` accepts only the exact literal `true`.
    static func isEnabled(on db: Database) async -> Bool {
        await isEnabled { try await FeatureFlagService.resolve(on: db) }
    }

    static func isEnabled(_ resolve: () async throws -> [String: Bool]) async -> Bool {
        guard let flags = try? await resolve() else { return false }
        return flags[flagKey] == true
    }
}
