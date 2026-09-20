import Vapor
import Fluent
import FluentSQL

/// Constructed from installed storage configuration, never decoded from HTTP.
struct ObjectStorageWriteTarget: Sendable, Equatable {
    enum WriteProtocol: String, Sendable { case legacyUnknown = "legacy_unknown", createOnlyV1 = "create_only_v1" }
    let backend: String
    let backendIdentity: String
    let bucket: String
    let namespace: String
    let writeProtocol: WriteProtocol
}

/// Future concrete adapters own private storage credentials. None is installed
/// by this packet. The parser and public requests cannot implement this boundary.
protocol ObjectErasureFenceStorage: Sendable {
    var target: ObjectStorageWriteTarget { get }
    func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String
    func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback
}
struct ObjectErasureFenceReadback: Sendable {
    let target: ObjectStorageWriteTarget
    let key: String
    let body: Data
    let byteCount: Int64
    let contentType: String
    let metadata: [String: String]
    let etag: String
}

/// Positive IO evidence cannot be decoded or constructed by callers. It is
/// minted only after a successful adapter PUT and exact bounded direct readback.
struct VerifiedObjectErasureFence: Sendable {
    fileprivate let attemptID: UUID
    fileprivate let target: ObjectStorageWriteTarget
    fileprivate let key: String
    fileprivate let etag: String
}

enum ObjectErasureFenceService {
    static let marker = "snaglist-erased-v1"
    static let contentType = "application/x-snaglist-erased"
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    struct Ticket: Sendable {
        let fenceID: UUID
        let attemptID: UUID
        let jobID: UUID
        let leaseToken: UUID
        let target: ObjectStorageWriteTarget
        let kind: String
        let key: String
        let expiresAt: Date
        fileprivate let capability: String
    }
    /// Requires a real database pool, not Fluent's autocommit withConnection
    /// handle (which incorrectly advertises inTransaction). No IO inside this tx.
    static func request(_ lease: AccountDeletionWorker.Lease, target: ObjectStorageWriteTarget,
                        kind: String, key: String, on database: Database) async throws -> Ticket {
        guard let ticket = try await requestIfNeeded(lease, target: target, kind: kind, key: key, on: database) else {
            throw Abort(.conflict, reason: "Object erasure fence is already attested", identifier: "object_erasure_fence_already_attested")
        }
        return ticket
    }
    /// A durable successful fence survives acknowledgement loss and worker
    /// restart. A current worker can observe it without creating another attempt.
    static func requestIfNeeded(_ lease: AccountDeletionWorker.Lease, target: ObjectStorageWriteTarget,
                                kind: String, key: String, on database: Database,
                                transactionMode: AccountDeletionWorker.TransactionMode = .managed) async throws -> Ticket? {
        // A pooled handle must not already be in a transaction. The pinned
        // maintenance handle reports that it is without one ever having begun,
        // which is why the check follows the mode rather than the flag alone.
        guard target.writeProtocol == .createOnlyV1,
              transactionMode == .maintenanceConnection || !database.inTransaction else { throw unavailable() }
        return try await AccountDeletionTransaction.run(transactionMode, on: database) { db -> Ticket? in
            let sql = try VerifiedIdentityService.sql(db)
            let expiry = try await requireLease(lease.id, token: lease.token, on: sql)
            try await sql.raw("SELECT object_erasure_lock(\(bind:key))").run()
            try await context(lease.token, on: sql)
            var fenceID: UUID
            if let row = try await sql.raw("""
                SELECT id,job_id,storage_kind,storage_namespace FROM object_erasure_fences
                WHERE storage_backend=\(bind:target.backend) AND storage_backend_identity=\(bind:target.backendIdentity)
                    AND storage_bucket=\(bind:target.bucket) AND object_key=\(bind:key)
                """).first() {
                guard try row.decode(column: "job_id", as: UUID.self) == lease.id,
                      try row.decode(column: "storage_kind", as: String.self) == kind,
                      try row.decode(column: "storage_namespace", as: String.self) == target.namespace else { throw unavailable() }
                fenceID = try row.decode(column: "id", as: UUID.self)
            } else {
                fenceID = UUID()
                try await sql.raw("""
                    INSERT INTO object_erasure_fences(id,job_id,storage_kind,object_key,storage_backend,storage_backend_identity,
                        storage_bucket,storage_namespace,write_protocol)
                    VALUES(\(bind:fenceID),\(bind:lease.id),\(bind:kind),\(bind:key),\(bind:target.backend),\(bind:target.backendIdentity),
                        \(bind:target.bucket),\(bind:target.namespace),'create_only_v1')
                    """).run()
            }
            if try await sql.raw("SELECT id FROM object_erasure_fence_attestations WHERE fence_id=\(bind:fenceID)").first() != nil {
                _ = try await requireLease(lease.id, token: lease.token, on: sql)
                return nil
            }
            let ticket = Ticket(fenceID: fenceID, attemptID: UUID(), jobID: lease.id, leaseToken: lease.token,
                target: target, kind: kind, key: key, expiresAt: expiry, capability: try SecureTokenGenerator.generate(byteCount: 32))
            try await sql.raw("""
                INSERT INTO object_erasure_fence_attempts(id,fence_id,lease_token,capability_hash,expires_at)
                VALUES(\(bind:ticket.attemptID),\(bind:fenceID),\(bind:lease.token),\(bind:capabilityHash(ticket.capability)),\(bind:expiry))
                """).run()
            _ = try await requireLease(lease.id, token: lease.token, on: sql)
            return ticket
        }
    }
    /// No remote implementation is installed. This verifier is exercised with a
    /// synthetic adapter; a future reviewed R2 adapter must use direct bucket IO.
    static func verify(_ ticket: Ticket, using storage: any ObjectErasureFenceStorage,
                       on database: Database,
                       transactionMode: AccountDeletionWorker.TransactionMode = .managed) async throws -> VerifiedObjectErasureFence {
        guard ticket.target.writeProtocol == .createOnlyV1, storage.target == ticket.target,
              transactionMode == .maintenanceConnection || !database.inTransaction else { throw unavailable() }
        // Database time and the durable attempt decide admission. No application
        // wall clock is compared with PostgreSQL, and no lock is held over IO.
        // Admission commits before any storage call: no row transaction spans IO.
        try await AccountDeletionTransaction.run(transactionMode, on: database) { db in
            let sql = try VerifiedIdentityService.sql(db)
            _ = try await requireLease(ticket.jobID, token: ticket.leaseToken, on: sql)
            try await sql.raw("SELECT object_erasure_lock(\(bind:ticket.key))").run()
            guard try await matchingAttempt(ticket, current: true, on: sql) != nil else { throw unavailable() }
        }
        let metadata = ["snaglist-erasure": marker]
        let etag = try await storage.replaceWithEmptyFence(key: ticket.key, contentType: contentType, metadata: metadata)
        let read = try await storage.readFence(key: ticket.key, maximumBytes: 1)
        guard read.target == ticket.target, read.key == ticket.key, read.body.isEmpty, read.byteCount == 0,
              read.contentType == contentType, read.metadata == metadata,
              !etag.isEmpty, etag.utf8.count <= 512, read.etag == etag else { throw unavailable() }
        return .init(attemptID: ticket.attemptID, target: read.target, key: read.key, etag: etag)
    }
    /// Capability-bound observation only: this cannot create proof or mutate
    /// state, and remains safe after lease replacement or overall completion.
    static func isAttested(_ ticket: Ticket, on database: Database) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(database)
        guard let row = try await matchingAttempt(ticket, current: false, on: sql) else { throw unavailable() }
        return try row.decode(column: "attested", as: Bool.self)
    }
    static func attest(_ ticket: Ticket, evidence: VerifiedObjectErasureFence,
                       on database: Database,
                       transactionMode: AccountDeletionWorker.TransactionMode = .managed) async throws {
        guard evidence.attemptID == ticket.attemptID, evidence.target == ticket.target, evidence.key == ticket.key,
              transactionMode == .maintenanceConnection || !database.inTransaction else { throw unavailable() }
        try await AccountDeletionTransaction.run(transactionMode, on: database) { db in
            let sql = try VerifiedIdentityService.sql(db)
            // Serialize before observing completion so a concurrent successful
            // attestation remains recoverable even if it also finishes the job.
            _ = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind:ticket.jobID) FOR UPDATE").first()
            if try await isAttested(ticket, on: db) { return }
            _ = try await requireLease(ticket.jobID, token: ticket.leaseToken, on: sql)
            try await sql.raw("SELECT object_erasure_lock(\(bind:ticket.key))").run()
            try await context(ticket.leaseToken, on: sql)
            try await sql.raw("SELECT set_config('snaglist.object_erasure_capability',\(bind:ticket.capability),true)").run()
            try await sql.raw("""
                INSERT INTO object_erasure_fence_attestations(id,fence_id,attempt_id,storage_backend,storage_backend_identity,
                    storage_bucket,storage_namespace,object_key,object_sha256,byte_count,content_type,marker,provider_etag,verified_at)
                VALUES(\(bind:UUID()),\(bind:ticket.fenceID),\(bind:ticket.attemptID),\(bind:evidence.target.backend),\(bind:evidence.target.backendIdentity),
                    \(bind:evidence.target.bucket),\(bind:evidence.target.namespace),\(bind:evidence.key),\(bind:emptySHA256),0,
                    \(bind:contentType),\(bind:marker),\(bind:evidence.etag),clock_timestamp())
                """).run()
            // The fence permanently replaces the erased content. Do not issue a
            // physical DELETE, and do not falsely report that its writer settled.
            try await sql.raw("""
                UPDATE account_deletion_objects SET completed_at=clock_timestamp(),last_error_kind=NULL
                WHERE job_id=\(bind:ticket.jobID) AND storage_kind=\(bind:ticket.kind) AND object_key=\(bind:ticket.key)
                    AND completed_at IS NULL
                """).run()
            _ = try await requireLease(ticket.jobID, token: ticket.leaseToken, on: sql)
        }
    }
    private static func matchingAttempt(_ ticket: Ticket, current: Bool, on sql: SQLDatabase) async throws -> SQLRow? {
        try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM object_erasure_fence_attestations v WHERE v.fence_id=f.id) AS attested
            FROM object_erasure_fence_attempts a JOIN object_erasure_fences f ON f.id=a.fence_id
            WHERE a.id=\(bind:ticket.attemptID) AND a.fence_id=\(bind:ticket.fenceID)
                AND a.lease_token=\(bind:ticket.leaseToken) AND a.capability_hash=\(bind:capabilityHash(ticket.capability))
                AND f.job_id=\(bind:ticket.jobID) AND f.storage_kind=\(bind:ticket.kind) AND f.object_key=\(bind:ticket.key)
                AND f.storage_backend=\(bind:ticket.target.backend) AND f.storage_backend_identity=\(bind:ticket.target.backendIdentity)
                AND f.storage_bucket=\(bind:ticket.target.bucket) AND f.storage_namespace=\(bind:ticket.target.namespace)
                AND f.write_protocol=\(bind:ticket.target.writeProtocol.rawValue)
                AND (NOT \(bind:current) OR (a.expires_at>clock_timestamp() AND object_erasure_fence_eligible(f)))
            """).first()
    }
    private static func requireLease(_ jobID: UUID, token: UUID, on sql: SQLDatabase) async throws -> Date {
        _ = try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind:jobID) FOR UPDATE").first()
        guard let row = try await sql.raw("SELECT lease_expires_at FROM account_deletion_jobs WHERE id=\(bind:jobID) AND lease_token=\(bind:token) AND state='leased' AND lease_expires_at>clock_timestamp()").first() else { throw unavailable() }
        return try row.decode(column: "lease_expires_at", as: Date.self)
    }
    private static func context(_ leaseToken: UUID, on sql: SQLDatabase) async throws {
        try await sql.raw("SELECT set_config('snaglist.object_erasure_lease',\(bind:leaseToken.uuidString),true)").run()
    }
    private static func capabilityHash(_ value: String) -> String { SHA256Hasher.hash(token: "object-erasure-fence:" + value) }
    private static func unavailable() -> Abort {
        Abort(.conflict, reason: "Object erasure fence is unavailable", identifier: "object_erasure_fence_unavailable")
    }
}
