@testable import App
import Fluent
import FluentSQL
import XCTVapor

/// The allocation policy: the one place that decides which target and which key an
/// object gets, and that records the write intent the deletion fence later reads.
///
/// What these hold is the pair of properties the fence depends on. An address is
/// never reused, so a fence can never stand in the way of somebody else's upload;
/// and an intent recorded through this policy is offered to the fence pass with
/// exactly the target it was allocated against, rather than with no target at all,
/// which is what every intent in the system carries today.
final class PrivateObjectAllocationPolicyTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    // MARK: fixtures

    @discardableResult
    private func installNamespace() throws -> PrivateStorageTargetConfiguration {
        let configuration = try InMemoryPrivateContentStore.syntheticConfiguration()
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration
        return configuration
    }
    private func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// Genuine leading bytes. The policy now refuses a payload that is not the
    /// image it is declared to be before an intent exists, so a fixture that is
    /// merely a string is no longer content anything would accept.
    private func png(_ tail: String = "synthetic") -> Data { Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(tail.utf8) }
    private func jpeg(_ tail: String = "synthetic") -> Data { Data([255, 216, 255]) + Data(tail.utf8) }

    private func assertFails(_ expected: PrivateObjectAllocationPolicy.Failure, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        do {
            try body()
            XCTFail(message, file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PrivateObjectAllocationPolicy.Failure, expected, message, file: file, line: line)
        }
    }

    // MARK: which kinds move

    /// Six storage kinds exist and exactly one of them is written into the private
    /// namespace. The other five are not unfinished — the private content store has
    /// no shape that can hold a drawing page or an import object.
    func testExactlyOneStorageKindIsWrittenIntoThePrivateNamespace() throws {
        XCTAssertEqual(try PrivateObjectAllocationPolicy.placement(ofKind: "private_media"), .privateNamespace)
        for kind in ["private_drawing", "private_import", "legacy_photo", "legacy_drawing", "legacy_completion_photo"] {
            XCTAssertEqual(try PrivateObjectAllocationPolicy.placement(ofKind: kind), .legacy, kind)
        }
        XCTAssertEqual(PrivateObjectAllocationPolicy.storageKinds.count, 6)
        assertFails(.kindUnknown, "a kind nobody has placed is never guessed at") {
            _ = try PrivateObjectAllocationPolicy.placement(ofKind: "private_video")
        }
    }

    /// A kind that stays where it is cannot be allocated into the namespace by
    /// asking a different way.
    func testAKindThatStaysWhereItIsIsNeverAllocatedIntoTheNamespace() throws {
        let configuration = try installNamespace()
        let key = configuration.target.namespace + "media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original"
        assertFails(.keyKindMismatch, "a drawing key inside the media namespace is a contradiction, not an adoption") {
            _ = try PrivateObjectAllocationPolicy.binding(kind: "private_drawing", key: key, app: self.app)
        }
    }

    // MARK: the switch

    /// Off and misconfigured are different facts and keep different reasons. Only
    /// one of them is somebody's mistake.
    func testTheSwitchBeingOffIsNotTheSameRefusalAsTheSwitchBeingWrong() throws {
        XCTAssertNil(app.storage[PrivateObjectAllocationPolicy.InjectionKey.self])
        assertFails(.namespaceUnavailable, "with the switch off there is no private namespace") {
            _ = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: self.app)
        }
        // The switch on, and a namespace that is not a plain prefix behind it.
        let broken = ["R2_PRIVATE_NAMESPACE": "not-a-prefix"]
        PrivateObjectAllocationPolicy.install(app: app, lookup: { broken[$0] })
        assertFails(.namespaceUnusable, "a switch that is on and wrong never falls back to the legacy address") {
            _ = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: self.app)
        }
    }

    /// `.legacy` is a positive statement about an address, not a fallback. With no
    /// namespace installed a historical key binds to its historical address, and a
    /// namespaced-looking one is refused with the installation's own reason.
    ///
    /// The behaviour this replaces returned `.legacy` for both, which routed every
    /// namespaced read back through the legacy reader, whose validator then
    /// rejected the key as a 500. Switching the namespace off must fail closed with
    /// a reason a runbook can act on, not open on a shape accident.
    func testWithoutANamespaceAHistoricalKeyBindsAndANamespacedOneKeepsTheInstallationsReason() throws {
        let looksNamespaced = "immutable-v1/media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original"
        let historical = "platform/\(UUID().uuidString)/\(UUID().uuidString)/\(UUID().uuidString)/original"

        XCTAssertNil(app.storage[PrivateObjectAllocationPolicy.InjectionKey.self])
        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: historical, app: app), .legacy)
        assertFails(.namespaceUnavailable, "with the switch off a namespaced key is refused, never handed to the legacy reader") {
            _ = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: looksNamespaced, app: self.app)
        }

        // The switch on, and a namespace that is not a plain prefix behind it. The
        // two states keep different reasons here for the same runbook reason they
        // keep different reasons at allocation.
        let broken = ["R2_PRIVATE_NAMESPACE": "not-a-prefix"]
        PrivateObjectAllocationPolicy.install(app: app, lookup: { broken[$0] })
        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: historical, app: app), .legacy)
        assertFails(.namespaceUnusable, "and a switch that is on and wrong is not the same fact as a switch that is off") {
            _ = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: looksNamespaced, app: self.app)
        }

        // A kind that does not move is at its historical address whatever the key
        // looks like, because there is no installed namespace for it to be inside.
        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_drawing", key: looksNamespaced, app: app), .legacy)
    }

    /// And with a namespace installed, the only media key still at its historical
    /// address is one under `platform/`. A key that is neither historical nor
    /// inside the namespace is an address this policy never allocated, and it is
    /// refused as one rather than adopted as legacy.
    func testWithANamespaceInstalledOnlyAHistoricalKeyIsStillLegacy() throws {
        try installNamespace()
        let historical = "platform/\(UUID().uuidString)/\(UUID().uuidString)/\(UUID().uuidString)/original"
        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: historical, app: app), .legacy)

        for foreign in ["uploads/synced-photos/\(UUID()).jpg",
                        "drawings/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original",
                        "other-v1/media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original"] {
            assertFails(.keyNotAllocatable, "neither historical nor namespaced is not an address: \(foreign)") {
                _ = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: foreign, app: self.app)
            }
        }
    }

    // MARK: the key

    /// The allocated key is exactly the shape the private content store will accept,
    /// which is the only shape a fence can later be verified against.
    func testAnAllocatedKeyIsTheShapeTheContentStoreAccepts() throws {
        let configuration = try installNamespace()
        let workspace = UUID(), project = UUID()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: workspace, projectID: project, app: app)

        XCTAssertEqual(allocation.storageKind, "private_media")
        XCTAssertEqual(allocation.target, configuration.target)
        XCTAssertEqual(allocation.role, .original)
        XCTAssertNoThrow(try configuration.validateContentKey(allocation.key))

        let inside = String(allocation.key.dropFirst(configuration.target.namespace.count)).split(separator: "/")
        XCTAssertEqual(inside.count, 5)
        XCTAssertEqual(String(inside[0]), "media")
        XCTAssertEqual(String(inside[1]), lower(workspace))
        XCTAssertEqual(String(inside[2]), lower(project))
        XCTAssertEqual(String(inside[4]), "original")
        XCTAssertNotNil(UUID(uuidString: String(inside[3])))
        XCTAssertEqual(allocation.key, allocation.key.lowercased(), "one object has one key, so the case is fixed")
    }

    /// The property the nonce exists for: an address is spent once and is never
    /// re-derivable from the identifiers a client supplies. A fence that takes an
    /// address can therefore never stand in the way of a later upload.
    func testTwoAllocationsForTheSameProjectNeverShareAnAddress() throws {
        try installNamespace()
        let workspace = UUID(), project = UUID()
        let first = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: workspace, projectID: project, app: app)
        let second = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: workspace, projectID: project, app: app)

        XCTAssertNotEqual(first.key, second.key, "identical caller input must not produce the same address twice")
        let left = first.key.split(separator: "/"), right = second.key.split(separator: "/")
        XCTAssertEqual(Array(left.dropLast(2)), Array(right.dropLast(2)), "only the nonce differs")
        XCTAssertNotEqual(left.dropLast().last, right.dropLast().last, "and the nonce is what differs")
        XCTAssertNotEqual(String(left.dropLast().last ?? ""), lower(workspace))
        XCTAssertNotEqual(String(left.dropLast().last ?? ""), lower(project),
                          "the address does not repeat an identifier the caller chose")
    }

    /// A rendition has no address until its bytes exist, and then its address is
    /// its own digest — which is what makes a retry meet its earlier object rather
    /// than create a second one that no manifest knows about.
    func testARenditionAddressIsItsOwnDigest() throws {
        let configuration = try installNamespace()
        let original = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        let bytes = Data("synthetic rendition bytes".utf8), digest = PrivateImageProcessor.digest(bytes)
        let rendition = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: digest, app: app)

        XCTAssertEqual(rendition.role, .rendition)
        XCTAssertEqual(rendition.target, original.target)
        XCTAssertTrue(rendition.key.hasSuffix("view-\(digest).jpg"))
        XCTAssertEqual(String(rendition.key.dropLast("view-\(digest).jpg".count)),
                       String(original.key.dropLast("original".count)),
                       "a rendition sits beside its original, never somewhere else")
        XCTAssertNoThrow(try configuration.validateContentKey(rendition.key))

        assertFails(.digestInvalid, "an address is never built from something that is not a digest") {
            _ = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: "not-a-digest", app: self.app)
        }
        assertFails(.digestInvalid, "an uppercase digest is a second address for one object") {
            _ = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: digest.uppercased(), app: self.app)
        }
        assertFails(.keyNotAllocatable, "a rendition of a rendition is not a thing") {
            _ = try PrivateObjectAllocationPolicy.rendition(of: rendition, sha256: digest, app: self.app)
        }
    }

    /// A stale allocation is never quietly re-pointed at whatever is configured now.
    func testAnAllocationIsNeverRepointedAtADifferentTarget() throws {
        try installNamespace()
        let original = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] =
            try InMemoryPrivateContentStore.syntheticConfiguration(bucket: "synthetic-private-other")
        assertFails(.targetMismatch, "an allocation belongs to the target it was made against") {
            _ = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: PrivateImageProcessor.digest(Data("x".utf8)), app: self.app)
        }
    }

    // MARK: binding a key a row already carries

    func testAStoredKeyBindsToWhereItActuallyLives() throws {
        let configuration = try installNamespace()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)

        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: allocation.key, app: app),
                       .privateNamespace(allocation))
        // The shape every media object written before this packet carries: no
        // namespace, uppercase identifiers, and a `platform/` prefix.
        let historical = "platform/\(UUID().uuidString)/\(UUID().uuidString)/\(UUID().uuidString)/original"
        XCTAssertEqual(try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: historical, app: app), .legacy)

        let unallocatable = configuration.target.namespace + "media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/other"
        assertFails(.keyNotAllocatable, "a key inside the namespace that this policy never allocates is refused, not adopted") {
            _ = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: unallocatable, app: self.app)
        }
    }

    /// The placeholder a media row carries from allocation until processing. It is
    /// refused as itself, because a caller that meets it has met a real thing and
    /// needs to know which thing.
    func testTheRenditionPlaceholderIsRefusedAsItselfAndNotAsCorruption() throws {
        let configuration = try installNamespace()
        let placeholder = configuration.target.namespace + "media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/view.jpg"
        assertFails(.renditionPlaceholder, "the allocation placeholder is a known address with no object, not a malformed key") {
            _ = try PrivateObjectAllocationPolicy.binding(kind: "private_media", key: placeholder, app: self.app)
        }
    }

    // MARK: what may be written to an address

    func testContentMustMatchTheAddressItWouldBeWrittenTo() throws {
        try installNamespace()
        let original = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        let bytes = jpeg("rendition")
        let rendition = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: PrivateImageProcessor.digest(bytes), app: app)

        XCTAssertNoThrow(try PrivateObjectAllocationPolicy.requireContent(original, data: png(), contentType: "image/png"))
        XCTAssertNoThrow(try PrivateObjectAllocationPolicy.requireContent(rendition, data: bytes, contentType: "image/jpeg"))

        assertFails(.renditionDigestMismatch, "bytes that do not hash to a content-addressed key are refused before anything is recorded") {
            try PrivateObjectAllocationPolicy.requireContent(rendition, data: self.jpeg("other"), contentType: "image/jpeg")
        }
        assertFails(.contentTypeNotAllowed, "a rendition is a JPEG at an address that says so") {
            try PrivateObjectAllocationPolicy.requireContent(rendition, data: self.png(), contentType: "image/png")
        }
        assertFails(.contentTypeNotAllowed, "the private namespace holds images and the fence that replaces them") {
            try PrivateObjectAllocationPolicy.requireContent(original, data: bytes, contentType: ObjectErasureFenceService.contentType)
        }

        // The three refusals the content store makes before its first byte leaves
        // the process. Made here, they are made before the intent row exists.
        assertFails(.contentInvalid, "a payload that is not the image it is declared to be") {
            try PrivateObjectAllocationPolicy.requireContent(original, data: self.png(), contentType: "image/jpeg")
        }
        assertFails(.contentInvalid, "an empty object is not content") {
            try PrivateObjectAllocationPolicy.requireContent(original, data: Data(), contentType: "image/jpeg")
        }
        assertFails(.contentInvalid, "nor is one larger than a private object may ever be") {
            try PrivateObjectAllocationPolicy.requireContent(
                original, data: self.jpeg() + Data(repeating: 0, count: PrivateContent.maximumBytes), contentType: "image/jpeg")
        }
    }

    /// The reason those checks moved. The intent commits **before** the PUT is
    /// issued, so a PUT the store refuses before its first byte leaves the process
    /// would leave an `uncertain` row behind for a write that provably never
    /// happened — and an unresolved row blocks its owner's deletion from completing
    /// until a fence resolves it. A refusal that costs nothing is made before the
    /// row exists rather than after it.
    func testContentTheStoreWouldRefuseIsRefusedBeforeAnIntentExists() async throws {
        let configuration = try installNamespace()
        let store = InMemoryPrivateContentStore(configuration: configuration)
        // B2 took the `operation` closure away: the policy issues the PUT itself,
        // through the store that owns the allocation's target. So the store is
        // injected rather than called by hand, and "the store was never reached"
        // is a statement about a store the policy really would have used.
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = store
        let userID = try await user()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        // A PNG, declared a JPEG: exactly what `R2PrivateContentStore.put` refuses.
        let declaredJPEG = png("this is a PNG")

        do {
            try await PrivateObjectAllocationPolicy.write(
                allocation, data: declaredJPEG, contentType: "image/jpeg",
                source: .init(kind: "media_asset", id: UUID()), app: app, on: app.db,
                authorize: { _ in .init(userID: userID) })
            XCTFail("a payload the store would refuse must never reach an intent row")
        } catch {
            XCTAssertEqual(error as? PrivateObjectAllocationPolicy.Failure, .contentInvalid)
        }

        let calls = await store.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "the refusal is made before the store is reached at all")
        let rows = try await VerifiedIdentityService.sql(app.db)
            .raw("SELECT id FROM object_write_intents WHERE object_key=\(bind: allocation.key)").all()
        XCTAssertTrue(rows.isEmpty, "and before the row that would have blocked a deletion until a fence resolved it")
    }

    // MARK: the recorded intent

    /// The seam is closed by type: `begin` takes the allocation, so a target is no
    /// longer something a caller can assemble and hand over. A target under a
    /// protocol the fence cannot use is unreachable rather than refused — an
    /// `Allocation` is built only from a loaded configuration, and that loader
    /// produces create-only targets and nothing else, which is why the guard for it
    /// survives in `begin` as an assertion with no test to reach it.
    ///
    /// What is left to check is that the object being recorded is the object that
    /// was allocated. A caller that allocated one address and then recorded another
    /// is refused by name rather than as a constraint violation from a trigger.
    func testAnObjectWhoseKeyIsNotItsAllocationsKeyIsRefusedWithItsOwnReason() async throws {
        try installNamespace()
        let userID = try await user()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        let elsewhere = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)

        let mismatched: [ObjectWriteIntentService.Object] = [
            // A second address in the same namespace: allocated, but not this one.
            .init(storageKind: "private_media", key: elsewhere.key, data: Data("x".utf8), contentType: "image/jpeg"),
            // An address outside the target's namespace entirely.
            .init(storageKind: "private_media", key: "platform/elsewhere/original", data: Data("x".utf8), contentType: "image/jpeg"),
            // The right address under a kind the allocation was not made for.
            .init(storageKind: "private_drawing", key: allocation.key, data: Data("x".utf8), contentType: "image/jpeg"),
        ]
        for object in mismatched {
            do {
                _ = try await app.db.transaction { db in
                    try await ObjectWriteIntentService.begin(
                        object, source: .init(kind: "media_asset", id: UUID()),
                        scope: .init(userID: userID), allocation: allocation, on: db)
                }
                XCTFail("an object that is not the one allocated must be refused when it is recorded: \(object.key)")
            } catch let error as Abort {
                XCTAssertEqual(error.identifier, "object_write_key_outside_target")
            }
        }
    }

    /// The whole packet, end to end against the consumer that was built first: an
    /// allocation, recorded through this policy, is offered to the fence pass with
    /// exactly the target it was allocated against.
    ///
    /// Today's eight intent call sites all pass no target at all, so no key in the
    /// system can be a candidate. This is what changes that.
    func testAnAllocatedWriteIsOfferedToTheFencePassWithExactlyItsTarget() async throws {
        let configuration = try installNamespace()
        let store = InMemoryPrivateContentStore(configuration: configuration)
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = store
        let userID = try await user()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)
        let bytes = jpeg("original")

        // Twice, because a repeated write of the same address is the ordinary retry
        // and must not turn the key into one whose writers disagree. Under B2 the
        // policy performs the PUT itself: the first takes the create, the second
        // meets its own object and settles on the readback that verifies it.
        for _ in 0..<2 {
            try await PrivateObjectAllocationPolicy.write(
                allocation, data: bytes, contentType: "image/jpeg",
                source: .init(kind: "media_asset", id: UUID()), app: app, on: app.db,
                authorize: { _ in .init(userID: userID) })
        }
        let recorded = await store.recordedCalls()
        XCTAssertEqual(recorded, [.put(key: allocation.key, byteCount: bytes.count, contentType: "image/jpeg"),
                                  .put(key: allocation.key, byteCount: bytes.count, contentType: "image/jpeg"),
                                  .read(key: allocation.key, maximumBytes: PrivateContent.maximumBytes)])

        let lease = try await endAndLease(userID)
        try await manifest(lease, key: allocation.key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertEqual(found.map(\.key), [allocation.key])
        XCTAssertEqual(found.first?.target, configuration.target)
        XCTAssertEqual(found.first?.kind, "private_media")
    }

    /// And the counterexample in the same shape: the way every intent is recorded
    /// today produces a key the fence pass will never offer.
    func testAnIntentRecordedWithoutATargetIsNeverOffered() async throws {
        try installNamespace()
        let userID = try await user()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: UUID(), projectID: UUID(), app: app)

        try await ObjectWriteIntentService.write(
            .init(storageKind: "private_media", key: allocation.key, data: Data("x".utf8), contentType: "image/jpeg"),
            source: .init(kind: "media_asset", id: UUID()), on: app.db,
            authorize: { _ in .init(userID: userID) }, operation: { })

        let lease = try await endAndLease(userID)
        try await manifest(lease, key: allocation.key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertTrue(found.isEmpty, "an intent with no target is never promoted into something fenceable")
    }

    // MARK: deletion fixtures

    private func user() async throws -> UUID {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("allocation-\(UUID())@example.test", name: "Synthetic writer", on: db).requireID()
        }
    }
    private func endAndLease(_ id: UUID) async throws -> AccountDeletionWorker.Lease {
        _ = try await AccountDeletionService.request(userID: id, body: .init(confirmation: "DELETE", receiptReference: UUID().uuidString + UUID().uuidString), app: app)
        let token = UUID()
        let row = try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: token),lease_expires_at=clock_timestamp()+INTERVAL '5 minutes' WHERE user_id=\(bind: id) RETURNING id").first()!
        return try .init(id: row.decode(column: "id", as: UUID.self), userID: id, token: token, attempt: 1)
    }
    private func manifest(_ lease: AccountDeletionWorker.Lease, kind: String = "private_media", key: String) async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key,attempts)
            VALUES(\(bind: lease.id),\(bind: kind),\(bind: key),0)
            ON CONFLICT DO NOTHING
            """).run()
    }
}
