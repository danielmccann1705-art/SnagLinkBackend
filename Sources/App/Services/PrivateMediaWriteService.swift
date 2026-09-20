import Vapor
import Fluent
import FluentSQL
import Logging

/// The one place a private photograph's bytes are written.
///
/// Two routes upload private media — the manager route and the Contractor link
/// route — and they are near-duplicates of one flow, which is exactly why they
/// must not diverge. Everything that decides whether an upload happened lives
/// here: which address the object gets, when that address is written into the
/// row, what a PUT outcome means, when a readback is required, and which of the
/// six refusals a client is told. The controllers keep only what is genuinely
/// route-specific — who is allowed to do this, and what the response looks like.
///
/// **The three things this exists to make impossible.**
///
/// *A fenced key must never accept content, and a client must never be told a
/// write succeeded onto one.* Every PUT is create-only, so a fence holds its
/// address against every later writer; and where the PUT does not itself say the
/// bytes landed, the readback decides. A fence read back is `media_erased` and
/// the intent stays `uncertain` for good.
///
/// *An intent must never settle for bytes that did not land.* The PUT, the
/// readback and the verification all run inside the closure
/// `ObjectWriteIntentService.execute` wraps, and that closure returns only on the
/// three rows where the bytes are provably ours. `markUncertain` is therefore the
/// only path to `uncertain`, and `settle` is unreachable except after a verified
/// row. No caller supplies that closure; there is nowhere to put an unconditional
/// write.
///
/// *A namespaced key may exist in `media_assets` only alongside an intent
/// recorded in the same transaction.* `original_key` is NULL from allocation
/// until the upload that writes it, and it is written inside the `authorize`
/// closure that `begin` commits with. An address that reached the row without an
/// intent behind it would enter an erasure manifest with nothing to make it
/// fenceable, and the physical-delete branch refuses a namespaced address by
/// shape — so it would be stuck, by design, for every allocated-never-uploaded
/// asset.
///
/// **What is deliberately not mapped here.** `prevent_fenced_object_admission`
/// refuses the `INSERT` into `object_write_intents` with SQLSTATE 23514 when a
/// fence already exists for the key, and that refusal is not an `Abort`, so it
/// would reach a client as a 500. Nothing maps it, because it is unreachable
/// through these two routes: a fence exists only once
/// `database_cleanup_state='completed'`, which is set in the same transaction
/// that destroyed the `media_assets` row, and both routes load that row before
/// anything else — so a request that could meet a fence has already failed its
/// own re-authorization with a 404. The nonce in an allocated key closes the
/// fresh-allocation collision; this ordering closes the retry. The middleware's
/// 500 is the backstop, and if one is ever seen it means one of those two facts
/// stopped being true, which is worth a 500 rather than a mapping that hides it.
enum PrivateMediaWriteService {

    // MARK: - What the operator is told

    /// The fixed operator vocabulary for a private write. One line per key, one
    /// `kind` from this list, and nothing else: a storage error's own words can
    /// carry a key, an ETag, a bucket or a credential, and none of them reaches a
    /// log or a client. A6 collects these into one enum beside B3's read kinds.
    enum LogKind: String, Sendable {
        /// The address was already taken and then answered "nothing is here".
        /// Two facts that cannot both be true; storage is not to be trusted yet.
        case existsThenAbsent = "exists_then_absent"
        /// The address was already taken and the readback did not answer.
        case readbackUnavailable = "readback_unavailable"
        /// The PUT's outcome was unknown and nothing is at the address: the write
        /// never landed. This is the row the readback was built for — it is the
        /// one that says a retry will help.
        case notLanded = "not_landed"
        /// The PUT's outcome was unknown and neither did the readback answer.
        case storageUnreachable = "storage_unreachable"
    }

    // MARK: - What the client is told

    /// One case per non-settling row of the state table, thrown by the writer and
    /// turned into an `Abort` in exactly one place. Typed rather than an `Abort`
    /// from the start so that the row a refusal came from survives the trip out
    /// of the intent closure, where `markUncertain` still has to run.
    enum Refusal: Error, Equatable {
        /// Rows 6 and 12. The readback is an erasure fence: the key belongs to a
        /// deleted account, no content ever lands on it, the intent is never
        /// settled, and no retry of any kind can reach a settling row afterwards.
        case erased
        /// Rows 7 and 13. Something that is not ours occupies the address, and
        /// create-only will keep refusing. Terminal for this key.
        case keyConflict
        /// Row 10. Bytes that are not the image they are declared to be, empty or
        /// oversized. Refused before an intent exists.
        case mismatch
        /// Row 18. The row is bound to a historical `platform/` address and is not
        /// ready. It is never re-bound to a namespaced key.
        case reallocate
        /// Rows 16 and 19. There is no store for this target, or no namespace is
        /// installed. A deployment fact, not a fact about the photograph.
        case storageUnavailable
        /// Rows 8a, 8b, 14a, 14b and 15. The bytes may or may not be there; the
        /// intent stays `uncertain` and a retry may reach a settling row.
        case unavailable(LogKind?)
        /// Rows 9 and 17: a refusal the store makes about its caller, before any
        /// request is issued, for an address this policy itself validated. Meeting
        /// one is a server fault, not something a client should be invited to
        /// retry.
        case requestFailed
    }

    /// Every reason is a fixed literal chosen here. Nothing from a store error, a
    /// key, an ETag, a bucket, a namespace or a grant token is interpolated: a 4xx
    /// reason ships to the client verbatim, and only a 5xx is replaced wholesale.
    static func abort(_ error: any Error, logger: Logger) -> any Error {
        switch refusal(for: error) {
        case .erased:
            return Abort(.gone, reason: "This photo is no longer available", identifier: "media_erased")
        case .keyConflict:
            return Abort(.conflict, reason: "This photo could not be saved at its address. Allocate it again",
                         identifier: "media_key_conflict")
        case .mismatch:
            return Abort(.unprocessableEntity, reason: "Photo bytes differ from the allocated size, checksum or type",
                         identifier: "media_mismatch")
        case .reallocate:
            return Abort(.gone, reason: "Allocate this photo again", identifier: "media_reallocate")
        case .storageUnavailable:
            return Abort(.serviceUnavailable, reason: "Photo storage is unavailable. Try again shortly",
                         identifier: "media_storage_unavailable")
        case .unavailable(let kind):
            if let kind { logger.info("Private media write", metadata: ["kind": .string(kind.rawValue)]) }
            return Abort(.serviceUnavailable, reason: "This photo could not be saved. Try again",
                         identifier: "media_unavailable")
        case .requestFailed:
            return Abort(.internalServerError, reason: "This photo's write was refused before it was issued",
                         identifier: "request_failed")
        case .none:
            // An `Abort` the route itself raised — a revoked membership, a
            // retired upload, a snag that moved — keeps its own status and
            // reason. Only storage refusals are this service's to name.
            return error
        }
    }

    /// Maps everything the write path can throw onto one row of the table. The
    /// policy's own failures are included because two of them — no namespace, and
    /// a namespace that is installed and unusable — are row 19 wherever they are
    /// met, and the rest describe a key this policy allocated and then refused,
    /// which is a server fault.
    private static func refusal(for error: any Error) -> Refusal? {
        if let refusal = error as? Refusal { return refusal }
        if error is CancellationError { return .unavailable(nil) }
        if let failure = error as? PrivateObjectAllocationPolicy.Failure {
            switch failure {
            case .namespaceUnavailable, .namespaceUnusable:
                return .storageUnavailable
            case .contentInvalid, .contentTypeNotAllowed, .renditionDigestMismatch:
                return .mismatch
            case .kindUnknown, .kindNotEligible, .keyNotAllocatable,
                 .renditionPlaceholder, .digestInvalid, .keyKindMismatch, .targetMismatch:
                return .requestFailed
            }
        }
        if error is PrivateContentStoreProvider.Failure { return .storageUnavailable }
        if error is PrivateContentStoreError { return .requestFailed }
        return nil
    }

    // MARK: - Allocation

    /// The gate both allocate routes run before a row exists. Private media is
    /// allocated into the namespace or not at all: there is no unconditional
    /// writer left to fall back to, and an object written by one would be an
    /// object no deletion could ever make permanently unreadable.
    static func requireAllocatable(app: Application, logger: Logger) throws {
        do { _ = try PrivateObjectAllocationPolicy.configuration(app: app) }
        catch { throw abort(error, logger: logger) }
    }

    // MARK: - Writing one asset

    /// The two addresses an upload settled, for the readiness transaction to
    /// commit. `renditionKey` is returned rather than written here: readiness is
    /// the only place it is recorded, and only after both writes returned.
    struct Written: Sendable {
        let originalKey: String
        let renditionKey: String
        let renditionSHA256: String
    }

    /// Raised inside the `authorize` transaction when another request bound the
    /// row to a different address first. Never leaves this file: the writer
    /// catches it once, takes the row's address as the answer, and re-runs. It is
    /// raised before `begin` commits, so no intent and no object exist for the
    /// address that lost.
    private struct BoundElsewhere: Error { let key: String }

    /// Writes an asset's original and its rendition, in that order, and returns
    /// the two addresses. Throws an `Abort` and nothing else.
    ///
    /// `boundOriginalKey` is the row's `original_key` as the caller's own
    /// authorization transaction read it. It is a hint, not the authority: the
    /// row is re-read under a lock inside the transaction that records the
    /// intent, and that reading is what decides.
    static func write(assetID: UUID, workspaceID: UUID, projectID: UUID,
                      boundOriginalKey: String?,
                      original: Data, mimeType: String, rendition: Data,
                      app: Application, on database: Database, logger: Logger,
                      authorize: @escaping @Sendable (Database) async throws -> ObjectWriteIntentService.Scope) async throws -> Written {
        do {
            let source = ObjectWriteIntentService.Source(kind: "media_asset", id: assetID)
            let renditionSHA = PrivateImageProcessor.digest(rendition)
            var allocation = try allocation(for: boundOriginalKey, workspaceID: workspaceID, projectID: projectID, app: app)
            var rebound = false
            while true {
                do {
                    try await PrivateObjectAllocationPolicy.write(
                        allocation, data: original, contentType: mimeType, source: source, app: app, on: database,
                        authorize: binding(assetID, to: allocation, authorize))
                    break
                } catch let elsewhere as BoundElsewhere {
                    // Once, and once only. `preserve_media_asset_keys` makes a
                    // bound address final, so a second disagreement would mean the
                    // row changed under a rule that forbids it — a server fault,
                    // not something to keep chasing.
                    guard !rebound else { throw Refusal.requestFailed }
                    rebound = true
                    allocation = try self.allocation(for: elsewhere.key, workspaceID: workspaceID,
                                                     projectID: projectID, app: app)
                }
            }
            // Derived from the row's own original allocation, and from the bytes:
            // a rendition key is its own digest, so a repeat of the same
            // processing meets its own earlier object instead of creating a second.
            let renditionAllocation = try PrivateObjectAllocationPolicy.rendition(of: allocation, sha256: renditionSHA, app: app)
            try await PrivateObjectAllocationPolicy.write(
                renditionAllocation, data: rendition, contentType: "image/jpeg", source: source, app: app, on: database,
                authorize: confirmation(assetID, boundTo: allocation, authorize))
            return .init(originalKey: allocation.key, renditionKey: renditionAllocation.key, renditionSHA256: renditionSHA)
        } catch {
            throw abort(error, logger: logger)
        }
    }

    /// The address this upload will use: the row's, if it already has one, or a
    /// fresh one drawn from the policy.
    private static func allocation(for boundKey: String?, workspaceID: UUID, projectID: UUID,
                                   app: Application) throws -> PrivateObjectAllocationPolicy.Allocation {
        guard let boundKey else {
            return try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: workspaceID, projectID: projectID, app: app)
        }
        switch try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: boundKey, app: app) {
        case .legacy:
            // A historical address, allocated before the namespace existed and
            // never uploaded to. There is no writer for it any more, and it is
            // never re-bound to a namespaced key: the row's address is final, so
            // the only way forward is a new allocation.
            throw Refusal.reallocate
        case .privateNamespace(let allocation):
            guard allocation.role == .original else { throw Refusal.requestFailed }
            return allocation
        }
    }

    /// The row's address is written here, inside the transaction that records the
    /// intent, or it is confirmed to be the one we are writing. Nothing else in
    /// the codebase may set `original_key`.
    private static func binding(_ assetID: UUID, to allocation: PrivateObjectAllocationPolicy.Allocation,
                                _ authorize: @escaping @Sendable (Database) async throws -> ObjectWriteIntentService.Scope)
        -> @Sendable (Database) async throws -> ObjectWriteIntentService.Scope {
        { db in
            let scope = try await authorize(db)
            // The same lock allocation takes, so two first uploads of one asset
            // are serialized and converge on one address rather than racing to
            // write two.
            try await VerifiedIdentityService.lock("entity:media:\(assetID)", on: db)
            let sql = try VerifiedIdentityService.sql(db)
            guard let row = try await sql.raw("SELECT original_key FROM media_assets WHERE id = \(bind: assetID) FOR UPDATE").first() else {
                throw Abort(.notFound, reason: "Photo unavailable")
            }
            if let current = try row.decode(column: "original_key", as: String?.self) {
                guard current == allocation.key else { throw BoundElsewhere(key: current) }
            } else {
                try await sql.raw("UPDATE media_assets SET original_key = \(bind: allocation.key) WHERE id = \(bind: assetID)").run()
            }
            return scope
        }
    }

    /// The rendition's intent is recorded against the same row, so the row must
    /// still carry the original address this rendition was derived from.
    private static func confirmation(_ assetID: UUID, boundTo allocation: PrivateObjectAllocationPolicy.Allocation,
                                     _ authorize: @escaping @Sendable (Database) async throws -> ObjectWriteIntentService.Scope)
        -> @Sendable (Database) async throws -> ObjectWriteIntentService.Scope {
        { db in
            let scope = try await authorize(db)
            let sql = try VerifiedIdentityService.sql(db)
            guard let row = try await sql.raw("SELECT original_key FROM media_assets WHERE id = \(bind: assetID) FOR SHARE").first(),
                  try row.decode(column: "original_key", as: String?.self) == allocation.key else {
                throw Refusal.requestFailed
            }
            return scope
        }
    }

    // MARK: - Readiness

    /// Readiness is committed only from a row the writer returned, and only if the
    /// row still carries the address those bytes were written to. The caller has
    /// already re-authorized inside its own transaction; this is the storage half
    /// of that check and nothing else.
    static func requireWritten(_ row: SQLRow, matches written: Written) throws {
        guard try row.decode(column: "original_key", as: String?.self) == written.originalKey else {
            throw Abort(.forbidden)
        }
    }
}
