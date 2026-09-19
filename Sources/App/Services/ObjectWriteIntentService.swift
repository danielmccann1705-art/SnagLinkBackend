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
    static func write<T: Sendable>(_ object: Object, source: Source, target: ObjectStorageWriteTarget? = nil, on database: Database,
                                  authorize: @escaping @Sendable (Database) async throws -> Scope,
                                  operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let ticket = try await database.transaction { db in
            let scope = try await authorize(db)
            return try await begin(object, source: source, scope: scope, target: target, on: db)
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
    static func begin(_ object: Object, source: Source, scope: Scope, target: ObjectStorageWriteTarget? = nil, on db: Database) async throws -> Ticket {
        guard db.inTransaction, object.byteCount >= 0,
              object.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !object.key.isEmpty, !object.contentType.isEmpty,
              ["media_asset","staged_original","import_derived","completion_upload","legacy_link","drawing_asset"].contains(source.kind),
              ["private_media","private_import","private_drawing","legacy_photo","legacy_drawing","legacy_completion_photo"].contains(object.storageKind),
              scope.userID != nil || scope.workspaceID != nil || scope.magicLinkID != nil else {
            throw Abort(.internalServerError, reason: "Object write scope is incomplete")
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
