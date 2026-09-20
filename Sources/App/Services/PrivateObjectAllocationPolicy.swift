import Vapor
import Fluent

/// The one place that decides, for an object this process is about to write,
/// which storage target it belongs to and which key it is allocated — and the one
/// place that records the write intent the deletion fence later reads.
///
/// Everything downstream of a private object is built on the answers here. The
/// erasure fence can only fence a key whose captured intents agree on exactly one
/// physical target under `create_only_v1`, and those intents are written from an
/// allocation this policy produced. So an address that is decided anywhere else is
/// an address a deletion cannot make permanently unreadable.
///
/// It holds no credentials. It borrows `PrivateStorageTargetConfiguration`, which
/// is already the single reading of the environment that both stores are built
/// from, so there is one answer to "where does a private object live" rather than
/// three that have to keep agreeing with each other forever.
enum PrivateObjectAllocationPolicy {

    // MARK: - Storage kinds and where each one is written

    /// Where a storage kind's objects are written.
    enum Placement: String, Sendable, Equatable {
        /// Inside the installed private namespace: one target, create-only writes,
        /// and fenceable — a deletion replaces the bytes rather than removing them.
        case privateNamespace
        /// The historical address. An unconditional writer, no recorded target, and
        /// a deletion that physically deletes. Nothing here moves it.
        case legacy
    }

    /// Every storage kind that exists. The same closed set the schema fixes in
    /// `object_write_intents.storage_kind`; a new kind is added here first, so it
    /// cannot be recorded before somebody has decided where it is written.
    static let storageKinds: Set<String> = [
        "private_media", "private_import", "private_drawing",
        "legacy_photo", "legacy_drawing", "legacy_completion_photo",
    ]

    /// The allocation rule, per kind.
    ///
    /// Only `private_media` moves today, and the reason is structural rather than a
    /// matter of sequencing: `PrivateStorageTargetConfiguration.validateContentKey`
    /// admits exactly `<namespace>media/<uuid>/<uuid>/<uuid>/original` and its
    /// `view-<sha256>.jpg` rendition. A drawing page needs seven segments and an
    /// import object needs its own prefix and three purposes, so neither has a
    /// shape the private content store can write or read. Widening that validator
    /// is a change to the store, not to this policy, and until it happens a drawing
    /// or an import that claimed to be in the namespace would be an object no
    /// writer could create and no reader could fetch.
    static func placement(ofKind kind: String) throws -> Placement {
        switch kind {
        case "private_media":
            return .privateNamespace
        case "private_drawing", "private_import",
             "legacy_photo", "legacy_drawing", "legacy_completion_photo":
            return .legacy
        default:
            throw Failure.kindUnknown
        }
    }

    // MARK: - Failures

    /// Every refusal keeps its own reason. Two of these mean "no private storage
    /// here" and they are still separate, because "this deployment does not use the
    /// private namespace" and "somebody turned the private namespace on and got the
    /// configuration wrong" need different answers from a runbook, and only one of
    /// them is a mistake.
    enum Failure: Error, Equatable {
        /// `R2_PRIVATE_NAMESPACE` is not set. Private allocation is not installed.
        case namespaceUnavailable
        /// `R2_PRIVATE_NAMESPACE` is set and the configuration behind it is not
        /// usable. Allocation refuses rather than falling back to the legacy
        /// address, which would put an object somewhere a deletion does not look.
        case namespaceUnusable
        /// A storage kind this policy has never been told about.
        case kindUnknown
        /// A known kind whose objects are not written into the private namespace.
        case kindNotEligible
        /// A key inside the namespace whose shape this policy never allocates.
        case keyNotAllocatable
        /// The allocation-time rendition placeholder. It names an object that does
        /// not exist and never will at that address; it is not a malformed key.
        case renditionPlaceholder
        /// A digest that is not a lowercase hex sha-256.
        case digestInvalid
        /// Bytes that do not hash to the content-addressed key they would be
        /// written to.
        case renditionDigestMismatch
        /// A key whose storage kind and address disagree about where it lives.
        case keyKindMismatch
        /// An allocation produced against a different target than the one installed
        /// now. A stale allocation is never re-pointed at whatever is configured.
        case targetMismatch
        /// Content this address may not carry.
        case contentTypeNotAllowed
        /// Bytes that are not the image they are declared to be, or that are empty
        /// or larger than a private object may ever be. Every one of these is a
        /// refusal the content store makes before its first byte leaves the
        /// process; making it here means it is made before an intent exists.
        case contentInvalid
    }

    // MARK: - Installation

    /// The private namespace, as this process found it. Resolved once.
    enum Installation: Sendable {
        case installed(PrivateStorageTargetConfiguration)
        /// The switch is off.
        case absent
        /// The switch is on and what is behind it is not usable.
        case unusable
    }

    /// A configuration injected by a test. Honoured only under `.testing`; in any
    /// other environment its presence is ignored entirely rather than trusted.
    struct InjectionKey: StorageKey { typealias Value = PrivateStorageTargetConfiguration }

    private struct ResolvedKey: StorageKey { typealias Value = Installation }

    /// Called once from `configure`. Resolving here rather than on the first upload
    /// means a half-configured switch is visible at boot, and that a request never
    /// pays to parse configuration. Nothing is read out of the result but which of
    /// the three states it is.
    @discardableResult
    static func install(app: Application, lookup: (String) -> String? = Environment.get) -> Installation {
        let resolved: Installation
        do {
            if let configuration = try PrivateStorageTargetConfiguration.load(environment: app.environment, lookup: lookup) {
                resolved = .installed(configuration)
            } else {
                resolved = .absent
            }
        } catch {
            resolved = .unusable
        }
        app.storage[ResolvedKey.self] = resolved
        return resolved
    }

    static func installation(app: Application) -> Installation {
        if app.environment == .testing, let injected = app.storage[InjectionKey.self] { return .installed(injected) }
        if let resolved = app.storage[ResolvedKey.self] { return resolved }
        return install(app: app)
    }

    /// The installed configuration, or the reason there is not one.
    static func configuration(app: Application) throws -> PrivateStorageTargetConfiguration {
        switch installation(app: app) {
        case .installed(let configuration): return configuration
        case .absent: throw Failure.namespaceUnavailable
        case .unusable: throw Failure.namespaceUnusable
        }
    }

    // MARK: - An allocation

    /// Which of an object's two addresses this is. A rendition is content-addressed
    /// and an original is not, so they are not interchangeable.
    enum Role: String, Sendable, Equatable { case original, rendition }

    /// One object: the kind it belongs to, the target that owns it, and the single
    /// address it will ever have.
    ///
    /// Constructed only by this policy. A caller cannot assemble one from a request,
    /// a row, or a string, which is what keeps `contentStore.target`, the recorded
    /// intent's target, and the fence's target the same value rather than three
    /// values that happen to match.
    struct Allocation: Sendable, Equatable {
        let storageKind: String
        let target: ObjectStorageWriteTarget
        let key: String
        let role: Role
        fileprivate init(storageKind: String, target: ObjectStorageWriteTarget, key: String, role: Role) {
            self.storageKind = storageKind; self.target = target; self.key = key; self.role = role
        }
    }

    /// The one address a new private media object will ever have.
    ///
    /// The third segment is a fresh server-drawn UUID, not the media asset's id.
    /// Under create-only an address is spent the moment it is used, and spent for
    /// good once a fence has taken it; account deletion drops the `media_assets`
    /// row, so the asset id stops being reserved by its primary key while the fence
    /// at that address stays. Since the media, project and workspace ids all arrive
    /// from the client, a key built only from them can be re-presented, and the
    /// second upload at that address dies inside `prevent_fenced_object_admission`
    /// as an opaque constraint violation. A nonce makes that unreachable instead of
    /// unlikely, and nothing reads identity back out of a key — the graph matches
    /// keys by equality, so the segment carries no meaning anything depends on.
    ///
    /// Workspace and project stay in the key so a bucket listing is legible to an
    /// operator, which is the only thing they are for here.
    ///
    /// They are safe to keep only under one rule, and the rule is absolute: **no
    /// reader, router, manifest rule or deletion rule may ever parse tenancy out of
    /// a key; the row is the authority.** A fence is permanent, so a deleted
    /// tenant's workspace and project identifiers persist as key segments in the
    /// bucket for good. They are random identifiers whose only index - the database
    /// rows - is destroyed by the same deletion, so they are unlinkable afterwards;
    /// that stays true exactly as long as nothing downstream treats a key as a
    /// statement about who owns the object.
    static func allocateMedia(workspaceID: UUID, projectID: UUID, app: Application) throws -> Allocation {
        let configuration = try configuration(app: app)
        guard try placement(ofKind: "private_media") == .privateNamespace else { throw Failure.kindNotEligible }
        let key = configuration.target.namespace + "media/"
            + workspaceID.uuidString.lowercased() + "/"
            + projectID.uuidString.lowercased() + "/"
            + UUID().uuidString.lowercased() + "/original"
        do { try configuration.validateContentKey(key) } catch { throw Failure.keyNotAllocatable }
        return .init(storageKind: "private_media", target: configuration.target, key: key, role: .original)
    }

    /// The address a rendition of `original` has once its bytes exist — and not
    /// before, which is why this takes a digest rather than being derivable at
    /// allocation time. Content-addressing makes a repeat of the same processing
    /// land on the same address, so a retry under create-only meets its own earlier
    /// object instead of creating a second one.
    static func rendition(of original: Allocation, sha256: String, app: Application) throws -> Allocation {
        let configuration = try configuration(app: app)
        guard configuration.target == original.target else { throw Failure.targetMismatch }
        guard original.role == .original, original.key.hasSuffix("/original") else { throw Failure.keyNotAllocatable }
        guard isDigest(sha256) else { throw Failure.digestInvalid }
        let key = String(original.key.dropLast("original".count)) + "view-" + sha256 + ".jpg"
        do { try configuration.validateContentKey(key) } catch { throw Failure.keyNotAllocatable }
        return .init(storageKind: original.storageKind, target: configuration.target, key: key, role: .rendition)
    }

    // MARK: - Binding a key that is already recorded

    /// Where an already-recorded key lives.
    enum Binding: Sendable, Equatable {
        /// Inside the installed private namespace, with the allocation that owns it.
        case privateNamespace(Allocation)
        /// At its historical address. No target is recorded for it, so a deletion
        /// deletes it rather than fencing it.
        case legacy
    }

    /// The one historical address a media object can have. Every media object
    /// written before the namespace existed is under it, and it is the only shape
    /// of media key that binds `.legacy`.
    static let legacyMediaPrefix = "platform/"

    /// Classifies a key that a row already carries, so a retry, a read and a
    /// deletion all reach the same conclusion about where an object lives without
    /// any of them re-deriving it.
    ///
    /// Whether a key is in the private namespace is decidable from the key itself,
    /// which is why no row needs a column to remember it.
    ///
    /// `.legacy` is a positive statement about an address, never a fallback. A
    /// media key binds `.legacy` because it is under `platform/`, and for no other
    /// reason: a namespaced key met in a process with the namespace switched off,
    /// or switched on and misconfigured, is refused with that installation's own
    /// reason instead. The behaviour this replaces routed every namespaced read
    /// back through the legacy reader, whose validator then rejected the key as a
    /// 500 - failing open on a shape accident where it should fail closed with a
    /// typed reason. Kinds that do not move are unchanged: they are at their
    /// historical address, whatever it looks like, and only a key claiming to be
    /// inside an installed namespace is a contradiction rather than an address.
    static func binding(kind: String, key: String, app: Application) throws -> Binding {
        let placement = try placement(ofKind: kind)
        let installation = installation(app: app)
        guard placement == .privateNamespace else {
            if case .installed(let configuration) = installation, key.hasPrefix(configuration.target.namespace) {
                throw Failure.keyKindMismatch
            }
            return .legacy
        }
        switch installation {
        case .installed(let configuration):
            guard key.hasPrefix(configuration.target.namespace) else {
                guard key.hasPrefix(legacyMediaPrefix) else { throw Failure.keyNotAllocatable }
                return .legacy
            }
            let role: Role
            if key.hasSuffix("/original") {
                role = .original
            } else if key.hasSuffix("/view.jpg") {
                // A media row carries this from allocation until processing. It names an
                // object that does not exist, so it is refused as itself rather than as
                // a malformed key: a caller that meets it has met a real thing.
                throw Failure.renditionPlaceholder
            } else {
                role = .rendition
            }
            do { try configuration.validateContentKey(key) } catch { throw Failure.keyNotAllocatable }
            return .privateNamespace(.init(storageKind: kind, target: configuration.target, key: key, role: role))
        case .absent:
            guard key.hasPrefix(legacyMediaPrefix) else { throw Failure.namespaceUnavailable }
            return .legacy
        case .unusable:
            guard key.hasPrefix(legacyMediaPrefix) else { throw Failure.namespaceUnusable }
            return .legacy
        }
    }

    // MARK: - Recording the write intent

    /// The content an address may carry.
    ///
    /// A rendition key is its own digest. Bytes that do not hash to it are refused
    /// before anything is recorded, because a content-addressed key that does not
    /// address its content would make a retry create a second object rather than
    /// meet the first — and the second object is the one no manifest knows about.
    ///
    /// Every refusal the content store makes before its first byte leaves the
    /// process is also made here, and for one reason: the intent commits before the
    /// PUT is issued, so a PUT refused inside the store - a payload that is not the
    /// image it says it is, an empty body, an oversized one - would leave behind an
    /// `uncertain` row for a write that provably never happened, and that row
    /// blocks the owner's deletion from completing until a fence resolves it. A
    /// refusal that costs nothing is made before the row exists rather than after.
    static func requireContent(_ allocation: Allocation, data: Data, contentType: String) throws {
        guard PrivateContent.mimeTypes.contains(contentType) else { throw Failure.contentTypeNotAllowed }
        guard (1...PrivateContent.maximumBytes).contains(data.count) else { throw Failure.contentInvalid }
        // The same check, from the same function, the store runs on the same bytes.
        do { try PrivateImageProcessor.validateSignature(data, mime: contentType) }
        catch { throw Failure.contentInvalid }
        switch allocation.role {
        case .original:
            return
        case .rendition:
            guard contentType == "image/jpeg" else { throw Failure.contentTypeNotAllowed }
            guard let last = allocation.key.split(separator: "/").last,
                  last.hasPrefix("view-"), last.hasSuffix(".jpg") else { throw Failure.keyNotAllocatable }
            let digest = String(last.dropFirst("view-".count).dropLast(".jpg".count))
            guard isDigest(digest), PrivateImageProcessor.digest(data) == digest else { throw Failure.renditionDigestMismatch }
        }
    }

    /// Records the durable write intent for one allocated address and then performs
    /// the write, with the target filled in from the allocation.
    ///
    /// The ordering is `ObjectWriteIntentService`'s and is deliberately unchanged:
    /// the intent commits **before** the PUT is issued, and settles only once the
    /// PUT has definitely finished. A PUT whose outcome is unknown leaves the row
    /// `uncertain`, which keeps blocking deletion completion rather than expiring
    /// into success.
    ///
    /// What this seam adds is that a caller cannot record a namespaced key and
    /// forget to say where it lives. An intent with no target is a row the fence's
    /// candidate query silently drops, so the object it describes can never be made
    /// permanently unreadable — and nothing about the row shows that.
    ///
    /// The `operation` parameter is provisional and B2 removes it. A caller can
    /// still record a create-only intent and then write unconditionally inside the
    /// closure, which is the one thing recording the target does not close; B2
    /// closes it by performing the PUT and the readback here, through
    /// `PrivateContentStoreProvider.store(for: allocation.target)`, rather than
    /// taking a closure from a caller at all.
    @discardableResult
    static func write<T: Sendable>(_ allocation: Allocation, data: Data, contentType: String,
                                   source: ObjectWriteIntentService.Source, on database: Database,
                                   authorize: @escaping @Sendable (Database) async throws -> ObjectWriteIntentService.Scope,
                                   operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try requireContent(allocation, data: data, contentType: contentType)
        return try await ObjectWriteIntentService.write(
            .init(storageKind: allocation.storageKind, key: allocation.key, data: data, contentType: contentType),
            source: source, allocation: allocation, on: database, authorize: authorize, operation: operation)
    }

    private static func isDigest(_ value: String) -> Bool {
        guard let match = value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) else { return false }
        return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
    }
}
