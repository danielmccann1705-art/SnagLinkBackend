import Fluent
import FluentSQL
import Vapor

/// Publishes the retained company-side consequences of an account erasure.
/// The caller owns the enclosing deletion transaction and has already locked all
/// affected workspaces in stable order.
enum AccountDeletionPropagationService {
    static let maximumChangeGroupSize = 1_000

    static func pseudonymiseCompanyAttribution(userID: UUID, on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        let companyWorkspaces = try await sql.raw("""
            SELECT t.id FROM teams t JOIN workspace_memberships m ON m.workspace_id=t.id
            WHERE t.kind='company' AND m.user_id=\(bind:userID) AND m.state='active'
            ORDER BY t.id
            """).all().map { try $0.decode(column:"id",as:UUID.self) }

        try await sql.raw("""
            UPDATE project_comments c SET author_name='Former member',revision=c.revision+1
            FROM teams t WHERE t.id=c.workspace_id AND t.kind='company' AND c.author_user_id=\(bind:userID)
            """).run()
        let commentWorkspaces = try await sql.raw("""
            SELECT DISTINCT c.workspace_id FROM project_comments c JOIN teams t ON t.id=c.workspace_id
            WHERE t.kind='company' AND c.author_user_id=\(bind:userID) ORDER BY c.workspace_id
            """).all().map { try $0.decode(column:"workspace_id",as:UUID.self) }
        for workspaceID in commentWorkspaces {
            var afterProject: UUID?, afterComment: UUID?
            while true {
                let comments: [SQLRow]
                if let afterProject,let afterComment {
                    comments=try await sql.raw("""
                        SELECT * FROM project_comments WHERE workspace_id=\(bind:workspaceID)
                          AND author_user_id=\(bind:userID) AND (project_id,id)>(\(bind:afterProject),\(bind:afterComment))
                        ORDER BY project_id,id LIMIT \(bind:maximumChangeGroupSize)
                        """).all()
                } else {
                    comments=try await sql.raw("""
                        SELECT * FROM project_comments WHERE workspace_id=\(bind:workspaceID) AND author_user_id=\(bind:userID)
                        ORDER BY project_id,id LIMIT \(bind:maximumChangeGroupSize)
                        """).all()
                }
                guard !comments.isEmpty else { break }
                let groupID=UUID()
                _=try await sql.raw("SELECT set_config('snaglist.change_group',\(bind:groupID.uuidString),true)").first()
                for row in comments {
                    let response=try ProjectCommentResponse(row)
                    try await PlatformMutationService.change(workspaceID:workspaceID,projectID:response.projectId,
                        type:"comment",entityID:response.id,revision:response.revision,kind:"updated",
                        fields:["authorName"],payload:response,actorID:userID,on:database)
                }
                let last=comments.last!
                afterProject=try last.decode(column:"project_id",as:UUID.self)
                afterComment=try last.decode(column:"id",as:UUID.self)
            }
        }

        // This is a scope event only: no email, prior display name or other raw
        // contact detail is copied into durable activity.
        for workspaceID in companyWorkspaces {
            try await WorkspaceAccessService.activity(workspaceID:workspaceID,actorID:userID,
                action:"member_removed",targetID:userID,on:database)
        }
    }
}
