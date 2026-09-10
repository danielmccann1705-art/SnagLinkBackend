import Fluent
import Vapor

/// Private moderation record. Never returned in contractor/shared-report responses.
final class ContentReport: Model, Content, @unchecked Sendable {
    static let schema = "content_reports"
    @ID(key: .id) var id: UUID?
    @Field(key: "reporter_id") var reporterId: UUID
    @Field(key: "completion_id") var completionId: UUID
    @Field(key: "reason") var reason: String
    @Field(key: "details") var details: String
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "resolved_at") var resolvedAt: Date?
    init() {}
    init(id: UUID, reporterId: UUID, completionId: UUID, reason: String, details: String) {
        self.id = id
        self.reporterId = reporterId
        self.completionId = completionId
        self.reason = reason
        self.details = details
        self.status = "pending"
    }
}
