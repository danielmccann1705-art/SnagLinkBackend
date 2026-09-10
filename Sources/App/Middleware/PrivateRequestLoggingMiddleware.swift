import Vapor

/// Legacy URL paths contain capability tokens. Log only registered route patterns
/// and status codes, never request URLs, query strings, bodies or error bindings.
struct PrivateRequestLoggingMiddleware: AsyncMiddleware {
    struct Failure: Content { let error: Bool; let reason: String; let identifier: String }
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        do {
            response = try await next.respond(to: request)
        } catch let conflict as ProjectGrantConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as DirectoryConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as RevisionConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch {
            let abort = error as? AbortError
            let status = abort?.status ?? .internalServerError
            let reason = status.code < 500 ? (abort?.reason ?? "This action could not be completed") : "Snaglist is temporarily unavailable. Please try again shortly."
            response = Response(status: status, headers: abort?.headers ?? [:])
            try response.content.encode(Failure(error: true, reason: reason, identifier: (error as? Abort)?.identifier ?? "request_failed"))
        }
        let pattern = request.route.map { String(describing: $0.path) } ?? "unmatched"
        request.logger.log(level: response.status.code >= 500 ? .error : .info,
                           "Request completed", metadata: ["method": "\(request.method)", "route": "\(pattern)", "status": "\(response.status.code)"])
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        if request.url.path.hasPrefix("/api/") || request.url.path.hasPrefix("/m/") || request.url.path.hasPrefix("/auth/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        }
        return response
    }
}
