import Fluent
import Vapor

/// Reason a Project Manager sent a submitted snag back to the contractor (B5).
/// Raw values are stable — persisted to `snag_send_backs.reason`.
enum SendBackReason: String, Codable, CaseIterable {
    case workIncomplete
    case poorFinish
    case wrongLocation
    case needMorePhotos
    case cannotVerify
    case other
}

/// Audit record for a "send back" decision in the approval workflow (B5).
final class SnagSendBack: Model, Content, @unchecked Sendable {
    static let schema = "snag_send_backs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "snag_id")
    var snagId: UUID

    @Field(key: "reason")
    var reason: String

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "sent_back_by")
    var sentBackBy: UUID

    @Timestamp(key: "sent_back_at", on: .create)
    var sentBackAt: Date?

    init() {}

    init(id: UUID? = nil, snagId: UUID, reason: SendBackReason, note: String?, sentBackBy: UUID) {
        self.id = id
        self.snagId = snagId
        self.reason = reason.rawValue
        self.note = note
        self.sentBackBy = sentBackBy
    }
}
