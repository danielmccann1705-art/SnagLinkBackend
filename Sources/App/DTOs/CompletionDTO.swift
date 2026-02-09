import Vapor

// MARK: - Submit Completion Request
/// Request body for submitting a completion via magic link
struct SubmitCompletionRequest: Content, Validatable {
    let contractorName: String
    let notes: String?
    let photoUrls: [String]?

    static func validations(_ validations: inout Validations) {
        validations.add("contractorName", as: String.self, is: !.empty)
        validations.add("contractorName", as: String.self, is: .count(1...100))
    }
}

// MARK: - Approve Completion Request
struct ApproveCompletionRequest: Content {
    let reviewerName: String?
}

// MARK: - Reject Completion Request
struct RejectCompletionRequest: Content, Validatable {
    let reason: String
    let reviewerName: String?

    static func validations(_ validations: inout Validations) {
        validations.add("reason", as: String.self, is: !.empty)
        validations.add("reason", as: String.self, is: .count(1...500))
    }
}

// MARK: - Completion Response
/// Public response representation of a completion
struct CompletionResponse: Content {
    let id: UUID
    let snagId: UUID
    let contractorName: String
    let notes: String?
    let status: String
    let rejectionReason: String?
    let reviewedByName: String?
    let submittedAt: Date?
    let reviewedAt: Date?
    let photos: [CompletionPhotoResponse]?

    init(from completion: Completion, includePhotos: Bool = true) {
        self.id = completion.id!
        self.snagId = completion.snagId
        self.contractorName = completion.contractorName
        self.notes = completion.notes
        self.status = completion.status.rawValue
        self.rejectionReason = completion.rejectionReason
        self.reviewedByName = completion.reviewedByName
        self.submittedAt = completion.submittedAt
        self.reviewedAt = completion.reviewedAt

        if includePhotos {
            self.photos = completion.photos.map { CompletionPhotoResponse(from: $0) }
        } else {
            self.photos = nil
        }
    }
}

// MARK: - Completion Photo Response
struct CompletionPhotoResponse: Content {
    let id: UUID
    let url: String
    let thumbnailUrl: String?
    let filename: String?
    let uploadedAt: Date?

    init(from photo: CompletionPhoto) {
        self.id = photo.id!
        self.url = photo.url
        self.thumbnailUrl = photo.thumbnailUrl
        self.filename = photo.filename
        self.uploadedAt = photo.uploadedAt
    }
}

// MARK: - Pending Completions Response
/// Response for listing pending completions with summary info
struct PendingCompletionsResponse: Content {
    let completions: [PendingCompletionSummary]
    let totalCount: Int
}

struct PendingCompletionSummary: Content {
    let id: UUID
    let snagId: UUID
    let contractorName: String
    let submittedAt: Date?
    let photoCount: Int
    let hasNotes: Bool

    init(from completion: Completion) {
        self.id = completion.id!
        self.snagId = completion.snagId
        self.contractorName = completion.contractorName
        self.submittedAt = completion.submittedAt
        self.photoCount = completion.photos.count
        self.hasNotes = completion.notes != nil && !completion.notes!.isEmpty
    }
}

// MARK: - Snag Completions Response
/// Response for listing all completions for a specific snag
struct SnagCompletionsResponse: Content {
    let completions: [SnagCompletionEntry]
}

struct SnagCompletionEntry: Content {
    let id: UUID
    let snagId: UUID
    let contractorName: String
    let notes: String?
    let photoUrls: [String]
    let status: String
    let createdAt: Date?
}

// MARK: - Completion Action Response
/// Generic response for completion actions
struct CompletionActionResponse: Content {
    let success: Bool
    let message: String
    let completionId: UUID?
    let newStatus: String?

    static func submitted(id: UUID) -> CompletionActionResponse {
        CompletionActionResponse(
            success: true,
            message: "Completion submitted successfully",
            completionId: id,
            newStatus: "pending"
        )
    }

    static func approved(id: UUID) -> CompletionActionResponse {
        CompletionActionResponse(
            success: true,
            message: "Completion approved",
            completionId: id,
            newStatus: "approved"
        )
    }

    static func rejected(id: UUID) -> CompletionActionResponse {
        CompletionActionResponse(
            success: true,
            message: "Completion rejected",
            completionId: id,
            newStatus: "rejected"
        )
    }

    static func error(_ message: String) -> CompletionActionResponse {
        CompletionActionResponse(
            success: false,
            message: message,
            completionId: nil,
            newStatus: nil
        )
    }
}
