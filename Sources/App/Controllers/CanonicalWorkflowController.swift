import Vapor
import Fluent
import FluentSQL

struct CanonicalWorkflowController: RouteCollection {
    struct History: Content {
        let snag: PlatformSnagResponse
        let pending: CompletionAttemptResponse?
        let pendingEvidenceWaiver: ReviewDecisionResponse?
        let attempts: [CompletionAttemptResponse]
        let decisions: [ReviewDecisionResponse]
        let page: Int; let hasMore: Bool
    }
    func boot(routes: RoutesBuilder) throws {
        let workflow = routes.grouped("api", "v2", "projects", ":projectId", "snags", ":snagId", "workflow").grouped(PlatformAuthMiddleware())
        workflow.get(use: history)
        for action in WorkflowAction.allCases {
            workflow.post(PathComponent(stringLiteral: action.rawValue)) { req async throws -> WorkflowResponse in
                try await self.perform(req, action: action)
            }
        }
    }
    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func history(req: Request) async throws -> History {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let page = try req.query.get(Int?.self, at: "page") ?? 1
        guard (1...1000).contains(page) else { throw Abort(.badRequest, reason: "Invalid history page") }
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db)
            try PlatformMutationService.requireManaged(project)
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            let rows = try await sql.raw("SELECT * FROM completion_attempts WHERE snag_id = \(bind: snagID) AND project_id = \(bind: projectID) ORDER BY attempt_number DESC LIMIT 26 OFFSET \(bind: (page - 1) * 25)").all()
            let attempts = try await CanonicalWorkflowService.attempts(Array(rows.prefix(25)), on: db)
            let decisions = try await sql.raw("SELECT * FROM review_decisions WHERE snag_id = \(bind: snagID) AND project_id = \(bind: projectID) ORDER BY expected_workflow_revision DESC, CASE kind WHEN 'waiver' THEN 0 ELSE 1 END, id LIMIT 51 OFFSET \(bind: (page - 1) * 50)").all()
            let pending = try await CanonicalWorkflowService.pending(snagID: snagID, projectID: projectID, on: db)
            let waiver: ReviewDecisionResponse?
            if let pending {
                waiver = try await sql.raw("SELECT * FROM review_decisions WHERE attempt_id = \(bind: pending.id) AND kind = 'waiver'").first().map(ReviewDecisionResponse.init)
            } else { waiver = nil }
            return try .init(snag: PlatformSnagResponse(snag), pending: pending, pendingEvidenceWaiver: waiver, attempts: attempts, decisions: decisions.prefix(50).map(ReviewDecisionResponse.init), page: page, hasMore: rows.count > 25 || decisions.count > 50)
        }
    }
    @Sendable private func perform(_ req: Request, action: WorkflowAction) async throws -> WorkflowResponse {
        let projectID = try id("projectId", req), snagID = try id("snagId", req), actorID = try req.requireAuthenticatedUserId()
        let command = try req.content.decode(WorkflowCommand.self)
        let hash = try PlatformMutationService.requestHash(command, route: "POST:\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
            let capability: ProjectAccessPolicy.Action = [.accept, .sendBack, .reopen, .internalFix].contains(action) ? .review : .submitCompletion
            let (project, actions) = try await ProjectAccessService.require(capability, projectID: projectID, actorID: actorID, on: db)
            if let replay = try await PlatformMutationService.replay(WorkflowResponse.self, actorID: actorID, mutation: command.mutation, hash: hash, on: db) { return replay }
            let snag = try await PlatformSnagService.find(snagID, projectID: projectID, on: db)
            let response = try await CanonicalWorkflowService.execute(command, action: action, snag: snag, project: project, actorID: actorID, actions: actions, on: db)
            try await PlatformMutationService.record(response, actorID: actorID, workspaceID: project.workspaceId!, mutation: command.mutation, hash: hash, on: db)
            return response
        }
    }
}
