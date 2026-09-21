@testable import App
import XCTVapor
import Foundation

/// The real-R2 gate for the **content** store — the create-only protocol B2 and
/// B3 are built on.
///
/// Its sibling `R2FenceGateTests` proves the *fence* against Cloudflare. Until
/// this class existed, `PrivateContentStore` had met nothing but an in-memory
/// double (`InMemoryPrivateContentStore`) and a fake HTTP transport
/// (`PrivateContentStoreTests`), so every belief about what R2 answers a
/// create-only PUT, or a GET of an address nothing ever wrote, was a belief about
/// the double. Fable's B5 §5 item 3 names the sharpest of them: *"`absent` is
/// real (B0.1 was tested against a stub) … this is the one B0.1 behaviour no test
/// has run against the real status line."*
///
/// Five facts, none of which a local test can establish:
/// 1. a GET of a never-written namespaced key reaches `absent`, not `transportUnavailable`;
/// 2. a first PUT is `created`, and the readback is our own bytes with our digest;
/// 3. a second PUT to a taken address is refused by R2's own 412, and the first writer's bytes remain;
/// 4. a fence takes the address, the **content** store reads what it finds as a fence, and every later content PUT is refused;
/// 5. the rendition address and the original address are independent.
///
/// Fact 4 is the join between the two stores. Each store has now been proven
/// against R2 on its own; nothing had ever shown that an object one of them wrote
/// is a thing the other recognises, and the entire deletion story rests on it.
///
/// **What it writes is left in place.** Demonstrating that a barrier works and
/// then removing it would prove the opposite of what a gate is for. Everything is
/// under the gate's own `fence-gate-v1/` prefix — never `private-v1/`, so no gate
/// object sits at an address a real photograph will occupy — and both identifier
/// segments of every key are a fixed `b5a0…` sentinel, so a bucket listing says
/// at a glance which packet wrote them. The objects are a few hundred synthetic
/// bytes each, or zero-byte fences.
///
/// Skipped exactly as the fence gate is, on a deliberately supplied
/// `R2_PRIVATE_NAMESPACE`, so an ordinary suite run never touches a bucket.
///
/// Keys are drawn by `PrivateObjectAllocationPolicy`, not written by hand, so what
/// is exercised is the address shape the product actually writes — including the
/// server nonce and the content-addressed rendition — rather than a string that
/// happens to satisfy the validator.
final class R2PrivateContentGateTests: XCTestCase {

    private var store: R2PrivateContentStore!
    private var fenceStore: R2ObjectErasureFenceStore!
    private var target: ObjectStorageWriteTarget!
    private var app: Application?
    private var evidence: [String: Any] = [:]

    override func setUpWithError() throws {
        try XCTSkipUnless(Environment.get("R2_PRIVATE_NAMESPACE") != nil,
                          "The real-R2 gate runs only when deliberately enabled")
        let configuration = try XCTUnwrap(try PrivateStorageTargetConfiguration.load(environment: .testing),
                                          "Private storage configuration is not loadable")
        target = configuration.target
        store = try XCTUnwrap(try R2PrivateContentStore.makeIfConfigured(target: configuration.target, environment: .testing))
        // Both stores are built from one reading of the environment, which is the
        // point of the shared configuration: fact 4 could not even be stated if
        // they could be pointed at different buckets.
        fenceStore = try XCTUnwrap(try R2ObjectErasureFenceStore.makeIfEnabled(target: configuration.target, environment: .testing))
        XCTAssertEqual(fenceStore.target, store.target, "the fence and the content it fences are one target")
    }

    override func tearDown() async throws {
        if let store { try? await store.shutdown() }
        store = nil
        if let fenceStore { try? await fenceStore.shutdown() }
        fenceStore = nil
        if let app { try await app.asyncShutdown() }
        app = nil
        if !evidence.isEmpty {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r2-content-gate-\(name.filter(\.isLetter)).json")
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("GATE EVIDENCE \(url.path)")
        }
    }

    // MARK: drawing the addresses

    /// Obviously synthetic and obviously this packet's: every key the gate draws
    /// carries the same two `b5a0` sentinels where a real object carries a
    /// workspace and a project. Only the third segment — the server nonce the
    /// policy itself draws — is random.
    private static let gateWorkspace = UUID(uuidString: "b5a0b5a0-b5a0-4b5a-8b5a-b5a0b5a0b5a0")!
    private static func gateProject(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "b5a00000-0000-4b5a-8b5a-%012d", index))!
    }

    /// The allocation policy resolves its target from the same environment the two
    /// stores did. Asserting that here is the statement that there is one loader
    /// and one target, rather than three values that happen to match on the day.
    private func allocator() async throws -> Application {
        if let app { return app }
        let made = try await Application.make(.testing)
        app = made
        guard case .installed(let resolved) = PrivateObjectAllocationPolicy.install(app: made) else {
            XCTFail("the private namespace must resolve as installed for the gate to run")
            return made
        }
        XCTAssertEqual(resolved.target, target, "one loader, one target: the policy and the stores must agree")
        return made
    }

    private func allocateOriginal(_ index: Int) async throws -> PrivateObjectAllocationPolicy.Allocation {
        let app = try await allocator()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(
            workspaceID: Self.gateWorkspace, projectID: Self.gateProject(index), app: app)
        XCTAssertEqual(allocation.target, target)
        XCTAssertEqual(allocation.storageKind, "private_media")
        XCTAssertEqual(allocation.role, .original)
        XCTAssertTrue(allocation.key.hasPrefix(target.namespace + "media/"),
                      "a gate object never leaves the gate's own prefix")
        XCTAssertTrue(allocation.key.hasSuffix("/original"))
        return allocation
    }

    /// A few hundred bytes with a genuine signature, which is all the store will
    /// accept and all a gate needs. Distinct fills so a readback cannot pass by
    /// meeting some other test's object.
    private func syntheticJPEG(_ fill: UInt8, count: Int = 512) -> Data {
        Data([0xFF, 0xD8, 0xFF]) + Data(repeating: fill, count: count)
    }
    private func syntheticPNG(_ fill: UInt8, count: Int = 512) -> Data {
        Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: fill, count: count)
    }
    private var fenceMetadata: [String: String] { ["snaglist-erasure": ObjectErasureFenceService.marker] }

    // MARK: 1 — absence is real

    /// **The assertion this packet exists for.** B0.1 taught the reader to tell
    /// "nothing is there" apart from "storage did not answer", because a caller
    /// that has just written bytes acts differently on each. That distinction has
    /// only ever been made against a stub 404.
    ///
    /// Here R2 itself answers the 404, and it must reach `absent`. A
    /// `transportUnavailable` would mean the status-line branch in
    /// `R2PrivateContentHTTPClient` was not the thing that decided it — that
    /// absence was being inferred downstream from a parse failure, which is
    /// exactly the collapse B0.1 removed.
    ///
    /// That no body is read is decided at the same point and cannot be observed
    /// from out here: the 404 is thrown before a single header is inspected.
    /// `PrivateContentStoreTests.testAGETThatFindsNothingIsAbsentDecidedFromTheStatusLine`
    /// proves that half by attaching a body that never completes, so anything
    /// which collated it would stall rather than pass. This test proves the other
    /// half — that the status line R2 really sends is the one that branch reads.
    func testAReadOfANeverWrittenAddressIsAbsentDecidedFromTheRealStatusLine() async throws {
        let allocation = try await allocateOriginal(1)
        do {
            _ = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
            XCTFail("a namespaced key that was never written must not read back")
        } catch let error as PrivateContentStoreError {
            XCTAssertEqual(error, .absent,
                           "R2's own 404 must reach the reader's absent branch; transportUnavailable would mean absence was inferred rather than decided")
        } catch {
            XCTFail("the read answered with an unexpected error kind: \(type(of: error))")
        }
        // Repeating it is the same answer. Absence is a fact about an address,
        // not a transient a retry could resolve.
        do {
            _ = try await store.read(key: allocation.key, maximumBytes: 1)
            XCTFail("there is still nothing at that address")
        } catch let error as PrivateContentStoreError {
            XCTAssertEqual(error, .absent)
        } catch {
            XCTFail("the repeated read answered with an unexpected error kind: \(type(of: error))")
        }
        // The fence store meets the same 404 at the same address and has no
        // `absent` to answer with — `absent` is the content store's word. The
        // double models that asymmetry; nothing had checked it against a real
        // status line, and the deletion worker's retry logic depends on it.
        do {
            _ = try await fenceStore.readFence(key: allocation.key, maximumBytes: 1)
            XCTFail("there is no fence at an address nothing ever wrote")
        } catch R2ObjectErasureFenceError.transportUnavailable {
            // Expected: the fence reader has one failure word and this is it.
        } catch {
            XCTFail("the fence read answered with an unexpected error kind: \(type(of: error))")
        }
        evidence = ["key": allocation.key, "bucket": target.bucket, "namespace": target.namespace,
                    "outcome": "absent, decided from a real 404 status line"]
    }

    // MARK: 2 — a real create

    /// A first create-only PUT to a free address creates the object, and what R2
    /// serves back is our own bytes: the same length, the same digest, the same
    /// declared type, no user metadata, and the etag the provider named on write.
    ///
    /// The digest matters more than the bytes. Rows 5 and 11 of the write table
    /// settle an intent by proving that what is at an address is *this intent's*
    /// bytes, and they prove it by comparing this digest. If R2 re-encoded,
    /// padded or re-chunked what it stored, every one of those rows would be
    /// unreachable on real storage and a retried upload would take a terminal row
    /// instead.
    func testACreateOnlyPutCreatesTheObjectAndTheReadbackIsOurOwnBytes() async throws {
        let allocation = try await allocateOriginal(2)
        let bytes = syntheticJPEG(0x5A)
        let digest = PrivateImageProcessor.digest(bytes)
        let outcome = try await store.put(key: allocation.key, data: bytes, contentType: "image/jpeg")
        guard case .created(let etag) = outcome else {
            return XCTFail("a first create-only PUT to a free address must be created, not \(outcome)")
        }
        XCTAssertFalse(etag.isEmpty)
        let read = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertEqual(read.target, target)
        XCTAssertEqual(read.key, allocation.key)
        XCTAssertEqual(read.body, bytes, "the readback is our own bytes, byte for byte")
        XCTAssertEqual(read.byteCount, bytes.count)
        XCTAssertEqual(read.sha256, digest, "the digest we wrote is the digest R2 serves; rows 5 and 11 settle on this")
        XCTAssertEqual(read.contentType, "image/jpeg")
        XCTAssertTrue(read.metadata.isEmpty, "content carries no user metadata; only a fence does")
        XCTAssertFalse(read.isErasureFence, "content is not a fence, and an empty-looking reply would not make it one")
        XCTAssertEqual(read.etag, etag, "the etag the provider named on write is the one it serves on read")
        evidence = ["key": allocation.key, "etag": etag, "sha256": digest, "byteCount": bytes.count,
                    "outcome": "created by a real If-None-Match: * PUT, read back identical"]
    }

    // MARK: 3 — a real 412

    /// The create-only protocol, proven for *content* rather than for a fence.
    ///
    /// The Wave-1 fence gate proved the analogous transport fact for the fence
    /// store; this is the protocol B2 actually writes photographs with. R2 itself
    /// refuses the second `If-None-Match: *` PUT with a 412, the refusal arrives
    /// as an outcome rather than an error, and the first writer's bytes are what
    /// survives — not the second writer's, and not a merge of the two.
    ///
    /// The second writer deliberately brings different bytes *and* a different
    /// image type: what is taken is the address, never the content.
    func testASecondContentPutToATakenAddressIsRefusedByR2AndTheFirstWritersBytesRemain() async throws {
        let allocation = try await allocateOriginal(3)
        let first = syntheticJPEG(0x11)
        let firstDigest = PrivateImageProcessor.digest(first)
        let created = try await store.put(key: allocation.key, data: first, contentType: "image/jpeg")
        guard case .created(let etag) = created else {
            return XCTFail("the first writer must create the object, not \(created)")
        }
        let second = syntheticPNG(0x22)
        let refused = try await store.put(key: allocation.key, data: second, contentType: "image/png")
        XCTAssertEqual(refused, .alreadyExists,
                       "R2 itself must refuse the second create-only PUT; a created here would mean the whole protocol rests on nothing")
        let read = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertEqual(read.body, first, "the first writer's bytes are what survives a refused second write")
        XCTAssertEqual(read.sha256, firstDigest)
        XCTAssertEqual(read.contentType, "image/jpeg", "not the refused writer's declared type")
        XCTAssertEqual(read.etag, etag, "the object was never replaced")
        XCTAssertFalse(read.isErasureFence)
        evidence = ["key": allocation.key, "etag": etag, "sha256": firstDigest,
                    "outcome": "second content PUT refused by a real 412; first writer's bytes intact"]
    }

    // MARK: 4 — the join between the two stores

    /// **A fence wins the address, and the content store sees it as a fence.**
    ///
    /// This is the one fact only real R2 can establish, because it is a claim
    /// about two independently built stores meeting at one object: the fence store
    /// writes an unconditional zero-byte object with a fixed type and marker, and
    /// the *content* store — which is what a reader uses — must recognise what it
    /// finds there as a fence rather than as content, as an empty object, or as a
    /// malformed reply. A reader that could not tell those apart would answer a
    /// deleted photograph with a retryable failure instead of "this is gone for
    /// good", which is the whole deletion story.
    ///
    /// And the barrier has to hold afterwards: a later, retried or duplicated
    /// content writer at that address is refused by R2, never served a 200.
    ///
    /// The fence written here is left in place, as every fence this gate writes is.
    func testAFenceTakesTheAddressAndTheContentStoreReadsItAsAFenceAndRefusesEveryLaterWrite() async throws {
        let allocation = try await allocateOriginal(4)
        let bytes = syntheticJPEG(0x33)
        let created = try await store.put(key: allocation.key, data: bytes, contentType: "image/jpeg")
        guard case .created(let contentETag) = created else {
            return XCTFail("the content must exist before it can be fenced, got \(created)")
        }

        let fenceETag = try await fenceStore.replaceWithEmptyFence(
            key: allocation.key, contentType: ObjectErasureFenceService.contentType, metadata: fenceMetadata)
        XCTAssertFalse(fenceETag.isEmpty)
        XCTAssertNotEqual(fenceETag, contentETag, "the fence is a different object at the same address")

        let read = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertTrue(read.isErasureFence,
                      "a fenced address must read back through the content store as a fence, not as a failure")
        XCTAssertEqual(read.byteCount, 0)
        XCTAssertTrue(read.body.isEmpty)
        XCTAssertEqual(read.contentType, ObjectErasureFenceService.contentType)
        XCTAssertEqual(read.metadata, fenceMetadata, "the marker R2 stored is the marker the reader requires")
        XCTAssertEqual(read.etag, fenceETag)

        let refused = try await store.put(key: allocation.key, data: syntheticJPEG(0x44), contentType: "image/jpeg")
        XCTAssertEqual(refused, .alreadyExists,
                       "a fence holds its address against every later content writer; a created here is the one outcome that must never occur")
        let again = try await store.read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertTrue(again.isErasureFence, "and the refused write left the fence exactly as it was")
        XCTAssertEqual(again.etag, fenceETag)
        XCTAssertEqual(again.byteCount, 0)
        evidence = ["key": allocation.key, "contentETag": contentETag, "fenceETag": fenceETag,
                    "outcome": "fence read as a fence through the content store; later content PUT refused, fence unchanged"]
    }

    // MARK: 5 — two addresses, not one

    /// An object has two addresses, and they are separate objects on real storage.
    /// The rendition's address *is* its digest, so it is not derivable at
    /// allocation time and is not a decoration of the original's key: fencing one
    /// must leave the other exactly as it was.
    ///
    /// It matters because the deletion pass fences a manifest of keys, one at a
    /// time. If the two addresses were entangled at the provider — a common
    /// prefix treated as one object, say — a half-finished pass would either erase
    /// more than it was asked to or report a fence it had not placed.
    func testTheRenditionAddressAndTheOriginalAddressAreIndependent() async throws {
        let app = try await allocator()
        let original = try await allocateOriginal(5)
        let renditionBytes = syntheticJPEG(0x66)
        let renditionDigest = PrivateImageProcessor.digest(renditionBytes)
        let rendition = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: renditionDigest, app: app)
        XCTAssertEqual(rendition.role, .rendition)
        XCTAssertEqual(rendition.target, target)
        XCTAssertTrue(rendition.key.hasSuffix("view-\(renditionDigest).jpg"), "a rendition address is its own digest")
        XCTAssertNotEqual(rendition.key, original.key)

        let originalBytes = syntheticJPEG(0x55)
        let firstWrite = try await store.put(key: original.key, data: originalBytes, contentType: "image/jpeg")
        guard case .created(let originalETag) = firstWrite else {
            return XCTFail("the original address must be free, got \(firstWrite)")
        }
        let secondWrite = try await store.put(key: rendition.key, data: renditionBytes, contentType: "image/jpeg")
        guard case .created(let renditionETag) = secondWrite else {
            return XCTFail("the rendition address must be free, got \(secondWrite)")
        }
        XCTAssertNotEqual(originalETag, renditionETag, "two addresses, two objects")

        // Fence exactly one of the two.
        _ = try await fenceStore.replaceWithEmptyFence(
            key: original.key, contentType: ObjectErasureFenceService.contentType, metadata: fenceMetadata)

        let fenced = try await store.read(key: original.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertTrue(fenced.isErasureFence, "the address that was fenced reads as a fence")
        let survivor = try await store.read(key: rendition.key, maximumBytes: PrivateContent.maximumBytes)
        XCTAssertFalse(survivor.isErasureFence, "fencing the original must not fence the rendition")
        XCTAssertEqual(survivor.body, renditionBytes)
        XCTAssertEqual(survivor.sha256, renditionDigest, "and the rendition still hashes to its own address")
        XCTAssertEqual(survivor.contentType, "image/jpeg")
        XCTAssertEqual(survivor.etag, renditionETag)
        evidence = ["originalKey": original.key, "renditionKey": rendition.key,
                    "renditionSHA256": renditionDigest,
                    "outcome": "original fenced; rendition at its content address untouched"]
    }
}
