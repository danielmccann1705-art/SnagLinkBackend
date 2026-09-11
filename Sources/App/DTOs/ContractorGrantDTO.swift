import Vapor
import FluentSQL

struct LinkPrepareCommand: Content {
    let mutation: MutationMetadata
    let id: UUID
    let contractorId: UUID?
    let mode: String
    let snagIds: [UUID]
    let assetIds: [UUID]
    let durationDays: Int?
    let pin: String?
}
struct LinkRevisionCommand: Content { let mutation: MutationMetadata; let expectedRevision: Int64 }
struct LinkGrantResponse: Content {
    let id: UUID; let projectId: UUID; let contractorId: UUID?; let mode: String
    let state: String; let revision: Int64; let requiresPIN: Bool; let createdAt: Date
    let activatedAt: Date?; let expiresAt: Date; let revokedAt: Date?
    let selectedSnagIds: [UUID]; let activeSnagIds: [UUID]; let requiredAssetIds: [UUID]
    init(_ row: SQLRow, selected: [UUID], active: [UUID], assets: [UUID]) throws {
        id = try row.decode(column: "id", as: UUID.self); projectId = try row.decode(column: "project_id", as: UUID.self)
        contractorId = try row.decode(column: "contractor_id", as: UUID?.self); mode = try row.decode(column: "mode", as: String.self)
        state = try row.decode(column: "state", as: String.self); revision = try row.decode(column: "revision", as: Int64.self)
        requiresPIN = try row.decode(column: "pin_hash", as: String?.self) != nil
        createdAt = try row.decode(column: "created_at", as: Date.self); activatedAt = try row.decode(column: "activated_at", as: Date?.self)
        expiresAt = try row.decode(column: "expires_at", as: Date.self); revokedAt = try row.decode(column: "revoked_at", as: Date?.self)
        selectedSnagIds = selected; activeSnagIds = active; requiredAssetIds = assets
    }
}
struct LinkActivationResponse: Content { let grant: LinkGrantResponse; let contractorPath: String? }
struct ContractorItem: Content {
    struct Photo: Content { let id: UUID; let label: String; let width: Int?; let height: Int? }
    struct Submission: Content { let id: UUID; let number: Int64; let notes: String?; let state: String; let submittedAt: Date; let evidenceIds: [UUID]; let feedback: String? }
    let id: UUID; let reference: String; let title: String; let description: String?; let location: String?
    let priority: String; let dueDate: String?; let status: String; let revision: Int64; let workflowRevision: Int64
    let photos: [Photo]; let submissions: [Submission]
}
struct ContractorPage: Content {
    let projectName: String; let projectAddress: String?; let contractorName: String?
    let mode: String; let expiresAt: Date; let issuedAt: Date; let items: [ContractorItem]
    let total: Int; let page: Int; let hasMore: Bool
}
struct ContractorWorkflowResult: Content {
    let snagId: UUID; let status: String; let revision: Int64; let workflowRevision: Int64
    let attemptId: UUID?; let attemptState: String?
    init(_ response: WorkflowResponse) {
        snagId = response.snag.snag.id; status = response.snag.snag.status
        revision = response.snag.revision; workflowRevision = response.snag.workflowRevision
        attemptId = response.attempt?.id; attemptState = response.attempt?.state
    }
}
