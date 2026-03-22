import Fluent
import Vapor

final class Project: Model, Content, @unchecked Sendable {
    static let schema = "projects"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "reference")
    var reference: String

    @OptionalField(key: "client_name")
    var clientName: String?

    @OptionalField(key: "client_email")
    var clientEmail: String?

    @OptionalField(key: "client_phone")
    var clientPhone: String?

    @OptionalField(key: "address")
    var address: String?

    @OptionalField(key: "notes")
    var notes: String?

    @OptionalField(key: "project_type")
    var projectType: String?

    @Field(key: "status")
    var status: String

    @Field(key: "is_favorite")
    var isFavorite: Bool

    @OptionalField(key: "cover_image_path")
    var coverImagePath: String?

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @Field(key: "owner_id")
    var ownerId: UUID

    @OptionalField(key: "team_id")
    var teamId: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        reference: String,
        clientName: String? = nil,
        clientEmail: String? = nil,
        clientPhone: String? = nil,
        address: String? = nil,
        notes: String? = nil,
        projectType: String? = nil,
        status: String = "active",
        isFavorite: Bool = false,
        coverImagePath: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        ownerId: UUID,
        teamId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.reference = reference
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientPhone = clientPhone
        self.address = address
        self.notes = notes
        self.projectType = projectType
        self.status = status
        self.isFavorite = isFavorite
        self.coverImagePath = coverImagePath
        self.latitude = latitude
        self.longitude = longitude
        self.ownerId = ownerId
        self.teamId = teamId
    }
}
