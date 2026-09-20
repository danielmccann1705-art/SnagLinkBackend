@testable import App
import Fluent
import FluentSQL
import Foundation
import Vapor

/// Writes an `object_write_intents` row directly, replicating
/// `ObjectWriteIntentService.begin`'s INSERT column for column.
///
/// `begin` now takes an allocation rather than a loose target, and an `Allocation`
/// can only be produced by `PrivateObjectAllocationPolicy` from a loaded
/// configuration. That is the point of the change: no caller can hand-roll a
/// target for a key the policy never allocated. It also means the rows the fence's
/// candidate query exists to refuse — two buckets on one physical key, a legacy
/// protocol beside a create-only one, a namespaced key with no target at all — can
/// no longer be recorded through the service, because the type refuses to describe
/// them.
///
/// A test still has to be able to put those rows in the table, because what is
/// being tested is what the database does when they are there. This is the one
/// place that does it. It writes the same columns as `begin`, in the same order,
/// with the same defaults, so the `object_write_intent_durable` and
/// `z_object_write_fence_admission` triggers see exactly what a real writer would
/// have produced — a raw insert here is a shortcut past the Swift signature, never
/// past a rule the database enforces.
enum ObjectWriteIntentRows {

    /// The row as `begin` would have written it. Returns the intent id.
    @discardableResult
    static func insert(_ object: ObjectWriteIntentService.Object,
                       source: ObjectWriteIntentService.Source,
                       scope: ObjectWriteIntentService.Scope,
                       target: ObjectStorageWriteTarget?,
                       on db: Database) async throws -> UUID {
        let id = UUID()
        // `begin` stores the hash of a freshly generated writer token and keeps the
        // token itself in the returned ticket. Nothing here can settle the row, so
        // the token is generated, hashed and dropped rather than returned: a raw
        // row is evidence for the database to reason about, not a live write.
        let tokenHash = SHA256Hasher.hash(token: "object-write-intent:" + (try SecureTokenGenerator.generate(byteCount: 32)))
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO object_write_intents(id,writer_token_hash,ownership_kind,source_kind,source_id,source_session_id,
                scope_user_id,scope_workspace_id,scope_project_id,scope_magic_link_id,storage_kind,object_key,
                sha256,byte_count,content_type,state,created_at,storage_backend,storage_backend_identity,storage_bucket,storage_namespace,write_protocol)
            VALUES(\(bind: id),\(bind: tokenHash),\(bind: scope.workspaceID == nil ? "personal" : "workspace"),\(bind: source.kind),\(bind: source.id),\(bind: source.sessionID),
                \(bind: scope.userID),\(bind: scope.workspaceID),\(bind: scope.projectID),\(bind: scope.magicLinkID),\(bind: object.storageKind),\(bind: object.key),
                \(bind: object.sha256),\(bind: object.byteCount),\(bind: object.contentType),'active',NOW(),\(bind: target?.backend),\(bind: target?.backendIdentity),\(bind: target?.bucket),\(bind: target?.namespace),\(bind: target?.writeProtocol.rawValue ?? "legacy_unknown"))
            """).run()
        return id
    }

    /// The shape the fence suites need: one media-shaped intent for one key, under
    /// whatever target the case is about, inside the caller's transaction.
    @discardableResult
    static func insert(userID: UUID, key: String, kind: String = "private_media",
                       target: ObjectStorageWriteTarget?,
                       data: Data = Data("synthetic".utf8), contentType: String = "image/jpeg",
                       sourceKind: String = "media_asset", sourceID: UUID = UUID(),
                       on db: Database) async throws -> UUID {
        try await insert(.init(storageKind: kind, key: key, data: data, contentType: contentType),
                         source: .init(kind: sourceKind, id: sourceID),
                         scope: .init(userID: userID), target: target, on: db)
    }
}
