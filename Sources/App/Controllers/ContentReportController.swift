import Fluent
import Vapor

struct ContentReportController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped("api", "v1").grouped(JWTAuthMiddleware())
        authenticated.post("completions", ":completionId", "report", use: create)
        authenticated.get("moderation", "reports", use: pending)
        authenticated.get("moderation", "reports", ":reportId", use: evidence)
        authenticated.post("moderation", "reports", ":reportId", "resolve", use: resolve)
    }

    struct ReportRequest: Content {
        let id: UUID
        let reason: String
        let details: String
    }
    struct Receipt: Content { let success: Bool; let id: UUID }

    @Sendable func create(req: Request) async throws -> Receipt {
        let userId = try req.requireAuthenticatedUserId()
        guard let completionId = req.parameters.get("completionId", as: UUID.self),
              let completion = try await Completion.find(completionId, on: req.db),
              let link = try await MagicLink.find(completion.magicLinkId, on: req.db),
              link.createdById == userId else {
            throw Abort(.notFound, reason: "Completion not found")
        }
        let input = try req.content.decode(ReportRequest.self)
        let reasons = ["Inappropriate Content", "Spam or Misleading", "Harassment or Abuse", "False Completion Claim", "Other"]
        guard reasons.contains(input.reason), input.details.count <= 4000 else {
            throw Abort(.badRequest, reason: "Choose a report reason and keep details under 4,000 characters")
        }
        // A retry after a lost response returns the same private receipt.
        if let existing = try await ContentReport.find(input.id, on: req.db) {
            guard existing.reporterId == userId, existing.completionId == completionId,
                  existing.reason == input.reason,
                  existing.details == input.details.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw Abort(.conflict, reason: "Report reference is already in use")
            }
            return Receipt(success: true, id: input.id)
        }
        try await RateLimitService.enforce(key: "content_report:\(userId)", action: .apiCall, on: req.db)
        let report = ContentReport(id: input.id, reporterId: userId, completionId: completionId,
                                   reason: input.reason, details: input.details.trimmingCharacters(in: .whitespacesAndNewlines))
        try await report.save(on: req.db)
        return Receipt(success: true, id: input.id)
    }

    private func requireModerator(_ req: Request) throws {
        let userId = try req.requireAuthenticatedUserId()
        let allowed = (Environment.get("MODERATOR_USER_IDS") ?? "").split(separator: ",")
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard allowed.contains(userId) else { throw Abort(.forbidden) }
    }

    @Sendable func pending(req: Request) async throws -> [ContentReport] {
        try requireModerator(req)
        return try await ContentReport.query(on: req.db).filter(\.$status == "pending")
            .sort(\.$createdAt).limit(100).all()
    }

    struct Evidence: Content {
        let report: ContentReport
        let contractorName: String
        let notes: String?
        let photos: [CompletionPhoto]
    }
    @Sendable func evidence(req: Request) async throws -> Evidence {
        try requireModerator(req)
        guard let id = req.parameters.get("reportId", as: UUID.self),
              let report = try await ContentReport.find(id, on: req.db),
              let completion = try await Completion.find(report.completionId, on: req.db) else {
            throw Abort(.notFound)
        }
        let photos = try await CompletionPhoto.query(on: req.db)
            .filter(\.$completion.$id == report.completionId).all()
        return Evidence(report: report, contractorName: completion.contractorName, notes: completion.notes, photos: photos)
    }

    struct Resolution: Content { let blockLink: Bool }
    @Sendable func resolve(req: Request) async throws -> Receipt {
        try requireModerator(req)
        let input = try req.content.decode(Resolution.self)
        guard let id = req.parameters.get("reportId", as: UUID.self) else { throw Abort(.badRequest) }
        return try await req.db.transaction { db in
            guard let report = try await ContentReport.find(id, on: db) else { throw Abort(.notFound) }
            if input.blockLink,
               let completion = try await Completion.find(report.completionId, on: db),
               let link = try await MagicLink.find(completion.magicLinkId, on: db) {
                link.revokedAt = Date()
                try await link.save(on: db)
            }
            report.status = input.blockLink ? "link_blocked" : "reviewed"
            report.resolvedAt = Date()
            try await report.save(on: db)
            return Receipt(success: true, id: id)
        }
    }
}
