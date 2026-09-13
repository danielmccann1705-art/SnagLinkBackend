@testable import App
import XCTest
import SotoS3
import NIOCore
import NIOHTTP1
import Logging

/// Exercises the real pinned S3 encoder/signer/error parser without any socket.
actor StagedOriginalHTTPStub: AWSHTTPClient {
    var objects: [String: Data] = [:]
    var puts = 0, gets = 0, yieldedPutBytes = 0
    var headersValid = true
    var loseNextPutResponse = false
    var failNextPut = false
    var corruptRead = false
    var afterPut: (@Sendable () async throws -> Void)?
    func configure(lost: Bool = false, fail: Bool = false, corrupt: Bool = false,
                   afterPut: (@Sendable () async throws -> Void)? = nil) {
        loseNextPutResponse = lost; failNextPut = fail; corruptRead = corrupt; self.afterPut = afterPut
    }
    struct Snapshot: Sendable { let puts: Int; let gets: Int; let objects: Int; let yielded: Int; let headersValid: Bool; let paths: [String] }
    func snapshot() -> Snapshot { .init(puts: puts, gets: gets, objects: objects.count, yielded: yieldedPutBytes, headersValid: headersValid, paths: objects.keys.sorted()) }
    struct HiddenFailure: Error {} // Never inject a real credential or customer value.
    func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
        let path = request.url.path
        headersValid = headersValid && timeout.nanoseconds > 0 && timeout.nanoseconds <= 120_000_000_000
        if request.method == .PUT {
            puts += 1
            headersValid = headersValid && request.headers.first(name: "If-None-Match") == "*"
                && request.headers.first(name: "Content-Type") == "application/octet-stream"
                && request.headers.first(name: "Cache-Control") == "private, no-store"
                && request.headers.first(name: "Content-Encoding") != "aws-chunked"
            if failNextPut { failNextPut = false; throw HiddenFailure() }
            if objects[path] != nil { return error(.preconditionFailed, "PreconditionFailed") }
            var data = Data()
            for try await chunk in request.body { yieldedPutBytes += chunk.readableBytes; data.append(Data(buffer: chunk)) }
            if objects[path] != nil { return error(.preconditionFailed, "PreconditionFailed") }
            headersValid = headersValid && Int64(request.headers.first(name: "Content-Length") ?? "") == Int64(data.count)
            objects[path] = data
            if let hook = afterPut { afterPut = nil; try await hook() }
            if loseNextPutResponse { loseNextPutResponse = false; throw HiddenFailure() }
            return .init(status: .ok, headers: ["ETag": "not-a-checksum"])
        }
        if request.method == .GET {
            gets += 1
            guard let retained = objects[path] else { return error(.notFound, "NoSuchKey") }
            let data = corruptRead ? Data("corrupt private bytes".utf8) : retained
            return .init(status: .ok, headers: ["Content-Length": String(data.count), "ETag": "not-a-checksum"], body: stagedTestBody(data))
        }
        return error(.forbidden, "AccessDenied")
    }
    private func error(_ status: HTTPResponseStatus, _ code: String) -> AWSHTTPResponse {
        .init(status: status, headers: ["Content-Type": "application/xml"], body: .init(buffer: ByteBuffer(string: "<Error><Code>\(code)</Code><Message>synthetic private provider diagnostic</Message></Error>")))
    }
}

func stagedTestBody(_ data: Data, chunkBytes: Int = 65_536) -> AWSHTTPBody {
    .init(asyncSequence: ByteBuffer(data: data).asyncSequence(chunkSize: chunkBytes), length: data.count)
}
func stagedTestDeclaration(_ data: Data) -> StagedImportOriginalDeclaration {
    .init(sha256: LegacyProjectImportDecoder.digest(data), bytes: Int64(data.count))
}

final class StagedImportOriginalTransportTests: XCTestCase {
    var http: StagedOriginalHTTPStub!
    var client: AWSClient!
    var store: SotoStagedImportOriginalStore!
    let address = StagedImportOriginalAddress(workspaceId: UUID(), sessionId: UUID(), declarationId: UUID())
    override func setUp() async throws {
        http = StagedOriginalHTTPStub()
        client = AWSClient(credentialProvider: .static(accessKeyId: "synthetic-test-key", secretAccessKey: "synthetic-test-secret"), retryPolicy: .noRetry, httpClient: http)
        store = .init(s3: S3(client: client, endpoint: "https://synthetic.invalid"), privateBucket: "synthetic-private")
    }
    override func tearDown() async throws { try await client.shutdown() }
    private func transfer(_ data: Data, declaration: StagedImportOriginalDeclaration? = nil) async throws {
        let expected = declaration ?? stagedTestDeclaration(data), budget = try StagedImportIOBudget()
        try await budget.run {
            let body = try await StagedImportOriginalBytes.uploadBody(stagedTestBody(data, chunkBytes: 3), declaration: expected, budget: budget)
            _ = try await self.store.putIfAbsent(self.address, body: body, bytes: expected.bytes, budget: budget)
            let original = try await self.store.read(self.address, budget: budget)
            try await StagedImportOriginalBytes.measure(original, declaration: expected, budget: budget)
        }
    }
    private func rejected(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected rejection") } catch {}
    }
    func testActualSotoConditionalRequestAndOriginalReadbackUseOnlyTypedPrivateNamespace() async throws {
        let bytes = Data("opaque historical annotation bytes".utf8)
        try await transfer(bytes); try await transfer(bytes)
        let result = await http.snapshot()
        XCTAssertEqual(result.puts, 2); XCTAssertEqual(result.gets, 2); XCTAssertEqual(result.objects, 1); XCTAssertTrue(result.headersValid)
        XCTAssertEqual(result.paths, ["/synthetic-private/staged-import/\(address.workspaceId.uuidString.lowercased())/\(address.sessionId.uuidString.lowercased())/\(address.declarationId.uuidString.lowercased())/original"])
    }
    func testZeroByteOriginalIsRetainedAndInvalidNonemptyZeroDeclarationNeverSendsPUT() async throws {
        try await transfer(Data())
        await rejected { try await self.transfer(Data([1]), declaration: stagedTestDeclaration(Data())) }
        let result = await http.snapshot(); XCTAssertEqual(result.puts, 1); XCTAssertEqual(result.gets, 1); XCTAssertEqual(result.objects, 1)
    }
    func testWrongHashWithholdsFinalChunkAndNeverCreatesObject() async throws {
        let source = Data("abcdef".utf8), different = Data("abcdeg".utf8)
        await rejected { try await self.transfer(source, declaration: stagedTestDeclaration(different)) }
        let result = await http.snapshot(); XCTAssertEqual(result.yielded, 3); XCTAssertEqual(result.objects, 0); XCTAssertEqual(result.gets, 0)
    }
    func testExtraTrailingBytesWithholdFinalDeclaredChunk() async throws {
        await rejected { try await self.transfer(Data("abcdefX".utf8), declaration: stagedTestDeclaration(Data("abcdef".utf8))) }
        let result = await http.snapshot(); XCTAssertEqual(result.yielded, 3); XCTAssertEqual(result.objects, 0)
    }
    func testShortBodyCannotCreateOriginal() async throws {
        await rejected { try await self.transfer(Data("abc".utf8), declaration: stagedTestDeclaration(Data("abcdef".utf8))) }
        let result = await http.snapshot(); XCTAssertEqual(result.objects, 0)
    }
    func testPersistedReadbackChecksumIsRequiredDespiteSuccessfulPUTAndETag() async throws {
        await http.configure(corrupt: true)
        await rejected { try await self.transfer(Data("opaque retained bytes".utf8)) }
        let result = await http.snapshot(); XCTAssertEqual(result.objects, 1); XCTAssertEqual(result.gets, 1)
    }
    func testLostResponseRecoversThrough412WithoutOverwriting() async throws {
        let bytes = Data("same immutable bytes".utf8)
        await http.configure(lost: true)
        await rejected { try await self.transfer(bytes) }
        try await transfer(bytes)
        let result = await http.snapshot(); XCTAssertEqual(result.puts, 2); XCTAssertEqual(result.objects, 1); XCTAssertEqual(result.yielded, bytes.count)
    }
    func testReadbackAndInputEnforceBoundsInsteadOfAWSCollectMetadata() async throws {
        let data = Data(repeating: 1, count: StagedImportOriginalBytes.maximumChunkBytes + 1)
        let declaration = stagedTestDeclaration(data), budget = try StagedImportIOBudget()
        await rejected { try await StagedImportOriginalBytes.measure(.init(buffer: ByteBuffer(data: data)), declaration: declaration, budget: budget) }
        await rejected { try StagedImportOriginalBytes.validate(.init(sha256: declaration.sha256, bytes: StagedImportOriginalBytes.maximumBytes + 1)) }
        await rejected { try StagedImportOriginalBytes.validate(.init(sha256: declaration.sha256.uppercased(), bytes: 0)) }
    }
    struct Stalled: AsyncSequence, Sendable {
        typealias Element = ByteBuffer
        struct AsyncIterator: AsyncIteratorProtocol {
            mutating func next() async throws -> ByteBuffer? { try await Task.sleep(for: .seconds(30)); return nil }
        }
        func makeAsyncIterator() -> AsyncIterator { .init() }
    }
    func testCooperativeDeadlineCancelsAStalledByteStream() async throws {
        let budget = try StagedImportIOBudget(duration: .milliseconds(20)), start = ContinuousClock.now
        do {
            try await budget.run { try await StagedImportOriginalBytes.measure(.init(asyncSequence: Stalled(), length: nil), declaration: stagedTestDeclaration(Data()), budget: budget) }
            XCTFail("Expected timeout")
        } catch StagedImportOriginalError.deadlineExceeded {} catch { XCTFail("Unexpected timeout classification") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
    func testCancellationNeverBecomesAnOpaqueStorageError() async throws {
        let budget = try StagedImportIOBudget()
        let task = Task { try await budget.run { try await StagedImportOriginalBytes.measure(.init(asyncSequence: Stalled(), length: nil), declaration: stagedTestDeclaration(Data()), budget: budget) } }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Cancellation lost") }
    }
}
