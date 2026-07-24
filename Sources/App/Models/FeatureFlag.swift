import Fluent
import Vapor

/// A remote feature-flag override (B6). When a row exists for a flag key it wins; otherwise the
/// per-environment env-var default applies. Lets ops flip a flag (e.g. `useNewDesign`) instantly
/// via a DB row without a redeploy — enabling the F9 rollback path.
final class FeatureFlag: Model, Content, @unchecked Sendable {
    static let schema = "feature_flags"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "key")
    var key: String

    @Field(key: "enabled")
    var enabled: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, key: String, enabled: Bool) {
        self.id = id
        self.key = key
        self.enabled = enabled
    }
}
