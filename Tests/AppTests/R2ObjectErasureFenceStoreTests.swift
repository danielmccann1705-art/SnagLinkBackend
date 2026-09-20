@testable import App
import XCTest
import Vapor
import SotoS3
import NIOCore
import NIOHTTP1
import Logging

/// The real pinned Soto encoder/signer runs over a fake HTTP transport with no
/// sockets. These tests establish no provider atomicity or staging acceptance.
final class R2ObjectErasureFenceStoreTests: XCTestCase {
    actor HTTP: AWSHTTPClient {
        enum Mode: Sendable { case normal, redirect, error, nonempty, forgedZeroLength, missingLength, wrongMarker, extraMetadata, wrongMIME, missingETag, duplicateETag, lostPUT, stalled }
        var mode: Mode = .normal
        var methods: [String] = []
        var paths: [String] = []
        var wireValid = true
        let account = String(repeating: "a", count: 32)
        struct Failure: Error {}
        func set(_ mode: Mode) { self.mode = mode }
        func snapshot() -> (methods: [String], paths: [String], valid: Bool) { (methods, paths, wireValid) }
        func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
            methods.append(request.method.rawValue); paths.append(request.url.path)
            wireValid = wireValid && request.url.host == "\(account).r2.cloudflarestorage.com"
                && request.url.path == "/synthetic-private/immutable-v1/asset/original"
                && request.headers.first(name: "authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true
                && request.headers["if-none-match"].isEmpty && request.headers["if-match"].isEmpty
                && request.headers["range"].isEmpty
                && URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                    == (request.method == .PUT ? "x-id=PutObject" : "x-id=GetObject")
            var bytes = 0
            for try await chunk in request.body { bytes += chunk.readableBytes }
            wireValid = wireValid && bytes == 0
            if request.method == .PUT {
                wireValid = wireValid && request.headers["content-length"] == ["0"]
                    && request.headers["content-type"] == [ObjectErasureFenceService.contentType]
                    && request.headers["cache-control"] == ["private, no-store"]
                    && request.headers["x-amz-meta-snaglist-erasure"] == [ObjectErasureFenceService.marker]
                    && request.headers["content-encoding"].isEmpty
                if mode == .lostPUT { throw Failure() }
            }
            if mode == .redirect { return .init(status: .temporaryRedirect, headers: ["Location": "https://public.example.invalid/cached"], body: .init(asyncSequence: Stalled(), length: nil)) }
            if mode == .error { return .init(status: .forbidden, headers: [:], body: .init(asyncSequence: Stalled(), length: nil)) }
            var headers: HTTPHeaders = ["Content-Length": "0", "ETag": "\"synthetic-etag\""]
            if request.method == .GET {
                headers.add(name: "Content-Type", value: ObjectErasureFenceService.contentType)
                headers.add(name: "Cache-Control", value: "private, no-store")
                headers.add(name: "x-amz-meta-snaglist-erasure", value: ObjectErasureFenceService.marker)
            }
            switch mode {
            case .nonempty: headers.replaceOrAdd(name: "Content-Length", value: "64")
            case .missingLength: headers.remove(name: "Content-Length")
            case .wrongMarker: headers.replaceOrAdd(name: "x-amz-meta-snaglist-erasure", value: "foreign")
            case .extraMetadata: headers.add(name: "x-amz-meta-original-name", value: "synthetic-private-name")
            case .wrongMIME: headers.replaceOrAdd(name: "Content-Type", value: "image/jpeg")
            case .missingETag: headers.remove(name: "ETag")
            case .duplicateETag: headers.add(name: "ETag", value: "foreign")
            default: break
            }
            if mode == .stalled { return .init(status: .ok, headers: headers, body: .init(asyncSequence: Stalled(), length: 0)) }
            let body: AWSHTTPBody = mode == .nonempty || mode == .forgedZeroLength
                ? .init(buffer: ByteBuffer(repeating: 1, count: 64)) : .init()
            return .init(status: .ok, headers: headers, body: body)
        }
    }
    struct Stalled: AsyncSequence, Sendable {
        typealias Element = ByteBuffer
        struct AsyncIterator: AsyncIteratorProtocol {
            mutating func next() async throws -> ByteBuffer? { try await Task.sleep(for: .seconds(30)); return nil }
        }
        func makeAsyncIterator() -> AsyncIterator { .init() }
    }
    let key = "immutable-v1/asset/original"
    var http: HTTP!
    var configuration: R2ObjectErasureFenceConfiguration!
    var store: R2ObjectErasureFenceStore!
    var values: [String: String] { [
        "R2_ACCOUNT_ID": String(repeating: "a", count: 32),
        "R2_PRIVATE_BUCKET_NAME": "synthetic-private", "R2_BUCKET_NAME": "synthetic-public",
        "R2_PRIVATE_NAMESPACE": "immutable-v1/", "R2_ACCESS_KEY_ID": "synthetic-key", "R2_SECRET_ACCESS_KEY": "synthetic-secret"
    ] }
    override func setUp() async throws {
        let values = values
        configuration = try XCTUnwrap(R2ObjectErasureFenceConfiguration.load(environment: .testing, lookup: { values[$0] }))
        http = HTTP(); store = .init(configuration: configuration, httpClient: http)
    }
    override func tearDown() async throws { if let store { try await store.shutdown() } }
    private func rejected(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected fail-closed rejection", file: file, line: line) } catch { }
    }
    func testDisabledFactoryDoesNotReadCredentialsOrCreateTransport() throws {
        var read: [String] = []
        let disabled = try R2ObjectErasureFenceStore.makeIfEnabled(target: configuration.target, environment: .production, lookup: { read.append($0); return nil })
        XCTAssertNil(disabled); XCTAssertEqual(read, ["R2_PRIVATE_NAMESPACE"])
    }
    /// D1 lifted the `.testing` gate: `R2_PRIVATE_NAMESPACE` alone installs the
    /// namespace, in every environment, so that activation is one act by one
    /// person rather than a code change that has to accompany it. Everything the
    /// loader refuses it still refuses, and it still refuses on the exact target.
    func testEnabledConfigurationInstallsInEveryEnvironmentOnTheExactPrivateServerTarget() throws {
        let values = values
        let production = try XCTUnwrap(R2ObjectErasureFenceConfiguration.load(environment: .production, lookup: { values[$0] }))
        XCTAssertEqual(production.target, configuration.target)
        for (field,value) in [("R2_ACCOUNT_ID","foreign.example/path"), ("R2_PRIVATE_BUCKET_NAME","synthetic-public"),
                              ("R2_PRIVATE_NAMESPACE","../"), ("R2_SECRET_ACCESS_KEY","")] {
            var wrong = values; wrong[field] = value
            XCTAssertThrowsError(try R2ObjectErasureFenceConfiguration.load(environment: .testing, lookup: { wrong[$0] }))
        }
        var implicitPublic = values
        implicitPublic.removeValue(forKey: "R2_BUCKET_NAME")
        implicitPublic["R2_PRIVATE_BUCKET_NAME"] = "snaglist-uploads"
        XCTAssertThrowsError(try R2ObjectErasureFenceConfiguration.load(environment: .testing, lookup: { implicitPublic[$0] }))
        let foreign = ObjectStorageWriteTarget(backend: "r2", backendIdentity: configuration.target.backendIdentity,
            bucket: "foreign-private", namespace: configuration.target.namespace, writeProtocol: .createOnlyV1)
        XCTAssertThrowsError(try R2ObjectErasureFenceStore.makeIfEnabled(target: foreign, environment: .testing, lookup: { values[$0] }))
    }
    func testRealSotoSignsExactUnconditionalEmptyPUTAndDirectGET() async throws {
        let etag = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType,
                                                        metadata: ["snaglist-erasure": ObjectErasureFenceService.marker])
        let read = try await store.readFence(key: key, maximumBytes: 1)
        XCTAssertEqual(read.target, configuration.target); XCTAssertEqual(read.key, key)
        XCTAssertEqual(read.etag, etag); XCTAssertTrue(read.body.isEmpty); XCTAssertEqual(read.byteCount, 0)
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.methods, ["PUT","GET"]); XCTAssertTrue(snapshot.valid)
        XCTAssertEqual(snapshot.paths, Array(repeating: "/synthetic-private/" + key, count: 2))
    }
    func testInvalidKeysAndCallerMetadataNeverReachHTTP() async {
        for invalid in ["/"+key,"foreign/asset/original","immutable-v1/../escape","immutable-v1//original",
                        "immutable-v1/%2e%2e/original","immutable-v1/x?query","immutable-v1/x\\y","immutable-v1/"] {
            await rejected { _ = try await self.store.readFence(key: invalid, maximumBytes: 1) }
            await rejected { _ = try await self.store.replaceWithEmptyFence(key: invalid, contentType: ObjectErasureFenceService.contentType, metadata: ["snaglist-erasure":ObjectErasureFenceService.marker]) }
        }
        await rejected { _ = try await self.store.replaceWithEmptyFence(key: self.key, contentType: "image/jpeg", metadata: ["snaglist-erasure":ObjectErasureFenceService.marker]) }
        await rejected { _ = try await self.store.replaceWithEmptyFence(key: self.key, contentType: ObjectErasureFenceService.contentType, metadata: ["snaglist-erasure":ObjectErasureFenceService.marker,"filename":"synthetic"]) }
        await rejected { _ = try await self.store.readFence(key:self.key,maximumBytes:1024) }
        let snapshot = await http.snapshot(); XCTAssertTrue(snapshot.methods.isEmpty)
    }
    func testWrongTransportAuthorityAndConditionalOrHEADRequestsNeverReachHTTP() async {
        let transport = R2ObjectErasureFenceHTTPClient(base: http, configuration: configuration)
        for url in ["https://foreign.r2.cloudflarestorage.com/synthetic-private/"+key+"?x-id=GetObject",
                    configuration.endpoint+"/foreign-private/"+key+"?x-id=GetObject", configuration.endpoint+"/synthetic-private/foreign/key?x-id=GetObject",
                    configuration.endpoint+"/synthetic-private/"+key+"?versionId=old"] {
            await rejected { _ = try await transport.execute(request: .init(url: URL(string:url)!, method:.GET,headers:[:],body:.init()),timeout:.seconds(1),logger:AWSClient.loggingDisabled) }
        }
        let url=URL(string:configuration.endpoint+"/synthetic-private/"+key+"?x-id=GetObject")!
        await rejected { _ = try await transport.execute(request:.init(url:url,method:.HEAD,headers:[:],body:.init()),timeout:.seconds(1),logger:AWSClient.loggingDisabled) }
        await rejected { _ = try await transport.execute(request:.init(url:url,method:.GET,headers:["If-None-Match":"*"],body:.init()),timeout:.seconds(1),logger:AWSClient.loggingDisabled) }
        let snapshot = await http.snapshot(); XCTAssertTrue(snapshot.methods.isEmpty)
    }
    func testBadReadbackMetadataLengthETagAndBytesCannotBecomeProof() async {
        for mode in [HTTP.Mode.nonempty,.forgedZeroLength,.missingLength,.wrongMarker,.extraMetadata,.wrongMIME,.missingETag,.duplicateETag] {
            await http.set(mode)
            let before = await http.snapshot()
            await rejected { _ = try await self.store.readFence(key:self.key,maximumBytes:1) }
            let after = await http.snapshot()
            XCTAssertEqual(after.methods.count, before.methods.count + 1,"Malformed reply must be exercised, not rejected before HTTP")
            XCTAssertEqual(after.methods.last,"GET")
        }
    }
    func testErrorAndRedirectBodiesAreRejectedBeforeSotoCanCollateThem() async {
        let start = ContinuousClock.now
        for mode in [HTTP.Mode.redirect,.error] {
            await http.set(mode)
            await rejected { _ = try await self.store.readFence(key:self.key,maximumBytes:1) }
        }
        XCTAssertLessThan(start.duration(to:.now),.seconds(2),"The stalled error body must never be consumed")
        let snapshot=await http.snapshot(); XCTAssertEqual(snapshot.methods,["GET","GET"])
    }
    func testLostPUTResponseIsNotSuccessAndRetryRemainsIdentical() async throws {
        await http.set(.lostPUT)
        await rejected { _ = try await self.store.replaceWithEmptyFence(key:self.key,contentType:ObjectErasureFenceService.contentType,metadata:["snaglist-erasure":ObjectErasureFenceService.marker]) }
        await http.set(.normal)
        _ = try await store.replaceWithEmptyFence(key:key,contentType:ObjectErasureFenceService.contentType,metadata:["snaglist-erasure":ObjectErasureFenceService.marker])
        let snapshot=await http.snapshot(); XCTAssertEqual(snapshot.methods,["PUT","PUT"]); XCTAssertTrue(snapshot.valid)
    }
    func testStalledZeroLengthBodyStillRequiresEOFWithinDeadline() async {
        await http.set(.stalled)
        let transport=R2ObjectErasureFenceHTTPClient(base:http,configuration:configuration)
        let request=AWSHTTPRequest(url:URL(string:configuration.endpoint+"/synthetic-private/"+key+"?x-id=GetObject")!,method:.GET,headers:[:],body:.init())
        let start=ContinuousClock.now
        await rejected { _ = try await transport.execute(request:request,timeout:.milliseconds(20),logger:AWSClient.loggingDisabled) }
        XCTAssertLessThan(start.duration(to:.now),.seconds(2))
        let snapshot=await http.snapshot(); XCTAssertEqual(snapshot.methods,["GET"])
    }
    func testOnlyExactMethodSpecificSDKQueryIsAllowed() async {
        let transport=R2ObjectErasureFenceHTTPClient(base:http,configuration:configuration)
        let baseURL=configuration.endpoint+"/synthetic-private/"+key
        for query in ["", "?x-id=PutObject", "?x-id=GetObject&versionId=old", "?versionId=old&x-id=GetObject",
                      "?x-id=GetObject&extra=1", "?x-id=GetObject&x-id=GetObject", "?x-id=%47etObject"] {
            await rejected { _ = try await transport.execute(request:.init(url:URL(string:baseURL+query)!,method:.GET,
                headers:[:],body:.init()),timeout:.seconds(1),logger:AWSClient.loggingDisabled) }
        }
        let putHeaders: HTTPHeaders = ["Content-Length":"0","Content-Type":ObjectErasureFenceService.contentType,
            "Cache-Control":"private, no-store","x-amz-meta-snaglist-erasure":ObjectErasureFenceService.marker]
        await rejected { _ = try await transport.execute(request:.init(url:URL(string:baseURL+"?x-id=GetObject")!,method:.PUT,
            headers:putHeaders,body:.init()),timeout:.seconds(1),logger:AWSClient.loggingDisabled) }
        let snapshot=await http.snapshot(); XCTAssertTrue(snapshot.methods.isEmpty)
    }
}
