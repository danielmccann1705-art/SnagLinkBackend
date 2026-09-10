import Vapor

/// Closed JSON representation preserves absent keys versus explicit null in patches.
indirect enum PlatformJSON: Codable, Equatable, Sendable {
    case null, string(String), number(Double), bool(Bool), array([PlatformJSON]), object([String: PlatformJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([PlatformJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: PlatformJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

struct MutationMetadata: Content { let operationId: UUID; let deviceId: UUID }
struct SnagCreateCommand: Content {
    let mutation: MutationMetadata
    let id: UUID
    let fields: [String: PlatformJSON]
}
struct SnagEditCommand: Content {
    let mutation: MutationMetadata
    let expectedRevision: Int64
    let fields: [String: PlatformJSON]
}
struct SnagArchiveCommand: Content {
    let mutation: MutationMetadata
    let expectedRevision: Int64
    let reason: String
}
struct SnagPublishCommand: Content { let mutation: MutationMetadata; let expectedRevision: Int64 }
struct CanonicalSnagValues: Content {
    let dueOn: String?
    let costEstimateDecimal: String?
    let actualCostDecimal: String?
    let currency: String
    init(_ snag: Snag) {
        dueOn = snag.dueOn
        costEstimateDecimal = snag.costEstimateDecimal.map { NSDecimalNumber(decimal: $0).stringValue }
        actualCostDecimal = snag.actualCostDecimal.map { NSDecimalNumber(decimal: $0).stringValue }
        currency = snag.currency
    }
}
struct PlatformSnagResponse: Content {
    let snag: SnagResponse
    /// Authoritative exact values for new clients. Optional only to decode stored
    /// pre-parity candidate receipts; clients must refetch when absent.
    let canonical: CanonicalSnagValues?
    let revision: Int64
    let workflowRevision: Int64
    let displayNumber: Int64?
    let publishedAt: Date?
    let archivedAt: Date?
    let archiveReason: String?
    init(_ snag: Snag) {
        self.snag = SnagResponse(from: snag); revision = snag.revision; workflowRevision = snag.workflowRevision
        canonical = CanonicalSnagValues(snag)
        displayNumber = snag.displayNumber; publishedAt = snag.publishedAt; archivedAt = snag.archivedAt; archiveReason = snag.archiveReason
    }
}
struct RevisionConflict: Error {
    struct Body: Content {
        let error = true
        let identifier = "revision_conflict"
        let reason = "This snag changed since you opened it. Your draft has been kept; compare it with the latest version."
        let current: PlatformSnagResponse
        let changedFields: [String]
    }
    let body: Body
}
