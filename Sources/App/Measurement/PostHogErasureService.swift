import Vapor
import Fluent
import FluentSQL
import AsyncHTTPClient
import CoreFoundation

/// EU-only, one provider request per worker step. HTTP acceptance is never a
/// deletion receipt. No customer traffic is enabled until isolated acceptance.
enum PostHogErasureService {
    static let liveReceiverAccepted = false
    static let host = "https://eu.posthog.com"
    // Internal escalation policy, not a PostHog completion SLA. Preserve the
    // unresolved receipt for manual reconciliation after this observation window.
    static let observationWindow: TimeInterval = 7 * 86_400
    struct Configuration: Sendable {
        let projectID: String
        let apiKey: String
        var valid: Bool {
            (1...20).contains(projectID.utf8.count) && projectID.first != "0"
                && projectID.utf8.allSatisfy { (48...57).contains($0) }
                && (20...4096).contains(apiKey.utf8.count)
                && apiKey.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
        }
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }
    struct Reply: Sendable { let status: Int; let body: Data }
    typealias Transport = @Sendable (HTTPMethod, URI, HTTPHeaders, Data?) async throws -> Reply
    struct TransportKey: StorageKey { typealias Value = Transport }
    enum Outcome: Equatable { case completed, pending, retry, manual }
    private struct ClientKey: StorageKey { typealias Value = PostHogErasureHTTPClient }
    private struct ClientLock: LockKey {}

    static func configuration(_ app: Application) -> Configuration? {
        if app.environment == .testing { return app.storage[ConfigurationKey.self] }
        guard let project = Environment.get("POSTHOG_ERASURE_PROJECT_ID"),
              let key = Environment.get("POSTHOG_ERASURE_API_KEY") else { return nil }
        return .init(projectID: project, apiKey: key)
    }

    static func step(jobID: UUID, leaseToken: UUID, accountID: UUID, subjectID: UUID,
                     app: Application, now: Date = Date(), on db: Database) async -> Outcome {
        guard app.environment == .testing || liveReceiverAccepted,
              let config = configuration(app), config.valid,
              let transport = transport(app) else { return .manual }
        do {
            let sql = try VerifiedIdentityService.sql(db)
            guard let subject = try await sql.raw("""
                SELECT s.opaque_subject FROM measurement_erasure_jobs j
                JOIN measurement_subjects s ON s.id=j.subject_id AND s.account_id=j.account_id
                WHERE j.id=\(bind:jobID) AND j.lease_token=\(bind:leaseToken) AND j.state='leased'
                  AND j.lease_expires_at>\(bind:now) AND j.destination='posthog'
                  AND j.account_id=\(bind:accountID) AND j.subject_id=\(bind:subjectID)
                  AND s.purpose='productAnalytics' AND s.state='revoked'
                  AND NOT EXISTS (SELECT 1 FROM measurement_dispatch_jobs d
                    WHERE d.subject_id=s.id AND d.destination='posthog' AND d.state IN ('pending','failing','leased'))
                """).first() else { return .manual }
            let opaque = try subject.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased()
            let base = "\(host)/api/projects/\(config.projectID)/persons/"
            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: config.apiKey)
            headers.contentType = .json
            let receipt = try await sql.raw("SELECT * FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:jobID)").first()
            guard let receipt else {
                let reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil)
                guard reply.status == 200 else { return classifyRead(reply.status) }
                guard let person = matchedPerson(reply.body, distinctID: opaque) else { return .manual }
                // Persist the exact provider person UUID before any delete request.
                guard try await sql.raw("""
                    INSERT INTO measurement_posthog_erasure_receipts(job_id,project_id,person_uuid,phase,resolved_at)
                    SELECT id,\(bind:config.projectID),\(bind:person),'resolved',\(bind:now)
                    FROM measurement_erasure_jobs WHERE id=\(bind:jobID) AND lease_token=\(bind:leaseToken)
                      AND state='leased' AND lease_expires_at>\(bind:now)
                    ON CONFLICT(job_id) DO NOTHING RETURNING job_id
                    """).first() != nil else { return .retry }
                return .pending
            }
            guard try receipt.decode(column: "project_id", as: String.self) == config.projectID else { return .manual }
            let person = try receipt.decode(column: "person_uuid", as: UUID.self)
            let phase = try receipt.decode(column: "phase", as: String.self)
            if phase == "completed" { return .completed }
            if phase == "resolved" {
                // Autocommitted before network I/O: an ambiguous response or crash
                // resumes by polling this receipt, never by blindly re-deleting.
                guard try await sql.raw("""
                    UPDATE measurement_posthog_erasure_receipts SET phase='submitting',requested_at=\(bind:now)
                    WHERE job_id=\(bind:jobID) AND phase='resolved' AND EXISTS (
                      SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                        AND j.lease_token=\(bind:leaseToken) AND j.state='leased' AND j.lease_expires_at>\(bind:now))
                    RETURNING job_id
                    """).first() != nil else { return .retry }
                let body = try JSONSerialization.data(withJSONObject: ["distinct_ids": [opaque],
                    "delete_events": true, "delete_recordings": false, "keep_person": false], options: [.sortedKeys])
                let reply: Reply
                do { reply = try await transport(.POST, URI(string: base + "bulk_delete/"), headers, body) }
                catch { return .pending }
                if reply.status == 429 {
                    // An explicit rate refusal did not acknowledge a deletion.
                    try await update(jobID, leaseToken, sql, phase: "resolved", requestedAt: nil)
                    return .retry
                }
                guard reply.status == 202, queuedOnePerson(reply.body) else {
                    // 5xx/timeout/malformed acceptance are ambiguous; keep the
                    // persisted attempt and poll. Redirects/auth/refusals need action.
                    if reply.status == 202 || (500...599).contains(reply.status) { return .pending }
                    return .manual
                }
                try await sql.raw("""
                    UPDATE measurement_posthog_erasure_receipts SET phase='polling',queue_acknowledged_at=\(bind:now)
                    WHERE job_id=\(bind:jobID) AND EXISTS (SELECT 1 FROM measurement_erasure_jobs j
                      WHERE j.id=\(bind:jobID) AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                    """).run()
                return .pending
            }
            if phase == "submitting" || phase == "polling" {
                guard let requested = try receipt.decode(column: "requested_at", as: Date?.self) else { return .manual }
                let expired = now.timeIntervalSince(requested) >= observationWindow
                let reply: Reply
                do {
                    reply = try await transport(.GET,
                        URI(string: base + "deletion_status/?person_uuid=" + person.uuidString.lowercased() + "&status=all"), headers, nil)
                } catch { return expired ? .manual : .retry }
                guard reply.status == 200 else { return expired ? .manual : classifyRead(reply.status) }
                switch deletionStatus(reply.body, person: person, requestedAt: requested, now: now) {
                case .invalid: return .manual
                case .pending: return expired ? .manual : .pending
                case .verified(let created, let verified):
                    try await sql.raw("""
                        UPDATE measurement_posthog_erasure_receipts SET phase='events_verified',
                            provider_created_at=\(bind:created),events_verified_at=\(bind:verified)
                        WHERE job_id=\(bind:jobID) AND EXISTS (SELECT 1 FROM measurement_erasure_jobs j
                          WHERE j.id=\(bind:jobID) AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                        """).run()
                    return .pending
                }
            }
            guard phase == "events_verified" else { return .manual }
            guard let requested = try receipt.decode(column: "requested_at", as: Date?.self) else { return .manual }
            let expired = now.timeIntervalSince(requested) >= observationWindow
            // The documented status endpoint verifies events, not profile removal.
            let reply: Reply
            do { reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil) }
            catch { return expired ? .manual : .retry }
            guard reply.status == 200 else { return expired ? .manual : classifyRead(reply.status) }
            guard let results = list(reply.body) else { return .manual }
            guard results.isEmpty else { return expired ? .manual : .pending }
            guard try await sql.raw("""
                UPDATE measurement_posthog_erasure_receipts SET phase='completed',profile_absent_at=\(bind:now)
                WHERE job_id=\(bind:jobID) AND phase='events_verified' AND EXISTS (
                  SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                    AND j.lease_token=\(bind:leaseToken) AND j.state='leased') RETURNING job_id
                """).first() != nil else { return .retry }
            return .completed
        } catch { return .retry }
    }

    private static func update(_ job: UUID, _ token: UUID, _ sql: SQLDatabase,
                               phase: String, requestedAt: Date?) async throws {
        try await sql.raw("""
            UPDATE measurement_posthog_erasure_receipts SET phase=\(bind:phase),requested_at=\(bind:requestedAt)
            WHERE job_id=\(bind:job) AND EXISTS (SELECT 1 FROM measurement_erasure_jobs j
              WHERE j.id=\(bind:job) AND j.lease_token=\(bind:token) AND j.state='leased')
            """).run()
    }

    private static func classifyRead(_ status: Int) -> Outcome {
        [408, 425, 429].contains(status) || (500...599).contains(status) ? .retry : .manual
    }

    private static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= 262_144 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func list(_ data: Data) -> [[String: Any]]? {
        guard let object = object(data), let results = object["results"] as? [[String: Any]],
              object["next"] == nil || object["next"] is NSNull else { return nil }
        if let count = object["count"], integer(count) != results.count { return nil }
        return results
    }
    static func matchedPerson(_ data: Data, distinctID: String) -> UUID? {
        guard let results = list(data), results.count == 1,
              let distinctIDs = results[0]["distinct_ids"] as? [String], distinctIDs == [distinctID],
              let uuid = results[0]["uuid"] as? String else { return nil }
        // No alias-expanded deletion: this integration owns exactly one opaque ID.
        return UUID(uuidString: uuid)
    }
    static func queuedOnePerson(_ data: Data) -> Bool {
        guard let object = object(data), integer(object["persons_found"]) == 1,
              integer(object["persons_deleted"]) == 0,
              integer(object["persons_queued_for_deletion"]) == 1,
              boolean(object["events_queued_for_deletion"]) == true,
              let errors = object["deletion_errors"] as? [Any], errors.isEmpty else { return false }
        return true
    }
    enum DeletionStatus: Equatable { case invalid, pending, verified(created: Date, verified: Date) }
    static func deletionStatus(_ data: Data, person: UUID, requestedAt: Date, now: Date) -> DeletionStatus {
        guard let rows = list(data) else { return .invalid }
        guard !rows.isEmpty else { return .pending }
        guard rows.count == 1, let uuid = rows[0]["person_uuid"] as? String,
              UUID(uuidString: uuid) == person,
              let text = rows[0]["created_at"] as? String, let created = date(text),
              created >= requestedAt.addingTimeInterval(-5), created <= now.addingTimeInterval(300),
              let status = rows[0]["status"] as? String else { return .invalid }
        if status == "pending", rows[0]["delete_verified_at"] is NSNull { return .pending }
        guard status == "completed", let verifiedText = rows[0]["delete_verified_at"] as? String,
              let verified = date(verifiedText), verified >= created,
              verified <= now.addingTimeInterval(300) else { return .invalid }
        return .verified(created: created, verified: verified)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= 1000 else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func transport(_ app: Application) -> Transport? {
        if app.environment == .testing { return app.storage[TransportKey.self] }
        let client = app.locks.lock(for: ClientLock.self).withLock {
            if let client = app.storage[ClientKey.self] { return client }
            let client = PostHogErasureHTTPClient(eventLoopGroup: app.eventLoopGroup, logger: app.logger)
            app.storage[ClientKey.self] = client
            app.lifecycle.use(client)
            return client
        }
        return { method, uri, headers, body in try await client.request(method, uri, headers: headers, body: body) }
    }
}

final class PostHogErasureHTTPClient: LifecycleHandler, @unchecked Sendable {
    private let client: HTTPClient
    private let logger: Logger
    init(eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.client = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(redirectConfiguration: .disallow), backgroundActivityLogger: logger)
        self.logger = logger
    }
    func request(_ method: HTTPMethod, _ uri: URI, headers: HTTPHeaders, body: Data?) async throws -> PostHogErasureService.Reply {
        var request = HTTPClientRequest(url: uri.string)
        request.method = method
        request.headers = headers
        if let body { request.body = .bytes(ByteBuffer(data: body)) }
        let response = try await client.execute(request, timeout: .seconds(20), logger: logger)
        let data = try await response.body.collect(upTo: 262_144)
        return .init(status: Int(response.status.code), body: Data(buffer: data))
    }
    func close() async throws { try await client.shutdown() }
    func shutdown(_ application: Application) { try? client.syncShutdown() }
    func shutdownAsync(_ application: Application) async { try? await client.shutdown() }
}
