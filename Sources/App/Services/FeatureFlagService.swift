import Vapor
import Fluent

/// Resolves feature-flag values (B6). Precedence: DB override row → per-environment env-var
/// default → hard-coded default.
struct FeatureFlagService {
    /// The known flags. `envVar` supplies the per-environment default (e.g. staging sets
    /// FEATURE_USE_NEW_DESIGN=true; production leaves it unset → hardDefault false at launch).
    static let registry: [(key: String, envVar: String, hardDefault: Bool)] = [
        ("useNewDesign", "FEATURE_USE_NEW_DESIGN", false),
    ]

    static func resolve(on db: Database) async throws -> [String: Bool] {
        let overrides = try await FeatureFlag.query(on: db).all()
        var overrideMap: [String: Bool] = [:]
        for flag in overrides { overrideMap[flag.key] = flag.enabled }

        var result: [String: Bool] = [:]
        for flag in registry {
            if let override = overrideMap[flag.key] {
                result[flag.key] = override
            } else if let envValue = Environment.get(flag.envVar) {
                result[flag.key] = (envValue == "true")
            } else {
                result[flag.key] = flag.hardDefault
            }
        }
        return result
    }
}
