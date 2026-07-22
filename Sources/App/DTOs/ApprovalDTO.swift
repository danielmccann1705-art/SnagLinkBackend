import Vapor

// MARK: - Approval queue

/// A snag awaiting the PM's approval decision (B5).
struct SnagApprovalDTO: Content {
    let snagId: UUID
    let projectId: UUID
    let contractorId: UUID?
    let title: String
    let reference: String
    let status: String
    /// Best-available "submitted" time — the snag's last update (no dedicated column).
    let submittedAt: Date?
    let beforePhotoUrls: [String]
    let afterPhotoUrls: [String]
}

struct PendingApprovalsResponse: Content {
    let approvals: [SnagApprovalDTO]
    let totalCount: Int
    let page: Int
    let perPage: Int
}

// MARK: - Send back

struct SendBackRequest: Content {
    let reason: SendBackReason
    let note: String?

    func validate() throws {
        if let note = note, note.count > 1000 {
            throw Abort(.badRequest, reason: "Note must be 1000 characters or less")
        }
    }
}
