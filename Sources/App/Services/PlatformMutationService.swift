import Vapor
import Fluent
import FluentSQL

struct PlatformMutationService {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(value.utf8))
    }
    static func lock(actorID: UUID, mutation: MutationMetadata, on db: Database) async throws {
        try await VerifiedIdentityService.lock("operation:\(actorID):\(mutation.operationId)", on: db)
    }
    static func requestHash<T: Encodable>(_ command: T, route: String) throws -> String {
        SHA256Hasher.hash(token: route + "\n" + (try encode(command)))
    }
    /// Caller must first recheck current scope/permission, even for an old retry.
    static func replay<T: Decodable>(_ type: T.Type, actorID: UUID, mutation: MutationMetadata, hash: String, on db: Database) async throws -> T? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT request_hash, result_json, account_deletion_redacted_at, result_purged_at FROM mutation_receipts WHERE actor_id = \(bind: actorID) AND operation_id = \(bind: mutation.operationId)").first() else { return nil }
        guard try row.decode(column: "request_hash", as: String.self) == hash else {
            throw Abort(.conflict, reason: "This operation ID was already used for different work. Keep the original request when retrying", identifier: "operation_reused")
        }
        // A body removed at account deletion or by the M1 retention purge: the
        // operation is still recognised and never applied again (A4 §1.4).
        guard try row.decode(column: "account_deletion_redacted_at", as: Date?.self) == nil,
              try row.decode(column: "result_purged_at", as: Date?.self) == nil else {
            throw Abort(.conflict, reason: "This action was already applied. Refresh the current state before continuing", identifier: "already_applied_refresh_required")
        }
        return try decode(type, row.decode(column: "result_json", as: String.self))
    }
    /// Returns the database's immutable server receipt time from the same INSERT.
    /// Existing callers may ignore it; outcome hooks use it without another query.
    @discardableResult
    static func record<T: Encodable>(_ result: T, actorID: UUID, workspaceID: UUID, mutation: MutationMetadata, hash: String, on db: Database) async throws -> Date {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO mutation_receipts
                (actor_id,operation_id,device_id,workspace_id,request_hash,result_json,created_at)
            VALUES (\(bind:actorID),\(bind:mutation.operationId),\(bind:mutation.deviceId),\(bind:workspaceID),
                    \(bind:hash),\(bind:encode(result)),\(bind:Date()))
            RETURNING created_at
            """).first() else { throw Abort(.internalServerError, reason: "Mutation receipt unavailable") }
        return try row.decode(column: "created_at", as: Date.self)
    }
    /// Holds the same workspace transaction lock as membership changes. The counter
    /// update and payload commit together; rolled-back writes cannot leave a gap.
    static func change<T: Encodable>(workspaceID: UUID, projectID: UUID?, type: String, entityID: UUID,
                                     revision: Int64, kind: String, fields: [String], payload: T, actorID: UUID?, grantID: UUID? = nil, on db: Database) async throws {
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        // PostgreSQL LOCAL settings are connection/transaction scoped, reset on
        // commit/rollback, and shared across every change emitted by this command.
        let setting = try await sql.raw("SELECT current_setting('snaglist.change_group', true) AS value").first()!.decode(column: "value", as: String?.self)
        let groupID = setting.flatMap(UUID.init(uuidString:)) ?? UUID()
        if setting != groupID.uuidString {
            _ = try await sql.raw("SELECT set_config('snaglist.change_group', \(bind: groupID.uuidString), true)").first()
        }
        let groupCount = try await sql.raw("SELECT count(*) AS n FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND transaction_group = \(bind: groupID)").first()!.decode(column: "n", as: Int.self)
        guard groupCount < 1000 else { throw Abort(.payloadTooLarge, reason: "Split this operation into smaller batches. No changes were committed", identifier: "change_group_too_large") }
        guard let row = try await sql.raw("UPDATE teams SET change_sequence = change_sequence + 1 WHERE id = \(bind: workspaceID) RETURNING change_sequence").first() else { throw Abort(.notFound) }
        let sequence = try row.decode(column: "change_sequence", as: Int64.self)
        try await sql.raw("""
            INSERT INTO platform_changes (workspace_id, sequence, project_id, entity_type, entity_id, revision, kind, changed_fields, payload_json, actor_id, actor_grant_id, created_at, transaction_group)
            VALUES (\(bind: workspaceID), \(bind: sequence), \(bind: projectID), \(bind: type), \(bind: entityID), \(bind: revision), \(bind: kind), \(bind: fields.sorted()), \(bind: encode(payload)), \(bind: actorID), \(bind: grantID), \(bind: Date()), \(bind: groupID))
            """).run()
    }
    /// One `platform_changes` row, built in memory and written later by `changes` (Lane A WP2, Fable §3.2 rule 4).
    /// The payload is encoded when the row is built, from the value as it is at that moment, exactly as `change`
    /// encodes it when it writes.
    struct PendingChange: Sendable {
        let projectID: UUID?, type: String, entityID: UUID, revision: Int64, kind: String, fields: [String]
        let payloadJSON: String, actorID: UUID?, grantID: UUID?
        init<T: Encodable>(projectID: UUID?, type: String, entityID: UUID, revision: Int64, kind: String, fields: [String],
                           payload: T, actorID: UUID?, grantID: UUID? = nil) throws {
            self.projectID = projectID; self.type = type; self.entityID = entityID; self.revision = revision; self.kind = kind
            self.fields = fields; self.payloadJSON = try PlatformMutationService.encode(payload); self.actorID = actorID; self.grantID = grantID
        }
    }

    /// The change rows one command collects, in the order the per-row path would have written them.
    final class Batch: @unchecked Sendable {
        private(set) var items: [PendingChange] = []
        func append(_ change: PendingChange) { items.append(change) }
    }

    /// `change` for several rows in one pass (Lane A WP2, Fable §3.2 rule 4). Same workspace lock (re-entrant, taken
    /// once), the same transaction-local change group read once, one bound check that is exactly the per-row one
    /// summed — each row of `change` requires `groupCount < 1000` before it, so n rows succeed iff
    /// `groupCount + n <= 1000` — one `UPDATE teams … + n RETURNING`, and one multi-row INSERT with sequences
    /// `s−n+1 … s` in the order given. Under the exclusive workspace lock no other writer can take a sequence in
    /// between, so contiguous numbering is what the per-row path produces. Every row gets its own `Date()` as before.
    static func changes(_ pending: [PendingChange], workspaceID: UUID, on db: Database) async throws {
        guard !pending.isEmpty else { return }
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        let sql = try VerifiedIdentityService.sql(db)
        let setting = try await sql.raw("SELECT current_setting('snaglist.change_group', true) AS value").first()!.decode(column: "value", as: String?.self)
        let groupID = setting.flatMap(UUID.init(uuidString:)) ?? UUID()
        if setting != groupID.uuidString {
            _ = try await sql.raw("SELECT set_config('snaglist.change_group', \(bind: groupID.uuidString), true)").first()
        }
        let groupCount = try await sql.raw("SELECT count(*) AS n FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND transaction_group = \(bind: groupID)").first()!.decode(column: "n", as: Int.self)
        guard groupCount + pending.count <= 1000 else { throw Abort(.payloadTooLarge, reason: "Split this operation into smaller batches. No changes were committed", identifier: "change_group_too_large") }
        guard let row = try await sql.raw("UPDATE teams SET change_sequence = change_sequence + \(bind: Int64(pending.count)) WHERE id = \(bind: workspaceID) RETURNING change_sequence").first() else { throw Abort(.notFound) }
        let first = try row.decode(column: "change_sequence", as: Int64.self) - Int64(pending.count) + 1
        let values = pending.enumerated().map { (offset, change) -> SQLQueryString in
            "(\(bind: workspaceID), \(bind: first + Int64(offset)), \(bind: change.projectID), \(bind: change.type), \(bind: change.entityID), \(bind: change.revision), \(bind: change.kind), \(bind: change.fields.sorted()), \(bind: change.payloadJSON), \(bind: change.actorID), \(bind: change.grantID), \(bind: Date()), \(bind: groupID))"
        }
        try await sql.raw(SQLQueryString("INSERT INTO platform_changes (workspace_id, sequence, project_id, entity_type, entity_id, revision, kind, changed_fields, payload_json, actor_id, actor_grant_id, created_at, transaction_group) VALUES ")
                          + values.joined(separator: ", ")).run()
    }
    static func checkRevision(_ expected: Int64, snag: Snag, workspaceID: UUID, on db: Database) async throws {
        guard expected > 0 else { throw Abort(.badRequest, reason: "A positive base revision is required") }
        guard expected != snag.revision else { return }
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT changed_fields FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND entity_type = 'snag' AND entity_id = \(bind: snag.requireID()) AND revision > \(bind: expected)").all()
        let fields = try Set(rows.flatMap { try $0.decode(column: "changed_fields", as: [String].self) }).sorted()
        throw RevisionConflict(body: .init(current: PlatformSnagResponse(snag), changedFields: fields))
    }
    static func requireManaged(_ project: Project) throws {
        try requireManaged(platformManaged: project.platformManaged, archivedAt: project.archivedAt)
    }
    /// The same check from the two columns it reads (the one-statement register read has no Project model).
    static func requireManaged(platformManaged: Bool, archivedAt: Date?) throws {
        guard platformManaged else { throw Abort(.conflict, reason: "Import and verify this existing project before editing it in the shared workspace", identifier: "project_import_required") }
        guard archivedAt == nil else { throw Abort(.gone, reason: "This project is archived", identifier: "project_archived") }
    }
}
