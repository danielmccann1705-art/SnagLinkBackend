import Vapor
import FluentSQL

struct ProjectDiscoveryPage: Content {
    struct Item: Content {
        let project: PlatformProjectResponse
        /// This is a register bootstrap, never a promise of complete native recovery.
        let bootstrapState: String
        let coverage: [String]
    }
    let snapshotToken: String
    let items: [Item]
    let total: Int
    let nextOffset: Int?
    let complete: Bool
    let capturedAt: Date
    let expiresAt: Date
}

struct ProjectCommentCreateCommand: Content {
    let mutation: MutationMetadata
    let id: UUID
    let body: String
    let parentCommentId: UUID?
}
struct ProjectCommentRedactCommand: Content {
    let mutation: MutationMetadata
    let expectedRevision: Int64
    let reason: String
}
struct ProjectCommentResponse: Content {
    let id: UUID
    let projectId: UUID
    let snagId: UUID
    let parentCommentId: UUID?
    let authorUserId: UUID
    let authorName: String
    let visibility: String
    /// Redacted text is retained server-side for audit but never returned to clients.
    let body: String?
    let revision: Int64
    let createdAt: Date
    let redactedAt: Date?

    init(_ row: SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        projectId = try row.decode(column: "project_id", as: UUID.self)
        snagId = try row.decode(column: "snag_id", as: UUID.self)
        parentCommentId = try row.decode(column: "parent_comment_id", as: UUID?.self)
        authorUserId = try row.decode(column: "author_user_id", as: UUID.self)
        authorName = try row.decode(column: "author_name", as: String.self)
        revision = try row.decode(column: "revision", as: Int64.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        redactedAt = try row.decode(column: "redacted_at", as: Date?.self)
        body = redactedAt == nil ? try row.decode(column: "body", as: String.self) : nil
        visibility = "internal"
    }
}
