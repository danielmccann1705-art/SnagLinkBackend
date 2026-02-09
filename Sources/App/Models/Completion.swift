import Fluent
import Vapor

// MARK: - Completion Status
enum CompletionStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case rejected
}

// MARK: - Completion
/// Represents a contractor's submission of completed work for a snag
final class Completion: Model, Content, @unchecked Sendable {
    static let schema = "completions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "snag_id")
    var snagId: UUID

    @Field(key: "magic_link_id")
    var magicLinkId: UUID

    @Field(key: "contractor_name")
    var contractorName: String

    @Field(key: "notes")
    var notes: String?

    @Field(key: "status")
    var status: CompletionStatus

    @Field(key: "rejection_reason")
    var rejectionReason: String?

    @Field(key: "reviewed_by_user_id")
    var reviewedByUserId: UUID?

    @Field(key: "reviewed_by_name")
    var reviewedByName: String?

    @Timestamp(key: "submitted_at", on: .create)
    var submittedAt: Date?

    @Field(key: "reviewed_at")
    var reviewedAt: Date?

    @Children(for: \.$completion)
    var photos: [CompletionPhoto]

    // MARK: - Computed Properties

    var isPending: Bool {
        status == .pending
    }

    var isApproved: Bool {
        status == .approved
    }

    var isRejected: Bool {
        status == .rejected
    }

    // MARK: - Initializers

    init() {}

    init(
        id: UUID? = nil,
        snagId: UUID,
        magicLinkId: UUID,
        contractorName: String,
        notes: String? = nil,
        status: CompletionStatus = .pending
    ) {
        self.id = id
        self.snagId = snagId
        self.magicLinkId = magicLinkId
        self.contractorName = contractorName
        self.notes = notes
        self.status = status
    }

    // MARK: - Status Transitions

    func approve(by userId: UUID, userName: String) {
        self.status = .approved
        self.reviewedByUserId = userId
        self.reviewedByName = userName
        self.reviewedAt = Date()
    }

    func reject(by userId: UUID, userName: String, reason: String) {
        self.status = .rejected
        self.reviewedByUserId = userId
        self.reviewedByName = userName
        self.rejectionReason = reason
        self.reviewedAt = Date()
    }
}
