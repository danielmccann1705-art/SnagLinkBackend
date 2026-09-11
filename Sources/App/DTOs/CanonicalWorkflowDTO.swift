import Vapor
import FluentSQL

enum WorkflowAction: String, CaseIterable { case start, submit, accept, sendBack = "send-back", reopen, internalFix = "internal-fix" }
struct WorkflowCommand: Content {
    let mutation: MutationMetadata
    let expectedRevision: Int64
    let expectedWorkflowRevision: Int64
    let attemptId: UUID?
    let expectedAttemptRevision: Int64?
    let notes: String?
    let reason: String?
    let evidenceIds: [UUID]?
    let waiverReason: String?
}
struct CompletionAttemptResponse: Content {
    let id: UUID; let snagId: UUID; let number: Int64; let actorId: UUID; let actorKind: String
    let notes: String?; let state: String; let revision: Int64; let submittedAt: Date; let evidenceIds: [UUID]
    init(_ row: SQLRow, evidence: [UUID]) throws {
        id = try row.decode(column: "id", as: UUID.self); snagId = try row.decode(column: "snag_id", as: UUID.self)
        number = try row.decode(column: "attempt_number", as: Int64.self); actorId = try row.decode(column: "actor_id", as: UUID?.self) ?? row.decode(column: "actor_grant_id", as: UUID.self)
        actorKind = try row.decode(column: "actor_kind", as: String.self); notes = try row.decode(column: "notes", as: String?.self)
        state = try row.decode(column: "state", as: String.self); revision = try row.decode(column: "revision", as: Int64.self)
        submittedAt = try row.decode(column: "submitted_at", as: Date.self); evidenceIds = evidence
    }
}
struct ReviewDecisionResponse: Content {
    let id: UUID; let snagId: UUID; let attemptId: UUID?; let actorId: UUID
    let kind: String; let reason: String?; let createdAt: Date
    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self); snagId = try row.decode(column: "snag_id", as: UUID.self)
        attemptId = try row.decode(column: "attempt_id", as: UUID?.self); actorId = try row.decode(column: "actor_id", as: UUID.self)
        kind = try row.decode(column: "kind", as: String.self); reason = try row.decode(column: "reason", as: String?.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
    }
}
struct WorkflowResponse: Content {
    let snag: PlatformSnagResponse
    let attempt: CompletionAttemptResponse?
    let decisions: [ReviewDecisionResponse]
}
struct WorkflowConflict: Error {
    struct Body: Content {
        enum CodingKeys: String, CodingKey { case error, identifier, reason, current, attempt }
        init(current: PlatformSnagResponse, attempt: CompletionAttemptResponse?) { self.current = current; self.attempt = attempt }
        init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); current = try c.decode(PlatformSnagResponse.self, forKey: .current); attempt = try c.decodeIfPresent(CompletionAttemptResponse.self, forKey: .attempt) }
        func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(error, forKey: .error); try c.encode(identifier, forKey: .identifier); try c.encode(reason, forKey: .reason); try c.encode(current, forKey: .current); try c.encodeIfPresent(attempt, forKey: .attempt) }
        var error: Bool { true }; var identifier: String { "workflow_conflict" }
        var reason: String { "This completion or decision changed. Review the latest evidence before trying again." }
        let current: PlatformSnagResponse
        let attempt: CompletionAttemptResponse?
    }
    let body: Body
}
