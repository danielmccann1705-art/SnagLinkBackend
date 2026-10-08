import Vapor
import Fluent
import FluentSQL
import AsyncHTTPClient

/// One redirect-refusing client for measurement provider POSTs. Provider bodies
/// carry write credentials, so a 3xx response must be returned as-is rather than
/// replaying the request to a Location chosen by the receiver.
final class MeasurementDirectHTTPClient: LifecycleHandler, @unchecked Sendable {
    private let client: HTTPClient
    private let logger: Logger

    init(eventLoopGroup: EventLoopGroup, logger: Logger) {
        client = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(redirectConfiguration: .disallow),
            backgroundActivityLogger: logger)
        self.logger = logger
    }

    func post(_ uri: URI, headers: HTTPHeaders, body: Data) async throws -> MeasurementDispatchService.Reply {
        var request = HTTPClientRequest(url: uri.string)
        request.method = .POST
        request.headers = headers
        request.body = .bytes(ByteBuffer(data: body))
        let response = try await client.execute(request, timeout: .seconds(20), logger: logger)
        _ = try await response.body.collect(upTo: 65_536)
        return .init(status: Int(response.status.code), retryAfter: response.headers.first(name: .retryAfter))
    }

    func close() async throws { try await client.shutdown() }
    func shutdown(_ application: Application) { try? client.syncShutdown() }
    func shutdownAsync(_ application: Application) async { try? await client.shutdown() }
}

enum MeasurementDispatchService {
    struct Counts: Codable, Sendable, Equatable {
        var delivered = 0
        var suppressed = 0
        var retrying = 0
        var uncertain = 0
        var manualRequired = 0
    }
    struct Configuration: Sendable {
        var postHogProjectKey: String?
        var postHogEnvironment: LinkedInConversion.Environment?
        var singularURL: String?
        var singularAPIKey: String?
        var linkedInAccessToken: String?
        var linkedInSignupRule: String?
        var linkedInSubscriptionRule: String?
        var linkedInEnvironment: LinkedInConversion.Environment?
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }
    struct Reply: Sendable { let status: Int; let retryAfter: String? }
    typealias Transport = @Sendable (URI, HTTPHeaders, Data) async throws -> Reply
    struct TransportKey: StorageKey { typealias Value = Transport }
    private struct DirectHTTPKey: StorageKey { typealias Value = MeasurementDirectHTTPClient }
    private struct DirectHTTPLock: LockKey {}

    private enum Outcome { case delivered, suppressed, retry, uncertain, manual }
    private struct Lease {
        let id: UUID, token: UUID
    }

    static func configuration(_ app: Application) -> Configuration {
        if app.environment == .testing, let value = app.storage[ConfigurationKey.self] { return value }
        return .init(postHogProjectKey: Environment.get("POSTHOG_PROJECT_API_KEY"),
                     postHogEnvironment: LinkedInConversion.Environment(rawValue: Environment.get("POSTHOG_MEASUREMENT_ENVIRONMENT") ?? ""),
                     singularURL: Environment.get("SINGULAR_SERVER_EVENT_URL"),
                     singularAPIKey: Environment.get("SINGULAR_API_KEY"),
                     linkedInAccessToken: Environment.get("LINKEDIN_CONVERSIONS_ACCESS_TOKEN"),
                     linkedInSignupRule: Environment.get("LINKEDIN_SIGNUP_CONVERSION_RULE_ID"),
                     linkedInSubscriptionRule: Environment.get("LINKEDIN_SUBSCRIPTION_CONVERSION_RULE_ID"),
                     linkedInEnvironment: Environment.get("PLATFORM_ENVIRONMENT") == "production" ? .production : .sandbox)
    }

    static func run(app: Application, limit: Int = 50, on db: Database) async -> Counts {
        var counts = Counts()
        for _ in 0..<max(0, min(limit, 200)) {
            let lease: Lease
            do {
                guard let next = try await claim(now: Date(), on: db) else { break }
                lease = next
            } catch { counts.retrying += 1; break }
            let outcome: Outcome
            do { outcome = try await perform(lease, app: app, on: db) }
            catch { outcome = .uncertain }
            do { try await finish(lease, outcome: outcome, now: Date(), on: db) }
            catch { counts.uncertain += 1; continue }
            switch outcome {
            case .delivered: counts.delivered += 1
            case .suppressed: counts.suppressed += 1
            case .retry: counts.retrying += 1
            case .uncertain: counts.uncertain += 1
            case .manual: counts.manualRequired += 1
            }
        }
        return counts
    }

    private static func claim(now: Date, on db: Database) async throws -> Lease? {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET state='uncertain',payload=NULL,lease_token=NULL,lease_expires_at=NULL,
                    last_error_kind='expired_lease_ambiguous'
                WHERE state='leased' AND lease_expires_at<=\(bind:now)
                """).run()
            guard let row = try await sql.raw("""
                SELECT id FROM measurement_dispatch_jobs
                WHERE state IN ('pending','failing') AND available_at<=\(bind:now)
                ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 1
                """).first() else { return nil }
            let id = try row.decode(column: "id", as: UUID.self), token = UUID()
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET state='leased',attempts=attempts+1,lease_token=\(bind:token),
                    lease_expires_at=\(bind:now.addingTimeInterval(60)) WHERE id=\(bind:id)
                """).run()
            return .init(id: id, token: token)
        }
    }

    /// The job row and purpose advisory lock remain held through the single
    /// provider attempt. Withdrawal/deletion take the same purpose lock, so they
    /// either win first and suppress this job, or wait until the attempt has a
    /// durable outcome. Ordinary writes to the user's row remain independent.
    private static func perform(_ lease: Lease, app: Application, on db: Database) async throws -> Outcome {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            // Route first without a row lock so we can take the account/purpose
            // advisory before the leased job row. Permission mutation and account
            // deletion use the same advisory key and order.
            guard let route = try await sql.raw("""
                SELECT destination,account_id FROM measurement_dispatch_jobs
                WHERE id=\(bind:lease.id) AND lease_token=\(bind:lease.token) AND state='leased'
                """).first() else { return .suppressed }
            let destination = try route.decode(column: "destination", as: String.self)
            let purpose: MeasurementPurpose = destination == "posthog" ? .productAnalytics : .crossCompanyAds
            let accountID = try route.decode(column: "account_id", as: UUID.self)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):\(purpose.rawValue)", on: tx)

            let gateNow = Date()
            guard let row = try await sql.raw("""
                SELECT j.destination,j.source_kind,j.source_id,j.account_id,j.subject_id,j.consent_revision,j.installation_id,
                       j.payload::text AS payload_text,s.opaque_subject,u.lifecycle_state
                FROM measurement_dispatch_jobs j JOIN measurement_subjects s ON s.id=j.subject_id
                JOIN users u ON u.id=j.account_id
                WHERE j.id=\(bind:lease.id) AND j.lease_token=\(bind:lease.token) AND j.state='leased'
                  AND j.destination=\(bind:destination) AND j.account_id=\(bind:accountID)
                  AND j.lease_expires_at>\(bind:gateNow) FOR UPDATE OF j
                """).first() else { return .suppressed }
            guard try row.decode(column: "lifecycle_state", as: String.self) == "active" else { return .suppressed }
            let subjectID = try row.decode(column: "subject_id", as: UUID.self)
            let revision = try row.decode(column: "consent_revision", as: UUID.self)
            guard try await sql.raw("""
                SELECT 1 FROM measurement_permission_current c JOIN measurement_subjects s ON s.id=c.subject_id
                WHERE c.account_id=\(bind:accountID) AND c.purpose=\(bind:purpose.rawValue) AND c.decision='granted'
                  AND c.revision=\(bind:revision) AND c.subject_id=\(bind:subjectID) AND s.state='active'
                  AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.state<>'completed')
                """).first() != nil else { return .suppressed }
            let flags = try await FeatureFlagService.resolve(on: tx)
            guard (destination == "posthog" && flags["productAnalyticsEnabled"] == true) ||
                  (destination == "singular" && flags["crossCompanyAdsEnabled"] == true) ||
                  (destination == "linkedin" && flags["crossCompanyAdsEnabled"] == true && flags["linkedInConversionsEnabled"] == true)
            else { return .suppressed }
            let installationID = try row.decode(column: "installation_id", as: UUID?.self)
            if purpose == .crossCompanyAds {
                guard let installationID else { return .suppressed }
                guard try await sql.raw("""
                    SELECT 1 FROM measurement_att_assertions WHERE account_id=\(bind:accountID)
                      AND consent_revision=\(bind:revision) AND status='authorized' AND expires_at>\(bind:gateNow)
                      AND installation_id=\(bind:installationID) LIMIT 1
                    """).first() != nil else { return .suppressed }
            }
            let sourceKind = try row.decode(column: "source_kind", as: String.self)
            let sourceID = try row.decode(column: "source_id", as: UUID.self)
            guard let payloadText = try row.decode(column: "payload_text", as: String?.self),
                  let payloadData = payloadText.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: String] else { return .suppressed }
            if destination == "linkedin" && sourceKind == "revenueCatLifecycle" {
                guard let installationID, let verifiedEmailHash = payload["emailSha256"],
                      let continuityText = payload["attContinuityId"],
                      let attContinuityID = UUID(uuidString: continuityText),
                      try await RevenueCatMeasurementService.linkedInPurchaseIsEligible(
                        chargeID: sourceID, accountID: accountID, subjectID: subjectID,
                        revision: revision, installationID: installationID,
                        verifiedEmailHash: verifiedEmailHash,
                        attContinuityID: attContinuityID, now: gateNow, on: sql)
                else { return .suppressed }
            }
            let opaque = try row.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased()
            return await send(destination: destination, sourceKind: sourceKind, sourceID: sourceID,
                              accountID: accountID, subjectID: subjectID, revision: revision,
                              installationID: installationID, opaqueSubject: opaque, payload: payload,
                              app: app, now: gateNow, on: sql)
        }
    }

    private static func send(destination: String, sourceKind: String, sourceID: UUID, accountID: UUID,
                             subjectID: UUID, revision: UUID, installationID: UUID?, opaqueSubject: String,
                             payload: [String: String], app: Application, now: Date, on sql: SQLDatabase) async -> Outcome {
        let config = configuration(app)
        guard let transport = transport(app) else { return .manual }
        do {
            switch destination {
            case "posthog":
                guard let key = config.postHogProjectKey, validSecret(key), let configuredEnvironment = config.postHogEnvironment else { return .manual }
                if sourceKind == "revenueCatLifecycle" {
                    guard let row = try await sql.raw("SELECT environment FROM measurement_revenuecat_events WHERE id=\(bind:sourceID) AND account_id=\(bind:accountID)").first(),
                          try row.decode(column: "environment", as: String.self) == configuredEnvironment.rawValue else { return .suppressed }
                } else if sourceKind == "revenueCatEvent" {
                    guard let row = try await sql.raw("SELECT environment FROM measurement_revenuecat_lifecycle_events WHERE id=\(bind:sourceID) AND account_id=\(bind:accountID)").first(),
                          try row.decode(column: "environment", as: String.self) == configuredEnvironment.rawValue else { return .suppressed }
                }
                var properties = payload.reduce(into: [String: Any]()) { values, entry in
                    values[entry.key] = entry.value
                }
                properties["distinct_id"] = opaqueSubject
                properties["source_event_id"] = sourceID.uuidString.lowercased()
                // Create the minimal person profile needed for provider-side erasure.
                // The profile key remains the purpose-scoped opaque subject and no
                // customer properties are attached.
                properties["$process_person_profile"] = true
                // This relay sees the backend's IP, not the customer's. Prevent
                // PostHog from turning server location into user event location.
                properties["$geoip_disable"] = true
                let body = try JSONSerialization.data(withJSONObject: ["api_key": key,
                    "event": payload["event"] ?? "subscription_payment", "uuid": stableUUID(opaqueSubject, sourceKind, sourceID),
                    "timestamp": payload["occurredAt"] ?? ISO8601DateFormatter().string(from: now),
                    "properties": properties], options: [.sortedKeys])
                let reply = try await transport(URI(string: "https://eu.i.posthog.com/capture/"), jsonHeaders(), body)
                return classify(reply)
            case "singular":
                // The live Singular V2 contract and originating-installation authority
                // remain an activation decision. Only a synthetic injected test adapter
                // may exercise this placeholder; production fails closed.
                guard app.environment == .testing,
                      let rawURL = config.singularURL, let key = config.singularAPIKey,
                      rawURL.hasPrefix("https://"), validSecret(key), let installationID,
                      let binding = try await sql.raw("""
                        SELECT singular_device_id_ciphertext FROM measurement_device_bindings
                        WHERE account_id=\(bind:accountID) AND subject_id=\(bind:subjectID)
                          AND installation_id=\(bind:installationID) AND consent_revision=\(bind:revision)
                          AND revoked_at IS NULL LIMIT 1
                        """).first() else { return .manual }
                let encrypted = try binding.decode(column: "singular_device_id_ciphertext", as: String.self)
                let sdid = try MeasurementCredentialCipher.open(encrypted, accountID: accountID,
                    installationID: installationID, revision: revision, app: app)
                var object: [String: String] = payload
                object["event_id"] = sourceID.uuidString.lowercased(); object["sdid"] = sdid
                let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                var headers = jsonHeaders(); headers.bearerAuthorization = .init(token: key)
                return classify(try await transport(URI(string: rawURL), headers, body))
            case "linkedin":
                guard sourceKind == "revenueCatLifecycle", let token = config.linkedInAccessToken,
                      let signup = config.linkedInSignupRule, let subscription = config.linkedInSubscriptionRule,
                      let environment = config.linkedInEnvironment, validSecret(token),
                      let source = try await sql.raw("""
                        SELECT durable_key_hash,occurred_at,purchased_at,environment,currency_code,amount
                        FROM measurement_revenuecat_events WHERE id=\(bind:sourceID) AND account_id=\(bind:accountID)
                        """).first(),
                      let emailHash = payload["emailSha256"] else { return .manual }
                guard let factEnvironment = LinkedInConversion.Environment(rawValue: try source.decode(column: "environment", as: String.self)) else { return .suppressed }
                let fact = LinkedInConversion.Fact.subscriptionPayment(accountID: accountID,
                    occurredAt: try source.decode(column: "occurred_at", as: Date.self),
                    purchasedAt: try source.decode(column: "purchased_at", as: Date.self), environment: factEnvironment,
                    durableKeyHash: try source.decode(column: "durable_key_hash", as: String.self),
                    currency: try source.decode(column: "currency_code", as: String.self),
                    amount: try source.decode(column: "amount", as: String.self))
                let permission = LinkedInConversion.Permission(accountID: accountID, revision: revision, allowed: true,
                    attAuthorised: true, grantedAt: Date.distantPast, checkedAt: now,
                    expiresAt: now.addingTimeInterval(MeasurementPrivacyService.attLifetime))
                let configuration = LinkedInConversion.Configuration(enabled: true, environment: environment,
                    signupRule: signup, subscriptionRule: subscription, accessToken: token, fetchedAt: now)
                guard let prepared = LinkedInConversion.prepare(fact, verifiedEmailHash: emailHash, permission: permission,
                                                                configuration: configuration, now: now) else { return .suppressed }
                let delivery = await LinkedInConversion.send(prepared, configuration: configuration, now: now,
                    permission: { permission }, transport: { uri, headers, body in
                        let result = try await transport(uri, headers, body)
                        return .init(status: result.status, retryAfter: result.retryAfter)
                    })
                switch delivery {
                case .received: return .delivered
                case .suppressed: return .suppressed
                case .rateLimited: return .retry
                case .configurationRequired, .rejected: return .manual
                case .uncertain: return .uncertain
                }
            default: return .manual
            }
        } catch { return .uncertain }
    }

    private static func transport(_ app: Application) -> Transport? {
        if app.environment == .testing { return app.storage[TransportKey.self] }
        let direct = app.locks.lock(for: DirectHTTPLock.self).withLock {
            if let existing = app.storage[DirectHTTPKey.self] { return existing }
            let created = MeasurementDirectHTTPClient(eventLoopGroup: app.eventLoopGroup, logger: app.logger)
            app.storage[DirectHTTPKey.self] = created
            app.lifecycle.use(created)
            return created
        }
        return { uri, headers, body in try await direct.post(uri, headers: headers, body: body) }
    }

    private static func classify(_ reply: Reply) -> Outcome {
        switch reply.status {
        case 200..<300: return .delivered
        case 429: return .retry
        case 400..<500: return .manual
        default: return .uncertain
        }
    }

    private static func finish(_ lease: Lease, outcome: Outcome, now: Date, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        let state: String, deliveredAt: Date?, payloadCleared: Bool, error: String?
        switch outcome {
        case .delivered: (state, deliveredAt, payloadCleared, error) = ("delivered", now, true, nil)
        case .suppressed: (state, deliveredAt, payloadCleared, error) = ("suppressed", nil, true, nil)
        case .retry: (state, deliveredAt, payloadCleared, error) = ("failing", nil, false, "rate_limited")
        case .uncertain: (state, deliveredAt, payloadCleared, error) = ("uncertain", nil, true, "ambiguous_delivery")
        case .manual: (state, deliveredAt, payloadCleared, error) = ("manual_required", nil, true, "configuration_or_request")
        }
        try await sql.raw("""
            UPDATE measurement_dispatch_jobs SET state=\(bind:state),delivered_at=\(bind:deliveredAt),
                payload=CASE WHEN \(bind:payloadCleared) THEN NULL ELSE payload END,
                available_at=CASE WHEN \(bind:state)='failing' THEN \(bind:now.addingTimeInterval(300)) ELSE available_at END,
                lease_token=NULL,lease_expires_at=NULL,last_error_kind=\(bind:error)
            WHERE id=\(bind:lease.id) AND lease_token=\(bind:lease.token) AND state='leased'
            """).run()
    }

    private static func jsonHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders(); headers.contentType = .json; return headers
    }
    private static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func stableUUID(_ subject: String, _ sourceKind: String, _ sourceID: UUID) -> String {
        let hex = SHA256Hasher.hash(token: "posthog:v1:\(subject):\(sourceKind):\(sourceID.uuidString.lowercased())")
        let end = hex.index(hex.startIndex, offsetBy: 32)
        let value = String(hex[..<end])
        return "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20).prefix(12))"
    }
}
