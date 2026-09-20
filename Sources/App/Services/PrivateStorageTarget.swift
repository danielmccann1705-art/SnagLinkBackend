import Vapor
import SotoS3

/// The one private-storage target this process is allowed to write to, and the
/// credentials that reach it. Fixed server configuration: never decoded from a
/// request, an intent row, or anything else a caller supplies.
///
/// Both stores that touch a private object are built from this single struct —
/// the erasure fence that replaces content, and the content store that writes it.
/// That is the point of extracting it: `contentStore.target == fenceStore.target`
/// is trivially true because there is one reading of the environment, not two
/// loaders that have to keep agreeing with each other forever.
struct PrivateStorageTargetConfiguration: Sendable {
    let target: ObjectStorageWriteTarget
    var endpoint: String { "https://\(target.backendIdentity).r2.cloudflarestorage.com" }
    private let accessKey: String
    private let secretKey: String

    /// Credentials leave this type only as a provider handed straight to Soto.
    /// Nothing else can read them, including the stores built from this value.
    var credentialProvider: CredentialProviderFactory { .static(accessKeyId: accessKey, secretAccessKey: secretKey) }

    /// `R2_PRIVATE_NAMESPACE` is the single switch for private storage. Absent, it
    /// is not installed and every caller gets nil without a credential ever being
    /// read. Present but wrong in any particular — including a namespace that is
    /// not a plain prefix, or a private bucket that is actually the public one —
    /// and the caller gets an error, never a partially configured target.
    ///
    /// `R2_ERASURE_FENCE_ENABLED` and `R2_ERASURE_FENCE_NAMESPACE` are retired:
    /// the fence is not a separate installation from the storage it fences.
    ///
    /// A namespace equal to a legacy object family is refused outright; see
    /// `reservedNamespaces`.
    ///
    /// `environment` is threaded in by every caller — `PrivateObjectAllocationPolicy.install`,
    /// `R2PrivateContentStore.makeIfConfigured`, `R2ObjectErasureFenceStore.makeIfEnabled` —
    /// and is deliberately not consulted. It used to carry a `.testing` gate: the
    /// switch existed, nothing was behind it anywhere, and the gate was the catch
    /// that said so. The switch is now the whole answer, in every environment, so
    /// that installing the namespace is one act by one person rather than a code
    /// change that has to accompany it. What a *missing* namespace means still
    /// depends on the environment, and that question is decided once at boot
    /// (`PrivateStorageBoot`) — not here, where it would be answered per caller.
    static func load(environment: Environment, lookup: (String) -> String? = Environment.get) throws -> Self? {
        guard let namespace = lookup("R2_PRIVATE_NAMESPACE") else { return nil }
        guard matches(namespace, "^[A-Za-z0-9_-]+/$"),
              !reservedNamespaces.contains(namespace),
              let account = lookup("R2_ACCOUNT_ID"), matches(account, "^[a-f0-9]{32}$"),
              let bucket = lookup("R2_PRIVATE_BUCKET_NAME"), matches(bucket, "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"),
              bucket != (lookup("R2_BUCKET_NAME") ?? "snaglist-uploads"),
              let access = lookup("R2_ACCESS_KEY_ID"), !access.isEmpty,
              let secret = lookup("R2_SECRET_ACCESS_KEY"), !secret.isEmpty else {
            throw R2ObjectErasureFenceError.configurationUnavailable
        }
        return .init(target: .init(backend: "r2", backendIdentity: account, bucket: bucket,
                                 namespace: namespace, writeProtocol: .createOnlyV1), accessKey: access, secretKey: secret)
    }
    /// The prefixes a legacy object family already owns: `platform/` for private
    /// media written before the namespace, `drawings/` and `staged-import/` for
    /// the two kinds that do not move this wave, and `uploads/` for everything the
    /// public bucket and the synced-photo path put there. A private namespace
    /// equal to one of these would put create-only, fenceable content at addresses
    /// the physical-delete path still treats as its own to delete. Today nothing
    /// but a shape coincidence keeps them apart — `validateContentKey` happens to
    /// refuse the legacy shapes, `deleteAccountObject` happens to require them —
    /// and a coincidence that several validators must keep agreeing on is not a
    /// rule.
    /// This is the rule. Refused with the same `configurationUnavailable` as every
    /// other wrong particular: a misconfigured target never loads half-installed.
    static let reservedNamespaces: Set<String> = ["platform/", "drawings/", "staged-import/", "uploads/"]

    fileprivate static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let match = value.range(of: pattern, options: .regularExpression) else { return false }
        return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
    }
    /// Any key inside the namespace: path-safe, bounded, no escape and no empty
    /// segment. A fence can replace every object this target holds, so it checks
    /// that a key is well formed, not what the object was for.
    func validate(key: String) throws {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard key.utf8.count <= 1024, key.hasPrefix(target.namespace), key.count > target.namespace.count,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  Self.matches(String($0), "^[A-Za-z0-9_.-]+$") }) else {
            throw R2ObjectErasureFenceError.invalidFence
        }
    }
    /// The narrower shape the content store may write and read, exactly:
    /// `<namespace>media/<uuid>/<uuid>/<uuid>/original`, or `.../view-<sha256>.jpg`
    /// for a rendition. UUIDs are lowercase so one object has one key.
    ///
    /// The allocation placeholder `view.jpg` is refused. A row carries it from the
    /// moment the asset is allocated, long before a rendition has been computed;
    /// it names an object that does not exist, and a store that accepted it would
    /// let a caller write content to an address no deletion pass expects.
    ///
    /// This shape is deliberately not widened in Wave 2. Drawings and imports keep
    /// their legacy addresses and their physical deletes this wave; admitting them
    /// here is a store change with its own real-R2 gate, not a line in a packet
    /// that happens to be editing this file.
    func validateContentKey(_ key: String) throws {
        do { try validate(key: key) } catch { throw PrivateContentStoreError.invalidKey }
        let parts = key.dropFirst(target.namespace.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "media",
              parts[1...3].allSatisfy({ UUID(uuidString: String($0)) != nil && String($0) == String($0).lowercased() }),
              parts[4] == "original" || Self.matches(String(parts[4]), "^view-[a-f0-9]{64}\\.jpg$") else {
            throw PrivateContentStoreError.invalidKey
        }
    }
}

/// The fence store and its wire suite keep their own vocabulary while sharing one
/// loader. These two names are one type; there is no second configuration.
typealias R2ObjectErasureFenceConfiguration = PrivateStorageTargetConfiguration
