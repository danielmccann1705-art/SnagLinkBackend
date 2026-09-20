import Vapor
import Fluent
import FluentSQL

/// Durable external-write evidence outlives the application graph. A failed or
/// interrupted PUT is not known absent; its intent never expires into success.
enum ObjectWriteIntentService {
    struct Source: Sendable {
        let kind: String
        let id: UUID
        var sessionID: UUID? = nil
    }
    struct Scope: Sendable {
        var userID: UUID? = nil
        var workspaceID: UUID? = nil
        var projectID: UUID? = nil
        var magicLinkID: UUID? = nil
    }
    struct Object: Sendable {
        let storageKind: String
        let key: String
        let sha256: String
        let byteCount: Int64
        let contentType: String
        init(storageKind: String, key: String, data: Data, contentType: String) {
            self.storageKind = storageKind; self.key = key
            self.sha256 = PrivateImageProcessor.digest(data); self.byteCount = Int64(data.count); self.contentType = contentType
        }
        init(storageKind: String, key: String, sha256: String, byteCount: Int64, contentType: String) {
            self.storageKind = storageKind; self.key = key; self.sha256 = sha256; self.byteCount = byteCount; self.contentType = contentType
        }
    }
    struct Ticket: Sendable {
        let id: UUID
        fileprivate let token: String
    }
    /// Authorization runs again immediately before the intent is committed. It
    /// must prove the route-specific capability, assignment and exact source row.
    /// Database locks then serialize intent admission with account/company freeze.
    static func write<T: Sendable>(_ object: Object, source: Source,
                                  allocation: PrivateObjectAllocationPolicy.Allocation? = nil, on database: Database,
                                  authorize: @escaping @Sendable (Database) async throws -> Scope,
                                  operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let ticket = try await database.transaction { db in
            let scope = try await authorize(db)
            return try await begin(object, source: source, scope: scope, allocation: allocation, on: db)
        }
        return try await execute(ticket, on: database, operation: operation)
    }
    /// Execute only after begin has committed. Exposed for existing services
    /// whose own authority transaction must declare the intent atomically.
    static func execute<T: Sendable>(_ ticket: Ticket, on database: Database,
                                    beforeIssuing: (@Sendable () throws -> Void)? = nil,
                                    operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            try Task.checkCancellation()
            try beforeIssuing?()
        } catch {
            // Proven not issued: this branch runs synchronously before the
            // storage closure has ever been invoked. No remote PUT can be late.
            // A failed progress update still leaves durable active evidence.
            try await settle(ticket, on: database)
            throw error
        }
        let result: T
        do { result = try await operation() }
        catch {
            // A client timeout/cancellation does not prove the remote PUT failed.
            // If this update itself fails, durable active evidence still blocks
            // deletion. No provider error/body/key is copied into this row or logs.
            try? await markUncertain(ticket, on: database)
            throw error
        }
        try await settle(ticket, on: database)
        return result
    }
    /// Caller supplies a real transaction after current route authorization.
    /// This is also the boundary an injected drawing bridge must use before PUT.
    static func begin(_ object: Object, source: Source, scope: Scope,
                      allocation: PrivateObjectAllocationPolicy.Allocation? = nil, on db: Database) async throws -> Ticket {
        guard db.inTransaction, object.byteCount >= 0,
              object.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !object.key.isEmpty, !object.contentType.isEmpty,
              ["media_asset","staged_original","import_derived","completion_upload","legacy_link","drawing_asset"].contains(source.kind),
              PrivateObjectAllocationPolicy.storageKinds.contains(object.storageKind),
              scope.userID != nil || scope.workspaceID != nil || scope.magicLinkID != nil else {
            throw Abort(.internalServerError, reason: "Object write scope is incomplete")
        }
        // Where an intent's target comes from, and what may be said about it.
        //
        // A target is not a parameter of its own any more. It is read off an
        // allocation the policy produced, so nothing can hand-roll a target for a
        // key the policy never allocated, and the three values that have to agree
        // forever - the store's target, the recorded intent's target and the
        // fence's target - are one value rather than three that happen to match.
        // The checks kept here rather than only in the policy are the ones the two
        // services that must declare an intent inside their own authority
        // transaction would otherwise bypass, since they reach this entry point
        // directly.
        //
        // They are deliberately configuration-free. Whether a particular namespace
        // is installed is a property of the process, and this function is handed a
        // database and nothing else; a rule that consulted process configuration
        // here would hold in production and not in a test that injects one. The
        // rule that does depend on configuration - that a key inside the installed
        // namespace may only be recorded with the target that owns it - belongs to
        // PrivateObjectAllocationPolicy, which is the only thing that can produce
        // such a key in the first place.
        let target = allocation?.target
        if let allocation {
            // Unreachable now that the type carries the target: an Allocation is
            // built only from a loaded configuration, and that loader produces
            // create-only targets and nothing else. Kept as a one-line assertion
            // because a fully populated target under any other protocol satisfies
            // the object_write_target_complete CHECK, which constrains the columns
            // and not the protocol; such a row would look recorded and would be
            // dropped silently by the fence's candidate query, so the object it
            // describes could never be made permanently unreadable and nothing
            // about the row would say so.
            guard allocation.target.writeProtocol == .createOnlyV1 else {
                throw Abort(.internalServerError, reason: "Object write target protocol is unsupported",
                            identifier: "object_write_target_protocol")
            }
            // The object recorded must be the object allocated. An allocation's key
            // is inside its own namespace by construction - and the database
            // enforces that too, as a CHECK that surfaces as a 23514 - so what a
            // typed refusal here actually names is a caller that allocated one
            // address and then recorded another.
            guard allocation.key == object.key, allocation.storageKind == object.storageKind,
                  object.key.hasPrefix(allocation.target.namespace),
                  object.key.count > allocation.target.namespace.count else {
                throw Abort(.internalServerError, reason: "Object write key is outside its target namespace",
                            identifier: "object_write_key_outside_target")
            }
        }
        let sql = try VerifiedIdentityService.sql(db)
        if let projectID = scope.projectID, let project = try await Project.find(projectID, on: db) {
            guard project.workspaceId == scope.workspaceID else { throw unavailable() }
        }
        if let workspaceID = scope.workspaceID {
            try await WorkspaceAccessService.lock(workspaceID, on: db)
            guard try await sql.raw("SELECT id FROM teams WHERE id=\(bind: workspaceID) AND lifecycle_state='active' FOR SHARE").first() != nil else { throw unavailable() }
        }
        if let userID = scope.userID {
            guard try await sql.raw("SELECT id FROM users WHERE id=\(bind: userID) AND lifecycle_state='active' FOR SHARE").first() != nil else { throw unavailable() }
        }
        if let linkID = scope.magicLinkID {
            guard try await sql.raw("SELECT id FROM magic_links WHERE id=\(bind: linkID) AND project_id=\(bind: scope.projectID) AND created_by_id=\(bind: scope.userID) AND revoked_at IS NULL AND expires_at>clock_timestamp() FOR SHARE").first() != nil else { throw unavailable() }
        }
        let ticket = Ticket(id: UUID(), token: try SecureTokenGenerator.generate(byteCount: 32))
        try await sql.raw("""
            INSERT INTO object_write_intents(id,writer_token_hash,ownership_kind,source_kind,source_id,source_session_id,
                scope_user_id,scope_workspace_id,scope_project_id,scope_magic_link_id,storage_kind,object_key,
                sha256,byte_count,content_type,state,created_at,storage_backend,storage_backend_identity,storage_bucket,storage_namespace,write_protocol)
            VALUES(\(bind: ticket.id),\(bind: tokenHash(ticket.token)),\(bind: scope.workspaceID == nil ? "personal" : "workspace"),\(bind: source.kind),\(bind: source.id),\(bind: source.sessionID),
                \(bind: scope.userID),\(bind: scope.workspaceID),\(bind: scope.projectID),\(bind: scope.magicLinkID),\(bind: object.storageKind),\(bind: object.key),
                \(bind: object.sha256),\(bind: object.byteCount),\(bind: object.contentType),'active',NOW(),\(bind: target?.backend),\(bind: target?.backendIdentity),\(bind: target?.bucket),\(bind: target?.namespace),\(bind: target?.writeProtocol.rawValue ?? "legacy_unknown"))
            """).run()
        return ticket
    }
    /// Only call after the submitted PUT has definitely finished. This remains
    /// possible after account revocation; the ticket authorises progress only.
    static func settle(_ ticket: Ticket, on db: Database) async throws {
        guard try await VerifiedIdentityService.sql(db).raw("""
            UPDATE object_write_intents SET state='settled',settled_at=NOW()
            WHERE id=\(bind: ticket.id) AND writer_token_hash=\(bind: tokenHash(ticket.token)) AND state='active' RETURNING id
            """).first() != nil else { throw unavailable() }
    }
    static func markUncertain(_ ticket: Ticket, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("""
            UPDATE object_write_intents SET state='uncertain'
            WHERE id=\(bind: ticket.id) AND writer_token_hash=\(bind: tokenHash(ticket.token)) AND state='active'
            """).run()
    }
    private static func tokenHash(_ value: String) -> String { SHA256Hasher.hash(token: "object-write-intent:" + value) }
    private static func unavailable() -> Abort { Abort(.conflict, reason: "Object write is no longer available", identifier: "object_write_unavailable") }
}
