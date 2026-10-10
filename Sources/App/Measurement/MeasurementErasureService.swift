import Vapor
import Fluent
import FluentSQL

enum MeasurementErasureService {
    struct Counts: Codable, Sendable, Equatable {
        var completed = 0
        var retrying = 0
        var manualRequired = 0
        var pending = 0
        /// LinkedIn jobs closed as `provider_retention_bound` (LinkedInErasureResolution).
        var providerRetentionBound = 0
    }
    struct Configuration: Sendable {
        var singularURL: String?
        var singularAPIKey: String?
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }
    struct Reply: Sendable { let status: Int }
    typealias Transport = @Sendable (URI, HTTPHeaders, Data) async throws -> Reply
    struct TransportKey: StorageKey { typealias Value = Transport }
    private enum Outcome: Equatable {
        case completed, pending, retry, manual
        /// LinkedIn: sends stopped, our copies gone, provider copy ages out under the recorded basis.
        case providerRetentionBound(LinkedInErasureResolution.Bound)
        /// A local step (no provider call) could not finish; it runs again later.
        case localRetry
    }
    private struct Job { let id, token, accountID, subjectID: UUID; let destination: String }

    static func configuration(_ app: Application) -> Configuration {
        if app.environment == .testing, let value = app.storage[ConfigurationKey.self] { return value }
        return .init(singularURL: Environment.get("SINGULAR_ERASURE_URL"),
                     singularAPIKey: Environment.get("SINGULAR_API_KEY"))
    }

    static func run(app: Application, limit: Int = 25, on db: Database) async -> Counts {
        var counts = Counts()
        for _ in 0..<max(0, min(limit, 100)) {
            let job: Job
            do { guard let value = try await claim(now: Date(), on: db) else { break }; job = value }
            catch { counts.retrying += 1; break }
            let (outcome, postHogReason) = await erase(job, app: app, on: db)
            do { try await finish(job, outcome: outcome, postHogReason: postHogReason, now: Date(), on: db) }
            catch { counts.retrying += 1; continue }
            switch outcome {
            case .completed: counts.completed += 1
            case .pending: counts.pending += 1
            case .retry, .localRetry: counts.retrying += 1
            case .manual: counts.manualRequired += 1
            case .providerRetentionBound: counts.providerRetentionBound += 1
            }
        }
        return counts
    }

    private static func claim(now: Date, on db: Database) async throws -> Job? {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            // A PostHog attempt with a durable person receipt can resume by
            // polling the same UUID. Other ambiguous provider attempts still
            // require manual handling; no receipt is inferred from a lease.
            try await sql.raw("""
                UPDATE measurement_erasure_jobs j SET state='pending',lease_token=NULL,lease_expires_at=NULL,
                    available_at=\(bind:now),last_error_kind=NULL
                WHERE j.state='leased' AND j.lease_expires_at<=\(bind:now) AND j.destination='posthog'
                  AND EXISTS(SELECT 1 FROM measurement_posthog_erasure_receipts r WHERE r.job_id=j.id)
                """).run()
            // The LinkedIn step never calls LinkedIn (LinkedInErasureResolution), so an expired lease is
            // not an ambiguous provider attempt: the step simply runs again. A LinkedIn job an earlier image
            // left `manual_required` stood for the missing LinkedIn contract, never for a provider request,
            // so it re-enters the defined resolution.
            try await sql.raw("""
                UPDATE measurement_erasure_jobs SET state='pending',lease_token=NULL,lease_expires_at=NULL,
                    available_at=\(bind:now),last_error_kind=NULL
                WHERE destination='linkedin'
                  AND ((state='leased' AND lease_expires_at<=\(bind:now)) OR state='manual_required')
                """).run()
            try await sql.raw("""
                UPDATE measurement_erasure_jobs SET state='manual_required',lease_token=NULL,lease_expires_at=NULL,
                    last_error_kind='expired_lease_ambiguous'
                WHERE state='leased' AND lease_expires_at<=\(bind:now)
                """).run()
            try await sql.raw("""
                UPDATE account_deletion_jobs j SET measurement_erasure_state='manual_required'
                WHERE measurement_erasure_state='pending' AND EXISTS(
                    SELECT 1 FROM measurement_erasure_jobs e
                    WHERE e.account_deletion_job_id=j.id AND e.state='manual_required')
                """).run()
            guard let row = try await sql.raw("""
                SELECT id,account_id,subject_id,destination FROM measurement_erasure_jobs
                WHERE state IN ('pending','failing') AND available_at<=\(bind:now)
                ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 1
                """).first() else { return nil }
            let id = try row.decode(column: "id", as: UUID.self), token = UUID()
            try await sql.raw("""
                UPDATE measurement_erasure_jobs SET state='leased',attempts=attempts+1,lease_token=\(bind:token),
                    lease_expires_at=\(bind:now.addingTimeInterval(60)) WHERE id=\(bind:id)
                """).run()
            return .init(id: id, token: token,
                         accountID: try row.decode(column: "account_id", as: UUID.self),
                         subjectID: try row.decode(column: "subject_id", as: UUID.self),
                         destination: try row.decode(column: "destination", as: String.self))
        }
    }

    /// PostHog escalations carry their durable reason (POSTHOG-MANUAL-REMEDIATION.md).
    private static func erase(_ job: Job, app: Application,
                              on db: Database) async -> (Outcome, PostHogErasureService.ManualReason?) {
        if job.destination == "linkedin" {
            // No deletion contract exists at LinkedIn; the defined terminal state is not `completed`.
            do {
                guard let bound = try await LinkedInErasureResolution.settle(jobID: job.id, leaseToken: job.token,
                    accountID: job.accountID, subjectID: job.subjectID, on: db) else { return (.localRetry, nil) }
                return (.providerRetentionBound(bound), nil)
            } catch { return (.localRetry, nil) }
        }
        guard job.destination == "posthog" else { return (await eraseOther(job, app: app, on: db), nil) }
        switch await PostHogErasureService.step(jobID: job.id, leaseToken: job.token,
            accountID: job.accountID, subjectID: job.subjectID, app: app, on: db) {
        case .completed: return (.completed, nil)
        case .pending: return (.pending, nil)
        case .retry: return (.retry, nil)
        case .manual(let reason): return (.manual, reason)
        }
    }

    private static func eraseOther(_ job: Job, app: Application, on db: Database) async -> Outcome {
        // The remaining Singular deletion contract is unverified (LinkedIn has its own
        // resolution above). Production retains every manifest; the Singular test fixture
        // only exercises existing durable local state transitions.
        guard app.environment == .testing else { return .manual }
        let config = configuration(app)
        guard job.destination == "singular",
              let rawURL = config.singularURL, rawURL.hasPrefix("https://"),
              let key = config.singularAPIKey, !key.isEmpty,
              let transport = transport(app) else { return .manual }
        do {
            let sql = try VerifiedIdentityService.sql(db)
            guard let subject = try await sql.raw("SELECT opaque_subject FROM measurement_subjects WHERE id=\(bind:job.subjectID) AND account_id=\(bind:job.accountID)").first() else { return .completed }
            var body: [String: Any] = ["subject_id": try subject.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased()]
            if job.destination == "singular" {
                let rows = try await sql.raw("""
                    SELECT installation_id,consent_revision,singular_device_id_ciphertext
                    FROM measurement_device_bindings WHERE subject_id=\(bind:job.subjectID)
                    """).all()
                var devices: [String] = []
                for row in rows {
                    devices.append(try MeasurementCredentialCipher.open(
                        row.decode(column: "singular_device_id_ciphertext", as: String.self),
                        accountID: job.accountID,
                        installationID: row.decode(column: "installation_id", as: UUID.self),
                        revision: row.decode(column: "consent_revision", as: UUID.self), app: app))
                }
                guard !devices.isEmpty else { return .completed }
                body["device_ids"] = devices
            }
            var headers = HTTPHeaders(); headers.contentType = .json; headers.bearerAuthorization = .init(token: key)
            let reply = try await transport(URI(string: rawURL), headers,
                JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            switch reply.status {
            case 200..<300, 404: return .completed
            case 408, 409, 423, 425, 429, 500...599: return .retry
            default: return .manual
            }
        } catch { return .retry }
    }

    private static func transport(_ app: Application) -> Transport? {
        if app.environment == .testing { return app.storage[TransportKey.self] }
        return { uri, headers, body in
            let response = try await app.client.post(uri, headers: headers) { request in
                request.body = ByteBuffer(data: body); request.timeout = .seconds(20)
            }
            return .init(status: Int(response.status.code))
        }
    }

    private static func finish(_ job: Job, outcome: Outcome, postHogReason: PostHogErasureService.ManualReason?,
                               now: Date, on db: Database) async throws {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            let state: String, completedAt: Date?, error: String?
            var bound: LinkedInErasureResolution.Bound?
            switch outcome {
            case .completed: (state, completedAt, error) = ("completed", now, nil)
            case .pending: (state, completedAt, error) = ("pending", nil, nil)
            case .retry: (state, completedAt, error) = ("failing", nil, "provider_unavailable")
            case .localRetry: (state, completedAt, error) = ("failing", nil, "local_step_unavailable")
            case .manual: (state, completedAt, error) = ("manual_required", nil,
                                                         postHogReason?.rawValue ?? "provider_configuration_required")
            case .providerRetentionBound(let value):
                (state, completedAt, error) = (LinkedInErasureResolution.terminalState, nil, nil)
                bound = value
            }
            let basis: String? = bound == nil ? nil : LinkedInErasureResolution.version
            let boundAt: Date? = bound == nil ? nil : now
            let updated = try await sql.raw("""
                UPDATE measurement_erasure_jobs SET state=\(bind:state),completed_at=\(bind:completedAt),
                    available_at=CASE WHEN \(bind:state) IN ('pending','failing') THEN \(bind:now.addingTimeInterval(900)) ELSE available_at END,
                    lease_token=NULL,lease_expires_at=NULL,last_error_kind=\(bind:error),
                    provider_retention_basis=\(bind:basis),provider_last_send_by=\(bind:bound?.lastSendBy),
                    provider_copy_expires_at=\(bind:bound?.expiresAt),retention_bound_at=\(bind:boundAt)
                WHERE id=\(bind:job.id) AND lease_token=\(bind:job.token) AND state='leased'
                RETURNING id
                """).first() != nil
            if updated, outcome == .manual, let postHogReason {
                try await PostHogErasureService.recordManual(jobID: job.id, reason: postHogReason, at: now, on: sql)
            }
            if outcome == .completed, job.destination == "singular" {
                try await sql.raw("DELETE FROM measurement_device_bindings WHERE subject_id=\(bind:job.subjectID)").run()
            }
            try await settleAccountDeletionState(accountID: job.accountID, on: sql)
        }
    }

    /// Recomputes `account_deletion_jobs.measurement_erasure_state` for every account
    /// deletion of this account from its erasure jobs. Shared by the worker and by a
    /// recorded manual PostHog resolution (`PostHogManualResolution`). With nothing left to
    /// do but a LinkedIn copy that ages out under LinkedIn's terms, the deletion's state is
    /// `provider_retention_bound`, never `completed`.
    static func settleAccountDeletionState(accountID: UUID, on sql: SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE account_deletion_jobs j SET measurement_erasure_state=CASE
                WHEN EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.account_deletion_job_id=j.id AND e.state='manual_required') THEN 'manual_required'
                WHEN EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.account_deletion_job_id=j.id AND e.state='failing') THEN 'failing'
                WHEN EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.account_deletion_job_id=j.id
                            AND e.state NOT IN \(unsafeRaw: LinkedInErasureResolution.settledStates)) THEN 'pending'
                WHEN EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.account_deletion_job_id=j.id
                            AND e.state='provider_retention_bound') THEN 'provider_retention_bound'
                ELSE 'completed' END
            WHERE j.id IN (SELECT account_deletion_job_id FROM measurement_erasure_jobs
                           WHERE account_id=\(bind:accountID) AND account_deletion_job_id IS NOT NULL)
            """).run()
    }
}
