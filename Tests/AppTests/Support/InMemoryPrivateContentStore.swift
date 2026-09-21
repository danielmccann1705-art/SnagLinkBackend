@testable import App
import Vapor
import Foundation

/// One in-memory object store for one target, standing in for R2 on both sides of
/// a private photograph's life: the content store that writes it and the erasure
/// fence that replaces it. Three packets are written against this type, so what it
/// models has to be the real asymmetry rather than a convenient one.
///
/// **The asymmetry.** A content `put` is create-only: an address that is taken
/// stays taken, and a fence has taken it for good. A fence write is deliberately
/// unconditional: it replaces whatever is there, which is the whole mechanism by
/// which a photograph becomes permanently unreadable. Both halves are here, on one
/// dictionary of objects, so a test cannot accidentally let a content write land
/// on a fenced key — if that ever became possible here, a packet's tests would go
/// green while the thing they describe was broken.
///
/// Keys are validated through the real `PrivateStorageTargetConfiguration`: the
/// narrow content shape for `put`/`read`, the wider fence shape for
/// `replaceWithEmptyFence`/`readFence`, exactly as the two real stores do. A
/// caller cannot pass a test here that production would refuse.
///
/// Every call is recorded, so a test asserts what a caller actually did — not
/// merely that nothing threw. Nothing here talks to a network.
actor InMemoryPrivateContentStore: PrivateContentStorage, ObjectErasureFenceStorage {

    /// One entry per call that reached the store, in order, including the calls
    /// that then failed. A test that must show storage was never reached asserts
    /// on emptiness; a test that must show a readback happened asserts on shape.
    enum Call: Sendable, Equatable {
        case put(key: String, byteCount: Int, contentType: String)
        case read(key: String, maximumBytes: Int)
        case fence(key: String)
        case readFence(key: String, maximumBytes: Int)
    }

    struct Object: Sendable, Equatable {
        var data: Data
        var contentType: String
        var metadata: [String: String]
        var etag: String
        /// The same three conditions `Readback.isErasureFence` requires. An empty
        /// object is not a fence, and neither is a fence-typed object with bytes.
        var isErasureFence: Bool {
            data.isEmpty && contentType == ObjectErasureFenceService.contentType
                && metadata == ["snaglist-erasure": ObjectErasureFenceService.marker]
        }
    }

    nonisolated let configuration: PrivateStorageTargetConfiguration
    nonisolated var target: ObjectStorageWriteTarget { configuration.target }

    private var calls: [Call] = []
    private var objects: [String: Object] = [:]
    private var written = 0
    private var putFailure: (any Error)?
    private var readFailure: (any Error)?
    private var dropPutResponse = false

    init(configuration: PrivateStorageTargetConfiguration) { self.configuration = configuration }

    /// Built by the real loader, so the double and the real stores cannot disagree
    /// about what a valid target is.
    static func syntheticConfiguration(namespace: String = "immutable-v1/",
                                       bucket: String = "synthetic-private") throws -> PrivateStorageTargetConfiguration {
        let values = ["R2_PRIVATE_NAMESPACE": namespace, "R2_ACCOUNT_ID": String(repeating: "a", count: 32),
                      "R2_PRIVATE_BUCKET_NAME": bucket, "R2_BUCKET_NAME": "synthetic-public",
                      "R2_ACCESS_KEY_ID": "synthetic-key", "R2_SECRET_ACCESS_KEY": "synthetic-secret"]
        guard let configuration = try PrivateStorageTargetConfiguration.load(environment: .testing, lookup: { values[$0] }) else {
            throw PrivateContentStoreError.configurationUnavailable
        }
        return configuration
    }
    static func synthetic(namespace: String = "immutable-v1/",
                          bucket: String = "synthetic-private") throws -> InMemoryPrivateContentStore {
        .init(configuration: try syntheticConfiguration(namespace: namespace, bucket: bucket))
    }

    // MARK: key shapes

    nonisolated func originalKey(project: UUID = UUID(), snag: UUID = UUID(), asset: UUID = UUID()) -> String {
        "\(target.namespace)media/\(project.uuidString.lowercased())/\(snag.uuidString.lowercased())/\(asset.uuidString.lowercased())/original"
    }
    nonisolated func renditionKey(for original: String, sha256: String) -> String {
        String(original.dropLast("original".count)) + "view-\(sha256).jpg"
    }
    /// The allocation placeholder. Here so a test can show it is refused, never so
    /// that anything can write to it.
    nonisolated func placeholderKey(for original: String) -> String {
        String(original.dropLast("original".count)) + "view.jpg"
    }

    // MARK: observation

    func recordedCalls() -> [Call] { calls }
    func object(at key: String) -> Object? { objects[key] }
    func isFenced(_ key: String) -> Bool { objects[key]?.isErasureFence == true }

    // MARK: controls

    /// The next content `put` throws and stores nothing. With the default error
    /// this is a PUT whose request never reached storage: paired with a readback
    /// that finds nothing, it is the fixture for "the write never landed".
    func failNextPut(with error: any Error = PrivateContentStoreError.transportUnavailable) { putFailure = error }

    /// The next content `read` throws. Default: storage did not answer.
    func failNextRead(with error: any Error = PrivateContentStoreError.transportUnavailable) { readFailure = error }

    /// The next content `put` is performed — create-only rules and all — and then
    /// loses its response: the caller sees `transportUnavailable` while the bytes
    /// are there afterwards. This is the only way to build the case where a PUT
    /// reports a transport failure and the readback finds the caller's own bytes,
    /// and it is deliberately not the same control as `failNextPut`.
    ///
    /// A dropped response over an address that was already taken stores nothing,
    /// because the real provider would have refused that write before the response
    /// was lost.
    func dropNextPutResponse() { dropPutResponse = true }

    /// Places content without going through `put`, for a test that needs an object
    /// to exist already. Not recorded as a call.
    @discardableResult
    func seedContent(key: String, data: Data, contentType: String = "image/jpeg") throws -> String {
        try configuration.validateContentKey(key)
        return place(key: key, data: data, contentType: contentType, metadata: [:])
    }

    /// Places the exact erasure fence at a key, as a completed deletion pass would.
    /// Validated with the fence store's own wider key rule, because a fence may
    /// replace any object this target holds. Not recorded as a call.
    @discardableResult
    func seedErasureFence(key: String) throws -> String {
        try configuration.validate(key: key)
        return place(key: key, data: Data(), contentType: ObjectErasureFenceService.contentType,
                     metadata: ["snaglist-erasure": ObjectErasureFenceService.marker])
    }

    /// Every object this double stores gets a distinct etag. **Real storage does
    /// not**: B5a measured R2 against a live bucket and found that every fence
    /// carries the same ETag, because R2 answers a zero-byte object with the MD5
    /// of the empty string. The conclusion the old comment drew still holds — a
    /// fence's etag cannot collide with the etag of the content it replaced — but
    /// only because content is never empty, not because storage hands out
    /// distinct etags.
    ///
    /// Two rules follow, and they are about tests rather than about this type. No
    /// test may assert that two fences have distinct etags: on R2 they do not. And
    /// no "is this the fence I placed" check may be written against an ETag: on R2
    /// that comparison is true of every fence in the bucket, so it would identify
    /// nothing. The distinctness below is an artefact of the counter, kept only so
    /// a test can tell a fence from the content it replaced.
    private func place(key: String, data: Data, contentType: String, metadata: [String: String]) -> String {
        written += 1
        let etag = "\"memory-\(written)\""
        objects[key] = .init(data: data, contentType: contentType, metadata: metadata, etag: etag)
        return etag
    }

    // MARK: PrivateContentStorage

    /// Create-only, without exception. What is taken is the address, not the
    /// bytes: a fence holds its key against every later content writer, and that
    /// refusal is an outcome rather than an error.
    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome {
        calls.append(.put(key: key, byteCount: data.count, contentType: contentType))
        if let putFailure { self.putFailure = nil; self.dropPutResponse = false; throw putFailure }
        try configuration.validateContentKey(key)
        guard PrivateContent.mimeTypes.contains(contentType),
              contentType != ObjectErasureFenceService.contentType else { throw PrivateContentStoreError.invalidContent }
        // Bytes must be the image type they are declared to be, as the real store
        // requires, so a fixture of arbitrary bytes cannot pass here and fail there.
        do { try PrivateImageProcessor.validateSignature(data, mime: contentType) }
        catch { throw PrivateContentStoreError.invalidContent }
        let outcome: PutOutcome
        if objects[key] == nil {
            outcome = .created(etag: place(key: key, data: data, contentType: contentType, metadata: [:]))
        } else {
            outcome = .alreadyExists
        }
        if dropPutResponse { dropPutResponse = false; throw PrivateContentStoreError.transportUnavailable }
        return outcome
    }

    /// Content, the exact fence that replaced it, or `absent`. Absence is what an
    /// empty address answers; it is never what a failure answers.
    func read(key: String, maximumBytes: Int) async throws -> Readback {
        calls.append(.read(key: key, maximumBytes: maximumBytes))
        if let readFailure { self.readFailure = nil; throw readFailure }
        try configuration.validateContentKey(key)
        guard maximumBytes > 0, maximumBytes <= PrivateContent.maximumBytes else { throw PrivateContentStoreError.invalidContent }
        guard let object = objects[key] else { throw PrivateContentStoreError.absent }
        guard object.data.count <= maximumBytes else { throw PrivateContentStoreError.invalidReadback }
        return .init(target: target, key: key, body: object.data, contentType: object.contentType,
                     metadata: object.metadata, etag: object.etag)
    }

    // MARK: ObjectErasureFenceStorage

    /// Deliberately unconditional, exactly as `R2ObjectErasureFenceStore` is: the
    /// fence replaces whatever is at the key. Every writer of this physical key is
    /// already proven create-only by the database authority layer, which is what
    /// makes the asymmetry safe rather than merely convenient.
    func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String {
        calls.append(.fence(key: key))
        try configuration.validate(key: key)
        guard contentType == ObjectErasureFenceService.contentType,
              metadata == ["snaglist-erasure": ObjectErasureFenceService.marker] else { throw R2ObjectErasureFenceError.invalidFence }
        return place(key: key, data: Data(), contentType: contentType, metadata: metadata)
    }

    /// The bounded fence readback. A key holding something that is not the exact
    /// fence is a refusal, and a key holding nothing is a transport failure —
    /// `absent` is the content store's word and the fence store has no such answer.
    func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback {
        calls.append(.readFence(key: key, maximumBytes: maximumBytes))
        try configuration.validate(key: key)
        guard maximumBytes == 1 else { throw R2ObjectErasureFenceError.invalidFence }
        guard let object = objects[key] else { throw R2ObjectErasureFenceError.transportUnavailable }
        guard object.isErasureFence else { throw R2ObjectErasureFenceError.invalidFence }
        return .init(target: target, key: key, body: Data(), byteCount: 0,
                     contentType: ObjectErasureFenceService.contentType,
                     metadata: ["snaglist-erasure": ObjectErasureFenceService.marker], etag: object.etag)
    }
}
