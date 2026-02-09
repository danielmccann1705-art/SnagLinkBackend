import Fluent
import Vapor

/// Stores synced drawing files and metadata from the iOS app for a magic link.
final class SyncedDrawing: Model, Content, @unchecked Sendable {
    static let schema = "synced_drawings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "magic_link_token")
    var magicLinkToken: String

    @Field(key: "drawing_id")
    var drawingId: UUID

    @Field(key: "file_path")
    var filePath: String

    @Field(key: "file_name")
    var fileName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, magicLinkToken: String, drawingId: UUID, filePath: String, fileName: String) {
        self.id = id
        self.magicLinkToken = magicLinkToken
        self.drawingId = drawingId
        self.filePath = filePath
        self.fileName = fileName
    }
}
