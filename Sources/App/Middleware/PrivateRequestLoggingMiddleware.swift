import Vapor
import FluentPostgresDriver

/// Legacy URL paths contain capability tokens. Log only registered route patterns
/// and status codes, never request URLs, query strings, bodies or error bindings.
struct PrivateRequestLoggingMiddleware: AsyncMiddleware {
    struct Failure: Content { let error: Bool; let reason: String; let identifier: String }
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        let started = DispatchTime.now().uptimeNanoseconds
        var failure: (any Error)?
        do {
            response = try await next.respond(to: request)
        } catch let conflict as WorkflowConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as ProjectGrantConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as DirectoryConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as ProjectRevisionConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let conflict as RevisionConflict {
            response = Response(status: .conflict)
            try response.content.encode(conflict.body)
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "55P03" {
            failure = error
            // A bounded workspace-lock wait ran out (WorkspaceAccessService lock timeouts): nothing was
            // changed, and the same request can simply be sent again.
            response = Response(status: .serviceUnavailable, headers: ["Retry-After": "2"])
            try response.content.encode(Failure(error: true, reason: "This workspace is busy. Try again in a moment.", identifier: "workspace_busy"))
        } catch {
            failure = error
            let abort = error as? AbortError
            let status = abort?.status ?? .internalServerError
            let reason = status.code < 500 ? (abort?.reason ?? "This action could not be completed") : "Snaglist is temporarily unavailable. Please try again shortly."
            response = Response(status: status, headers: abort?.headers ?? [:])
            try response.content.encode(Failure(error: true, reason: reason, identifier: (error as? Abort)?.identifier ?? "request_failed"))
        }
        let pattern = request.route.map { String(describing: $0.path) } ?? "unmatched"
        request.logger.log(level: response.status.code >= 500 ? .error : .info,
                           "Request completed", metadata: ["method": "\(request.method)", "route": "\(pattern)", "status": "\(response.status.code)"])
        if ServerTiming.enabled, pattern.contains("contractor") {
            // A 5xx, or an answer that only succeeded because the write path retried: the retry would otherwise hide the
            // very fault the record exists to find.
            let notes = request.storage[ServerTiming.RecorderKey.self]?.failureContext.notes ?? ""
            if response.status.code >= 500 || notes.contains("retry_after") {
                DiagnosticFailureRecord.record(request: request, route: pattern, status: Int(response.status.code), error: failure,
                                               durationMs: Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000))
            }
        }
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        if ["/api/", "/m/", "/auth/", "/internal/"].contains(where: request.url.path.hasPrefix) {
            // Retain a route's explicit private response contract while enforcing
            // no-store on every sensitive response, including error responses.
            let directives = response.headers[.cacheControl].flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            response.headers.replaceOrAdd(name: .cacheControl,
                                          value: directives.contains("private") ? "private, no-store" : "no-store")
        }
        return response
    }
}

/// Lane A P0e, staging only (`RUNTIME_DIAGNOSTICS=enabled`; production refuses it): the failure record for Contractor-link
/// routes. One log line and one durable row (`diagnostic_request_failures`) per 5xx answer — and per answer that succeeded
/// only because the write path retried — each holding
/// the route pattern, status, the answer's identifier, the error's type (and SQLSTATE for a database error), the phases
/// the request completed (`ServerTiming`) and the write path's notes (which refusal row, whether a retry ran). No URL,
/// token, key, message, body or bound value is ever read here.
enum DiagnosticFailureRecord {
    static func cause(of error: (any Error)?) -> String {
        guard let error else { return "response" }
        if let psql = error as? PSQLError { return "PSQLError(" + (psql.serverInfo?[.sqlState] ?? "\(psql.code)") + ")" }
        if error is CancellationError { return "CancellationError" }
        if let abort = error as? AbortError { return "Abort(\(abort.status.code))" }
        return String(reflecting: type(of: error))
    }
    static func record(request: Request, route: String, status: Int, error: (any Error)?, durationMs: Int) {
        let identifier = status < 500 ? "recovered" : (error as? Abort)?.identifier ?? ((error as? PSQLError)?.serverInfo?[.sqlState] == "55P03" ? "workspace_busy" : "request_failed")
        let context = request.storage[ServerTiming.RecorderKey.self]?.failureContext ?? (phases: "", notes: "")
        let requestID: String? = request.logger[metadataKey: "request-id"].map { "\($0)" }
        let cause = cause(of: error)
        request.logger.log(level: status >= 500 ? .error : .warning, status >= 500 ? "Request failed" : "Request recovered by retry", metadata: ["route": .string(route), "status": .string("\(status)"), "identifier": .string(identifier),
                                                         "cause": .string(cause), "phases": .string(context.phases), "notes": .string(context.notes)])
        let db = request.application.db, method = "\(request.method)"
        // Off the answer's path: a failure that is itself about the pool must not wait on the pool to be answered.
        Task.detached {
            try? await VerifiedIdentityService.sql(db).raw("""
                INSERT INTO diagnostic_request_failures (id, occurred_at, method, route, status, identifier, cause, phases, notes, request_id, duration_ms)
                VALUES (\(bind: UUID()), \(bind: Date()), \(bind: method), \(bind: route), \(bind: status), \(bind: identifier),
                        \(bind: cause), \(bind: context.phases), \(bind: context.notes), \(bind: requestID), \(bind: durationMs))
                """).run()
        }
    }
}
