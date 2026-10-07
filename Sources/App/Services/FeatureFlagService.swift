import Vapor
import Fluent

/// Resolves feature-flag values (B6). Precedence: DB override row → per-environment env-var
/// default → hard-coded default.
struct FeatureFlagService {
    /// The known flags. `envVar` supplies the per-environment default (e.g. staging sets
    /// FEATURE_USE_NEW_DESIGN=true; production leaves it unset → hardDefault false at launch).
    ///
    /// `adMeasurementEnabled` (2.0.2, MEASUREMENT-DECISION.md §3.0 ¶7): the server switch for Apple
    /// ads measurement. Its hard default is `false` and must stay `false`: with no override row and no
    /// environment value, no installation measures and `POST /api/v1/ad-measurement/apple` answers 503
    /// (`AdMeasurementPolicy`). Only the exact literal `true` in the environment, or an override row,
    /// turns it on, and turning it on in production is Dan's decision.
    static let registry: [(key: String, envVar: String, hardDefault: Bool)] = [
        ("useNewDesign", "FEATURE_USE_NEW_DESIGN", false),
        ("adMeasurementEnabled", "FEATURE_AD_MEASUREMENT_ENABLED", false),
        ("productAnalyticsEnabled", "FEATURE_PRODUCT_ANALYTICS_ENABLED", false),
        ("crossCompanyAdsEnabled", "FEATURE_CROSS_COMPANY_ADS_ENABLED", false),
        ("linkedInConversionsEnabled", "FEATURE_LINKEDIN_CONVERSIONS_ENABLED", false),
    ]

    /// `lookup` is the process environment; a test passes its own instead of setting a variable the
    /// rest of the suite shares.
    static func resolve(on db: Database, lookup: (String) -> String? = Environment.get) async throws -> [String: Bool] {
        let overrides = try await FeatureFlag.query(on: db).all()
        var overrideMap: [String: Bool] = [:]
        for flag in overrides { overrideMap[flag.key] = flag.enabled }

        var result: [String: Bool] = [:]
        for flag in registry {
            if let override = overrideMap[flag.key] {
                result[flag.key] = override
            } else if let envValue = lookup(flag.envVar) {
                result[flag.key] = (envValue == "true")
            } else {
                result[flag.key] = flag.hardDefault
            }
        }
        return result
    }
}
