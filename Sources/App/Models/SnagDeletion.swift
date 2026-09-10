import Fluent
import Vapor

/// Durable, owner-scoped tombstone. Old clients/snapshots must not resurrect a snag.
final class SnagDeletion: Model, @unchecked Sendable {
    static let schema = "snag_deletions"
    @ID(key: .id) var id: UUID?
    @Field(key: "snag_id") var snagId: UUID
    @Field(key: "owner_id") var ownerId: UUID
    @Field(key: "project_id") var projectId: UUID
    @Field(key: "file_paths") var filePaths: [String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(snagId: UUID, ownerId: UUID, projectId: UUID) {
        self.snagId = snagId; self.ownerId = ownerId; self.projectId = projectId; filePaths = []
    }
}
