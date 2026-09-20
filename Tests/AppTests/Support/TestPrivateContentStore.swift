@testable import App
import Vapor
import Foundation

/// An in-memory private content store for packets that need one without a
/// network. It is create-only like the store it stands in for — an address that
/// is taken stays taken, including when a fence has taken it — and it validates
/// keys through the real `PrivateStorageTargetConfiguration`, so a caller cannot
/// pass a test here that production would refuse.
///
/// Every call is recorded. A test asserts what a caller actually did, not merely
/// that nothing threw.
actor TestPrivateContentStore: PrivateContentStorage {

    enum Call: Sendable, Equatable {
        case put(key: String, byteCount: Int, contentType: String)
        case read(key: String, maximumBytes: Int)
    }

    struct Object: Sendable, Equatable {
        var data: Data
        var contentType: String
        var metadata: [String: String]
        var etag: String
    }

    nonisolated let configuration: PrivateStorageTargetConfiguration
    nonisolated var target: ObjectStorageWriteTarget { configuration.target }

    private var calls: [Call] = []
    private var objects: [String: Object] = [:]
    private var putFailure: (any Error)?
    private var readFailure: (any Error)?

    init(configuration: PrivateStorageTargetConfiguration) { self.configuration = configuration }

    /// The synthetic target the wire suites use, produced by the real loader so
    /// the fake and the real store cannot disagree about what a valid target is.
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
                          bucket: String = "synthetic-private") throws -> TestPrivateContentStore {
        .init(configuration: try syntheticConfiguration(namespace: namespace, bucket: bucket))
    }

    // MARK: key shapes

    nonisolated func originalKey(project: UUID = UUID(), snag: UUID = UUID(), asset: UUID = UUID()) -> String {
        "\(target.namespace)media/\(project.uuidString.lowercased())/\(snag.uuidString.lowercased())/\(asset.uuidString.lowercased())/original"
    }
    nonisolated func renditionKey(for original: String, sha256: String) -> String {
        String(original.dropLast("original".count)) + "view-\(sha256).jpg"
    }
    /// The placeholder a media row carries from allocation onwards. It is here so
    /// a test can show that it is refused, never so that anything can write to it.
    nonisolated func placeholderKey(for original: String) -> String {
        String(original.dropLast("original".count)) + "view.jpg"
    }

    // MARK: observation

    func recordedCalls() -> [Call] { calls }
    func object(at key: String) -> Object? { objects[key] }
    func failNextPut(with error: any Error) { putFailure = error }
    func failNextRead(with error: any Error) { readFailure = error }

    /// Places an object without going through `put`, for a test that needs content
    /// — or a fence — to exist already. Not recorded as a call.
    @discardableResult
    func seed(key: String, data: Data, contentType: String, metadata: [String: String] = [:]) throws -> String {
        try configuration.validateContentKey(key)
        let etag = "\"test-\(objects.count)-\(data.count)\""
        objects[key] = .init(data: data, contentType: contentType, metadata: metadata, etag: etag)
        return etag
    }
    @discardableResult
    func seedErasureFence(key: String) throws -> String {
        try seed(key: key, data: Data(), contentType: ObjectErasureFenceService.contentType,
                 metadata: ["snaglist-erasure": ObjectErasureFenceService.marker])
    }

    // MARK: PrivateContentStorage

    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome {
        calls.append(.put(key: key, byteCount: data.count, contentType: contentType))
        if let putFailure { self.putFailure = nil; throw putFailure }
        try configuration.validateContentKey(key)
        guard PrivateContent.mimeTypes.contains(contentType), contentType != ObjectErasureFenceService.contentType,
              !data.isEmpty, data.count <= PrivateContent.maximumBytes else { throw PrivateContentStoreError.invalidContent }
        guard objects[key] == nil else { return .alreadyExists }
        let etag = try seed(key: key, data: data, contentType: contentType)
        return .created(etag: etag)
    }

    func read(key: String, maximumBytes: Int) async throws -> Readback {
        calls.append(.read(key: key, maximumBytes: maximumBytes))
        if let readFailure { self.readFailure = nil; throw readFailure }
        try configuration.validateContentKey(key)
        guard maximumBytes > 0, maximumBytes <= PrivateContent.maximumBytes else { throw PrivateContentStoreError.invalidContent }
        guard let object = objects[key] else { throw PrivateContentStoreError.transportUnavailable }
        guard object.data.count <= maximumBytes else { throw PrivateContentStoreError.invalidReadback }
        return .init(target: target, key: key, body: object.data, contentType: object.contentType,
                     metadata: object.metadata, etag: object.etag)
    }
}
