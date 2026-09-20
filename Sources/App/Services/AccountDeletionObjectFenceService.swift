import Fluent
import SQLKit
import Vapor

/// The fence pass of a deletion job: the part that makes an object permanently
/// unreadable instead of deleting it.
///
/// It runs after the graph has committed its manifest and before the ordinary
/// physical deletes, because a key that must be fenced must never fall through to
/// a DELETE — not even when every write intent it has is already settled. A
/// settled write says the bytes arrived; it says nothing about whether another
/// writer may still arrive, and only the fence answers that.
///
/// Nothing here decides authority. The candidate query selects keys whose captured
/// intents agree on exactly one physical target under `create_only_v1`, and the
/// existing SQL function `object_erasure_fence_eligible` makes the final decision
/// on the actual fence row, before any storage call. A key with unknown, missing or
/// mixed targets simply never appears, and is therefore blocked without storage IO.
enum AccountDeletionObjectFenceService {

    /// A pass is bounded by time, not by a key count. The bound exists so one job
    /// cannot hold the maintenance connection for the whole window, and it is time
    /// rather than keys because a key count that looks cautious on paper — two per
    /// hourly pass — is a month of wall clock for a person with a few hundred
    /// photographs. Whatever is left is picked up by the next scheduled pass.
    struct Budget: Sendable {
        /// How long one job may spend fencing in a single pass.
        var pass: TimeInterval = 120
        /// The most candidate rows read in one query. Bounds memory, not work.
        var candidates: Int = 512
        static let `default` = Budget()
    }

    struct Candidate: Sendable {
        let kind: String
        let key: String
        let target: ObjectStorageWriteTarget
    }

    /// Fences what it can within the budget. Returns the number of keys attested in
    /// this pass, which is evidence for the runbook rather than a control signal.
    @discardableResult
    static func perform(_ lease: AccountDeletionWorker.Lease, app: Application, on db: Database,
                        transactionMode: AccountDeletionWorker.TransactionMode = .managed,
                        budget: Budget = .default, now: @Sendable () -> Date = Date.init) async throws -> Int {
        let deadline = now().addingTimeInterval(budget.pass)
        var attested = 0
        for candidate in try await candidates(lease, on: db, limit: budget.candidates) {
            guard now() < deadline else { break }
            // Renewed before each key, so a key is never started under a lease that
            // has already been replaced.
            guard try await AccountDeletionWorker.renew(lease, on: db) else { break }
            if try await fence(candidate, lease: lease, app: app, on: db, transactionMode: transactionMode) { attested += 1 }
        }
        return attested
    }

    /// Keys whose captured intents agree on one exact physical target under
    /// `create_only_v1`. Requested fences come first, so an interrupted pass
    /// finishes what it started before it starts anything new.
    ///
    /// A key this `HAVING` drops is not merely skipped: the delete branch excludes
    /// it too, because it has a create-only intent, so nothing will ever act on it
    /// again. `AccountDeletionGraphService.targetAmbiguous` is this `HAVING`
    /// negated, and is what turns that into a visible `blocked` state with
    /// `object_target_ambiguous` instead of an hourly retry for ever. The two must
    /// keep saying the same thing; change them together.
    static func candidates(_ lease: AccountDeletionWorker.Lease, on db: Database, limit: Int) async throws -> [Candidate] {
        let sql = try VerifiedIdentityService.sql(db)
        let rows = try await sql.raw("""
            SELECT o.storage_kind, o.object_key,
                   min(i.storage_backend) AS storage_backend,
                   min(i.storage_backend_identity) AS storage_backend_identity,
                   min(i.storage_bucket) AS storage_bucket,
                   min(i.storage_namespace) AS storage_namespace,
                   bool_or(f.id IS NOT NULL) AS requested
            FROM account_deletion_objects o
            JOIN account_deletion_write_intents d ON d.job_id=o.job_id
            JOIN object_write_intents i ON i.id=d.intent_id
                AND i.storage_kind=o.storage_kind AND i.object_key=o.object_key
            LEFT JOIN object_erasure_fences f ON f.job_id=o.job_id
                AND f.storage_kind=o.storage_kind AND f.object_key=o.object_key
            WHERE o.job_id=\(bind: lease.id) AND o.completed_at IS NULL
            GROUP BY o.storage_kind, o.object_key
            HAVING count(*) FILTER (WHERE i.write_protocol<>'create_only_v1')=0
               AND count(*) FILTER (WHERE i.storage_backend IS NULL OR i.storage_backend_identity IS NULL
                                       OR i.storage_bucket IS NULL OR i.storage_namespace IS NULL)=0
               AND count(DISTINCT (i.storage_backend,i.storage_backend_identity,i.storage_bucket,i.storage_namespace))=1
            ORDER BY bool_or(f.id IS NOT NULL) DESC, o.storage_kind, o.object_key
            LIMIT \(bind: limit)
            """).all()
        return try rows.map { row in
            Candidate(kind: try row.decode(column: "storage_kind", as: String.self),
                      key: try row.decode(column: "object_key", as: String.self),
                      target: .init(backend: try row.decode(column: "storage_backend", as: String.self),
                                    backendIdentity: try row.decode(column: "storage_backend_identity", as: String.self),
                                    bucket: try row.decode(column: "storage_bucket", as: String.self),
                                    namespace: try row.decode(column: "storage_namespace", as: String.self),
                                    writeProtocol: .createOnlyV1))
        }
    }

    /// One key: request, check eligibility on the real row, verify, attest.
    ///
    /// A nil ticket is durable success from an earlier pass whose acknowledgement
    /// was lost, not a reason to try again. A failure is classified and recorded
    /// under the current lease; the provider's own words are never persisted,
    /// because they can carry a key or a token.
    ///
    /// The classification follows where the refusal happened, and the boundary is
    /// the first storage call. Everything before it is the database declining to
    /// admit a fence — whether that is the insert's own constraints or the
    /// eligibility function — and reads as `fence_not_eligible`. Everything from
    /// the provider onwards is the storage side, and reads as `fence_unavailable`.
    /// A runbook needs to tell "we are not allowed to fence this yet" from "R2 did
    /// not answer", because only one of them is waiting on us.
    static func fence(_ candidate: Candidate, lease: AccountDeletionWorker.Lease, app: Application,
                      on db: Database, transactionMode: AccountDeletionWorker.TransactionMode) async throws -> Bool {
        let ticket: ObjectErasureFenceService.Ticket
        do {
            guard let requested = try await ObjectErasureFenceService.requestIfNeeded(
                lease, target: candidate.target, kind: candidate.kind, key: candidate.key,
                on: db, transactionMode: transactionMode) else { return false }
            guard try await isEligible(requested, on: db) else { throw Refusal.notEligible }
            ticket = requested
        } catch {
            try await record(failure: .fenceNotEligible, candidate, lease: lease, on: db, transactionMode: transactionMode)
            return false
        }
        do {
            let store = try AccountDeletionFenceProvider.store(for: candidate.target, app: app)
            let evidence = try await ObjectErasureFenceService.verify(ticket, using: store, on: db, transactionMode: transactionMode)
            try await ObjectErasureFenceService.attest(ticket, evidence: evidence, on: db, transactionMode: transactionMode)
            return true
        } catch let failure as AccountDeletionFenceProvider.Failure where failure == .unavailable {
            try await record(failure: .fenceConfiguration, candidate, lease: lease, on: db, transactionMode: transactionMode)
            return false
        } catch {
            try await record(failure: .fenceUnavailable, candidate, lease: lease, on: db, transactionMode: transactionMode)
            return false
        }
    }

    private enum Refusal: Error { case notEligible }

    /// The SQL function decides, on the row that exists, before anything is written
    /// to storage.
    private static func isEligible(_ ticket: ObjectErasureFenceService.Ticket, on db: Database) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(db)
        guard let row = try await sql.raw("""
            SELECT object_erasure_fence_eligible(f.*) AS eligible FROM object_erasure_fences f WHERE f.id=\(bind: ticket.fenceID)
            """).first() else { return false }
        return try row.decode(column: "eligible", as: Bool.self)
    }

    /// Fixed internal reasons only, from the closed set every deletion writes
    /// from. A raw provider error may contain a key, a bucket or a credential;
    /// none of those may reach a durable row, and a durable row is read by an
    /// operator runbook long after the pass that wrote it.
    private static func record(failure kind: DeletionReasonKind, _ candidate: Candidate, lease: AccountDeletionWorker.Lease,
                               on db: Database, transactionMode: AccountDeletionWorker.TransactionMode) async throws {
        _ = try await AccountDeletionWorker.writeIfCurrent(lease, on: db, transactionMode: transactionMode) { sql in
            try await sql.raw("""
                UPDATE account_deletion_objects SET attempts=attempts+1,last_error_kind=\(bind: kind.rawValue)
                WHERE job_id=\(bind: lease.id) AND storage_kind=\(bind: candidate.kind) AND object_key=\(bind: candidate.key)
                    AND completed_at IS NULL
                """).run()
        }
    }
}
