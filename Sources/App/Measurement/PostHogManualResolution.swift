import Vapor
import Fluent
import FluentSQL
import Crypto

/// Closes a `manual_required` PostHog erasure job after a person removed the
/// residual data through a supported PostHog mechanism
/// (POSTHOG-MANUAL-REMEDIATION.md). It never calls PostHog and never infers
/// completion: it checks a person's version 1 evidence file against the job and,
/// only with `--apply`, writes the closing record, the job's completion and the
/// account-deletion state in one transaction.
///
/// Accepted proof, gathered after the escalation:
/// - a supported PostHog deletion (`posthog_support_deletion` with PostHog's
///   support reference, or `posthog_person_deletion`): an uncached
///   (`force_blocking`, `is_cached` false) Query API count of 0 for the exact
///   opaque distinct ID, plus an empty persons lookup;
/// - `sandbox_project_deletion`: only for the synthetic sandbox project, only with
///   Dan's separate concrete approval reference, never in production; proof is
///   the project API answering 403 or 404.
enum PostHogManualResolution {
    enum Method: String, CaseIterable, Sendable {
        case supportDeletion = "posthog_support_deletion"
        case personDeletion = "posthog_person_deletion"
        case sandboxProjectDeletion = "sandbox_project_deletion"
    }

    struct Evidence: Decodable, Sendable {
        struct Verification: Decodable, Sendable {
            let queryAt: String?
            let query: String?
            let refresh: String?
            let isCached: Bool?
            let eventCount: Int?
            let personsLookupAt: String?
            let personsResultCount: Int?
            let projectLookupAt: String?
            let projectLookupStatus: Int?
        }
        let schemaVersion: Int
        let jobId: UUID
        let postHogProjectId: String
        let distinctId: String
        let method: String
        let `operator`: String
        let supportReference: String?
        let approvalReference: String?
        let verification: Verification
    }

    struct Job: Sendable {
        let id: UUID
        let accountID: UUID
        let state: String
        let destination: String
        let lastErrorKind: String?
        let opaque: String
        let createdAt: Date
        let receiptProjectID: String?
        let receiptManualAt: Date?
        let lastPassAt: Date?
    }

    struct Resolution: Sendable, Equatable {
        let jobID: UUID
        let projectID: String
        let manualReason: String
        let method: Method
        let operatorName: String
        let supportReference: String?
        let approvalReference: String?
        let verificationQueryAt: Date?
        let profileAbsentVerifiedAt: Date?
        let projectAccessLostAt: Date?
        let projectLookupStatus: Int?
        let escalatedAt: Date
        let evidenceSHA256: String
        let evidenceReference: String
    }

    struct Summary: Encodable, Sendable {
        let jobId: UUID
        let method: String
        let manualReason: String
        let escalatedAt: String
        let evidenceSha256: String
        let evidenceReference: String
        let recorded: Bool
    }

    struct Refusal: Error, CustomStringConvertible, Equatable {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let maximumEvidenceBytes = 65_536
    /// Lower-cased substrings that mean a file carries a credential or an HTTP
    /// header. Evidence is kept and hashed; it must never hold a key.
    static let forbiddenMarkers = ["phx_", "phc_", "bearer ", "authorization", "api_key", "apikey",
                                   "personalapikey", "publicwritetoken", "password"]
    /// Reasons a resolution may close: the worker's reasons plus the claim sweep's.
    static let closableReasons = Set(PostHogErasureService.ManualReason.allCases.map(\.rawValue)
        + ["expired_lease_ambiguous"])

    static func load(jobID: UUID, on db: Database) async throws -> Job? {
        let sql = try VerifiedIdentityService.sql(db)
        guard let row = try await sql.raw("""
            SELECT j.id,j.account_id,j.state,j.destination,j.last_error_kind,j.created_at,s.opaque_subject,
                   r.posthog_project_id,r.manual_at,
                   (SELECT MAX(p.checked_at) FROM measurement_posthog_erasure_passes p WHERE p.job_id=j.id) AS last_pass_at
            FROM measurement_erasure_jobs j
            JOIN measurement_subjects s ON s.id=j.subject_id AND s.account_id=j.account_id
            LEFT JOIN measurement_posthog_erasure_receipts r ON r.job_id=j.id
            WHERE j.id=\(bind:jobID)
            """).first() else { return nil }
        return Job(id: try row.decode(column: "id", as: UUID.self),
                   accountID: try row.decode(column: "account_id", as: UUID.self),
                   state: try row.decode(column: "state", as: String.self),
                   destination: try row.decode(column: "destination", as: String.self),
                   lastErrorKind: try row.decode(column: "last_error_kind", as: String?.self),
                   opaque: try row.decode(column: "opaque_subject", as: UUID.self).uuidString.lowercased(),
                   createdAt: try row.decode(column: "created_at", as: Date.self),
                   receiptProjectID: try row.decode(column: "posthog_project_id", as: String?.self),
                   receiptManualAt: try row.decode(column: "manual_at", as: Date?.self),
                   lastPassAt: try row.decode(column: "last_pass_at", as: Date?.self))
    }

    static func validate(_ data: Data, evidenceReference: String, job: Job, configuredProjectID: String?,
                         platformEnvironment: String?, now: Date) throws -> Resolution {
        guard data.count <= maximumEvidenceBytes else { throw Refusal("the evidence file is larger than 64 KiB") }
        let lowered = String(decoding: data, as: UTF8.self).lowercased()
        if let marker = forbiddenMarkers.first(where: { lowered.contains($0) }) {
            throw Refusal("the evidence must not contain credentials or HTTP headers (forbidden marker \"\(marker)\")")
        }
        guard matches(evidenceReference, "^[A-Za-z0-9._/-]{1,200}$") else {
            throw Refusal("the evidence file name may contain only letters, digits, '.', '_', '-' and '/'")
        }
        let evidence: Evidence
        do { evidence = try JSONDecoder().decode(Evidence.self, from: data) }
        catch { throw Refusal("the evidence is not the version 1 JSON shape") }
        guard evidence.schemaVersion == 1 else { throw Refusal("unsupported evidence schemaVersion") }
        guard job.destination == "posthog" else { throw Refusal("the job is not a PostHog erasure job") }
        guard job.state == "manual_required" else { throw Refusal("the job is \(job.state), not manual_required") }
        guard let reason = job.lastErrorKind, closableReasons.contains(reason) else {
            throw Refusal("the job carries no recognised manual reason")
        }
        guard evidence.jobId == job.id else { throw Refusal("the evidence names another job") }
        guard evidence.distinctId == job.opaque else { throw Refusal("the evidence names another distinct ID") }
        guard let expectedProject = job.receiptProjectID ?? configuredProjectID else {
            throw Refusal("the job's PostHog project is unknown: no receipt and no configured erasure project")
        }
        guard evidence.postHogProjectId == expectedProject else { throw Refusal("the evidence names another PostHog project") }
        guard let method = Method(rawValue: evidence.method) else { throw Refusal("unknown method") }
        guard matches(evidence.operator, "^[a-z][a-z0-9._-]{1,63}$") else {
            throw Refusal("operator must be a lower-case handle (not an email address)")
        }
        let referencePattern = "^[A-Za-z0-9][A-Za-z0-9 #._:/-]{0,119}$"
        if let reference = evidence.supportReference, !matches(reference, referencePattern) {
            throw Refusal("supportReference has unsupported characters or length")
        }
        if let reference = evidence.approvalReference, !matches(reference, "^[A-Za-z0-9][A-Za-z0-9 #._:/-]{0,159}$") {
            throw Refusal("approvalReference has unsupported characters or length")
        }
        // Proof must post-date the escalation it closes and cannot be in the future.
        let escalatedAt = job.receiptManualAt ?? job.lastPassAt ?? job.createdAt
        func checkedTime(_ text: String?, _ name: String) throws -> Date {
            guard let text, let value = date(text) else { throw Refusal("\(name) is missing or not ISO 8601") }
            guard value > escalatedAt else { throw Refusal("\(name) is not after the escalation it closes") }
            guard value <= now else { throw Refusal("\(name) is in the future") }
            return value
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let v = evidence.verification
        switch method {
        case .sandboxProjectDeletion:
            guard platformEnvironment != "production" else {
                throw Refusal("a project deletion is never a production remediation")
            }
            guard evidence.approvalReference != nil else {
                throw Refusal("a sandbox project deletion needs Dan's separate concrete approval reference")
            }
            guard let status = v.projectLookupStatus, [403, 404].contains(status) else {
                throw Refusal("projectLookupStatus must show lost access (403 or 404)")
            }
            let lost = try checkedTime(v.projectLookupAt, "projectLookupAt")
            return Resolution(jobID: job.id, projectID: expectedProject, manualReason: reason, method: method,
                              operatorName: evidence.operator, supportReference: evidence.supportReference,
                              approvalReference: evidence.approvalReference, verificationQueryAt: nil,
                              profileAbsentVerifiedAt: nil, projectAccessLostAt: lost, projectLookupStatus: status,
                              escalatedAt: escalatedAt, evidenceSHA256: digest, evidenceReference: evidenceReference)
        case .supportDeletion, .personDeletion:
            if method == .supportDeletion, evidence.supportReference == nil {
                throw Refusal("a PostHog support deletion needs PostHog's support reference")
            }
            guard v.query == "SELECT count() FROM events WHERE distinct_id = '\(job.opaque)'" else {
                throw Refusal("verification.query must be the worker's exact event count for this distinct ID")
            }
            guard v.refresh == "force_blocking", v.isCached == false else {
                throw Refusal("the event count must be uncached (refresh force_blocking, isCached false)")
            }
            guard v.eventCount == 0 else { throw Refusal("the event count is not 0; the job stays manual_required") }
            guard v.personsResultCount == 0 else { throw Refusal("a profile is still present; the job stays manual_required") }
            let queried = try checkedTime(v.queryAt, "queryAt")
            let looked = try checkedTime(v.personsLookupAt, "personsLookupAt")
            return Resolution(jobID: job.id, projectID: expectedProject, manualReason: reason, method: method,
                              operatorName: evidence.operator, supportReference: evidence.supportReference,
                              approvalReference: evidence.approvalReference, verificationQueryAt: queried,
                              profileAbsentVerifiedAt: looked, projectAccessLostAt: nil, projectLookupStatus: nil,
                              escalatedAt: escalatedAt, evidenceSHA256: digest, evidenceReference: evidenceReference)
        }
    }

    static func record(_ resolution: Resolution, now: Date, on db: Database) async throws {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let row = try await sql.raw("""
                SELECT account_id,state,last_error_kind FROM measurement_erasure_jobs
                WHERE id=\(bind:resolution.jobID) AND destination='posthog' FOR UPDATE
                """).first(),
                  try row.decode(column: "state", as: String.self) == "manual_required",
                  try row.decode(column: "last_error_kind", as: String?.self) == resolution.manualReason else {
                throw Refusal("the job is no longer manual_required with the same reason")
            }
            let accountID = try row.decode(column: "account_id", as: UUID.self)
            let verifiedCount: Int? = resolution.verificationQueryAt == nil ? nil : 0
            try await sql.raw("""
                INSERT INTO measurement_posthog_manual_resolutions(job_id,posthog_project_id,manual_reason,method,operator,
                    support_reference,approval_reference,verification_query_at,verified_event_count,profile_absent_verified_at,
                    project_access_lost_at,project_lookup_status,escalated_at,evidence_sha256,evidence_reference,recorded_at)
                VALUES (\(bind:resolution.jobID),\(bind:resolution.projectID),\(bind:resolution.manualReason),
                    \(bind:resolution.method.rawValue),\(bind:resolution.operatorName),\(bind:resolution.supportReference),
                    \(bind:resolution.approvalReference),\(bind:resolution.verificationQueryAt),
                    \(bind:verifiedCount),\(bind:resolution.profileAbsentVerifiedAt),
                    \(bind:resolution.projectAccessLostAt),\(bind:resolution.projectLookupStatus),\(bind:resolution.escalatedAt),
                    \(bind:resolution.evidenceSHA256),\(bind:resolution.evidenceReference),\(bind:now))
                """).run()
            guard try await sql.raw("""
                UPDATE measurement_erasure_jobs SET state='completed',completed_at=\(bind:now),last_error_kind=NULL
                WHERE id=\(bind:resolution.jobID) AND state='manual_required' RETURNING id
                """).first() != nil else { throw Refusal("the job changed while recording") }
            try await MeasurementErasureService.settleAccountDeletionState(accountID: accountID, on: sql)
        }
    }

    /// The command's whole behaviour, callable from tests.
    static func execute(app: Application, jobID: UUID, evidencePath: String, apply: Bool,
                        now: Date = Date()) async throws -> Summary {
        let url = URL(fileURLWithPath: evidencePath)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size, size <= maximumEvidenceBytes else {
            throw Refusal("the evidence file is missing or larger than 64 KiB")
        }
        let data = try Data(contentsOf: url)
        guard let job = try await load(jobID: jobID, on: app.db) else { throw Refusal("no such erasure job") }
        let resolution = try validate(data, evidenceReference: url.lastPathComponent, job: job,
                                      configuredProjectID: PostHogErasureService.configuration(app)?.projectID,
                                      platformEnvironment: Environment.get("PLATFORM_ENVIRONMENT"), now: now)
        if apply { try await record(resolution, now: now, on: app.db) }
        return Summary(jobId: job.id, method: resolution.method.rawValue, manualReason: resolution.manualReason,
                       escalatedAt: ISO8601DateFormatter().string(from: resolution.escalatedAt),
                       evidenceSha256: resolution.evidenceSHA256, evidenceReference: resolution.evidenceReference,
                       recorded: apply)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// `App posthog-erasure-resolve --job <uuid> --evidence <file.json> [--apply]`
struct PostHogErasureResolveCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "job", help: "The manual_required PostHog erasure job ID")
        var job: String?
        @Option(name: "evidence", help: "Version 1 evidence JSON (POSTHOG-MANUAL-REMEDIATION.md)")
        var evidence: String?
        @Flag(name: "apply", help: "Record the resolution; without it the evidence is only checked")
        var apply: Bool
        init() {}
    }

    var help: String { "Record a manual PostHog erasure resolution with evidence (never calls PostHog)" }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let text = signature.job, let jobID = UUID(uuidString: text), let path = signature.evidence else {
            context.console.error("Usage: posthog-erasure-resolve --job <uuid> --evidence <file.json> [--apply]")
            throw PostHogManualResolution.Refusal("missing --job or --evidence")
        }
        do {
            let summary = try await PostHogManualResolution.execute(app: context.application, jobID: jobID,
                                                                    evidencePath: path, apply: signature.apply)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            context.console.print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            if !signature.apply { context.console.print("Checked only. Nothing was recorded; pass --apply to record.") }
        } catch let refusal as PostHogManualResolution.Refusal {
            context.console.error("Refused: \(refusal.description)")
            throw refusal
        }
    }
}
