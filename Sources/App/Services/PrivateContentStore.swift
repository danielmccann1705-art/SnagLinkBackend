import Vapor
import SotoS3
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Logging

/// The outcome of a create-only PUT. There is no third case: either this call
/// created the object and the provider named it, or the address was already
/// taken and these bytes were not written. "Overwrote" is not expressible.
enum PutOutcome: Sendable, Equatable {
    case created(etag: String)
    case alreadyExists
}

/// What a bounded direct readback actually returned. Constructed only by a store
/// after the bytes have been counted, so `byteCount` and `sha256` describe the
/// body in hand rather than something a provider header claimed.
struct Readback: Sendable, Equatable {
    let target: ObjectStorageWriteTarget
    let key: String
    let body: Data
    let byteCount: Int
    let contentType: String
    let metadata: [String: String]
    let etag: String
    let sha256: String

    init(target: ObjectStorageWriteTarget, key: String, body: Data,
         contentType: String, metadata: [String: String], etag: String) {
        self.target = target; self.key = key; self.body = body; self.byteCount = body.count
        self.contentType = contentType; self.metadata = metadata; self.etag = etag
        self.sha256 = PrivateImageProcessor.digest(body)
    }

    /// True only for the exact erasure fence: no bytes, the erasure content type,
    /// and the marker. A caller that reads an erased object learns that the photo
    /// is gone for good — not that a read failed, and not that the object is
    /// merely empty, which any of the three conditions alone could mean.
    var isErasureFence: Bool {
        byteCount == 0 && body.isEmpty
            && contentType == ObjectErasureFenceService.contentType
            && metadata == ["snaglist-erasure": ObjectErasureFenceService.marker]
    }
}

/// Private image content, and the two fixed properties every such object has.
enum PrivateContent {
    /// The only content MIME types. The erasure MIME is deliberately absent: a
    /// fence is what replaces content, never something a content writer stores.
    static let mimeTypes: Set<String> = ["image/jpeg", "image/png"]
    static let cacheControl = "private, no-store"
    static let maximumBytes = PrivateImageProcessor.maximumBytes
    /// One byte past the largest legal object. Reading to here and failing means
    /// an oversized object is refused rather than silently truncated to the limit
    /// and then treated as if those were all the bytes there ever were.
    static let readCeiling = PrivateImageProcessor.maximumBytes + 1
}

/// The private content boundary. Every method is addressed by a server-computed
/// key in one namespace; none accepts a bucket, endpoint, URL or public address.
protocol PrivateContentStorage: Sendable {
    var target: ObjectStorageWriteTarget { get }
    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome
    func read(key: String, maximumBytes: Int) async throws -> Readback
}

enum PrivateContentStoreError: Error, Equatable {
    case configurationUnavailable, transportUnavailable, invalidKey, invalidContent, invalidReadback
    /// Carried out of the transport so that a refused conditional PUT becomes a
    /// typed outcome decided from the status line, without the provider's error
    /// page ever being collated.
    case alreadyExists
}

/// Writes and reads private image content over the same transport discipline as
/// `R2ObjectErasureFenceStore`: direct R2 only, no retries, no redirects, a
/// bounded deadline, the pinned operation query, and no collated error bodies.
///
/// The one substantive difference from its sibling is the conditional header.
/// Every PUT here carries `If-None-Match: *`, so a writer can only ever create an
/// object. A fence that has replaced a photo cannot be overwritten back into
/// content by a late, retried or duplicated writer — the provider refuses, and
/// the caller is told `alreadyExists` rather than quietly succeeding.
final class R2PrivateContentStore: PrivateContentStorage, Sendable {
    let target: ObjectStorageWriteTarget
    private let configuration: PrivateStorageTargetConfiguration
    private let client: AWSClient
    private let s3: S3
    private let ownedHTTP: HTTPClient?

    static func makeIfConfigured(target: ObjectStorageWriteTarget, environment: Environment,
                                 lookup: (String) -> String? = Environment.get) throws -> R2PrivateContentStore? {
        guard let configuration = try PrivateStorageTargetConfiguration.load(environment: environment, lookup: lookup) else { return nil }
        guard configuration.target == target else { throw PrivateContentStoreError.configurationUnavailable }
        let http = HTTPClient(configuration: .init(redirectConfiguration: .disallow))
        return .init(configuration: configuration, httpClient: http, ownedHTTP: http)
    }
    /// Internal dependency injection exercises the pinned Soto wire contract. It
    /// establishes nothing about R2's own conditional-write behaviour, which only
    /// the real-R2 gate can.
    convenience init(configuration: PrivateStorageTargetConfiguration, httpClient: any AWSHTTPClient) {
        self.init(configuration: configuration, httpClient: httpClient, ownedHTTP: nil)
    }
    private init(configuration: PrivateStorageTargetConfiguration, httpClient: any AWSHTTPClient, ownedHTTP: HTTPClient?) {
        self.configuration = configuration; self.target = configuration.target; self.ownedHTTP = ownedHTTP
        let transport = R2PrivateContentHTTPClient(base: httpClient, configuration: configuration)
        let client = AWSClient(credentialProvider: configuration.credentialProvider,
                               retryPolicy: .noRetry, httpClient: transport)
        self.client = client
        self.s3 = S3(client: client, region: .init(rawValue: "auto"), endpoint: configuration.endpoint,
                     timeout: .seconds(30), options: [.s3DisableChunkedUploads])
    }
    func shutdown() async throws {
        do { try await client.shutdown() }
        catch { if let ownedHTTP { try? await ownedHTTP.shutdown() }; throw PrivateContentStoreError.transportUnavailable }
        if let ownedHTTP { try await ownedHTTP.shutdown() }
    }

    /// Create-only. A refused write is an outcome, not a failure: the caller
    /// learns the address is taken and can decide, but it never learns that from
    /// a body, because none is read.
    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome {
        try configuration.validateContentKey(key)
        guard PrivateContent.mimeTypes.contains(contentType),
              contentType != ObjectErasureFenceService.contentType else { throw PrivateContentStoreError.invalidContent }
        // Bytes must be the image type they are declared to be. A caller cannot
        // store an arbitrary payload under an image MIME in the private bucket.
        do { try PrivateImageProcessor.validateSignature(data, mime: contentType) }
        catch { throw PrivateContentStoreError.invalidContent }
        do {
            let result = try await s3.putObject(.init(
                body: .init(buffer: ByteBuffer(data: data)), bucket: target.bucket,
                cacheControl: PrivateContent.cacheControl, contentLength: Int64(data.count),
                contentType: contentType, ifNoneMatch: "*", key: key))
            try Task.checkCancellation()
            guard let etag = result.eTag, !etag.isEmpty, etag.utf8.count <= 512 else { throw PrivateContentStoreError.invalidReadback }
            return .created(etag: etag)
        } catch is CancellationError { throw CancellationError() }
        catch PrivateContentStoreError.alreadyExists { return .alreadyExists }
        catch { throw PrivateContentStoreError.transportUnavailable }
    }

    /// Bounded direct readback. Returns content, or the fence that replaced it,
    /// and refuses everything else including its own provider's malformed replies.
    func read(key: String, maximumBytes: Int) async throws -> Readback {
        try configuration.validateContentKey(key)
        guard maximumBytes > 0, maximumBytes <= PrivateContent.maximumBytes else { throw PrivateContentStoreError.invalidContent }
        do {
            let result = try await s3.getObject(.init(bucket: target.bucket, key: key))
            try Task.checkCancellation()
            guard let etag = result.eTag, !etag.isEmpty, etag.utf8.count <= 512,
                  let contentType = result.contentType,
                  let declared = result.contentLength, declared >= 0,
                  declared <= Int64(maximumBytes) else { throw PrivateContentStoreError.invalidReadback }
            let metadata = result.metadata ?? [:]
            let fenced = contentType == ObjectErasureFenceService.contentType
            if fenced {
                guard declared == 0, metadata == ["snaglist-erasure": ObjectErasureFenceService.marker] else { throw PrivateContentStoreError.invalidReadback }
            } else {
                guard PrivateContent.mimeTypes.contains(contentType), declared > 0, metadata.isEmpty else { throw PrivateContentStoreError.invalidReadback }
            }
            // The transport already bounded and counted every chunk. Do not use
            // AWSHTTPBody.collect(upTo:), which returns a buffered body whole and
            // ignores the bound entirely, so an oversized object would arrive
            // having already been held in memory.
            var body = Data()
            for try await chunk in result.body {
                try Task.checkCancellation()
                body.append(contentsOf: chunk.readableBytesView)
                guard body.count <= maximumBytes, body.count <= PrivateContent.readCeiling,
                      Int64(body.count) <= declared else { throw PrivateContentStoreError.invalidReadback }
            }
            guard Int64(body.count) == declared else { throw PrivateContentStoreError.invalidReadback }
            if fenced {
                guard body.isEmpty else { throw PrivateContentStoreError.invalidReadback }
            } else {
                guard PrivateImageProcessor.detectMime(body) == contentType else { throw PrivateContentStoreError.invalidReadback }
            }
            return .init(target: target, key: key, body: body, contentType: contentType, metadata: metadata, etag: etag)
        } catch is CancellationError { throw CancellationError() }
        catch { throw PrivateContentStoreError.transportUnavailable }
    }
}

/// Intercepts before Soto's error/body collation. It admits only the exact direct
/// R2 authority, requires the create-only header on every PUT, bounds what it will
/// read back, and turns a refused conditional write into a typed error without
/// touching the provider's response body.
struct R2PrivateContentHTTPClient: AWSHTTPClient {
    let base: any AWSHTTPClient
    let configuration: PrivateStorageTargetConfiguration
    func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
        // The pinned Soto API includes this exact operation identifier in the
        // signed URL. Preserve it byte-for-byte; permit no caller query options.
        let expectedQuery = request.method == .PUT ? "x-id=PutObject" : "x-id=GetObject"
        guard timeout.nanoseconds > 0, timeout.nanoseconds <= 30_000_000_000,
              request.url.scheme == "https", request.url.host == "\(configuration.target.backendIdentity).r2.cloudflarestorage.com",
              request.url.port == nil, request.url.user == nil, request.url.password == nil,
              URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery == expectedQuery,
              request.url.fragment == nil,
              request.method == .PUT || request.method == .GET else { throw PrivateContentStoreError.invalidKey }
        let prefix = "/\(configuration.target.bucket)/"
        guard request.url.path.hasPrefix(prefix) else { throw PrivateContentStoreError.invalidKey }
        let key = String(request.url.path.dropFirst(prefix.count))
        try configuration.validateContentKey(key)
        guard URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath == prefix + key,
              request.headers["if-match"].isEmpty, request.headers["range"].isEmpty else { throw PrivateContentStoreError.invalidKey }
        if request.method == .PUT {
            // Every content PUT is conditional. There is no unconditional content
            // writer on this transport, so no writer here can replace a fence.
            guard request.headers["if-none-match"] == ["*"],
                  request.headers["cache-control"] == [PrivateContent.cacheControl],
                  request.headers["content-type"].count == 1,
                  let contentType = request.headers.first(name: "content-type"),
                  PrivateContent.mimeTypes.contains(contentType),
                  request.headers["content-length"].count == 1,
                  let declaredHeader = request.headers.first(name: "content-length"),
                  let declared = Int(declaredHeader), declared > 0, declared <= PrivateContent.maximumBytes,
                  request.headers["content-encoding"].isEmpty,
                  let requestMetadata = userMetadata(request.headers), requestMetadata.isEmpty,
                  // Content is a bounded in-memory image, so the body is replayable
                  // and can be counted here before it is forwarded.
                  !request.body.isStreaming else { throw PrivateContentStoreError.invalidContent }
            var sent = 0
            for try await chunk in request.body {
                try Task.checkCancellation()
                sent += chunk.readableBytes
                guard sent <= declared else { throw PrivateContentStoreError.invalidContent }
            }
            guard sent == declared else { throw PrivateContentStoreError.invalidContent }
        } else {
            guard request.headers["if-none-match"].isEmpty else { throw PrivateContentStoreError.invalidKey }
        }
        return try await withThrowingTaskGroup(of: AWSHTTPResponse.self) { group in
            group.addTask {
                let response = try await base.execute(request: request, timeout: timeout, logger: AWSClient.loggingDisabled)
                // A refused create is decided from the status line alone, before
                // any of the branches below could read, collate or log a body.
                if request.method == .PUT, response.status == .preconditionFailed {
                    throw PrivateContentStoreError.alreadyExists
                }
                // Never collate an error/redirect page, and never follow a public
                // cache URL. The production HTTPClient has redirects disabled.
                guard response.status == .ok, response.headers["etag"].count == 1,
                      let etag = response.headers.first(name: "etag"), !etag.isEmpty, etag.utf8.count <= 512,
                      response.headers["content-encoding"].isEmpty, response.headers["content-range"].isEmpty,
                      response.headers["content-disposition"].isEmpty, response.headers["content-language"].isEmpty else {
                    throw PrivateContentStoreError.transportUnavailable
                }
                if request.method == .PUT {
                    guard response.headers["content-length"].isEmpty || response.headers["content-length"] == ["0"] else {
                        throw PrivateContentStoreError.invalidContent
                    }
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        guard chunk.readableBytes == 0 else { throw PrivateContentStoreError.invalidContent }
                    }
                    return .init(status: response.status, headers: response.headers, body: .init())
                }
                // A GET returns one of exactly two shapes: content, or the fence
                // that replaced it. Anything else is refused before it is read.
                guard response.headers["cache-control"] == [PrivateContent.cacheControl],
                      response.headers["content-type"].count == 1,
                      let contentType = response.headers.first(name: "content-type"),
                      response.headers["content-length"].count == 1,
                      let declaredHeader = response.headers.first(name: "content-length"),
                      let declared = Int(declaredHeader), declared >= 0, declared <= PrivateContent.maximumBytes,
                      let responseMetadata = userMetadata(response.headers) else { throw PrivateContentStoreError.invalidContent }
                if contentType == ObjectErasureFenceService.contentType {
                    guard declared == 0,
                          responseMetadata == ["snaglist-erasure": ObjectErasureFenceService.marker] else { throw PrivateContentStoreError.invalidContent }
                } else {
                    guard PrivateContent.mimeTypes.contains(contentType), declared > 0,
                          responseMetadata.isEmpty else { throw PrivateContentStoreError.invalidContent }
                }
                var collected = ByteBuffer()
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    var chunk = chunk
                    collected.writeBuffer(&chunk)
                    // The first chunk that takes the object past either bound ends
                    // the read. A provider that under-declares its own length does
                    // not get to stream an unbounded body through this seam.
                    guard collected.readableBytes <= PrivateContent.readCeiling,
                          collected.readableBytes <= declared else { throw PrivateContentStoreError.invalidContent }
                }
                guard collected.readableBytes == declared else { throw PrivateContentStoreError.invalidContent }
                return .init(status: response.status, headers: response.headers, body: .init(buffer: collected))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
                throw PrivateContentStoreError.transportUnavailable
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw PrivateContentStoreError.transportUnavailable }
            return response
        }
    }
    private func userMetadata(_ headers: HTTPHeaders) -> [String: String]? {
        var result: [String: String] = [:]
        for header in headers where header.name.lowercased().hasPrefix("x-amz-meta-") {
            let name = String(header.name.lowercased().dropFirst("x-amz-meta-".count))
            guard result[name] == nil else { return nil }
            result[name] = header.value
        }
        return result
    }
}

/// The one place anything obtains a private content store.
///
/// The same two rules as `AccountDeletionFenceProvider`, for the same reason. One
/// immutable server configuration produces one store for one exact target, and a
/// request for any other target is refused. And there is no fallback: a missing or
/// mismatched store is an error, never a legacy writer, never the public bucket,
/// never local disk. Falling back would put a customer's photograph somewhere the
/// deletion pass does not know to look, which is the whole failure this boundary
/// exists to make impossible.
enum PrivateContentStoreProvider {

    /// A store injected by a test. Honoured only under `.testing`; in any other
    /// environment its presence is ignored entirely rather than trusted.
    struct InjectionKey: StorageKey { typealias Value = any PrivateContentStorage }

    private struct LiveKey: StorageKey { typealias Value = R2PrivateContentStore }

    enum Failure: Error, Equatable { case unavailable }

    /// Returns the store that owns `target`, or throws. Never returns a store for a
    /// different target, and never constructs one from anything the caller supplied.
    static func store(for target: ObjectStorageWriteTarget, app: Application) throws -> any PrivateContentStorage {
        guard target.writeProtocol == .createOnlyV1 else { throw Failure.unavailable }
        if app.environment == .testing, let injected = app.storage[InjectionKey.self] {
            guard injected.target == target else { throw Failure.unavailable }
            return injected
        }
        if let live = app.storage[LiveKey.self] {
            guard live.target == target else { throw Failure.unavailable }
            return live
        }
        guard let store = try? R2PrivateContentStore.makeIfConfigured(target: target, environment: app.environment),
              store.target == target else { throw Failure.unavailable }
        // One store per process for one target. Built once so a pass does not open
        // an HTTP client per key, and owned here so shutdown has somewhere to run.
        app.storage[LiveKey.self] = store
        return store
    }

    /// Called from the application's shutdown path, beside the other clients. A
    /// store that was never built has nothing to close.
    static func shutdown(app: Application) async {
        guard let live = app.storage[LiveKey.self] else { return }
        app.storage[LiveKey.self] = nil
        try? await live.shutdown()
    }
}
