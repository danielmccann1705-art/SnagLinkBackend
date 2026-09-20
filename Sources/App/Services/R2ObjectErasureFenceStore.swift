import Vapor
import SotoS3
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Logging

/// This store's configuration is `PrivateStorageTargetConfiguration` (see
/// PrivateStorageTarget.swift), which the private content store is built from
/// too. One loader, one target: the fence and the content it fences cannot drift
/// onto different buckets or namespaces, because there is nothing to drift from.

enum R2ObjectErasureFenceError: Error { case configurationUnavailable, transportUnavailable, invalidFence }

/// Unwired and off by default. The caller owns shutdown, including when a future
/// worker is cancelled. There is no public URL, disk, default bucket or HEAD path.
final class R2ObjectErasureFenceStore: ObjectErasureFenceStorage, Sendable {
    let target: ObjectStorageWriteTarget
    private let configuration: R2ObjectErasureFenceConfiguration
    private let client: AWSClient
    private let s3: S3
    private let ownedHTTP: HTTPClient?

    static func makeIfEnabled(target: ObjectStorageWriteTarget, environment: Environment,
                              lookup: (String) -> String? = Environment.get) throws -> R2ObjectErasureFenceStore? {
        guard let configuration = try R2ObjectErasureFenceConfiguration.load(environment: environment, lookup: lookup) else { return nil }
        guard configuration.target == target else { throw R2ObjectErasureFenceError.configurationUnavailable }
        let http = HTTPClient(configuration: .init(redirectConfiguration: .disallow))
        return .init(configuration: configuration, httpClient: http, ownedHTTP: http)
    }
    /// Internal dependency injection exercises the pinned Soto wire contract,
    /// not a model claiming to establish R2 atomicity or remote acceptance.
    init(configuration: R2ObjectErasureFenceConfiguration, httpClient: any AWSHTTPClient) {
        self.configuration = configuration; self.target = configuration.target; self.ownedHTTP = nil
        let transport = R2ObjectErasureFenceHTTPClient(base: httpClient, configuration: configuration)
        let client = AWSClient(credentialProvider: configuration.credentialProvider,
                               retryPolicy: .noRetry, httpClient: transport)
        self.client = client
        self.s3 = S3(client: client, region: .init(rawValue: "auto"), endpoint: configuration.endpoint, timeout: .seconds(30), options: [.s3DisableChunkedUploads])
    }
    private init(configuration: R2ObjectErasureFenceConfiguration, httpClient: HTTPClient, ownedHTTP: HTTPClient) {
        self.configuration = configuration; self.target = configuration.target; self.ownedHTTP = ownedHTTP
        let transport = R2ObjectErasureFenceHTTPClient(base: httpClient, configuration: configuration)
        let client = AWSClient(credentialProvider: configuration.credentialProvider,
                               retryPolicy: .noRetry, httpClient: transport)
        self.client = client
        self.s3 = S3(client: client, region: .init(rawValue: "auto"), endpoint: configuration.endpoint, timeout: .seconds(30), options: [.s3DisableChunkedUploads])
    }
    func shutdown() async throws {
        do { try await client.shutdown() }
        catch { if let ownedHTTP { try? await ownedHTTP.shutdown() }; throw R2ObjectErasureFenceError.transportUnavailable }
        if let ownedHTTP { try await ownedHTTP.shutdown() }
    }
    func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String {
        try configuration.validate(key: key)
        guard contentType == ObjectErasureFenceService.contentType,
              metadata == ["snaglist-erasure": ObjectErasureFenceService.marker] else { throw R2ObjectErasureFenceError.invalidFence }
        do {
            // Deliberately unconditional. All writers for this exact physical key
            // must already be proven create-only by the database authority layer.
            let result = try await s3.putObject(.init(body: .init(), bucket: target.bucket,
                cacheControl: "private, no-store", contentLength: 0, contentType: contentType, key: key, metadata: metadata))
            try Task.checkCancellation()
            guard let etag = result.eTag, !etag.isEmpty, etag.utf8.count <= 512 else { throw R2ObjectErasureFenceError.invalidFence }
            return etag
        } catch is CancellationError { throw CancellationError() }
        catch { throw R2ObjectErasureFenceError.transportUnavailable }
    }
    func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback {
        try configuration.validate(key: key)
        guard maximumBytes == 1 else { throw R2ObjectErasureFenceError.invalidFence }
        do {
            let result = try await s3.getObject(.init(bucket: target.bucket, key: key))
            try Task.checkCancellation()
            guard result.contentLength == 0, result.contentType == ObjectErasureFenceService.contentType,
                  result.metadata == ["snaglist-erasure": ObjectErasureFenceService.marker],
                  let etag = result.eTag, !etag.isEmpty, etag.utf8.count <= 512 else { throw R2ObjectErasureFenceError.invalidFence }
            // The transport already consumed and checked every chunk. Do not use
            // AWSHTTPBody.collect(upTo:), which ignores the bound for buffered bodies.
            for try await chunk in result.body { guard chunk.readableBytes == 0 else { throw R2ObjectErasureFenceError.invalidFence } }
            return .init(target: target, key: key, body: Data(), byteCount: 0,
                         contentType: ObjectErasureFenceService.contentType,
                         metadata: ["snaglist-erasure": ObjectErasureFenceService.marker], etag: etag)
        } catch is CancellationError { throw CancellationError() }
        catch { throw R2ObjectErasureFenceError.transportUnavailable }
    }
}

/// Intercepts before Soto's error/body collation. It admits only the exact direct
/// R2 authority and consumes no retained content: the first nonempty chunk fails.
struct R2ObjectErasureFenceHTTPClient: AWSHTTPClient {
    let base: any AWSHTTPClient
    let configuration: R2ObjectErasureFenceConfiguration
    func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
        // The pinned Soto API includes this exact operation identifier in the
        // signed URL. Preserve it byte-for-byte; permit no caller query options.
        let expectedQuery = request.method == .PUT ? "x-id=PutObject" : "x-id=GetObject"
        guard timeout.nanoseconds > 0, timeout.nanoseconds <= 30_000_000_000,
              request.url.scheme == "https", request.url.host == "\(configuration.target.backendIdentity).r2.cloudflarestorage.com",
              request.url.port == nil, request.url.user == nil, request.url.password == nil,
              URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery == expectedQuery,
              request.url.fragment == nil,
              request.method == .PUT || request.method == .GET else { throw R2ObjectErasureFenceError.invalidFence }
        let prefix = "/\(configuration.target.bucket)/"
        guard request.url.path.hasPrefix(prefix) else { throw R2ObjectErasureFenceError.invalidFence }
        let key = String(request.url.path.dropFirst(prefix.count))
        try configuration.validate(key: key)
        guard URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath == prefix + key,
              request.headers["if-match"].isEmpty, request.headers["if-none-match"].isEmpty,
              request.headers["range"].isEmpty else { throw R2ObjectErasureFenceError.invalidFence }
        if request.method == .PUT {
            guard request.headers["content-length"] == ["0"],
                  request.headers["content-type"] == [ObjectErasureFenceService.contentType],
                  request.headers["cache-control"] == ["private, no-store"],
                  metadata(request.headers) == ["snaglist-erasure": ObjectErasureFenceService.marker],
                  request.headers["content-encoding"].isEmpty else { throw R2ObjectErasureFenceError.invalidFence }
        }
        for try await chunk in request.body { guard chunk.readableBytes == 0 else { throw R2ObjectErasureFenceError.invalidFence } }
        return try await withThrowingTaskGroup(of: AWSHTTPResponse.self) { group in
            group.addTask {
                let response = try await base.execute(request: request, timeout: timeout, logger: AWSClient.loggingDisabled)
                // Never collate an error/redirect page, and never follow a public
                // cache URL. The production HTTPClient has redirects disabled.
                guard response.status == .ok, response.headers["etag"].count == 1,
                      let etag = response.headers.first(name: "etag"), !etag.isEmpty, etag.utf8.count <= 512,
                      response.headers["content-encoding"].isEmpty, response.headers["content-range"].isEmpty else {
                    throw R2ObjectErasureFenceError.transportUnavailable
                }
                if request.method == .GET {
                    guard response.headers["content-length"] == ["0"],
                          response.headers["content-type"] == [ObjectErasureFenceService.contentType],
                          response.headers["cache-control"] == ["private, no-store"],
                          metadata(response.headers) == ["snaglist-erasure": ObjectErasureFenceService.marker],
                          response.headers["content-disposition"].isEmpty,
                          response.headers["content-language"].isEmpty else { throw R2ObjectErasureFenceError.invalidFence }
                } else {
                    guard response.headers["content-length"].isEmpty || response.headers["content-length"] == ["0"] else {
                        throw R2ObjectErasureFenceError.invalidFence
                    }
                }
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    guard chunk.readableBytes == 0 else { throw R2ObjectErasureFenceError.invalidFence }
                }
                return .init(status: response.status, headers: response.headers, body: .init())
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
                throw R2ObjectErasureFenceError.transportUnavailable
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw R2ObjectErasureFenceError.transportUnavailable }
            return response
        }
    }
    private func metadata(_ headers: HTTPHeaders) -> [String: String]? {
        var result: [String: String] = [:]
        for header in headers where header.name.lowercased().hasPrefix("x-amz-meta-") {
            let name = String(header.name.lowercased().dropFirst("x-amz-meta-".count))
            guard result[name] == nil else { return nil }
            result[name] = header.value
        }
        return result
    }
}
