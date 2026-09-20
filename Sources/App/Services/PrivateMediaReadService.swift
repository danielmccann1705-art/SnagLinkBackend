import Vapor
import Logging

/// The one place a private photograph's bytes are fetched for a reader.
///
/// Two routes disclose private media — the manager route and the Contractor link
/// route — and before this existed each of them called `StorageService` directly.
/// That was survivable only while every media key had one shape. It stops being
/// survivable the moment some keys live in the private namespace and some do not,
/// because the two addresses are served by two different transports with two
/// different deletion semantics: a legacy object is physically deleted, and a
/// namespaced object is *replaced* by an erasure fence that stays at its address
/// for good. A reader that met a fence through the legacy reader would be handed
/// the fence object's bytes as though they were the photograph.
///
/// So the routing decision is made once, here, from
/// `PrivateObjectAllocationPolicy.binding`, and both routes ask this service for
/// bytes rather than asking storage for them.
///
/// **What this service does not do, and must never learn to do.** It does not
/// decide who may see the object. The row and the ACL are the authority; the key
/// is not, and no reader, router, manifest rule or deletion rule may ever parse
/// tenancy out of a key. A namespaced key carries a workspace and a project
/// identifier purely so that a bucket listing is legible to an operator, and a
/// fence is permanent, so those identifiers outlive the tenant that owned them.
/// They are unlinkable only because the rows that indexed them are destroyed by
/// the same deletion — which stays true exactly as long as nothing downstream
/// treats a key as a statement about who owns the object. Both callers therefore
/// keep their authorization transaction before the fetch, and their re-check
/// after it.
enum PrivateMediaReadService {

    /// The fixed operator vocabulary for a private read: one line per key, one
    /// `kind`, and nothing else. It is the shared private-media vocabulary, not a
    /// second one — a read that finds nothing at an address and a write whose PUT
    /// never landed are the same physical observation, and they belong in one
    /// list rather than in two that can drift. See `PrivateMediaLogKind`.
    typealias LogKind = PrivateMediaLogKind

    /// Every refusal this service makes, as a fixed literal chosen here. Nothing
    /// from a store error, a key, an ETag, a bucket, a namespace or a grant token
    /// is ever interpolated: a 4xx reason ships verbatim to the client.
    private static func unavailable() -> Abort {
        Abort(.serviceUnavailable, reason: "This photo is temporarily unavailable. Try again", identifier: "media_unavailable")
    }
    private static func storageUnavailable() -> Abort {
        Abort(.serviceUnavailable, reason: "Photo storage is unavailable. Try again shortly", identifier: "media_storage_unavailable")
    }
    private static func erased() -> Abort {
        Abort(.gone, reason: "This photo is no longer available", identifier: "media_erased")
    }

    /// Fetches the bytes at `key`, or refuses with the reason that belongs to what
    /// was actually found. The caller verifies those bytes against its own row and
    /// re-checks its own authorization afterwards; neither is this service's job.
    static func read(key: String, app: Application, logger: Logger) async throws -> Data {
        let binding: PrivateObjectAllocationPolicy.Binding
        do {
            binding = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: key, app: app)
        } catch PrivateObjectAllocationPolicy.Failure.namespaceUnavailable,
                PrivateObjectAllocationPolicy.Failure.namespaceUnusable {
            // The row holds a namespaced key and this process has no namespace, or
            // has one it cannot use. Both are deployment facts rather than facts
            // about the photograph, and both fail closed: the legacy reader is
            // never handed a namespaced key, because its validator would refuse it
            // as a malformed key and report a server fault for a correct row.
            throw storageUnavailable()
        } catch {
            // `renditionPlaceholder`, `keyNotAllocatable`, `keyKindMismatch`. A row
            // that is `ready` carries two addresses that were written after their
            // bytes existed, so none of these is reachable from a correct row —
            // meeting one means the row is corrupt, which is a server fault and not
            // something a client should be invited to retry.
            throw Abort(.internalServerError, reason: "This photo's stored address is not readable", identifier: "request_failed")
        }
        switch binding {
        case .legacy:
            // Unchanged, deliberately and in every particular: the historical
            // address keeps the historical reader. This is the only branch any
            // object written before the namespace existed can take.
            do { return try await StorageService.downloadPrivate(key: key, app: app) }
            catch { throw unavailable() }
        case .privateNamespace(let allocation):
            return try await read(allocation, app: app, logger: logger)
        }
    }

    private static func read(_ allocation: PrivateObjectAllocationPolicy.Allocation,
                             app: Application, logger: Logger) async throws -> Data {
        let store: any PrivateContentStorage
        do { store = try PrivateContentStoreProvider.store(for: allocation.target, app: app) }
        catch {
            // There is no fallback here on purpose. A store for another target, or
            // no store at all, is a refusal — never the legacy reader, never the
            // public bucket, never local disk.
            throw storageUnavailable()
        }
        let readback: Readback
        do {
            readback = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
        } catch is CancellationError {
            // Nobody is waiting for an answer; inventing one would only mislabel
            // the request in the log.
            throw CancellationError()
        } catch PrivateContentStoreError.absent {
            // Nothing is at the address. Distinct from "storage did not answer"
            // for the operator, and deliberately not distinct for the reader: a
            // reader learns that an object it is entitled to is not available now,
            // and learns nothing about the shape of the bucket behind it.
            logger.info("Private media read", metadata: ["kind": .string(LogKind.absent.rawValue)])
            throw unavailable()
        } catch PrivateContentStoreError.invalidKey, PrivateContentStoreError.invalidContent {
            // Refusals the store makes about its caller before the GET is issued.
            // Unreachable from a bound allocation — the key was validated by the
            // same configuration the store holds — so meeting one is a caller bug,
            // and a caller bug is a 500 rather than a 503 that invites a retry.
            throw Abort(.internalServerError, reason: "This photo's read was refused before it was issued", identifier: "request_failed")
        } catch {
            logger.info("Private media read", metadata: ["kind": .string(LogKind.storageUnreachable.rawValue)])
            throw unavailable()
        }
        // A fence is the whole point of the namespace, and it is the one readback
        // that must never be served. It holds the address of a photograph that a
        // person asked to have destroyed; its own contents are zero bytes under an
        // erasure content type, and a reader handed them would receive a 200 with
        // strange bytes instead of being told the object is gone. The integrity
        // check the callers run afterwards would refuse those bytes as a 503, which
        // reads as "try again" for something that can never succeed.
        guard !readback.isErasureFence else { throw erased() }
        return readback.body
    }
}
