import Vapor
import Fluent

struct AnalyticsController: RouteCollection {

    // MARK: - DTOs

    struct EventBatch: Content {
        let events: [EventDTO]
    }

    struct EventDTO: Content {
        let name: String
        let properties: [String: String]?
        let deviceId: String?
        let appVersion: String
        let timestamp: Date?
    }

    struct EventResponse: Content {
        let success: Bool
        let received: Int
    }

    // MARK: - Routes

    func boot(routes: RoutesBuilder) throws {
        let group = routes.grouped("api", "v1")
        // Public endpoint — anonymous events allowed (paywall_viewed before sign in, etc.)
        group.post("events", use: ingestEvents)
        group.post("diagnostics", use: ingestDiagnostics)
    }

    // MARK: - Ingest Events

    func ingestEvents(req: Request) async throws -> EventResponse {
        let batch = try req.content.decode(EventBatch.self)

        // Optional auth — link to user if Bearer token present
        let userId = try await optionalActor(req)

        var saved = 0
        for event in batch.events {
            // JSON-encode properties
            let propsJSON: String?
            if let props = event.properties, let data = try? JSONEncoder().encode(props) {
                propsJSON = String(data: data, encoding: .utf8)
            } else {
                propsJSON = nil
            }

            let model = AnalyticsEvent(
                eventName: event.name,
                userId: userId,
                deviceId: event.deviceId,
                properties: propsJSON,
                appVersion: event.appVersion,
                platform: "ios"
            )
            try await model.save(on: req.db)
            saved += 1
        }

        return EventResponse(success: true, received: saved)
    }

    private func optionalActor(_ req: Request) async throws -> UUID? {
        guard req.headers.first(name: .authorization) != nil else { return nil }
        // Public ingestion permits absent credentials, never unverified attribution.
        return try await JWTAuthMiddleware.authenticate(req).userId
    }

    // MARK: - Ingest Diagnostics (MetricKit payloads)

    func ingestDiagnostics(req: Request) async throws -> HTTPStatus {
        // Just store the raw MetricKit payload as a special analytics event
        guard let body = req.body.data else {
            throw Abort(.badRequest, reason: "Missing body")
        }
        let bodyString = String(buffer: body)
        let kind = req.headers.first(name: "X-Diagnostic-Kind") ?? "unknown"

        let userId = try await optionalActor(req)

        let event = AnalyticsEvent(
            eventName: "metrickit_\(kind)",
            userId: userId,
            properties: bodyString.count > 100_000 ? String(bodyString.prefix(100_000)) : bodyString,
            appVersion: "unknown",
            platform: "ios"
        )
        try await event.save(on: req.db)
        return .ok
    }
}
