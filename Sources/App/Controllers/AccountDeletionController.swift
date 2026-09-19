import Vapor

struct AccountDeletionController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let privateRoutes = routes.grouped(AccountDeletionPrivacyBoundary())
        privateRoutes.grouped("api","v1","users").grouped(JWTAuthMiddleware()).delete("me", use: request)
        privateRoutes.grouped("api","v2").grouped(PlatformAuthMiddleware()).delete("account", use: request)
        privateRoutes.grouped("api", "v1", "users").grouped(JWTAuthMiddleware()).get("me", "deletion-preparation", use: preparation)
        privateRoutes.grouped("api", "v2").grouped(PlatformAuthMiddleware()).get("account", "deletion-preparation", use: preparation)
        privateRoutes.grouped("api", "v1", "users").grouped(JWTAuthMiddleware()).post("me", "company-closures", "confirmation", use: closureConfirmation)
        privateRoutes.grouped("api", "v2").grouped(PlatformAuthMiddleware()).post("account", "company-closures", "confirmation", use: closureConfirmation)
        // Capability is in POST body, never a URL written to an access log.
        privateRoutes.post("api","v1","account-deletion","status", use: status)
        privateRoutes.post("api","v2","account-deletion","status", use: status)
    }
    @Sendable func preparation(req: Request) async throws -> AccountDeletionPreparation {
        try AccountDeletionService.requireAvailable(req.application)
        let userID = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            try await CompanyDeletionPreparationService.prepare(userID: userID, on: db)
        }
    }
    @Sendable func closureConfirmation(req: Request) async throws -> CompanyClosureConfirmationResponse {
        try AccountDeletionService.requireAvailable(req.application)
        let userID = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(CompanyClosureConfirmationRequest.self)
        return try await req.db.transaction { db in
            try await CompanyClosureConfirmationService.issue(userID: userID, body: body, on: db)
        }
    }
    @Sendable func request(req: Request) async throws -> Response {
        try AccountDeletionService.requireAvailable(req.application)
        let body = try req.content.decode(AccountDeletionRequest.self)
        let receipt = try await AccountDeletionService.request(userID: req.requireAuthenticatedUserId(), body: body, app: req.application)
        let response = try await receipt.encodeResponse(status: .accepted, for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
    @Sendable func status(req: Request) async throws -> Response {
        try await RateLimitService.enforce(key: "deletion-status:" + (req.remoteAddress?.ipAddress ?? "unknown"), action: .tokenLookup, on: req.db)
        let body = try req.content.decode(AccountDeletionStatusRequest.self)
        let receipt = try await AccountDeletionService.status(reference: body.receiptReference, on: req.db)
        let response = try await receipt.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
}

/// Include the same privacy headers on errors, expired receipts and rate limits.
/// Unknown failures carry no underlying database/provider message into a response.
private struct AccountDeletionPrivacyBoundary: AsyncMiddleware {
    struct Failure: Content { let error: Bool; let reason: String; let identifier: String }
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        do { response = try await next.respond(to: req) }
        catch {
            let abort = error as? AbortError
            let body = Failure(error: true, reason: abort?.reason ?? "Account deletion is temporarily unavailable",
                               identifier: (error as? Abort)?.identifier ?? (abort?.status == .badRequest ? "invalid_request" : "account_deletion_unavailable"))
            response = try await body.encodeResponse(status: abort?.status ?? .internalServerError, for: req)
            if let headers = abort?.headers {
                for (name, value) in headers { response.headers.replaceOrAdd(name: name, value: value) }
            }
        }
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return response
    }
}
