@testable import App
import XCTVapor
import SotoS3
import Foundation

/// The real-R2 gate: the one place the fence mechanism is exercised against
/// Cloudflare rather than against a fake HTTP seam.
///
/// It is skipped unless somebody has deliberately supplied real credentials, so an
/// ordinary run never touches a bucket. What it proves is the part no local test
/// can: that R2 itself stores a fence exactly as written, hands it back byte for
/// byte, and — the counterexample — that an unconditional writer really can
/// overwrite one, which is why the conditional protocol is load-bearing rather
/// than decorative.
///
/// **The fences it writes are left in place.** Demonstrating that the barrier works
/// and then removing it would prove the opposite of what the gate is for. They are
/// zero-byte objects under their own prefix.
final class R2FenceGateTests: XCTestCase {

    private var store: R2ObjectErasureFenceStore!
    private var target: ObjectStorageWriteTarget!
    private var evidence: [String: Any] = [:]

    override func setUpWithError() throws {
        try XCTSkipUnless(Environment.get("R2_ERASURE_FENCE_ENABLED") == "true",
                          "The real-R2 gate runs only when deliberately enabled")
        let configuration = try XCTUnwrap(try R2ObjectErasureFenceConfiguration.load(environment: .testing),
                                          "Fence configuration is not loadable")
        target = configuration.target
        store = try XCTUnwrap(try R2ObjectErasureFenceStore.makeIfEnabled(target: configuration.target, environment: .testing))
    }

    override func tearDown() async throws {
        if let store { try? await store.shutdown() }
        store = nil
        if !evidence.isEmpty {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r2-fence-gate-\(name.filter(\.isLetter)).json")
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("GATE EVIDENCE \(url.path)")
        }
    }

    private func key(_ label: String) -> String { target.namespace + "gate-\(label)-\(UUID().uuidString.lowercased())" }
    private var marker: [String: String] { ["snaglist-erasure": ObjectErasureFenceService.marker] }

    /// An unconditional S3 writer, standing in for the legacy code path. This is
    /// the shape of writer the create-only protocol exists to displace.
    private func writeUnconditionally(_ bytes: Data, to key: String, contentType: String = "image/jpeg") async throws {
        let client = AWSClient(credentialProvider: .static(
            accessKeyId: try XCTUnwrap(Environment.get("R2_ACCESS_KEY_ID")),
            secretAccessKey: try XCTUnwrap(Environment.get("R2_SECRET_ACCESS_KEY"))))
        defer { Task { try? await client.shutdown() } }
        let s3 = S3(client: client, region: .init(rawValue: "auto"),
                    endpoint: "https://\(target.backendIdentity).r2.cloudflarestorage.com",
                    options: [.s3DisableChunkedUploads])
        _ = try await s3.putObject(.init(body: .init(buffer: ByteBuffer(data: bytes)), bucket: target.bucket,
                                         contentType: contentType, key: key))
    }

    // MARK: the fence itself

    /// A fence written to R2 comes back exactly as written: zero bytes, the fixed
    /// content type, the fixed marker, and an etag the provider chose.
    func testAFenceIsStoredAndReadBackExactly() async throws {
        let key = key("exact")
        let written = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
        XCTAssertFalse(written.isEmpty)
        let read = try await store.readFence(key: key, maximumBytes: 1)
        XCTAssertEqual(read.target, target)
        XCTAssertEqual(read.key, key)
        XCTAssertEqual(read.byteCount, 0)
        XCTAssertTrue(read.body.isEmpty)
        XCTAssertEqual(read.contentType, ObjectErasureFenceService.contentType)
        XCTAssertEqual(read.metadata, marker)
        XCTAssertEqual(read.etag, written, "the etag the provider returned on write is the one it serves on read")
        evidence = ["key": key, "etag": written, "bucket": target.bucket, "namespace": target.namespace]
    }

    /// The ordinary case: real content exists, and the fence replaces it. What is
    /// left is the constant empty fence, not a truncated or partial object.
    func testAFenceReplacesRealContentWithTheConstantEmptyObject() async throws {
        let key = key("replaces")
        try await writeUnconditionally(Data(repeating: 0x7A, count: 4_096), to: key)
        _ = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
        let read = try await store.readFence(key: key, maximumBytes: 1)
        XCTAssertEqual(read.byteCount, 0)
        XCTAssertEqual(read.metadata, marker)
        evidence = ["key": key, "replacedBytes": 4_096]
    }

    /// Writing the same fence twice is not a second fence. A lost acknowledgement
    /// followed by a retry leaves exactly the same object.
    func testRepeatingAFenceIsIdempotentInSubstance() async throws {
        let key = key("repeat")
        _ = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
        _ = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
        let read = try await store.readFence(key: key, maximumBytes: 1)
        XCTAssertEqual(read.byteCount, 0)
        XCTAssertEqual(read.metadata, marker)
        evidence = ["key": key]
    }

    // MARK: the required counterexample

    /// **This test asserts the danger is real.** An unconditional writer overwrites
    /// a fence. If R2 refused it, every conditional test would be proving nothing,
    /// because the refusal would not be coming from the header we rely on.
    ///
    /// It runs on its own throwaway key, so no retained barrier is disturbed.
    func testAnUnconditionalWriterOverwritesAFenceWhichIsWhyTheProtocolMatters() async throws {
        let key = key("counterexample")
        _ = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
        try await writeUnconditionally(Data(repeating: 0x41, count: 32), to: key)
        do {
            _ = try await store.readFence(key: key, maximumBytes: 1)
            XCTFail("the counterexample must overwrite the fence; if it did not, the conditional tests prove nothing")
        } catch {
            // Expected: the object is no longer a fence.
        }
        evidence = ["key": key, "outcome": "fence overwritten by an unconditional writer, as required"]
    }

    // MARK: the number the disclosed timeframe depends on

    /// Measures sustained fence throughput: request, write, read back, per key.
    /// Fable's threshold is one key per second — at or above it the public wording
    /// is "normally within 24 hours", below it "within a few days".
    func testFenceThroughput() async throws {
        let count = Int(Environment.get("R2_FENCE_GATE_SAMPLES") ?? "20") ?? 20
        var keys: [String] = []
        let started = Date()
        for index in 0..<count {
            let key = key("throughput-\(index)")
            _ = try await store.replaceWithEmptyFence(key: key, contentType: ObjectErasureFenceService.contentType, metadata: marker)
            let read = try await store.readFence(key: key, maximumBytes: 1)
            XCTAssertEqual(read.byteCount, 0)
            keys.append(key)
        }
        let elapsed = Date().timeIntervalSince(started)
        let perSecond = Double(count) / elapsed
        let perTwoMinutePass = perSecond * 120
        print(String(format: "GATE THROUGHPUT %d keys in %.2fs = %.2f keys/second, %.0f per 120s pass", count, elapsed, perSecond, perTwoMinutePass))
        evidence = ["keys": count, "elapsedSeconds": elapsed, "keysPerSecond": perSecond,
                    "keysPerPass": perTwoMinutePass, "meetsOnePerSecond": perSecond >= 1.0,
                    "firstKey": keys.first ?? "", "lastKey": keys.last ?? ""]
        XCTAssertGreaterThan(perSecond, 0)
    }
}
