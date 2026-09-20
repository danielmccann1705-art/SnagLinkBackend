@testable import App
import XCTVapor
import NIOCore

/// Nothing in `StorageService` may write to, or delete from, an address inside the
/// installed private namespace.
///
/// Every entry there either writes unconditionally or physically deletes, and the
/// namespace is built on neither being possible: an object is created once and
/// never overwritten, and a deletion replaces its bytes with an erasure fence that
/// has to stay at that address for good. One unconditional PUT would overwrite a
/// fence back into content; one DELETE would remove it. Both turn "permanently
/// unreadable" back into "readable", which is the single promise the whole
/// mechanism makes.
///
/// Until B3 the only thing keeping them apart was a coincidence of shapes — the
/// legacy validators happen to demand the legacy prefixes. These hold the rule
/// that replaced the coincidence, and the other half of it: that everything those
/// entries accepted before still goes through.
final class StorageMutationRefusalTests: XCTestCase {
    var app: Application!
    var configuration: PrivateStorageTargetConfiguration!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        configuration = try InMemoryPrivateContentStore.syntheticConfiguration()
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func installNamespace() { app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration }
    private func lower(_ id: UUID) -> String { id.uuidString.lowercased() }
    private var namespace: String { configuration.target.namespace }
    private func namespaced(_ suffix: String = "original") -> String {
        namespace + "media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/" + suffix
    }
    private let digest = String(repeating: "ab", count: 32)

    /// Refused by the namespace rule itself, with its own identifier, as an
    /// internal fault: no route can reach these entries with a caller-supplied key,
    /// so meeting this is a server bug and the identifier is for the operator.
    private func assertNamespaceRefusal(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                        _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail(message, file: file, line: line)
        } catch {
            let abort = error as? Abort
            XCTAssertEqual(abort?.identifier, "private_namespace_mutation_refused", message, file: file, line: line)
            XCTAssertEqual(abort?.status, .internalServerError, message, file: file, line: line)
        }
    }
    /// Refused, but not by this rule. Used where an entry's own shape logic is the
    /// thing that has always refused and must keep refusing.
    private func assertRefusedButNotByTheNamespaceRule(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                                       _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail(message, file: file, line: line)
        } catch {
            XCTAssertNotEqual((error as? Abort)?.identifier, "private_namespace_mutation_refused", message, file: file, line: line)
        }
    }

    // MARK: the refusal

    /// Every writing and deleting entry, refused before any shape logic runs — and
    /// for `deleteAccountObject`, under every one of the six storage kinds, because
    /// the kind is not what makes an address part of the namespace.
    func testEveryStorageMutationRefusesAKeyInsideTheInstalledNamespace() async throws {
        installNamespace()
        let key = namespaced()

        await assertNamespaceRefusal("the public writer never writes into the private namespace") {
            try await StorageService.upload(data: ByteBuffer(data: Self.png), key: key, contentType: "image/png", app: self.app)
        }
        await assertNamespaceRefusal("the unconditional private writer is exactly what a fence must be safe from") {
            try await StorageService.uploadPrivate(Self.png, key: key, mime: "image/png", app: self.app)
        }
        await assertNamespaceRefusal("snag deletion never removes a namespaced object") {
            try await StorageService.deleteOwnedSyncedPhoto(key: key, app: self.app)
        }
        for kind in PrivateObjectAllocationPolicy.storageKinds.sorted() {
            await assertNamespaceRefusal("a namespaced key is refused under \(kind): the kind is not what puts an address in the namespace") {
                try await StorageService.deleteAccountObject(kind: kind, key: key, app: self.app)
            }
        }
        // And nothing was created anywhere on the way to being refused.
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.publicDirectory + key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.workingDirectory + "PrivateMedia/" + key))
    }

    /// A key that carries a leading slash is the same address. The two legacy
    /// entries strip it before they act, so a refusal that only looked at the
    /// spelling it was handed would let the slashed form through to storage as its
    /// unslashed self.
    func testALeadingSlashDoesNotSmuggleANamespacedKeyPastTheRefusal() async throws {
        installNamespace()
        let key = "/" + namespaced()
        await assertNamespaceRefusal("a slashed namespaced key is still a namespaced key") {
            try await StorageService.deleteOwnedSyncedPhoto(key: key, app: self.app)
        }
        await assertNamespaceRefusal("and it is still one in the deletion path") {
            try await StorageService.deleteAccountObject(kind: "legacy_photo", key: key, app: self.app)
        }
    }

    // MARK: what the same entries still accept

    /// The other half of the rule. A refusal that also refused the legacy families
    /// would have stopped account deletion working at all, so each entry is shown
    /// accepting exactly what it accepted before the namespace existed — with the
    /// namespace installed the whole time.
    func testTheSameEntriesStillAcceptEveryHistoricalAddressTheyAccepted() async throws {
        installNamespace()
        let publicKey = "uploads/photos/\(UUID().uuidString).jpg"
        try await StorageService.upload(data: ByteBuffer(data: Self.png), key: publicKey, contentType: "image/png", app: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.directory.publicDirectory + publicKey))

        let privateKey = "platform/\(UUID().uuidString)/\(UUID().uuidString)/\(UUID().uuidString)/original"
        try await StorageService.uploadPrivate(Self.png, key: privateKey, mime: "image/png", app: app)
        let stored = try await StorageService.downloadPrivate(key: privateKey, app: app)
        XCTAssertEqual(stored, Self.png)

        try await StorageService.deleteOwnedSyncedPhoto(key: "uploads/synced-photos/\(UUID().uuidString).jpg", app: app)
        try await StorageService.deleteAccountObject(kind: "legacy_photo", key: "uploads/synced-photos/\(UUID().uuidString).jpg", app: app)
        try await StorageService.deleteAccountObject(kind: "legacy_drawing", key: "uploads/synced-drawings/\(UUID().uuidString).jpg", app: app)
        try await StorageService.deleteAccountObject(kind: "legacy_completion_photo", key: publicKey, app: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.publicDirectory + publicKey))
        try await StorageService.deleteAccountObject(kind: "private_media", key: privateKey, app: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.workingDirectory + "PrivateMedia/" + privateKey))

        // These two have no local adapter, so they refuse for want of a configured
        // private bucket — which is what they did before B3 and must keep doing.
        for (kind, key) in [("private_import", "staged-import/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original"),
                            ("private_drawing", "drawings/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original")] {
            await assertRefusedButNotByTheNamespaceRule("\(kind) keeps its own refusal") {
                try await StorageService.deleteAccountObject(kind: kind, key: key, app: self.app)
            }
        }
    }

    /// With no namespace installed there is no address that could be inside one, so
    /// the rule has nothing to say and the entry's own shape logic is what refuses.
    /// A deployment that does not use private storage is not one where this rule
    /// silently starts refusing legacy work.
    func testWithNoNamespaceInstalledThereIsNothingForTheRuleToRefuse() async throws {
        XCTAssertNil(app.storage[PrivateObjectAllocationPolicy.InjectionKey.self])
        let key = namespaced()
        await assertRefusedButNotByTheNamespaceRule("the private writer refuses it for its shape, as it always did") {
            try await StorageService.uploadPrivate(Self.png, key: key, mime: "image/png", app: self.app)
        }
        await assertRefusedButNotByTheNamespaceRule("and so does the deletion path") {
            try await StorageService.deleteAccountObject(kind: "private_media", key: key, app: self.app)
        }
        await assertRefusedButNotByTheNamespaceRule("and the synced-photo deletion") {
            try await StorageService.deleteOwnedSyncedPhoto(key: key, app: self.app)
        }
        // And the legacy families still work with the rule dormant.
        try await StorageService.deleteAccountObject(kind: "legacy_photo", key: "uploads/synced-photos/\(UUID().uuidString).jpg", app: app)
    }

    // MARK: the deletion path's private-media branch

    /// Stated rather than inferred: a `private_media` deletion key is a historical
    /// `platform/` address and nothing else. A namespaced key is fenced or it is
    /// blocked; it is never physically deleted, and the delete branch is not where
    /// that gets decided. Nothing reaches storage either way.
    func testTheDeletionPathRefusesAPrivateMediaKeyThatIsNotAHistoricalAddress() async throws {
        for install in [false, true] {
            if install { installNamespace() }
            for key in [namespaced(), "immutable-v1/media/not/a/real/address",
                        "drawings/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/original"] {
                do {
                    try await StorageService.deleteAccountObject(kind: "private_media", key: key, app: app)
                    XCTFail("a private-media deletion key that is not a historical address must be refused: \(key)")
                } catch {
                    XCTAssertEqual((error as? Abort)?.status, .internalServerError, key)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.workingDirectory + "PrivateMedia/" + key))
            }
        }
    }

    // MARK: the two kinds that do not move

    /// No import or drawing key can ever be inside the namespace, and not by luck.
    /// A namespace is one `[A-Za-z0-9_-]+/` segment, so a key under `staged-import/`
    /// or `drawings/` could only be inside one if the namespace were exactly that
    /// string — and both are reserved, refused by the loader before a target is
    /// ever built. The builders themselves can produce nothing else.
    func testTheImportAndDrawingKeyBuildersCannotProduceAKeyInsideTheNamespace() async throws {
        let address = StagedImportOriginalAddress(workspaceId: UUID(), sessionId: UUID(), declarationId: UUID())
        let built = [ImportedObjectKey.original(address).value,
                     try ImportedObjectKey.derived(address, purpose: "rendition", sha256: digest).value,
                     try ImportedObjectKey.derived(address, purpose: "drawing-page", sha256: digest).value,
                     try ImportedObjectKey.derived(address, purpose: "drawing-thumb", sha256: digest).value]
        for key in built { XCTAssertTrue(key.hasPrefix("staged-import/"), key) }
        // And the re-validator refuses a namespaced key, so a stored one cannot be
        // laundered into an import address either.
        XCTAssertThrowsError(try ImportedObjectKey.stored(namespaced()))

        // The drawing key shapes, exactly as `CanonicalDrawingService` builds them.
        let workspace = UUID(), project = UUID(), asset = UUID(), page = UUID()
        let drawings = ["drawings/\(workspace)/\(project)/\(asset)/original",
                        "drawings/\(workspace)/\(project)/\(asset)/pages/\(page)/\(digest).jpg",
                        "drawings/\(workspace)/\(project)/\(asset)/pages/\(page)/thumb-\(digest).jpg"]

        for key in built + drawings {
            XCTAssertFalse(key.hasPrefix(namespace), key)
            for reserved in PrivateStorageTargetConfiguration.reservedNamespaces where key.hasPrefix(reserved) {
                // The only namespace that could prefix this key is refused outright.
                let values = ["R2_PRIVATE_NAMESPACE": reserved, "R2_ACCOUNT_ID": String(repeating: "a", count: 32),
                              "R2_PRIVATE_BUCKET_NAME": "synthetic-private", "R2_BUCKET_NAME": "synthetic-public",
                              "R2_ACCESS_KEY_ID": "synthetic-key", "R2_SECRET_ACCESS_KEY": "synthetic-secret"]
                XCTAssertThrowsError(try PrivateStorageTargetConfiguration.load(environment: .testing, lookup: { values[$0] }), reserved)
            }
        }
        // With the namespace installed, none of them is refused by the rule.
        installNamespace()
        for key in built + drawings {
            await assertRefusedButNotByTheNamespaceRule("\(key) is outside the namespace and keeps its own handling") {
                try await StorageService.deleteAccountObject(kind: key.hasPrefix("drawings/") ? "private_drawing" : "private_import", key: key, app: self.app)
            }
        }
    }
}
