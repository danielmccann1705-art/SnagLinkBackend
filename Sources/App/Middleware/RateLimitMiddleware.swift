import Vapor
import Fluent

struct RateLimitMiddleware: AsyncMiddleware {
    let action: RateLimitAction

    init(action: RateLimitAction = .apiCall) {
        self.action = action
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Use IP address as the rate limit key
        let key = IPAddressExtractor.extract(from: request)

        // Check rate limit
        let result = try await RateLimitService.check(
            key: key,
            action: action,
            on: request.db
        )

        if !result.allowed {
            // Log rate limit exceeded
            try await AuditService.logRateLimitExceeded(
                resourceType: .user,
                request: request,
                on: request.db
            )

            let retryAfter = Int(result.resetAt.timeIntervalSince(Date()))
            var headers = HTTPHeaders()
            headers.add(name: "Retry-After", value: String(retryAfter))
            headers.add(name: "X-RateLimit-Limit", value: String(action.limit))
            headers.add(name: "X-RateLimit-Remaining", value: "0")
            headers.add(name: "X-RateLimit-Reset", value: String(Int(result.resetAt.timeIntervalSince1970)))

            throw Abort(.tooManyRequests, headers: headers, reason: "Rate limit exceeded")
        }

        // Add rate limit headers to response
        let response = try await next.respond(to: request)

        response.headers.add(name: "X-RateLimit-Limit", value: String(action.limit))
        response.headers.add(name: "X-RateLimit-Remaining", value: String(result.remaining))
        response.headers.add(name: "X-RateLimit-Reset", value: String(Int(result.resetAt.timeIntervalSince1970)))

        return response
    }
}
