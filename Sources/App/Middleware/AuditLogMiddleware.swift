import Vapor
import Fluent

struct AuditLogMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)

            // Log successful requests for specific paths
            if shouldLog(request: request, response: response) {
                try await logRequest(
                    request: request,
                    statusCode: response.status.code,
                    success: true
                )
            }

            return response
        } catch {
            // Log failed requests
            let statusCode = (error as? AbortError)?.status.code ?? 500
            try? await logRequest(
                request: request,
                statusCode: statusCode,
                success: false,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func shouldLog(request: Request, response: Response) -> Bool {
        // Log all non-GET requests and specific important paths
        let method = request.method
        let path = request.url.path

        // Always log POST, PUT, DELETE, PATCH
        if method != .GET {
            return true
        }

        // Log validation endpoints
        if path.contains("/validate") || path.contains("/verify") {
            return true
        }

        return false
    }

    private func logRequest(
        request: Request,
        statusCode: UInt,
        success: Bool,
        error: String? = nil
    ) async throws {
        let path = request.url.path
        let method = request.method.rawValue

        var details = "\(method) \(path)"
        if let error = error {
            details += " - Error: \(error)"
        }

        // Determine event type based on path
        let eventType: AuditEventType = determineEventType(path: path, method: method)
        let resourceType: ResourceType = determineResourceType(path: path)

        try await AuditService.log(
            eventType: eventType,
            resourceType: resourceType,
            userId: request.authenticatedUserId,
            request: request,
            success: success,
            details: details,
            on: request.db
        )
    }

    private func determineEventType(path: String, method: String) -> AuditEventType {
        if path.contains("magic-link") {
            if path.contains("validate") {
                return .magicLinkValidated
            } else if path.contains("verify-pin") {
                return .pinVerifySuccess
            } else if method == "POST" {
                return .magicLinkCreated
            } else if method == "DELETE" {
                return .magicLinkRevoked
            }
            return .magicLinkValidated
        } else if path.contains("team-invite") {
            if path.contains("accept") {
                return .teamInviteAccepted
            } else if path.contains("decline") {
                return .teamInviteDeclined
            } else if method == "POST" {
                return .teamInviteCreated
            } else if method == "DELETE" {
                return .teamInviteRevoked
            }
            return .teamInviteCreated
        }
        return .magicLinkValidated
    }

    private func determineResourceType(path: String) -> ResourceType {
        if path.contains("magic-link") {
            return .magicLink
        } else if path.contains("team-invite") {
            return .teamInvite
        }
        return .user
    }
}
