import Vapor
import Fluent
import FluentSQL
import AsyncHTTPClient
import CoreFoundation

/// EU-only, one provider request per worker step. HTTP acceptance is never a
/// deletion receipt. No customer traffic is enabled until isolated acceptance.
///
/// The first deletion request waits until the subject's last possible in-flight
/// capture plus the ingestion-lag window has passed. Completion then needs two
/// provider passes per deletion round (POSTHOG-DELAYED-INGESTION-OCT9.md):
///  1. the queued person event deletion is verified for *this round's* request
///     and the profile lookup is empty;
///  2. once the ingestion-lag window has passed, measured from the later of this
///     round's deletion request and the subject's last possible in-flight capture,
///     a Query API count of events carrying the opaque distinct ID is zero and the
///     profile lookup is still empty.
/// PostHog's person deletion removes only events written before its request
/// (`_timestamp <= created_at` in its source), so data that lands later is
/// invisible to pass 1. When pass 2 finds data the person deletion is re-issued
/// for a bounded number of rounds; late events with no resolvable profile, or a
/// round PostHog does not freshly verify, escalate to manual handling. Every
/// pass is retained in `measurement_posthog_erasure_passes`.
enum PostHogErasureService {
    static let liveReceiverAccepted = false
    static let host = "https://eu.posthog.com"
    // Internal escalation policy, not a PostHog completion SLA. Preserve the
    // unresolved receipt for manual reconciliation after this observation window.
    static let observationWindow: TimeInterval = 7 * 86_400
    /// Internal assumption about PostHog's worst-case capture-to-storage lag, not
    /// a vendor figure. Override with POSTHOG_ERASURE_INGESTION_LAG_SECONDS.
    static let defaultIngestionLagWindow: TimeInterval = 86_400
    static let ingestionLagWindowRange: ClosedRange<TimeInterval> = 3_600...(7 * 86_400)
    /// Deletion rounds per job, the first included. A later round exists only
    /// because pass 2 found data; exhausting them requires manual handling.
    static let maximumRounds = 3
    struct Configuration: Sendable {
        let projectID: String
        let apiKey: String
        var ingestionLagWindow: TimeInterval = PostHogErasureService.defaultIngestionLagWindow
        var valid: Bool {
            (1...20).contains(projectID.utf8.count) && projectID.first != "0"
                && projectID.utf8.allSatisfy { (48...57).contains($0) }
                && (20...4096).contains(apiKey.utf8.count)
                && apiKey.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
                && PostHogErasureService.ingestionLagWindowRange.contains(ingestionLagWindow)
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
        var window = defaultIngestionLagWindow
        if let text = Environment.get("POSTHOG_ERASURE_INGESTION_LAG_SECONDS") {
            // An unreadable override fails closed through `valid`, never to the default.
            window = TimeInterval(text) ?? -1
        }
        return .init(projectID: project, apiKey: key, ingestionLagWindow: window)
    }

    static func step(jobID: UUID, leaseToken: UUID, accountID: UUID, subjectID: UUID,
                     app: Application, now: Date = Date(), on db: Database) async -> Outcome {
        guard app.environment == .testing || liveReceiverAccepted,
              let config = configuration(app), config.valid,
              let transport = transport(app) else { return .manual }
        do {
            let sql = try VerifiedIdentityService.sql(db)
            guard let subject = try await sql.raw("""
                SELECT s.opaque_subject,s.send_in_flight_until FROM measurement_erasure_jobs j
                JOIN measurement_subjects s ON s.id=j.subject_id AND s.account_id=j.account_id
                WHERE j.id=\(bind:jobID) AND j.lease_token=\(bind:leaseToken) AND j.state='leased'
                  AND j.lease_expires_at>\(bind:now) AND j.destination='posthog'
                  AND j.account_id=\(bind:accountID) AND j.subject_id=\(bind:subjectID)
                  AND s.purpose='productAnalytics' AND s.state='revoked'
                  AND NOT EXISTS (SELECT 1 FROM measurement_dispatch_jobs d
                    WHERE d.subject_id=s.id AND d.destination='posthog' AND d.state IN ('pending','failing','leased'))
                """).first() else { return .manual }
            let opaque = try subject.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased()
            // Latest instant a capture for this subject could still have been in
            // flight when the dispatch barrier was recorded (claim-time lease end).
            let inFlightUntil = try subject.decode(column: "send_in_flight_until", as: Date?.self)
            let base = "\(host)/api/projects/\(config.projectID)/persons/"
            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: config.apiKey)
            headers.contentType = .json
            let receipt = try await sql.raw("SELECT * FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:jobID)").first()
            guard let receipt else {
                // Settle before the one deletion request. PostHog's person deletion
                // covers only events written before its request and is queued once per
                // person, so it waits until every capture that could still have been in
                // flight at the barrier has had the ingestion-lag window to be written.
                // A profile created by such a capture then exists to be resolved.
                if let inFlightUntil, now < inFlightUntil.addingTimeInterval(config.ingestionLagWindow) {
                    return .pending
                }
                let reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil)
                guard reply.status == 200 else { return classifyRead(reply.status) }
                guard let person = matchedPerson(reply.body, distinctID: opaque) else { return .manual }
                // Persist the exact provider person UUID before any delete request.
                guard try await sql.raw("""
                    INSERT INTO measurement_posthog_erasure_receipts(job_id,posthog_project_id,person_uuid,phase,resolved_at,in_flight_until)
                    SELECT id,\(bind:config.projectID),\(bind:person),'resolved',\(bind:now),\(bind:inFlightUntil)
                    FROM measurement_erasure_jobs WHERE id=\(bind:jobID) AND lease_token=\(bind:leaseToken)
                      AND state='leased' AND lease_expires_at>\(bind:now)
                    ON CONFLICT(job_id) DO NOTHING RETURNING job_id
                    """).first() != nil else { return .retry }
                return .pending
            }
            guard try receipt.decode(column: "posthog_project_id", as: String.self) == config.projectID else { return .manual }
            let person = try receipt.decode(column: "person_uuid", as: UUID.self)
            let phase = try receipt.decode(column: "phase", as: String.self)
            let round = try receipt.decode(column: "round", as: Int.self)
            let lease = Lease(job: jobID, token: leaseToken)
            switch phase {
            case "completed":
                return .completed
            case "resolved":
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
                // Acknowledgement only enters polling. A 202 is never a completion.
                return .pending
            case "submitting", "polling":
                guard let requested = try receipt.decode(column: "requested_at", as: Date?.self) else { return .manual }
                let expired = now.timeIntervalSince(requested) >= observationWindow
                let reply: Reply
                do {
                    reply = try await transport(.GET,
                        URI(string: base + "deletion_status/?person_uuid=" + person.uuidString.lowercased() + "&status=all"), headers, nil)
                } catch { return expired ? .manual : .retry }
                guard reply.status == 200 else { return expired ? .manual : classifyRead(reply.status) }
                // The status row must belong to this round's request. A row created
                // before it (a person whose event deletion was already queued once)
                // says nothing about data written since, so it is invalid here.
                switch deletionStatus(reply.body, person: person, requestedAt: requested, now: now) {
                case .invalid: return .manual
                case .pending: return expired ? .manual : .pending
                case .verified(let created, let verified):
                    return try await db.transaction { tx -> Outcome in
                        let txSQL = try VerifiedIdentityService.sql(tx)
                        guard try await txSQL.raw("""
                            UPDATE measurement_posthog_erasure_receipts SET phase='events_verified',
                                provider_created_at=\(bind:created),events_verified_at=\(bind:verified)
                            WHERE job_id=\(bind:jobID) AND phase IN ('submitting','polling') AND EXISTS (
                              SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                                AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                            RETURNING job_id
                            """).first() != nil else { return .retry }
                        try await recordPass(lease, txSQL, round: round, stage: "deletion", check: "deletion_status",
                            at: now, person: person, requestedAt: requested, providerVerifiedAt: verified,
                            eventCount: nil, outcome: "absent")
                        return .pending
                    }
                }
            case "events_verified":
                guard let requested = try receipt.decode(column: "requested_at", as: Date?.self) else { return .manual }
                let expired = now.timeIntervalSince(requested) >= observationWindow
                // The documented status endpoint verifies events, not profile removal.
                let reply: Reply
                do { reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil) }
                catch { return expired ? .manual : .retry }
                guard reply.status == 200 else { return expired ? .manual : classifyRead(reply.status) }
                guard let results = list(reply.body) else { return .manual }
                guard results.isEmpty else { return expired ? .manual : .pending }
                // Pass 1 is complete. The quiet period starts from the later of this
                // round's request and the last possible in-flight capture.
                let quietFrom = max(requested, inFlightUntil ?? requested)
                let quietUntil = quietFrom.addingTimeInterval(config.ingestionLagWindow)
                return try await db.transaction { tx -> Outcome in
                    let txSQL = try VerifiedIdentityService.sql(tx)
                    guard try await txSQL.raw("""
                        UPDATE measurement_posthog_erasure_receipts SET phase='quiet',profile_absent_at=\(bind:now),
                            in_flight_until=\(bind:inFlightUntil),quiet_until=\(bind:quietUntil)
                        WHERE job_id=\(bind:jobID) AND phase='events_verified' AND EXISTS (
                          SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                            AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                        RETURNING job_id
                        """).first() != nil else { return .retry }
                    try await recordPass(lease, txSQL, round: round, stage: "deletion", check: "profile",
                        at: now, person: person, requestedAt: requested, providerVerifiedAt: nil,
                        eventCount: nil, outcome: "absent")
                    return .pending
                }
            case "quiet":
                guard let quietUntil = try receipt.decode(column: "quiet_until", as: Date?.self) else { return .manual }
                // No provider request is made, and nothing completes, inside the window.
                guard now >= quietUntil else { return .pending }
                let overdue = now.timeIntervalSince(quietUntil) >= observationWindow
                guard let body = eventCountQuery(distinctID: opaque) else { return .manual }
                let reply: Reply
                do { reply = try await transport(.POST, URI(string: "\(host)/api/projects/\(config.projectID)/query/"), headers, body) }
                catch { return overdue ? .manual : .retry }
                guard reply.status == 200 else {
                    let outcome: Outcome = overdue ? .manual : classifyRead(reply.status)
                    if outcome == .manual {
                        // A key without query access cannot prove event absence.
                        try await recordPass(lease, sql, round: round, stage: "quiet", check: "events", at: now,
                            person: nil, requestedAt: nil, providerVerifiedAt: nil, eventCount: nil, outcome: "unverifiable")
                    }
                    return outcome
                }
                switch eventCount(reply.body) {
                case .invalid:
                    try await recordPass(lease, sql, round: round, stage: "quiet", check: "events", at: now,
                        person: nil, requestedAt: nil, providerVerifiedAt: nil, eventCount: nil, outcome: "unverifiable")
                    return .manual
                case .cached:
                    // A cached answer could predate late data; ask again later.
                    return overdue ? .manual : .retry
                case .count(let count) where count > 0:
                    return try await lateData(lease, round: round, phase: phase, check: "events",
                                              eventCount: count, now: now, on: db)
                case .count:
                    return try await db.transaction { tx -> Outcome in
                        let txSQL = try VerifiedIdentityService.sql(tx)
                        guard try await txSQL.raw("""
                            UPDATE measurement_posthog_erasure_receipts SET phase='quiet_events_absent'
                            WHERE job_id=\(bind:jobID) AND phase='quiet' AND EXISTS (
                              SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                                AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                            RETURNING job_id
                            """).first() != nil else { return .retry }
                        try await recordPass(lease, txSQL, round: round, stage: "quiet", check: "events", at: now,
                            person: nil, requestedAt: nil, providerVerifiedAt: nil, eventCount: 0, outcome: "absent")
                        return .pending
                    }
                }
            case "quiet_events_absent":
                guard let quietUntil = try receipt.decode(column: "quiet_until", as: Date?.self),
                      now >= quietUntil else { return .manual }
                let overdue = now.timeIntervalSince(quietUntil) >= observationWindow
                let reply: Reply
                do { reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil) }
                catch { return overdue ? .manual : .retry }
                guard reply.status == 200 else { return overdue ? .manual : classifyRead(reply.status) }
                guard let results = list(reply.body) else { return .manual }
                guard results.isEmpty else {
                    return try await lateData(lease, round: round, phase: phase, check: "profile",
                                              eventCount: nil, now: now, on: db)
                }
                return try await db.transaction { tx -> Outcome in
                    let txSQL = try VerifiedIdentityService.sql(tx)
                    guard try await txSQL.raw("""
                        UPDATE measurement_posthog_erasure_receipts SET phase='completed',completed_at=\(bind:now)
                        WHERE job_id=\(bind:jobID) AND phase='quiet_events_absent' AND quiet_until<=\(bind:now) AND EXISTS (
                          SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                            AND j.lease_token=\(bind:leaseToken) AND j.state='leased')
                        RETURNING job_id
                        """).first() != nil else { return .retry }
                    try await recordPass(lease, txSQL, round: round, stage: "quiet", check: "profile", at: now,
                        person: nil, requestedAt: nil, providerVerifiedAt: nil, eventCount: nil, outcome: "absent")
                    return .completed
                }
            case "reresolving":
                guard round < maximumRounds else { return .manual }
                let quietUntil = try receipt.decode(column: "quiet_until", as: Date?.self)
                let overdue = quietUntil.map { now.timeIntervalSince($0) >= observationWindow } ?? true
                let reply: Reply
                do { reply = try await transport(.GET, URI(string: base + "?distinct_id=" + opaque), headers, nil) }
                catch { return overdue ? .manual : .retry }
                guard reply.status == 200 else { return overdue ? .manual : classifyRead(reply.status) }
                // Late events without a resolvable profile have no supported
                // person-deletion path; an alias-expanded profile is never ours to delete.
                guard let next = matchedPerson(reply.body, distinctID: opaque) else { return .manual }
                guard try await sql.raw("""
                    UPDATE measurement_posthog_erasure_receipts SET round=round+1,phase='resolved',person_uuid=\(bind:next),
                        resolved_at=\(bind:now),requested_at=NULL,queue_acknowledged_at=NULL,provider_created_at=NULL,
                        events_verified_at=NULL,profile_absent_at=NULL,in_flight_until=NULL,quiet_until=NULL
                    WHERE job_id=\(bind:jobID) AND phase='reresolving' AND round<\(bind:maximumRounds) AND EXISTS (
                      SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:jobID)
                        AND j.lease_token=\(bind:leaseToken) AND j.state='leased' AND j.lease_expires_at>\(bind:now))
                    RETURNING job_id
                    """).first() != nil else { return .retry }
                return .pending
            default:
                return .manual
            }
        } catch { return .retry }
    }

    private struct Lease: Sendable { let job: UUID; let token: UUID }

    /// Pass 2 found data. A further round re-resolves the profile and re-issues the
    /// person deletion; the last round keeps its receipt and escalates.
    private static func lateData(_ lease: Lease, round: Int, phase: String, check: String,
                                 eventCount: Int?, now: Date, on db: Database) async throws -> Outcome {
        try await db.transaction { tx -> Outcome in
            let sql = try VerifiedIdentityService.sql(tx)
            let another = round < maximumRounds
            if another {
                guard try await sql.raw("""
                    UPDATE measurement_posthog_erasure_receipts SET phase='reresolving'
                    WHERE job_id=\(bind:lease.job) AND phase=\(bind:phase) AND EXISTS (
                      SELECT 1 FROM measurement_erasure_jobs j WHERE j.id=\(bind:lease.job)
                        AND j.lease_token=\(bind:lease.token) AND j.state='leased')
                    RETURNING job_id
                    """).first() != nil else { return .retry }
            }
            try await recordPass(lease, sql, round: round, stage: "quiet", check: check, at: now,
                person: nil, requestedAt: nil, providerVerifiedAt: nil, eventCount: eventCount, outcome: "present")
            return another ? .pending : .manual
        }
    }

    private static func recordPass(_ lease: Lease, _ sql: SQLDatabase, round: Int, stage: String, check: String,
                                   at checkedAt: Date, person: UUID?, requestedAt: Date?, providerVerifiedAt: Date?,
                                   eventCount: Int?, outcome: String) async throws {
        try await sql.raw("""
            INSERT INTO measurement_posthog_erasure_passes(job_id,sequence,round,stage,check_kind,checked_at,
                person_uuid,requested_at,provider_verified_at,event_count,outcome)
            SELECT r.job_id,COALESCE((SELECT MAX(p.sequence) FROM measurement_posthog_erasure_passes p
                     WHERE p.job_id=r.job_id),0)+1,
                   \(bind:round),\(bind:stage),\(bind:check),\(bind:checkedAt),\(bind:person),\(bind:requestedAt),
                   \(bind:providerVerifiedAt),\(bind:eventCount),\(bind:outcome)
            FROM measurement_posthog_erasure_receipts r JOIN measurement_erasure_jobs j ON j.id=r.job_id
            WHERE r.job_id=\(bind:lease.job) AND j.lease_token=\(bind:lease.token) AND j.state='leased'
            """).run()
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

    /// Documented Query API (`POST /api/projects/:id/query/`, Query Read scope):
    /// the only supported read found that counts stored events by distinct ID,
    /// whatever person they were attached to and whenever they were written.
    /// `force_blocking` always executes rather than returning a cached result.
    static func eventCountQuery(distinctID: String) -> Data? {
        // Interpolated only after proving it is a canonical lowercase UUID.
        guard distinctID.utf8.count == 36, UUID(uuidString: distinctID)?.uuidString.lowercased() == distinctID
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "name": "snaglist-erasure-verification",
            "query": ["kind": "HogQLQuery",
                      "query": "SELECT count() FROM events WHERE distinct_id = '\(distinctID)'"],
            "refresh": "force_blocking"], options: [.sortedKeys])
    }
    enum EventCount: Equatable { case invalid, cached, count(Int) }
    static func eventCount(_ data: Data) -> EventCount {
        guard let object = object(data) else { return .invalid }
        if let cached = object["is_cached"], !(cached is NSNull) {
            guard let flag = boolean(cached) else { return .invalid }
            if flag { return .cached }
        }
        guard let rows = object["results"] as? [[Any]], rows.count == 1, rows[0].count == 1,
              let number = rows[0][0] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(Int32.max) else { return .invalid }
        return .count(number.intValue)
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
