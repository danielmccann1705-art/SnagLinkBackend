import Fluent
import Vapor

// MARK: - Completion Photo
/// Photos uploaded by a contractor as evidence of completed work
final class CompletionPhoto: Model, Content, @unchecked Sendable {
    static let schema = "completion_photos"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "completion_id")
    var completion: Completion

    @Field(key: "url")
    var url: String

    @Field(key: "thumbnail_url")
    var thumbnailUrl: String?

    @Field(key: "filename")
    var filename: String?

    @Field(key: "content_type")
    var contentType: String?

    @Field(key: "file_size")
    var fileSize: Int?

    @Timestamp(key: "uploaded_at", on: .create)
    var uploadedAt: Date?

    // MARK: - Initializers

    init() {}

    init(
        id: UUID? = nil,
        completionId: UUID,
        url: String,
        thumbnailUrl: String? = nil,
        filename: String? = nil,
        contentType: String? = nil,
        fileSize: Int? = nil
    ) {
        self.id = id
        self.$completion.id = completionId
        self.url = url
        self.thumbnailUrl = thumbnailUrl
        self.filename = filename
        self.contentType = contentType
        self.fileSize = fileSize
    }
}
