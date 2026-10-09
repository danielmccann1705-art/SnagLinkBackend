@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// `posthog-erasure-resolve` evidence checks (POSTHOG-MANUAL-REMEDIATION.md). Pure:
/// no database, no provider.
final class PostHogManualResolutionValidationTests: XCTestCase {
    private let now = Date()
    private let opaque = UUID().uuidString.lowercased()
    private lazy var job = PostHogManualResolution.Job(
        id: UUID(), accountID: UUID(), state: "manual_required", destination: "posthog",
        lastErrorKind: "posthog_stale_receipt", opaque: opaque, createdAt: now.addingTimeInterval(-3 * 86_400),
        receiptProjectID: "298161", receiptManualAt: now.addingTimeInterval(-86_400), lastPassAt: now.addingTimeInterval(-86_400))

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func evidence(_ changes: [String: Any] = [:], verification: [String: Any] = [:]) throws -> Data {
        var check: [String: Any] = ["queryAt": iso(now.addingTimeInterval(-600)),
                                    "query": "SELECT count() FROM events WHERE distinct_id = '\(opaque)'",
                                    "refresh": "force_blocking", "isCached": false, "eventCount": 0,
                                    "personsLookupAt": iso(now.addingTimeInterval(-590)), "personsResultCount": 0]
        check.merge(verification) { _, new in new }
        var object: [String: Any] = ["schemaVersion": 1, "jobId": job.id.uuidString, "postHogProjectId": "298161",
                                     "distinctId": opaque, "method": "posthog_support_deletion", "operator": "codex",
                                     "supportReference": "PostHog ticket 12345", "verification": check]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validate(_ data: Data, job: PostHogManualResolution.Job? = nil, environment: String? = "staging",
                          reference: String = "posthog-remediation-evidence.json") throws -> PostHogManualResolution.Resolution {
        try PostHogManualResolution.validate(data, evidenceReference: reference, job: job ?? self.job,
                                             configuredProjectID: nil, platformEnvironment: environment, now: now)
    }

    private func assertRefused(_ data: Data, job: PostHogManualResolution.Job? = nil, environment: String? = "staging",
                               reference: String = "posthog-remediation-evidence.json", _ fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try validate(data, job: job, environment: environment, reference: reference)
            XCTFail("accepted; expected refusal containing \(fragment)", file: file, line: line)
        } catch let refusal as PostHogManualResolution.Refusal {
            XCTAssertTrue(refusal.description.contains(fragment), refusal.description, file: file, line: line)
        } catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    func testSupportedDeletionWithFreshZeroCountAndAbsentProfileIsAccepted() throws {
        let data = try evidence()
        let resolution = try validate(data)
        XCTAssertEqual(resolution.method, .supportDeletion)
        XCTAssertEqual(resolution.manualReason, "posthog_stale_receipt")
        XCTAssertEqual(resolution.projectID, "298161")
        XCTAssertEqual(resolution.evidenceSHA256.count, 64)
        XCTAssertNotNil(resolution.verificationQueryAt)
        let person = try validate(try evidence(["method": "posthog_person_deletion", "supportReference": NSNull()]))
        XCTAssertEqual(person.method, .personDeletion)
    }

    func testResidualDataOrWeakProofKeepsTheJobManual() throws {
        assertRefused(try evidence(verification: ["eventCount": 1]), "not 0")
        assertRefused(try evidence(verification: ["personsResultCount": 1]), "profile is still present")
        assertRefused(try evidence(verification: ["isCached": true]), "uncached")
        assertRefused(try evidence(verification: ["refresh": "blocking"]), "uncached")
        assertRefused(try evidence(verification: ["query": "SELECT count() FROM events"]), "exact event count")
        assertRefused(try evidence(verification: ["queryAt": iso(now.addingTimeInterval(-2 * 86_400))]), "not after the escalation")
        assertRefused(try evidence(verification: ["personsLookupAt": iso(now.addingTimeInterval(600))]), "in the future")
        assertRefused(try evidence(verification: ["queryAt": "yesterday"]), "ISO 8601")
    }

    func testEvidenceMustMatchTheJobAndCarryNoCredential() throws {
        assertRefused(try evidence(["jobId": UUID().uuidString]), "another job")
        assertRefused(try evidence(["distinctId": UUID().uuidString.lowercased()]), "another distinct ID")
        assertRefused(try evidence(["postHogProjectId": "123456"]), "another PostHog project")
        assertRefused(try evidence(["method": "delete_everything"]), "unknown method")
        assertRefused(try evidence(["operator": "someone@example.test"]), "lower-case handle")
        assertRefused(try evidence(["supportReference": NSNull()]), "support reference")
        assertRefused(try evidence(["note": "Authorization: Bearer phx_synthetic"]), "credentials")
        assertRefused(try evidence(["note": "phc_synthetic_project_token"]), "credentials")
        assertRefused(try evidence(), reference: "../evidence file.json", "file name")
        assertRefused(Data("{}".utf8), "version 1")
        var completed = job
        completed = .init(id: job.id, accountID: job.accountID, state: "completed", destination: "posthog",
                          lastErrorKind: nil, opaque: opaque, createdAt: job.createdAt, receiptProjectID: "298161",
                          receiptManualAt: job.receiptManualAt, lastPassAt: job.lastPassAt)
        assertRefused(try evidence(), job: completed, "not manual_required")
        let singular = PostHogManualResolution.Job(id: job.id, accountID: job.accountID, state: "manual_required",
            destination: "singular", lastErrorKind: "provider_configuration_required", opaque: opaque,
            createdAt: job.createdAt, receiptProjectID: nil, receiptManualAt: nil, lastPassAt: nil)
        assertRefused(try evidence(), job: singular, "not a PostHog erasure job")
    }

    func testSandboxProjectDeletionNeedsSeparateApprovalAndIsNeverProduction() throws {
        let lost: [String: Any] = ["projectLookupAt": iso(now.addingTimeInterval(-60)), "projectLookupStatus": 404]
        let approved = try evidence(["method": "sandbox_project_deletion", "supportReference": NSNull(),
                                     "approvalReference": "DAN-APPROVAL-2026-10-12 sandbox 298161"], verification: lost)
        let resolution = try validate(approved)
        XCTAssertEqual(resolution.method, .sandboxProjectDeletion)
        XCTAssertEqual(resolution.projectLookupStatus, 404)
        XCTAssertNil(resolution.verificationQueryAt)
        assertRefused(approved, environment: "production", "never a production remediation")
        assertRefused(try evidence(["method": "sandbox_project_deletion", "supportReference": NSNull()], verification: lost),
                      "separate concrete approval")
        assertRefused(try evidence(["method": "sandbox_project_deletion", "approvalReference": "DAN-APPROVAL-1"],
                                   verification: ["projectLookupAt": iso(now), "projectLookupStatus": 200]), "lost access")
    }
}

/// The closing record against PostgreSQL. No provider is involved.
final class PostHogManualResolutionTests: XCTestCase {
    private var app: Application!
    private var account = UUID(), subject = UUID(), opaque = UUID(), job = UUID(), deletion = UUID()
    private var files: [URL] = []
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        account = UUID(); subject = UUID(); opaque = UUID(); job = UUID(); deletion = UUID()
        let user = User(appleUserId: nil, email: "resolution-\(account)@example.test", name: nil, authProvider: .magicLink)
        user.id = account
        try await user.save(on: app.db)
        try await sql.raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state,measurement_erasure_state)
            VALUES(\(bind:deletion),\(bind:account),\(bind:SHA256Hasher.hash(token: "resolution-\(deletion)")),NOW(),'ready',NOW(),
                   'pending','completed','not_applicable','manual_required')
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_subjects(id,account_id,purpose,opaque_subject,state,created_at,revoked_at)
            VALUES (\(bind:subject),\(bind:account),'productAnalytics',\(bind:opaque),'revoked',NOW()-INTERVAL '3 days',NOW()-INTERVAL '3 days')
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_erasure_jobs(id,account_id,subject_id,destination,account_deletion_job_id,state,
                available_at,created_at,last_error_kind)
            VALUES (\(bind:job),\(bind:account),\(bind:subject),'posthog',\(bind:deletion),'manual_required',
                NOW()-INTERVAL '3 days',NOW()-INTERVAL '3 days','posthog_stale_receipt')
            """).run()
        try await sql.raw("""
            INSERT INTO measurement_posthog_erasure_receipts(job_id,posthog_project_id,person_uuid,phase,resolved_at,
                requested_at,round,manual_reason,manual_at)
            VALUES (\(bind:job),'298161',\(bind:UUID()),'polling',NOW()-INTERVAL '2 days',NOW()-INTERVAL '2 days',2,
                'posthog_stale_receipt',NOW()-INTERVAL '1 day')
            """).run()
    }

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let app {
            try? await sql.raw("DELETE FROM measurement_erasure_jobs WHERE account_id=\(bind:account)").run()
            try? await sql.raw("DELETE FROM account_deletion_jobs WHERE id=\(bind:deletion)").run()
            try? await sql.raw("DELETE FROM measurement_subjects WHERE account_id=\(bind:account)").run()
            try? await User.query(on: app.db).filter(\.$id == account).delete()
            try await app.asyncShutdown()
        }
        app = nil; files = []
    }

    private func write(_ object: [String: Any]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("posthog-remediation-\(UUID().uuidString.lowercased()).json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        files.append(url)
        return url.path
    }

    private func evidence(eventCount: Int = 0) -> [String: Any] {
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let id = opaque.uuidString.lowercased()
        return ["schemaVersion": 1, "jobId": job.uuidString, "postHogProjectId": "298161", "distinctId": id,
                "method": "posthog_support_deletion", "operator": "codex", "supportReference": "PostHog ticket 12345",
                "verification": ["queryAt": at, "query": "SELECT count() FROM events WHERE distinct_id = '\(id)'",
                                 "refresh": "force_blocking", "isCached": false, "eventCount": eventCount,
                                 "personsLookupAt": at, "personsResultCount": 0]]
    }

    private func state() async throws -> (job: String, reason: String?, deletion: String) {
        let row = try await sql.raw("""
            SELECT j.state,j.last_error_kind,d.measurement_erasure_state FROM measurement_erasure_jobs j
            JOIN account_deletion_jobs d ON d.id=j.account_deletion_job_id WHERE j.id=\(bind:job)
            """).first()!
        return (try row.decode(column: "state", as: String.self), try row.decode(column: "last_error_kind", as: String?.self),
                try row.decode(column: "measurement_erasure_state", as: String.self))
    }

    func testCheckOnlyThenApplyClosesTheJobOnceAndSettlesAccountDeletion() async throws {
        XCTAssertNotNil(app.asyncCommands.commands["posthog-erasure-resolve"], "the admin command is registered")
        let path = try write(evidence())
        let checked = try await PostHogManualResolution.execute(app: app, jobID: job, evidencePath: path, apply: false)
        XCTAssertFalse(checked.recorded)
        var current = try await state()
        XCTAssertEqual(current.job, "manual_required", "checking alone records nothing")

        let applied = try await PostHogManualResolution.execute(app: app, jobID: job, evidencePath: path, apply: true)
        XCTAssertTrue(applied.recorded)
        XCTAssertEqual(applied.evidenceSha256, checked.evidenceSha256)
        current = try await state()
        XCTAssertEqual(current.job, "completed")
        XCTAssertNil(current.reason)
        XCTAssertEqual(current.deletion, "completed", "account deletion can now settle")
        let record = try await sql.raw("""
            SELECT manual_reason,method,operator,support_reference,verified_event_count,evidence_sha256
            FROM measurement_posthog_manual_resolutions WHERE job_id=\(bind:job)
            """).first()
        XCTAssertEqual(try record?.decode(column: "manual_reason", as: String.self), "posthog_stale_receipt")
        XCTAssertEqual(try record?.decode(column: "method", as: String.self), "posthog_support_deletion")
        XCTAssertEqual(try record?.decode(column: "verified_event_count", as: Int?.self), 0)
        XCTAssertEqual(try record?.decode(column: "evidence_sha256", as: String.self), applied.evidenceSha256)
        let receipt = try await sql.raw("SELECT manual_reason FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        XCTAssertEqual(try receipt?.decode(column: "manual_reason", as: String?.self), "posthog_stale_receipt",
                       "the receipt keeps why it needed a person")
        do {
            _ = try await PostHogManualResolution.execute(app: app, jobID: job, evidencePath: path, apply: true)
            XCTFail("a closed job cannot be resolved twice")
        } catch is PostHogManualResolution.Refusal {}
    }

    func testResidualEventsRefuseAndLeaveEverythingUnchanged() async throws {
        let path = try write(evidence(eventCount: 2))
        do {
            _ = try await PostHogManualResolution.execute(app: app, jobID: job, evidencePath: path, apply: true)
            XCTFail("residual events cannot close the job")
        } catch is PostHogManualResolution.Refusal {}
        let current = try await state()
        XCTAssertEqual(current.job, "manual_required")
        XCTAssertEqual(current.reason, "posthog_stale_receipt")
        XCTAssertEqual(current.deletion, "manual_required")
        let record = try await sql.raw("SELECT job_id FROM measurement_posthog_manual_resolutions WHERE job_id=\(bind:job)").first()
        XCTAssertNil(record)
    }

    func testClosingRecordChecksHoldWithoutTheService() async throws {
        for refused in [
            // support deletion without PostHog's reference
            "'posthog_support_deletion',NULL,NULL,NOW()-INTERVAL '1 hour',0,NOW()-INTERVAL '1 hour',NULL,NULL",
            // non-zero count
            "'posthog_person_deletion',NULL,NULL,NOW()-INTERVAL '1 hour',1,NOW()-INTERVAL '1 hour',NULL,NULL",
            // proof older than the escalation
            "'posthog_person_deletion',NULL,NULL,NOW()-INTERVAL '3 days',0,NOW()-INTERVAL '3 days',NULL,NULL",
            // project deletion without Dan's approval
            "'sandbox_project_deletion',NULL,NULL,NULL,NULL,NULL,NOW()-INTERVAL '1 hour',404",
        ] {
            do {
                try await sql.raw("""
                    INSERT INTO measurement_posthog_manual_resolutions(job_id,posthog_project_id,manual_reason,operator,
                        method,support_reference,approval_reference,verification_query_at,verified_event_count,
                        profile_absent_verified_at,project_access_lost_at,project_lookup_status,escalated_at,
                        evidence_sha256,evidence_reference,recorded_at)
                    VALUES (\(bind:job),'298161','posthog_stale_receipt','codex',\(unsafeRaw: refused),
                        NOW()-INTERVAL '1 day',\(bind:String(repeating: "a", count: 64)),'evidence.json',NOW())
                    """).run()
                XCTFail("closing-record check accepted: \(refused)")
            } catch {}
        }
    }
}
