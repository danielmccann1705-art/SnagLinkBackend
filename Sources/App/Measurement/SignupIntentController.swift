import Vapor

/// Native-only pre-auth signup measurement routes. Capabilities travel only in request
/// bodies, never in a URL; the request logger records route patterns and status codes only.
struct SignupIntentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let intents = routes.grouped("api", "v2", "measurement", "signup-intents")
        intents.on(.POST, body: .collect(maxSize: "2kb"), use: issue)
        intents.on(.POST, ":intentId", "cancel", body: .collect(maxSize: "1kb"), use: cancel)
    }

    @Sendable func issue(req: Request) async throws -> Response {
        try requireNative(req)
        let platform = try PlatformConfiguration.load(on: req.application)
        try await limit(req, platform: platform, route: "issue")
        let input = try decode(SignupIntentRequest.self, req)
        let issued = try await SignupIntentService.issue(input, platform: platform, on: req.db)
        let response = Response(status: .created)
        try response.content.encode(issued)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func cancel(req: Request) async throws -> Response {
        try requireNative(req)
        let platform = try PlatformConfiguration.load(on: req.application)
        try await limit(req, platform: platform, route: "cancel")
        guard let raw = req.parameters.get("intentId"), raw.utf8.count == 36, let intentID = UUID(uuidString: raw) else {
            throw SignupIntentService.notFound()
        }
        let input = try decode(SignupIntentCancelRequest.self, req)
        let state = try await SignupIntentService.cancel(intentID: intentID, capability: input.capability, on: req.db)
        let response = Response(status: .ok)
        try response.content.encode(SignupIntentCancelResponse(intentId: intentID, state: state))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    private func requireNative(_ req: Request) throws {
        guard req.headers["Origin"].isEmpty, req.headers["Sec-Fetch-Site"].isEmpty else {
            throw Abort(.forbidden, reason: "Use this measurement choice from the Snaglist app", identifier: "measurement_native_required")
        }
    }

    private func decode<T: Content>(_ type: T.Type, _ req: Request) throws -> T {
        do { return try req.content.decode(type) }
        catch { throw Abort(.badRequest, reason: "Use a valid measurement request", identifier: "measurement_request_invalid") }
    }

    private func limit(_ req: Request, platform: PlatformConfiguration, route: String) async throws {
        let key = "signup-intent-\(route):" + SHA256Hasher.hash(token: platform.environment + ":" + IPAddressExtractor.extract(from: req))
        try await req.db.transaction { db in
            try await VerifiedIdentityService.lock("rate:" + key, on: db)
            try await RateLimitService.enforce(key: key, action: .signupIntent, on: db)
        }
    }
}
