@testable import App
import XCTest
import Vapor
import SotoS3
import NIOCore
import NIOHTTP1
import Logging

/// The real pinned Soto encoder/signer runs over a fake HTTP transport with no
/// sockets. These tests establish nothing about R2's own conditional-write
/// behaviour — only the real-R2 gate can — but they do establish what this
/// process puts on the wire, and what it refuses to accept back.
final class PrivateContentStoreTests: XCTestCase {

    actor HTTP: AWSHTTPClient {
        enum Mode: Sendable {
            case normal, alreadyExists, lostPUT, redirect, error, stalled, putEchoesBody
            case fence, fenceWithBytes, fenceWithoutMarker
            case missingETag, duplicateETag, wrongCacheControl, foreignMIME, contentWithMetadata
            case mislabelledBytes, overDeclared, underDeclared, oversizedDeclaration
            case contentEncoding, contentRange
        }
        let account = String(repeating: "a", count: 32)
        let allowedPaths: Set<String>
        var mode: Mode = .normal
        var payload = Data()
        var methods: [String] = []
        var paths: [String] = []
        var conditional: [[String]] = []
        var putBytes: [Int] = []
        var putContentTypes: [String] = []
        var wireValid = true
        struct Failure: Error {}
        struct Snapshot: Sendable {
            var methods: [String]; var paths: [String]; var conditional: [[String]]
            var putBytes: [Int]; var putContentTypes: [String]; var valid: Bool
        }
        init(allowedPaths: Set<String>) { self.allowedPaths = allowedPaths }
        func set(_ mode: Mode) { self.mode = mode }
        func setPayload(_ data: Data) { payload = data }
        func snapshot() -> Snapshot {
            .init(methods: methods, paths: paths, conditional: conditional,
                  putBytes: putBytes, putContentTypes: putContentTypes, valid: wireValid)
        }
        func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
            methods.append(request.method.rawValue); paths.append(request.url.path)
            conditional.append(request.headers["if-none-match"])
            wireValid = wireValid && request.url.host == "\(account).r2.cloudflarestorage.com"
                && allowedPaths.contains(request.url.path)
                && request.headers.first(name: "authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true
                && request.headers["if-match"].isEmpty && request.headers["range"].isEmpty
                && URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                    == (request.method == .PUT ? "x-id=PutObject" : "x-id=GetObject")
            var bytes = 0
            for try await chunk in request.body { bytes += chunk.readableBytes }
            if request.method == .PUT {
                putBytes.append(bytes)
                putContentTypes.append(request.headers.first(name: "content-type") ?? "")
                // The claim this suite exists to keep honest: every content PUT
                // that reaches a provider carries the create-only condition.
                let sentType: String = request.headers.first(name: "content-type") ?? ""
                let sentMetadata = request.headers.filter { $0.name.lowercased().hasPrefix("x-amz-meta-") }
                wireValid = wireValid && request.headers["if-none-match"] == ["*"]
                wireValid = wireValid && request.headers["content-length"] == [String(bytes)]
                wireValid = wireValid && request.headers["cache-control"] == ["private, no-store"]
                wireValid = wireValid && PrivateContent.mimeTypes.contains(sentType)
                wireValid = wireValid && request.headers["content-encoding"].isEmpty && sentMetadata.isEmpty
                if mode == .alreadyExists {
                    // A real provider sends an error document with its 412. If it
                    // is ever collated, this stalls the test instead of passing.
                    return .init(status: .preconditionFailed, headers: [:], body: .init(asyncSequence: Stalled(), length: nil))
                }
                if mode == .lostPUT { throw Failure() }
            }
            if mode == .redirect {
                return .init(status: .temporaryRedirect, headers: ["Location": "https://public.example.invalid/cached"],
                             body: .init(asyncSequence: Stalled(), length: nil))
            }
            if mode == .error { return .init(status: .forbidden, headers: [:], body: .init(asyncSequence: Stalled(), length: nil)) }
            var headers: HTTPHeaders = ["ETag": "\"synthetic-etag\""]
            if request.method == .PUT {
                headers.add(name: "Content-Length", value: "0")
                if mode == .missingETag { headers.remove(name: "ETag") }
                if mode == .duplicateETag { headers.add(name: "ETag", value: "foreign") }
                let body: AWSHTTPBody = mode == .putEchoesBody ? .init(buffer: ByteBuffer(repeating: 1, count: 64)) : .init()
                return .init(status: .ok, headers: headers, body: body)
            }
            var body = payload
            var contentType = PrivateImageProcessor.detectMime(payload) ?? "image/jpeg"
            switch mode {
            case .fence, .fenceWithBytes, .fenceWithoutMarker:
                contentType = ObjectErasureFenceService.contentType
                body = mode == .fenceWithBytes ? Data(repeating: 0x41, count: 16) : Data()
            default: break
            }
            headers.add(name: "Cache-Control", value: "private, no-store")
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: String(body.count))
            if mode == .fence || mode == .fenceWithBytes {
                headers.add(name: "x-amz-meta-snaglist-erasure", value: ObjectErasureFenceService.marker)
            }
            switch mode {
            case .missingETag: headers.remove(name: "ETag")
            case .duplicateETag: headers.add(name: "ETag", value: "foreign")
            case .wrongCacheControl: headers.replaceOrAdd(name: "Cache-Control", value: "public, max-age=31536000")
            case .foreignMIME: headers.replaceOrAdd(name: "Content-Type", value: "text/html")
            case .contentWithMetadata: headers.add(name: "x-amz-meta-original-name", value: "synthetic-name")
            case .contentEncoding: headers.add(name: "Content-Encoding", value: "gzip")
            case .contentRange: headers.add(name: "Content-Range", value: "bytes 0-15/16")
            // Declares zero and streams bytes: the object is not the fence it claims.
            case .fenceWithBytes: headers.replaceOrAdd(name: "Content-Length", value: "0")
            // Declares more than it streams, and less than it streams.
            case .overDeclared: headers.replaceOrAdd(name: "Content-Length", value: String(body.count + 16))
            case .underDeclared: headers.replaceOrAdd(name: "Content-Length", value: String(max(0, body.count - 16)))
            case .oversizedDeclaration: headers.replaceOrAdd(name: "Content-Length", value: String(PrivateContent.maximumBytes + 1))
            case .mislabelledBytes:
                headers.replaceOrAdd(name: "Content-Type", value: "image/jpeg")
                body = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: 0x33, count: 56)
                headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
            default: break
            }
            if mode == .stalled { return .init(status: .ok, headers: headers, body: .init(asyncSequence: Stalled(), length: nil)) }
            return .init(status: .ok, headers: headers, body: .init(buffer: ByteBuffer(data: body)))
        }
    }
    struct Stalled: AsyncSequence, Sendable {
        typealias Element = ByteBuffer
        struct AsyncIterator: AsyncIteratorProtocol {
            mutating func next() async throws -> ByteBuffer? { try await Task.sleep(for: .seconds(30)); return nil }
        }
        func makeAsyncIterator() -> AsyncIterator { .init() }
    }

    // Hex letters, deliberately: a UUID of digits alone is its own uppercase, so
    // the lowercase rule below would be asserted against an unchanged string.
    let project = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    let snag = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
    let asset = "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f"
    let digest = String(repeating: "a", count: 64)
    var key: String { "immutable-v1/media/\(project)/\(snag)/\(asset)/original" }
    var renditionKey: String { "immutable-v1/media/\(project)/\(snag)/\(asset)/view-\(digest).jpg" }
    var placeholderKey: String { "immutable-v1/media/\(project)/\(snag)/\(asset)/view.jpg" }
    let jpeg = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x5A, count: 1021)
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: 0x2C, count: 1016)

    var http: HTTP!
    var configuration: PrivateStorageTargetConfiguration!
    var store: R2PrivateContentStore!
    var values: [String: String] { [
        "R2_ACCOUNT_ID": String(repeating: "a", count: 32),
        "R2_PRIVATE_BUCKET_NAME": "synthetic-private", "R2_BUCKET_NAME": "synthetic-public",
        "R2_PRIVATE_NAMESPACE": "immutable-v1/", "R2_ACCESS_KEY_ID": "synthetic-key", "R2_SECRET_ACCESS_KEY": "synthetic-secret"
    ] }

    override func setUp() async throws {
        let values = values
        configuration = try XCTUnwrap(PrivateStorageTargetConfiguration.load(environment: .testing, lookup: { values[$0] }))
        http = HTTP(allowedPaths: ["/synthetic-private/" + key, "/synthetic-private/" + renditionKey])
        await http.setPayload(jpeg)
        store = .init(configuration: configuration, httpClient: http)
    }
    override func tearDown() async throws { if let store { try await store.shutdown() } }

    private func rejected(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected fail-closed rejection", file: file, line: line) } catch { }
    }

    // MARK: the create-only PUT

    /// Not "no error was raised": the fake transport must have been reached, on
    /// the exact path, carrying the create-only condition, on every PUT.
    func testEveryPUTIsConditionalAndActuallyReachesTheTransport() async throws {
        // An original may be either supported type; a rendition is always a JPEG.
        let first = try await store.put(key: key, data: png, contentType: "image/png")
        guard case .created(let etag) = first else { return XCTFail("Expected a created outcome, got \(first)") }
        XCTAssertFalse(etag.isEmpty)
        _ = try await store.put(key: renditionKey, data: jpeg, contentType: "image/jpeg")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT", "PUT"], "the transport must have been reached, twice")
        XCTAssertEqual(snapshot.paths, ["/synthetic-private/" + key, "/synthetic-private/" + renditionKey])
        XCTAssertEqual(snapshot.conditional, [["*"], ["*"]], "If-None-Match: * on every PUT, without exception")
        XCTAssertEqual(snapshot.putBytes, [png.count, jpeg.count])
        XCTAssertEqual(snapshot.putContentTypes, ["image/png", "image/jpeg"])
        XCTAssertTrue(snapshot.valid)
    }

    /// The refusal that makes a fence permanent. It is an outcome, not an error,
    /// and it is decided from the status line: the provider's error document is
    /// attached to a sequence that never completes, so any collation stalls.
    func testRefusedConditionalPUTIsAlreadyExistsAndNoBodyIsRead() async throws {
        await http.set(.alreadyExists)
        let start = ContinuousClock.now
        let outcome = try await store.put(key: key, data: jpeg, contentType: "image/jpeg")
        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "the 412 body must never be collated")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT"])
        XCTAssertEqual(snapshot.conditional, [["*"]])
        XCTAssertTrue(snapshot.valid)
    }

    /// A lost PUT response is not a success, and the retry is byte-identical —
    /// still conditional, so the retry cannot overwrite what the first one wrote.
    func testLostPUTResponseIsNotSuccessAndRetryRemainsConditional() async throws {
        await http.set(.lostPUT)
        await rejected { _ = try await self.store.put(key: self.key, data: self.jpeg, contentType: "image/jpeg") }
        await http.set(.normal)
        _ = try await store.put(key: key, data: jpeg, contentType: "image/jpeg")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT", "PUT"])
        XCTAssertEqual(snapshot.conditional, [["*"], ["*"]])
        XCTAssertTrue(snapshot.valid)
    }

    func testPUTRepliesCarryingABodyOrABadETagCannotBecomeProof() async {
        for mode in [HTTP.Mode.putEchoesBody, .missingETag, .duplicateETag] {
            await http.set(mode)
            let before = await http.snapshot()
            await rejected { _ = try await self.store.put(key: self.key, data: self.jpeg, contentType: "image/jpeg") }
            let after = await http.snapshot()
            XCTAssertEqual(after.methods.count, before.methods.count + 1, "the malformed reply must be exercised, not pre-empted")
            XCTAssertEqual(after.methods.last, "PUT")
        }
    }

    // MARK: readback

    func testReadbackIsExactInBytesDigestSizeAndMIME() async throws {
        let written = try await store.put(key: key, data: jpeg, contentType: "image/jpeg")
        guard case .created(let etag) = written else { return XCTFail("Expected a created outcome") }
        let read = try await store.read(key: key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertEqual(read.target, configuration.target)
        XCTAssertEqual(read.key, key)
        XCTAssertEqual(read.body, jpeg)
        XCTAssertEqual(read.byteCount, jpeg.count)
        XCTAssertEqual(read.sha256, PrivateImageProcessor.digest(jpeg))
        XCTAssertEqual(read.contentType, "image/jpeg")
        XCTAssertEqual(read.metadata, [:])
        XCTAssertEqual(read.etag, etag, "the etag returned on write is the one served on read")
        XCTAssertFalse(read.isErasureFence)
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT", "GET"])
        XCTAssertTrue(snapshot.valid)
    }

    /// Reading an erased object is not a failed read. The caller is told exactly
    /// what it found: the photograph is gone and this is the barrier that replaced it.
    func testAnErasureFenceIsRecognisedRatherThanReadAsContent() async throws {
        await http.set(.fence)
        let read = try await store.read(key: key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertTrue(read.isErasureFence)
        XCTAssertTrue(read.body.isEmpty)
        XCTAssertEqual(read.byteCount, 0)
        XCTAssertEqual(read.contentType, ObjectErasureFenceService.contentType)
        XCTAssertEqual(read.metadata, ["snaglist-erasure": ObjectErasureFenceService.marker])
        XCTAssertEqual(read.sha256, ObjectErasureFenceService.emptySHA256)
        let snapshot = await http.snapshot(); XCTAssertEqual(snapshot.methods, ["GET"])
    }

    /// Ordinary content is not a fence, and neither is anything that has only some
    /// of a fence's three properties.
    func testPartialFenceShapesAreNeitherContentNorAFence() async throws {
        await http.setPayload(jpeg)
        let content = try await store.read(key: key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertFalse(content.isErasureFence)
        for mode in [HTTP.Mode.fenceWithBytes, .fenceWithoutMarker] {
            await http.set(mode)
            await rejected { _ = try await self.store.read(key: self.key, maximumBytes: PrivateContent.maximumBytes) }
        }
    }

    func testMalformedRepliesCannotBecomeContent() async {
        for mode in [HTTP.Mode.missingETag, .duplicateETag, .wrongCacheControl, .foreignMIME, .contentWithMetadata,
                     .mislabelledBytes, .overDeclared, .underDeclared, .oversizedDeclaration, .contentEncoding, .contentRange] {
            await http.set(mode)
            let before = await http.snapshot()
            await rejected { _ = try await self.store.read(key: self.key, maximumBytes: PrivateContent.maximumBytes) }
            let after = await http.snapshot()
            XCTAssertEqual(after.methods.count, before.methods.count + 1, "the malformed reply must be exercised, not pre-empted")
            XCTAssertEqual(after.methods.last, "GET")
        }
    }

    /// An object larger than the caller's bound is refused, not truncated to it.
    func testOversizedAndOutOfRangeReadbacksAreRefused() async {
        await rejected { _ = try await self.store.read(key: self.key, maximumBytes: 16) }
        let exercised = await http.snapshot()
        XCTAssertEqual(exercised.methods, ["GET"], "the provider's own declared length is what fails it")
        for bound in [0, -1, PrivateContent.maximumBytes + 1] {
            await rejected { _ = try await self.store.read(key: self.key, maximumBytes: bound) }
        }
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["GET"], "an impossible bound never reaches the transport")
    }

    func testErrorAndRedirectBodiesAreRejectedBeforeSotoCanCollateThem() async {
        let start = ContinuousClock.now
        for mode in [HTTP.Mode.redirect, .error] {
            await http.set(mode)
            await rejected { _ = try await self.store.read(key: self.key, maximumBytes: PrivateContent.maximumBytes) }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "the stalled error body must never be consumed")
        let snapshot = await http.snapshot(); XCTAssertEqual(snapshot.methods, ["GET", "GET"])
    }

    // MARK: what never reaches a provider at all

    func testInvalidKeysAndContentNeverReachHTTP() async {
        let base = "immutable-v1/media/\(project)/\(snag)/\(asset)/"
        // One object, one key. If this ever holds, the uppercase entry below is
        // the valid key and proves nothing, which is exactly how it once passed.
        XCTAssertNotEqual(project.uppercased(), project, "the lowercase-UUID rule needs a UUID with letters in it")
        XCTAssertNotEqual(base.uppercased(), base)
        for invalid in [placeholderKey,
                        base + "view-\(String(repeating: "a", count: 63)).jpg",
                        base + "view-\(String(repeating: "a", count: 64)).png",
                        base + "view-\(String(repeating: "A", count: 64)).jpg",
                        base + "original/extra",
                        base.uppercased() + "original",
                        "immutable-v1/media/\(project.uppercased())/\(snag)/\(asset)/original",
                        "immutable-v1/media/not-a-uuid/\(snag)/\(asset)/original",
                        "immutable-v1/media/\(project)/\(snag)/original",
                        "immutable-v1/\(project)/\(snag)/\(asset)/original",
                        "immutable-v1/staged-import/\(project)/\(snag)/\(asset)/original",
                        "/" + key, "foreign/media/\(project)/\(snag)/\(asset)/original",
                        "immutable-v1/media/../../original", "immutable-v1//media/original",
                        "immutable-v1/", key + "?query"] {
            await rejected { _ = try await self.store.read(key: invalid, maximumBytes: PrivateContent.maximumBytes) }
            await rejected { _ = try await self.store.put(key: invalid, data: self.jpeg, contentType: "image/jpeg") }
        }
        // The erasure MIME is not content. Only a fence writer may ever send it,
        // and this store is not one.
        await rejected { _ = try await self.store.put(key: self.key, data: Data(), contentType: ObjectErasureFenceService.contentType) }
        await rejected { _ = try await self.store.put(key: self.key, data: self.jpeg, contentType: ObjectErasureFenceService.contentType) }
        for (data, mime) in [(jpeg, "application/octet-stream"), (jpeg, "image/png"), (png, "image/jpeg"),
                             (Data(), "image/jpeg"), (Data(repeating: 0xFF, count: 8), "image/jpeg"),
                             (jpeg + Data(repeating: 0x5A, count: PrivateContent.maximumBytes), "image/jpeg")] {
            await rejected { _ = try await self.store.put(key: self.key, data: data, contentType: mime) }
        }
        let snapshot = await http.snapshot()
        XCTAssertTrue(snapshot.methods.isEmpty, "nothing refused by the store may reach a provider")
    }

    func testWrongTransportAuthorityConditionalGETAndHEADNeverReachHTTP() async {
        let transport = R2PrivateContentHTTPClient(base: http, configuration: configuration)
        let direct = configuration.endpoint + "/synthetic-private/" + key
        for url in ["https://foreign.r2.cloudflarestorage.com/synthetic-private/" + key + "?x-id=GetObject",
                    configuration.endpoint + "/foreign-private/" + key + "?x-id=GetObject",
                    configuration.endpoint + "/synthetic-private/immutable-v1/foreign/key?x-id=GetObject",
                    configuration.endpoint + "/synthetic-private/" + placeholderKey + "?x-id=GetObject",
                    direct + "?versionId=old", direct, direct + "?x-id=PutObject",
                    direct + "?x-id=GetObject&extra=1", direct + "?x-id=%47etObject",
                    "http://\(configuration.target.backendIdentity).r2.cloudflarestorage.com/synthetic-private/" + key + "?x-id=GetObject"] {
            await rejected { _ = try await transport.execute(request: .init(url: URL(string: url)!, method: .GET, headers: [:], body: .init()),
                                                             timeout: .seconds(1), logger: AWSClient.loggingDisabled) }
        }
        let url = URL(string: direct + "?x-id=GetObject")!
        for method in [HTTPMethod.HEAD, .DELETE, .POST] {
            await rejected { _ = try await transport.execute(request: .init(url: url, method: method, headers: [:], body: .init()),
                                                             timeout: .seconds(1), logger: AWSClient.loggingDisabled) }
        }
        for headers in [HTTPHeaders([("If-None-Match", "*")]), HTTPHeaders([("If-Match", "\"etag\"")]), HTTPHeaders([("Range", "bytes=0-15")])] {
            await rejected { _ = try await transport.execute(request: .init(url: url, method: .GET, headers: headers, body: .init()),
                                                             timeout: .seconds(1), logger: AWSClient.loggingDisabled) }
        }
        let snapshot = await http.snapshot(); XCTAssertTrue(snapshot.methods.isEmpty)
    }

    /// The counterexample the fence depends on: there is no way to send an
    /// unconditional PUT through this transport, whatever the caller assembles.
    func testAPUTWithoutTheCreateOnlyHeaderIsRefusedByTheTransport() async {
        let transport = R2PrivateContentHTTPClient(base: http, configuration: configuration)
        let url = URL(string: configuration.endpoint + "/synthetic-private/" + key + "?x-id=PutObject")!
        let body = AWSHTTPBody(buffer: ByteBuffer(data: jpeg))
        let complete: [(String, String)] = [("Content-Length", String(jpeg.count)), ("Content-Type", "image/jpeg"),
                                            ("Cache-Control", "private, no-store"), ("If-None-Match", "*")]
        let unconditional = complete.filter { $0.0 != "If-None-Match" }
        for headers in [unconditional,
                        unconditional + [("If-None-Match", "\"some-etag\"")],
                        unconditional + [("If-Match", "*")],
                        complete + [("x-amz-meta-snaglist-erasure", ObjectErasureFenceService.marker)],
                        complete + [("Content-Encoding", "gzip")],
                        complete.filter { $0.0 != "Cache-Control" },
                        complete.map { $0.0 == "Content-Type" ? ($0.0, ObjectErasureFenceService.contentType) : $0 },
                        complete.map { $0.0 == "Content-Length" ? ($0.0, "0") : $0 }] {
            await rejected { _ = try await transport.execute(request: .init(url: url, method: .PUT, headers: .init(headers), body: body),
                                                             timeout: .seconds(1), logger: AWSClient.loggingDisabled) }
        }
        // The same request with nothing removed is admitted. The refusals above are
        // that one header doing the work, not some other part of the shape.
        _ = try? await transport.execute(request: .init(url: url, method: .PUT, headers: .init(complete), body: body),
                                         timeout: .seconds(1), logger: AWSClient.loggingDisabled)
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT"], "only the complete create-only request reaches a provider")
        XCTAssertEqual(snapshot.conditional, [["*"]])
    }

    func testStalledBodyStillRequiresEOFWithinTheDeadline() async {
        await http.set(.stalled)
        let transport = R2PrivateContentHTTPClient(base: http, configuration: configuration)
        let request = AWSHTTPRequest(url: URL(string: configuration.endpoint + "/synthetic-private/" + key + "?x-id=GetObject")!,
                                     method: .GET, headers: [:], body: .init())
        let start = ContinuousClock.now
        await rejected { _ = try await transport.execute(request: request, timeout: .milliseconds(20), logger: AWSClient.loggingDisabled) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let snapshot = await http.snapshot(); XCTAssertEqual(snapshot.methods, ["GET"])
    }

    /// Cancellation is not swallowed into a storage error. A deletion pass that is
    /// cancelled mid-read must learn that it was cancelled.
    func testCancellationPropagates() async throws {
        await http.set(.stalled)
        let store = try XCTUnwrap(self.store)
        let key = self.key
        let task = Task { try await store.read(key: key, maximumBytes: PrivateContent.maximumBytes) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
    }

    // MARK: configuration and provider

    func testOneConfigurationBuildsBothStoresOnOneTarget() async throws {
        let values = values
        let shared = try XCTUnwrap(PrivateStorageTargetConfiguration.load(environment: .testing, lookup: { values[$0] }))
        let content = R2PrivateContentStore(configuration: shared, httpClient: HTTP(allowedPaths: []))
        let fence = R2ObjectErasureFenceStore(configuration: shared, httpClient: HTTP(allowedPaths: []))
        XCTAssertEqual(content.target, fence.target)
        XCTAssertEqual(content.target, shared.target)
        XCTAssertEqual(content.target.writeProtocol, .createOnlyV1)
        try await content.shutdown()
        try await fence.shutdown()
    }

    func testAbsentNamespaceDisablesPrivateStorageWithoutReadingCredentials() throws {
        var read: [String] = []
        let disabled = try R2PrivateContentStore.makeIfConfigured(target: configuration.target, environment: .production,
                                                                  lookup: { read.append($0); return nil })
        XCTAssertNil(disabled)
        XCTAssertEqual(read, ["R2_PRIVATE_NAMESPACE"])
        let values = values
        XCTAssertThrowsError(try R2PrivateContentStore.makeIfConfigured(target: configuration.target, environment: .production,
                                                                        lookup: { values[$0] }))
        let foreign = ObjectStorageWriteTarget(backend: "r2", backendIdentity: configuration.target.backendIdentity,
                                               bucket: "foreign-private", namespace: configuration.target.namespace,
                                               writeProtocol: .createOnlyV1)
        XCTAssertThrowsError(try R2PrivateContentStore.makeIfConfigured(target: foreign, environment: .testing, lookup: { values[$0] }))
    }

    /// No fallback of any kind: a missing or mismatched store is an error, never
    /// some other writer that happens to be reachable.
    func testProviderReturnsOneStoreForOneTargetAndNeverFallsBack() async throws {
        let injected = try TestPrivateContentStore.synthetic()
        let app = try await Application.make(.testing)
        let target = injected.target
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = injected
        XCTAssertNoThrow(try PrivateContentStoreProvider.store(for: target, app: app))
        for wrong in [ObjectStorageWriteTarget(backend: "r2", backendIdentity: target.backendIdentity, bucket: "elsewhere-private",
                                               namespace: target.namespace, writeProtocol: .createOnlyV1),
                      ObjectStorageWriteTarget(backend: "r2", backendIdentity: "other-account", bucket: target.bucket,
                                               namespace: target.namespace, writeProtocol: .createOnlyV1),
                      ObjectStorageWriteTarget(backend: "r2", backendIdentity: target.backendIdentity, bucket: target.bucket,
                                               namespace: "other-v1/", writeProtocol: .createOnlyV1),
                      ObjectStorageWriteTarget(backend: "r2", backendIdentity: target.backendIdentity, bucket: target.bucket,
                                               namespace: target.namespace, writeProtocol: .legacyUnknown)] {
            XCTAssertThrowsError(try PrivateContentStoreProvider.store(for: wrong, app: app))
        }
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = nil
        XCTAssertThrowsError(try PrivateContentStoreProvider.store(for: target, app: app),
                             "with nothing installed the caller gets an error, not a legacy writer")
        await PrivateContentStoreProvider.shutdown(app: app)
        try await app.asyncShutdown()
    }

    func testAnInjectedStoreIsIgnoredOutsideTesting() async throws {
        let injected = try TestPrivateContentStore.synthetic()
        let app = try await Application.make(.development)
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = injected
        XCTAssertThrowsError(try PrivateContentStoreProvider.store(for: injected.target, app: app))
        try await app.asyncShutdown()
    }

    func testTheInMemoryStandInIsCreateOnlyAndRecordsItsCalls() async throws {
        let fake = try TestPrivateContentStore.synthetic()
        let key = fake.originalKey()
        let created = try await fake.put(key: key, data: jpeg, contentType: "image/jpeg")
        guard case .created(let etag) = created else { return XCTFail("Expected a created outcome, got \(created)") }
        XCTAssertFalse(etag.isEmpty)
        let repeated = try await fake.put(key: key, data: png, contentType: "image/png")
        XCTAssertEqual(repeated, .alreadyExists)
        let read = try await fake.read(key: key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertEqual(read.body, jpeg)
        XCTAssertEqual(read.etag, etag)
        XCTAssertFalse(read.isErasureFence)
        let fenced = fake.originalKey()
        _ = try await fake.seedErasureFence(key: fenced)
        let afterFence = try await fake.put(key: fenced, data: jpeg, contentType: "image/jpeg")
        XCTAssertEqual(afterFence, .alreadyExists, "a fence holds its address against a later content writer")
        let fenceReadback = try await fake.read(key: fenced, maximumBytes: 1)
        XCTAssertTrue(fenceReadback.isErasureFence)
        let placeholder = fake.placeholderKey(for: key)
        await rejected { _ = try await fake.put(key: placeholder, data: self.jpeg, contentType: "image/jpeg") }
        let calls = await fake.recordedCalls()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls.first, TestPrivateContentStore.Call.put(key: key, byteCount: jpeg.count, contentType: "image/jpeg"))
        XCTAssertEqual(calls.last, TestPrivateContentStore.Call.put(key: placeholder, byteCount: jpeg.count, contentType: "image/jpeg"))
    }
}
