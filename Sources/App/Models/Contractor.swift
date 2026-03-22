import Fluent
import Vapor

final class Contractor: Model, Content, @unchecked Sendable {
    static let schema = "contractors"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "company_name")
    var companyName: String

    @OptionalField(key: "contact_name")
    var contactName: String?

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "phone")
    var phone: String?

    @OptionalField(key: "notes")
    var notes: String?

    @Field(key: "is_archived")
    var isArchived: Bool

    @Field(key: "trade_ids")
    var tradeIds: [UUID]

    @Field(key: "owner_id")
    var ownerId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        companyName: String,
        contactName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        notes: String? = nil,
        isArchived: Bool = false,
        tradeIds: [UUID] = [],
        ownerId: UUID
    ) {
        self.id = id
        self.companyName = companyName
        self.contactName = contactName
        self.email = email
        self.phone = phone
        self.notes = notes
        self.isArchived = isArchived
        self.tradeIds = tradeIds
        self.ownerId = ownerId
    }
}
