@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Where a private photograph's bytes come from, and what a reader is told when
/// they are not there.
///
/// The namespace introduces a second address for the same kind of object, served
/// by a second transport with a different deletion semantic. Everything here is
/// about the join between them: a historical key must keep exactly the reader it
/// has always had, a namespaced key must reach the content store, and the one
/// readback that must never be served as a photograph — the erasure fence — must
/// come back as gone rather than as bytes.
///
/// Written against B0.1's `InMemoryPrivateContentStore`, so a refusal a test
/// relies on is the refusal the real store makes.
final class PrivateMediaReadTests: XCTestCase {
    var app: Application!
    var store: InMemoryPrivateContentStore!
    var configuration: PrivateStorageTargetConfiguration!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[LinkGrantTokenKey.self] = Data(repeating: 7, count: 32)
        configuration = try InMemoryPrivateContentStore.syntheticConfiguration()
        store = InMemoryPrivateContentStore(configuration: configuration)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    // MARK: fixtures

    /// The switch, on. The same configuration reaches the policy and the store, so
    /// the target an allocation carries is the target the store answers for —
    /// which is what `PrivateContentStoreProvider` refuses to assume.
    private func installNamespace(_ storage: (any PrivateContentStorage)? = nil) {
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = storage ?? store
    }
    private func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("read-\(UUID())@example.test", name: "Synthetic photo reader", on: db) }
    }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:], bytes: Data? = nil, mime: String = "image/png", cookie: String? = nil) async throws -> XCTHTTPResponse {
        let jwt: String?
        if let user {
            let id = try user.requireID()
            jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        } else { jwt = nil }
        let payload = try bytes ?? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
            req.headers.replaceOrAdd(name: "X-Snaglist-Contractor", value: "1")
            if method != .GET {
                req.headers.replaceOrAdd(name: .contentType, value: bytes == nil ? "application/json" : mime)
                req.body = .init(data: payload)
            }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func project(_ user: User) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: user.requireID(), on: db) }
        let response = try await call(.POST, "api/v2/projects", user, body: ["mutation": meta(), "workspaceId": try workspace.requireID().uuidString, "project": ["id": UUID().uuidString, "name": "Plot 12", "reference": "WC12"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func snag(_ user: User, _ project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let response = try await call(.POST, "api/v2/projects/\(project.project.id)/snags", user, body: ["mutation": meta(), "id": UUID().uuidString, "fields": ["title": "Seal shower tray", "location": "Plot 12 · Ensuite"]])
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformSnagResponse.self)
    }
    private func path(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media" }
    private func command(_ snag: PlatformSnagResponse) -> [String: Any] {
        ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": snag.revision, "purpose": "capture",
         "sha256": PrivateImageProcessor.digest(Self.png), "byteCount": Self.png.count, "mimeType": "image/png"]
    }

    /// One ready asset, uploaded the way every asset is uploaded today: a
    /// historical `platform/` address written by the historical writer. The
    /// namespace is installed for these tests, and it deliberately changes nothing
    /// about that — B2 is what moves allocation.
    private struct Ready {
        let actor: User
        let project: PlatformProjectResponse
        let snag: PlatformSnagResponse
        let path: String
        let assetID: UUID
        let renditionBytes: Data
        let renditionSHA: String
    }
    private func ready(_ existingActor: User? = nil, project existingProject: PlatformProjectResponse? = nil) async throws -> Ready {
        let actor: User
        if let existingActor { actor = existingActor } else { actor = try await user() }
        let project: PlatformProjectResponse
        if let existingProject { project = existingProject } else { project = try await self.project(actor) }
        let snag = try await self.snag(actor, project)
        let route = path(project, snag)
        let allocated = try await call(.POST, route, actor, body: command(snag))
        XCTAssertEqual(allocated.status, .ok, allocated.body.string)
        let asset = try allocated.content.decode(MediaAssetResponse.self)
        let uploaded = try await call(.PUT, route + "/\(asset.id)/content", actor, bytes: Self.png)
        XCTAssertEqual(uploaded.status, .ok, uploaded.body.string)
        let row = try await PrivateMediaService.row(asset.id, snagID: snag.snag.id, projectID: project.project.id, on: app.db)
        let renditionKey = try row.decode(column: "rendition_key", as: String.self)
        let bytes = try await StorageService.downloadPrivate(key: renditionKey, app: app)
        return .init(actor: actor, project: project, snag: snag, path: route, assetID: asset.id,
                     renditionBytes: bytes, renditionSHA: try row.decode(column: "rendition_sha256", as: String.self))
    }

    /// Repoints a ready row at two namespaced addresses and puts the same bytes
    /// there. B2 makes this the ordinary case; until then it is the only way to
    /// hold a namespaced row against the reader that has to serve it.
    @discardableResult
    private func moveIntoNamespace(_ ready: Ready, seed: Bool = true,
                                   rendition renditionBytes: Data? = nil) async throws -> (original: String, rendition: String) {
        let original = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: ready.project.workspaceId, projectID: ready.project.project.id, app: app)
        let rendition = try PrivateObjectAllocationPolicy.rendition(of: original, sha256: ready.renditionSHA, app: app)
        if seed {
            try await store.seedContent(key: original.key, data: Self.png, contentType: "image/png")
            try await store.seedContent(key: rendition.key, data: renditionBytes ?? ready.renditionBytes)
        }
        try await rebind(ready, original: original.key, rendition: rendition.key)
        return (original.key, rendition.key)
    }
    private func rebind(_ ready: Ready, original: String, rendition: String) async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE media_assets SET original_key = \(bind: original), rendition_key = \(bind: rendition) WHERE id = \(bind: ready.assetID)
            """).run()
    }

    // MARK: the Contractor link route

    private func contractorLink(_ ready: Ready) async throws -> String {
        let owner = ready.actor, project = ready.project
        let contractorID = UUID()
        let created = try await call(.POST, "api/v2/workspaces/\(project.workspaceId)/contractors", owner, body: ["mutation": meta(), "id": contractorID.uuidString, "expectedRevision": 0, "fields": ["companyName": "Alder Joinery"]])
        XCTAssertEqual(created.status, .ok, created.body.string)
        let published = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(ready.snag.snag.id)/publish", owner, body: ["mutation": meta(), "expectedRevision": ready.snag.revision])
        XCTAssertEqual(published.status, .ok, published.body.string)
        var snag = try published.content.decode(PlatformSnagResponse.self)
        let assigned = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/assignment", owner, body: ["mutation": meta(), "expectedRevision": snag.revision, "fields": ["contractorId": contractorID.uuidString]])
        XCTAssertEqual(assigned.status, .ok, assigned.body.string)
        snag = try assigned.content.decode(PlatformSnagResponse.self)
        let attached = try await call(.POST, ready.path + "/\(ready.assetID)/attach", owner, body: ["mutation": meta(), "expectedRevision": snag.revision])
        XCTAssertEqual(attached.status, .ok, attached.body.string)
        snag = try attached.content.decode(PlatformSnagResponse.self)
        let grant = try await call(.POST, "api/v2/projects/\(project.project.id)/links/prepare", owner, body: ["mutation": meta(), "id": UUID().uuidString, "mode": "completion", "snagIds": [snag.snag.id.uuidString], "assetIds": [ready.assetID.uuidString], "contractorId": contractorID.uuidString])
        XCTAssertEqual(grant.status, .ok, grant.body.string)
        let prepared = try grant.content.decode(LinkGrantResponse.self)
        let activated = try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(prepared.id)/activate", owner, body: ["mutation": meta(), "expectedRevision": prepared.revision])
        XCTAssertEqual(activated.status, .ok, activated.body.string)
        let activation = try activated.content.decode(LinkActivationResponse.self)
        let token = String(try XCTUnwrap(activation.contractorPath).dropFirst(3))
        return "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(ready.assetID)/content"
    }

    // MARK: a namespaced photograph is served, and from the store

    /// The routing itself: a row whose keys are inside the namespace is fetched
    /// through the content store on both routes, the bytes are the row's bytes, and
    /// nothing was written to or read from the historical location.
    func testANamespacedPhotographIsServedThroughTheContentStoreOnBothRoutes() async throws {
        installNamespace()
        let fixture = try await ready()
        let keys = try await moveIntoNamespace(fixture)
        let contractorRoute = try await contractorLink(fixture)

        let processed = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
        XCTAssertEqual(processed.status, .ok, processed.body.string)
        XCTAssertEqual(Data(buffer: processed.body), fixture.renditionBytes)
        XCTAssertEqual(processed.headers.contentType?.description, "image/jpeg")

        let original = try await call(.GET, fixture.path + "/\(fixture.assetID)/original", fixture.actor)
        XCTAssertEqual(original.status, .ok, original.body.string)
        XCTAssertEqual(Data(buffer: original.body), Self.png)
        XCTAssertEqual(original.headers.contentType?.description, "image/png")

        let contractor = try await call(.GET, contractorRoute, nil)
        XCTAssertEqual(contractor.status, .ok, contractor.body.string)
        XCTAssertEqual(Data(buffer: contractor.body), fixture.renditionBytes)

        // Read from the store, at exactly the two addresses the row carries, with
        // the ceiling rather than a declared size — so a size disagreement is a
        // verification failure and never a truncated photograph.
        let calls = await store.recordedCalls()
        XCTAssertEqual(calls, [.read(key: keys.rendition, maximumBytes: PrivateContent.maximumBytes),
                               .read(key: keys.original, maximumBytes: PrivateContent.maximumBytes),
                               .read(key: keys.rendition, maximumBytes: PrivateContent.maximumBytes)])
        // And nothing put a namespaced object on the historical local path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.workingDirectory + "PrivateMedia/" + keys.original))
    }

    /// The other half of the same rule. `.legacy` is a positive statement about an
    /// address, so a historical key keeps the historical reader even in a process
    /// where the namespace is installed — and the content store is never asked.
    func testAHistoricalKeyKeepsItsHistoricalReaderWhileTheNamespaceIsInstalled() async throws {
        installNamespace()
        let fixture = try await ready()
        let contractorRoute = try await contractorLink(fixture)

        for route in [fixture.path + "/\(fixture.assetID)/content", fixture.path + "/\(fixture.assetID)/original"] {
            let response = try await call(.GET, route, fixture.actor)
            XCTAssertEqual(response.status, .ok, response.body.string)
        }
        let contractor = try await call(.GET, contractorRoute, nil)
        XCTAssertEqual(contractor.status, .ok, contractor.body.string)
        let calls = await store.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "a historical address is never fetched through the private content store")
    }

    // MARK: the fence

    /// The refusal this whole packet exists for. A fenced key belongs to an account
    /// that asked to be erased; its object is zero bytes under an erasure content
    /// type. A reader must be told the photograph is gone — never handed the
    /// fence's own contents as though they were the photograph, and never told
    /// "temporarily unavailable" about something that can never come back.
    func testAFencedNamespacedKeyIsGoneOnBothRoutesAndItsOwnBytesAreNeverServed() async throws {
        installNamespace()
        let fixture = try await ready()
        let keys = try await moveIntoNamespace(fixture)
        let contractorRoute = try await contractorLink(fixture)
        try await store.seedErasureFence(key: keys.rendition)
        try await store.seedErasureFence(key: keys.original)
        let fenced = await store.isFenced(keys.rendition)
        XCTAssertTrue(fenced)

        for route in [fixture.path + "/\(fixture.assetID)/content", fixture.path + "/\(fixture.assetID)/original", contractorRoute] {
            let response = try await call(.GET, route, route == contractorRoute ? nil : fixture.actor)
            XCTAssertEqual(response.status, .gone, route + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("media_erased"), response.body.string)
            XCTAssertTrue(response.body.string.contains("This photo is no longer available"), response.body.string)
            XCTAssertFalse(response.body.string.contains(ObjectErasureFenceService.marker))
            XCTAssertNotEqual(response.headers.contentType?.description, "image/jpeg")
        }
    }

    // MARK: what is not there, and what did not answer

    /// Nothing at the address. The reader is told the photograph is temporarily
    /// unavailable; the operator is told which of the two facts it was.
    func testAnAbsentNamespacedObjectIsTemporarilyUnavailableRatherThanFoundEmpty() async throws {
        installNamespace()
        let fixture = try await ready()
        try await moveIntoNamespace(fixture, seed: false)

        // Nothing was seeded, so both addresses answer `absent`.
        for route in [fixture.path + "/\(fixture.assetID)/content", fixture.path + "/\(fixture.assetID)/original"] {
            let response = try await call(.GET, route, fixture.actor)
            XCTAssertEqual(response.status, .serviceUnavailable, response.body.string)
            XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
            XCTAssertFalse(response.body.string.contains("media_storage_unavailable"), response.body.string)
        }
    }

    /// Storage did not answer. Same status and same words to the reader as absence
    /// — the shape of the bucket is not a client's business — and a different log
    /// kind for the operator, which is the whole reason B0.1 split the two.
    func testStorageThatDoesNotAnswerIsTemporarilyUnavailableAndSaysNothingElse() async throws {
        installNamespace()
        let fixture = try await ready()
        let keys = try await moveIntoNamespace(fixture)
        await store.failNextRead()
        let response = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
        XCTAssertEqual(response.status, .serviceUnavailable, response.body.string)
        XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
        XCTAssertFalse(response.body.string.contains(keys.rendition), "a storage refusal never carries an address to the client")
        XCTAssertFalse(response.body.string.contains(configuration.target.bucket))
        XCTAssertFalse(response.body.string.contains(configuration.target.namespace))
    }

    // MARK: the re-check after the bytes are in hand

    /// The post-fetch authorization check survives the reroute. The bytes are
    /// fetched — the store records the read — and the download is still refused,
    /// because storage IO happens outside the membership locks and a removed member
    /// must not be able to finish a slow download.
    func testAccessRevokedWhileTheBytesWereInFlightStillRefusesTheDownload() async throws {
        let owner = try await user(), member = try await user()
        let project = try await self.project(owner)
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member", projects: [.init(projectId: project.project.id, role: "member")], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: member.requireID(), on: db) }
        installNamespace()
        let fixture = try await ready(member, project: project)
        let keys = try await moveIntoNamespace(fixture)

        let box = UnsafeTestBox(value: (app!, project.workspaceId, try member.requireID(), try owner.requireID()))
        installNamespace(ReadInterceptingStore(inner: store) {
            let (app, workspaceID, memberID, ownerID) = box.value
            try await app.db.transaction { db in
                try await WorkspaceAccessService.changeMember(workspaceID: workspaceID, targetID: memberID, newRole: nil, expectedRevision: 1, actorID: ownerID, on: db)
            }
        })

        let response = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
        XCTAssertEqual(response.status, .notFound, response.body.string)
        XCTAssertNotEqual(Data(buffer: response.body), fixture.renditionBytes)
        let calls = await store.recordedCalls()
        XCTAssertEqual(calls, [.read(key: keys.rendition, maximumBytes: PrivateContent.maximumBytes)],
                       "the bytes were fetched and then refused, which is what makes this the post-fetch check")
    }

    // MARK: the installation itself

    /// A namespaced row met by a process with no namespace, or with one it cannot
    /// use, is a deployment fact rather than a fact about the photograph. It fails
    /// closed with its own identifier — never by handing a namespaced key to the
    /// legacy reader, whose validator would report a correct row as a server fault.
    func testANamespacedRowIsRefusedAsStorageUnavailableWhenTheNamespaceIsOffOrWrong() async throws {
        installNamespace()
        let fixture = try await ready()
        let keys = try await moveIntoNamespace(fixture)

        // The switch off. Nothing injected, and `configure` resolved `.absent`.
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = nil
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = nil
        let off = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
        XCTAssertEqual(off.status, .serviceUnavailable, off.body.string)
        XCTAssertTrue(off.body.string.contains("media_storage_unavailable"), off.body.string)

        // The switch on and what is behind it unusable. A different fact, the same
        // answer to the reader, and a different one in the runbook.
        let broken = ["R2_PRIVATE_NAMESPACE": "not-a-prefix"]
        PrivateObjectAllocationPolicy.install(app: app, lookup: { broken[$0] })
        let wrong = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
        XCTAssertEqual(wrong.status, .serviceUnavailable, wrong.body.string)
        XCTAssertTrue(wrong.body.string.contains("media_storage_unavailable"), wrong.body.string)
        XCTAssertFalse(wrong.body.string.contains(keys.rendition))

        let calls = await store.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "without an installed namespace there is no store to ask")
    }

    // MARK: verification, and corruption

    /// The integrity refusal survives the reroute on both routes: bytes that are
    /// not the row's bytes are never disclosed, wherever they came from. Both
    /// routes now check the row's size as well as its digest, which is what makes
    /// a size disagreement a verification failure rather than something only the
    /// digest happens to catch.
    func testNamespacedBytesThatAreNotTheRowsBytesAreRefusedByTheIntegrityCheckOnBothRoutes() async throws {
        installNamespace()
        let fixture = try await ready()
        let contractorRoute = try await contractorLink(fixture)
        try await moveIntoNamespace(fixture, rendition: Data([255, 216, 255]) + Data("a different photograph".utf8))
        for route in [fixture.path + "/\(fixture.assetID)/content", contractorRoute] {
            let response = try await call(.GET, route, route == contractorRoute ? nil : fixture.actor)
            XCTAssertEqual(response.status, .serviceUnavailable, route + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
            XCTAssertFalse(response.body.string.contains("a different photograph"))
        }
    }

    /// A `ready` row's two addresses were both written after their bytes existed,
    /// so neither can be the allocation placeholder and neither can be a shape the
    /// policy never allocates. Meeting one means the row is corrupt, and a corrupt
    /// row is a server fault rather than something a client should retry.
    func testAReadyRowCarryingAnUnreadableNamespacedAddressIsAServerFaultNotARetry() async throws {
        installNamespace()
        let fixture = try await ready()
        let keys = try await moveIntoNamespace(fixture)
        let namespace = configuration.target.namespace

        for corrupt in [String(keys.original.dropLast("original".count)) + "view.jpg",
                        namespace + "media/\(lower(UUID()))/\(lower(UUID()))/\(lower(UUID()))/thumbnail.jpg"] {
            try await rebind(fixture, original: keys.original, rendition: corrupt)
            let response = try await call(.GET, fixture.path + "/\(fixture.assetID)/content", fixture.actor)
            XCTAssertEqual(response.status, .internalServerError, corrupt + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("request_failed"), response.body.string)
            XCTAssertFalse(response.body.string.contains(corrupt), "a 5xx reason is replaced wholesale; no address reaches the client")
        }
    }
}

/// Carries a test's own values into a `@Sendable` hook. Test-local, and nothing
/// crosses a real concurrency boundary: the hook runs inside the request it is
/// hooking.
private struct UnsafeTestBox<T>: @unchecked Sendable { let value: T }

/// The shared in-memory double, with one hook between the bytes arriving and the
/// bytes being returned.
///
/// This is the only way to hold the state B3 has to survive: access that was valid
/// when the row was read and is not valid by the time the response is written. It
/// delegates rather than reimplements, so the store's own rules — create-only,
/// the exact fence, `absent` — are still the real ones.
private struct ReadInterceptingStore: PrivateContentStorage {
    let inner: InMemoryPrivateContentStore
    let afterRead: @Sendable () async throws -> Void
    init(inner: InMemoryPrivateContentStore, afterRead: @escaping @Sendable () async throws -> Void) {
        self.inner = inner; self.afterRead = afterRead
    }
    var target: ObjectStorageWriteTarget { inner.target }
    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome {
        try await inner.put(key: key, data: data, contentType: contentType)
    }
    func read(key: String, maximumBytes: Int) async throws -> Readback {
        let readback = try await inner.read(key: key, maximumBytes: maximumBytes)
        try await afterRead()
        return readback
    }
}
