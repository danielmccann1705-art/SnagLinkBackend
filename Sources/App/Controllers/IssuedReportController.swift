import Vapor
import Fluent

/// Report contract v1 routes (`LANE-D-BACKEND.md` §0). Every call re-checks project
/// access inside its transaction; issuing needs `.review`, everything else `.read`.
struct IssuedReportController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let reports = routes.grouped("api", "v2", "projects", ":projectId", "reports").grouped(PlatformAuthMiddleware())
        reports.post("preview", use: preview)
        reports.post(use: issue)
        reports.get(use: list)
        reports.get(":reportId", use: get)
        reports.get(":reportId", "download", use: download)
    }
    private func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return id
    }
    @Sendable func preview(req: Request) async throws -> IssuedReportDetail {
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(ReportPreviewCommand.self)
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.requireRead(projectID: projectID, actorID: actorID, on: db)
            let snapshot = try await IssuedReportService.build(title: body.title, scope: body.scope, project: project, on: db)
            let people = try await IssuedReportService.people(IssuedReportService.peopleIn(snapshot, issuer: nil), on: db)
            return IssuedReportDetail(report: nil, snapshot: snapshot, people: people)
        }
    }
    /// Idempotent by `mutation.operationId`, exactly like snag commands: a retry with
    /// the same body returns the same report; a reused id with a different body is 409.
    /// Marks a failure that happened after the actor's `.review` right was confirmed and
    /// the operation was found to be new: the only failures `report_failed` counts.
    private struct GenuineIssueFailure: Error { let underlying: Error }

    @Sendable func issue(req: Request) async throws -> IssuedReportResponse {
        let receivedAt = Date()
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(ReportIssueCommand.self)
        let hash = try PlatformMutationService.requestHash(body, route: "\(req.method):\(req.url.path)")
        let applied: (IssuedReportResponse, MeasurementRelayService.OutcomeCandidate?)
        do {
            applied = try await req.db.transaction { db -> (IssuedReportResponse, MeasurementRelayService.OutcomeCandidate?) in
                try await PlatformMutationService.lock(actorID: actorID, mutation: body.mutation, on: db)
                let (project, _) = try await ProjectAccessService.require(.review, projectID: projectID, actorID: actorID, on: db)
                if let old = try await PlatformMutationService.replay(IssuedReportResponse.self, actorID: actorID, mutation: body.mutation, hash: hash, on: db) { return (old, nil) }
                do {
                    let result = try await IssuedReportService.issue(body, project: project, actorID: actorID, on: db)
                    let occurredAt = try await PlatformMutationService.record(result, actorID: actorID, workspaceID: result.workspaceId, mutation: body.mutation, hash: hash, on: db)
                    let candidate = await MeasurementRelayService.outcomeCandidate(
                        accountID: actorID, operationID: body.mutation.operationId,
                        installationID: body.mutation.deviceId, event: .reportIssued,
                        occurredAt: occurredAt, on: db)
                    return (result, candidate)
                } catch { throw GenuineIssueFailure(underlying: error) }
            }
        } catch let failure as GenuineIssueFailure {
            // The issue transaction has rolled back. The response is the original error.
            await ProductFunnelMeasurement.reportFailed(failure.underlying, accountID: actorID,
                operationID: body.mutation.operationId, receivedAt: receivedAt, app: req.application, on: req.db)
            throw failure.underlying
        }
        if let candidate = applied.1 {
            await MeasurementRelayService.recordOutcome(
                candidate, app: req.application, logger: req.logger, on: req.db)
        }
        return applied.0
    }
    @Sendable func list(req: Request) async throws -> IssuedReportPage {
        let projectID = try id("projectId", req), actorID = try req.requireAuthenticatedUserId()
        let page = (try? req.query.get(Int.self, at: "page")) ?? 1
        return try await req.db.transaction { db in
            _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: actorID, on: db)
            return try await IssuedReportService.list(projectID: projectID, page: page, on: db)
        }
    }
    @Sendable func get(req: Request) async throws -> IssuedReportDetail {
        let projectID = try id("projectId", req), reportID = try id("reportId", req), actorID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: actorID, on: db)
            return try await IssuedReportService.find(reportID, projectID: projectID, on: db)
        }
    }
    @Sendable func download(req: Request) async throws -> Response {
        let projectID = try id("projectId", req), reportID = try id("reportId", req), actorID = try req.requireAuthenticatedUserId()
        let detail = try await req.db.transaction { db -> IssuedReportDetail in
            _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: actorID, on: db)
            return try await IssuedReportService.find(reportID, projectID: projectID, on: db)
        }
        guard let report = detail.report else { throw Abort(.notFound, reason: "Report unavailable") }
        let html = IssuedReportRenderer.html(report: report, snapshot: detail.snapshot, people: detail.people)
        let filename = IssuedReportRenderer.filename(project: detail.snapshot.project, reference: report.reference)
        return Response(status: .ok, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Disposition": "attachment; filename=\"\(filename)\"",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": IssuedReportRenderer.contentSecurityPolicy,
            "X-Snaglist-Report-Sha256": report.snapshotSha256
        ], body: .init(string: html))
    }
}
