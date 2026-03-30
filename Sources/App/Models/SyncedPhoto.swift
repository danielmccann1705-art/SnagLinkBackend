import Fluent
import Vapor

/// Stores synced photo files and metadata from the iOS app for a magic link.
/// Photos are linked to specific snags within the report.
final class SyncedPhoto: Model, Content, @unchecked Sendable {
    static let schema = "synced_photos"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "magic_link_token")
    var magicLinkToken: String

    @Field(key: "snag_id")
    var snagId: UUID

    @Field(key: "label")
    var label: String

    @Field(key: "file_path")
    var filePath: String

    @OptionalField(key: "thumbnail_file_path")
    var thumbnailFilePath: String?

    @Field(key: "sort_order")
    var sortOrder: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, magicLinkToken: String, snagId: UUID, label: String, filePath: String, sortOrder: Int, thumbnailFilePath: String? = nil) {
        self.id = id
        self.magicLinkToken = magicLinkToken
        self.snagId = snagId
        self.label = label
        self.filePath = filePath
        self.sortOrder = sortOrder
        self.thumbnailFilePath = thumbnailFilePath
    }
}
