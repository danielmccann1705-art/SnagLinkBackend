import Fluent
import Vapor

/// Stores synced report data (project, snags, drawings metadata) from the iOS app
/// for a magic link. The web viewer reads this to display the report.
final class SyncedReport: Model, Content, @unchecked Sendable {
    static let schema = "synced_reports"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "magic_link_token")
    var magicLinkToken: String

    @Field(key: "report_json")
    var reportJSON: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, magicLinkToken: String, reportJSON: String) {
        self.id = id
        self.magicLinkToken = magicLinkToken
        self.reportJSON = reportJSON
    }
}
