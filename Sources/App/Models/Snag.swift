import Fluent
import Vapor

final class Snag: Model, Content, @unchecked Sendable {
    static let schema = "snags"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "reference")
    var reference: String

    @Field(key: "title")
    var title: String

    @OptionalField(key: "description")
    var snagDescription: String?

    @Field(key: "status")
    var status: String

    @Field(key: "priority")
    var priority: String

    @OptionalField(key: "location")
    var location: String?

    @OptionalField(key: "due_date")
    var dueDate: Date?

    @OptionalField(key: "closed_at")
    var closedAt: Date?

    @OptionalField(key: "cost_estimate")
    var costEstimate: Double?

    @OptionalField(key: "actual_cost")
    var actualCost: Double?

    @Field(key: "currency")
    var currency: String

    @OptionalField(key: "drawing_pin_x")
    var drawingPinX: Double?

    @OptionalField(key: "drawing_pin_y")
    var drawingPinY: Double?

    @Field(key: "project_id")
    var projectId: UUID

    @OptionalField(key: "contractor_id")
    var contractorId: UUID?

    @OptionalField(key: "trade_id")
    var tradeId: UUID?

    @OptionalField(key: "drawing_id")
    var drawingId: UUID?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    @Field(key: "owner_id")
    var ownerId: UUID

    @Field(key: "tags")
    var tags: [String]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        reference: String,
        title: String,
        snagDescription: String? = nil,
        status: String = "open",
        priority: String = "medium",
        location: String? = nil,
        dueDate: Date? = nil,
        costEstimate: Double? = nil,
        actualCost: Double? = nil,
        currency: String = "GBP",
        drawingPinX: Double? = nil,
        drawingPinY: Double? = nil,
        projectId: UUID,
        contractorId: UUID? = nil,
        tradeId: UUID? = nil,
        drawingId: UUID? = nil,
        assignedAt: Date? = nil,
        ownerId: UUID,
        tags: [String] = []
    ) {
        self.id = id
        self.reference = reference
        self.title = title
        self.snagDescription = snagDescription
        self.status = status
        self.priority = priority
        self.location = location
        self.dueDate = dueDate
        self.costEstimate = costEstimate
        self.actualCost = actualCost
        self.currency = currency
        self.drawingPinX = drawingPinX
        self.drawingPinY = drawingPinY
        self.projectId = projectId
        self.contractorId = contractorId
        self.tradeId = tradeId
        self.drawingId = drawingId
        self.assignedAt = assignedAt
        self.ownerId = ownerId
        self.tags = tags
    }
}
