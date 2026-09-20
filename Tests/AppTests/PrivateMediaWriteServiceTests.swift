@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Logging

/// What happens to a private photograph's bytes, on both routes that write them.
///
/// Every row of B2's state table is here, driven through HTTP on the manager
/// route and the Contractor link route, because the two are near-duplicates of
/// one flow and the whole point of `PrivateMediaWriteService` is that they cannot
/// answer differently. A row is not "tested" here by asserting a status: each
/// case also asserts what reached storage, what the write intent says afterwards,
/// and whether readiness was allowed to follow — which is the only way to tell
/// row 11 (the bytes landed, the acknowledgement was lost) from row 14a (the
/// write never landed) at all.
///
/// Three properties are what this suite exists to hold:
///
/// * a fenced address never accepts content and never reports success;
/// * an intent settles only after a readback proved the bytes at the key are
///   this intent's bytes, so `settle` is unreachable from any other row;
/// * a namespaced key appears in `media_assets` only alongside the intent
///   recorded in the same transaction.
final class PrivateMediaWriteServiceTests: XCTestCase {
    var app: Application!
    var store: InMemoryPrivateContentStore!
    var configuration: PrivateStorageTargetConfiguration!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    /// A genuine PNG header followed by other bytes: an object that is not ours,
    /// placed at an address we are about to write to.
    static let foreign = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data("a different photograph entirely".utf8)

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[LinkGrantTokenKey.self] = Data(repeating: 7, count: 32)
        configuration = try InMemoryPrivateContentStore.syntheticConfiguration()
        store = InMemoryPrivateContentStore(configuration: configuration)
        installNamespace()
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func installNamespace(_ storage: (any PrivateContentStorage)? = nil) {
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = storage ?? store
    }

    // MARK: - Graph fixtures

    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("write-\(UUID())@example.test", name: "Synthetic photo writer", on: db) }
    }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:],
                      bytes: Data? = nil, mime: String = "image/png") async throws -> XCTHTTPResponse {
        let jwt: String?
        if let user {
            let id = try user.requireID()
            jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        } else { jwt = nil }
        let payload = try bytes ?? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
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
    private func command(_ snag: PlatformSnagResponse, bytes: Data = png, purpose: String = "capture", intent: UUID? = nil) -> [String: Any] {
        var value: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": snag.revision,
                                    "purpose": purpose, "sha256": PrivateImageProcessor.digest(bytes),
                                    "byteCount": bytes.count, "mimeType": "image/png"]
        if let intent { value["intentId"] = intent.uuidString }
        return value
    }

    // MARK: - The two routes, as one shape

    enum Route: String, CaseIterable { case manager, contractorLink }

    /// One allocated, not-yet-uploaded asset, and everything needed to PUT its
    /// bytes. `actor` is nil on the Contractor link route, whose authority is the
    /// link in the path rather than a bearer token.
    private struct Target {
        let route: Route
        let actor: User?
        let owner: User
        let project: PlatformProjectResponse
        let snag: PlatformSnagResponse
        let assetID: UUID
        let contentPath: String
        let token: String?
    }

    private func allocated(_ route: Route) async throws -> Target {
        let owner = try await user(), project = try await self.project(owner)
        switch route {
        case .manager:
            let snag = try await self.snag(owner, project)
            let path = "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media"
            let response = try await call(.POST, path, owner, body: command(snag))
            XCTAssertEqual(response.status, .ok, response.body.string)
            let asset = try response.content.decode(MediaAssetResponse.self)
            return .init(route: route, actor: owner, owner: owner, project: project, snag: snag,
                         assetID: asset.id, contentPath: path + "/\(asset.id)/content", token: nil)
        case .contractorLink:
            let contractorID = UUID()
            let created = try await call(.POST, "api/v2/workspaces/\(project.workspaceId)/contractors", owner,
                                         body: ["mutation": meta(), "id": contractorID.uuidString, "expectedRevision": 0, "fields": ["companyName": "Alder Joinery"]])
            XCTAssertEqual(created.status, .ok, created.body.string)
            let draft = try await self.snag(owner, project)
            let published = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(draft.snag.id)/publish", owner,
                                           body: ["mutation": meta(), "expectedRevision": draft.revision])
            XCTAssertEqual(published.status, .ok, published.body.string)
            var snag = try published.content.decode(PlatformSnagResponse.self)
            let assigned = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/assignment", owner,
                                          body: ["mutation": meta(), "expectedRevision": snag.revision, "fields": ["contractorId": contractorID.uuidString]])
            XCTAssertEqual(assigned.status, .ok, assigned.body.string)
            snag = try assigned.content.decode(PlatformSnagResponse.self)
            let grant = try await call(.POST, "api/v2/projects/\(project.project.id)/links/prepare", owner,
                                       body: ["mutation": meta(), "id": UUID().uuidString, "mode": "completion",
                                              "snagIds": [snag.snag.id.uuidString], "assetIds": [],
                                              "contractorId": contractorID.uuidString])
            XCTAssertEqual(grant.status, .ok, grant.body.string)
            let prepared = try grant.content.decode(LinkGrantResponse.self)
            let activated = try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(prepared.id)/activate", owner,
                                           body: ["mutation": meta(), "expectedRevision": prepared.revision])
            XCTAssertEqual(activated.status, .ok, activated.body.string)
            let activation = try activated.content.decode(LinkActivationResponse.self)
            let token = String(try XCTUnwrap(activation.contractorPath).dropFirst(3))
            let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media"
            let response = try await call(.POST, path, nil, body: command(snag, purpose: "completion", intent: UUID()))
            XCTAssertEqual(response.status, .ok, response.body.string)
            let asset = try response.content.decode(ContractorGrantController.PhotoResult.self)
            return .init(route: route, actor: nil, owner: owner, project: project, snag: snag,
                         assetID: asset.id, contentPath: path + "/\(asset.id)/content", token: token)
        }
    }

    private func put(_ target: Target, bytes: Data = png, mime: String = "image/png") async throws -> XCTHTTPResponse {
        try await call(.PUT, target.contentPath, target.actor, bytes: bytes, mime: mime)
    }


    // MARK: - Assertions on values that had to be awaited

    /// XCTest's assertions take a non-`async` autoclosure, so anything read from
    /// the store — which is an actor — or from the database is fetched first and
    /// asserted on as a value. These forward to XCTest unchanged, file and line
    /// included, so a failure still points at the caller.
    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
    private func assertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    private func assertFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }
    private func assertNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, message, file: file, line: line)
    }
    private func assertNotNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(value, message, file: file, line: line)
    }
    private func unwrap<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, message, file: file, line: line)
    }

    // MARK: - Observation

    private func row(_ target: Target) async throws -> SQLRow {
        try await PrivateMediaService.row(target.assetID, snagID: target.snag.snag.id, projectID: target.project.project.id, on: app.db)
    }
    private func originalKey(_ target: Target) async throws -> String? {
        try await row(target).decode(column: "original_key", as: String?.self)
    }
    private func state(_ target: Target) async throws -> String {
        try await row(target).decode(column: "state", as: String.self)
    }
    private struct Intent {
        let key: String, state: String, backend: String?, identity: String?, bucket: String?, namespace: String?, writeProtocol: String
    }
    private func intents(_ target: Target) async throws -> [Intent] {
        try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT object_key, state, storage_backend, storage_backend_identity, storage_bucket, storage_namespace, write_protocol
            FROM object_write_intents WHERE source_kind = 'media_asset' AND source_id = \(bind: target.assetID)
            ORDER BY created_at, id
            """).all().map { row in
            try Intent(key: row.decode(column: "object_key", as: String.self),
                       state: row.decode(column: "state", as: String.self),
                       backend: row.decode(column: "storage_backend", as: String?.self),
                       identity: row.decode(column: "storage_backend_identity", as: String?.self),
                       bucket: row.decode(column: "storage_bucket", as: String?.self),
                       namespace: row.decode(column: "storage_namespace", as: String?.self),
                       writeProtocol: row.decode(column: "write_protocol", as: String.self))
        }
    }
    private func mark() async -> Int { await store.recordedCalls().count }
    private func calls(since mark: Int) async -> [InMemoryPrivateContentStore.Call] {
        Array(await store.recordedCalls().dropFirst(mark))
    }

    /// One upload attempt that reached the store and failed there, so the row now
    /// carries its final address and nothing is at it. This is row 14a, and it is
    /// also the only way a later case can know an address in advance — which is
    /// the point of the nonce in the key.
    @discardableResult
    private func boundButEmpty(_ target: Target) async throws -> String {
        await store.failNextPut()
        let response = try await put(target)
        XCTAssertEqual(response.status, .serviceUnavailable, response.body.string)
        XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
        let key = try unwrap(await originalKey(target))
        XCTAssertTrue(key.hasPrefix(configuration.target.namespace), key)
        let object = await store.object(at: key)
        XCTAssertNil(object, "row 14a: the write never landed")
        return key
    }

    /// Nothing a refusal says may name where the object lives or who asked for it.
    private func assertDiscloses(_ response: XCTHTTPResponse, nothingAbout target: Target,
                                 key: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let body = response.body.string
        for secret in [key, target.token, configuration.target.bucket, configuration.target.namespace,
                       configuration.target.backendIdentity].compactMap({ $0 }) {
            XCTAssertFalse(body.contains(secret), "a refusal carried \(secret.prefix(4))… to the client", file: file, line: line)
        }
    }

    // MARK: - Allocation

    /// R1, the half that is visible from outside: allocation produces no address
    /// and touches no storage. A row with no address contributes nothing to an
    /// erasure manifest, which is the correct amount of work for an object whose
    /// bytes were never written — and the old behaviour, a key with no intent
    /// behind it, produced a deletion that was stuck by design for every
    /// allocated-never-uploaded asset.
    func testAnAllocatedPhotoCarriesNoAddressAndReachesNoStorageOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let row = try await row(target)
            XCTAssertNil(try row.decode(column: "original_key", as: String?.self), route.rawValue)
            XCTAssertNil(try row.decode(column: "rendition_key", as: String?.self), route.rawValue)
            XCTAssertEqual(try row.decode(column: "state", as: String.self), "allocated", route.rawValue)
            assertTrue(try await intents(target).isEmpty, route.rawValue)
        }
        assertTrue(await store.recordedCalls().isEmpty, "allocation never touches storage")
    }

    /// Row 19. Private media is allocated into the installed namespace or not at
    /// all: there is no unconditional writer left to fall back to. The two
    /// installation failures stay separate in the policy — "not installed" and
    /// "installed and unusable" need different answers from a runbook — and
    /// converge on one identifier for the client, which learns nothing about the
    /// shape of the deployment behind it.
    func testAllocationIsRefusedUnderBothInstallationFailuresWithOneIdentifier() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await snag(owner, project)
        let path = "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media"

        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = nil
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = nil
        PrivateObjectAllocationPolicy.install(app: app, lookup: { _ in nil })
        XCTAssertThrowsError(try PrivateObjectAllocationPolicy.configuration(app: app)) {
            XCTAssertEqual($0 as? PrivateObjectAllocationPolicy.Failure, .namespaceUnavailable)
        }
        let absent = try await call(.POST, path, owner, body: command(snag))
        XCTAssertEqual(absent.status, .serviceUnavailable, absent.body.string)
        XCTAssertTrue(absent.body.string.contains("media_storage_unavailable"), absent.body.string)

        PrivateObjectAllocationPolicy.install(app: app, lookup: { ["R2_PRIVATE_NAMESPACE": "not-a-prefix"][$0] })
        XCTAssertThrowsError(try PrivateObjectAllocationPolicy.configuration(app: app)) {
            XCTAssertEqual($0 as? PrivateObjectAllocationPolicy.Failure, .namespaceUnusable)
        }
        let unusable = try await call(.POST, path, owner, body: command(snag))
        XCTAssertEqual(unusable.status, .serviceUnavailable, unusable.body.string)
        XCTAssertTrue(unusable.body.string.contains("media_storage_unavailable"), unusable.body.string)

        let rows = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM media_assets WHERE project_id = \(bind: project.project.id)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(rows, 0, "a refused allocation leaves no row")
        assertTrue(await store.recordedCalls().isEmpty)
    }

    // MARK: - The settling rows: 1, 5, 11

    /// Row 1. A create-only provider that names an object it has just made at an
    /// address nobody else could have taken has said everything a readback could:
    /// the bytes are ours by construction. So there is no readback, and no 10 MB
    /// GET per upload to pay for one.
    func testACreatedPutSettlesWithoutAReadbackAndBecomesReadyOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let mark = await mark()
            let response = try await put(target)
            XCTAssertEqual(response.status, .ok, route.rawValue + " → " + response.body.string)
            assertEqual(try await state(target), "ready", route.rawValue)
            let calls = await calls(since: mark)
            XCTAssertEqual(calls.count, 2, route.rawValue + ": two puts and no readback — \(calls)")
            XCTAssertTrue(calls.allSatisfy({ if case .put = $0 { return true } else { return false } }), route.rawValue)
            assertEqual(try await intents(target).map(\.state), ["settled", "settled"], route.rawValue)
        }
    }

    /// Row 5. The address already holds these exact bytes — an earlier attempt of
    /// this same upload landed after its caller had given up. The intent's claim
    /// is "these bytes, this digest, at this key", not "this request wrote them",
    /// so the readback verifies it and the intent settles.
    func testAnAddressAlreadyHoldingOurOwnBytesSettlesOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let key = try await boundButEmpty(target)
            try await store.seedContent(key: key, data: Self.png, contentType: "image/png")
            let mark = await mark()
            let response = try await put(target)
            XCTAssertEqual(response.status, .ok, route.rawValue + " → " + response.body.string)
            assertEqual(try await state(target), "ready", route.rawValue)
            let calls = await calls(since: mark)
            XCTAssertEqual(calls.first, .put(key: key, byteCount: Self.png.count, contentType: "image/png"), route.rawValue)
            XCTAssertEqual(calls.dropFirst().first, .read(key: key, maximumBytes: PrivateContent.maximumBytes),
                           route.rawValue + ": an outcome that does not say the bytes landed is always read back")
            assertEqual(try await intents(target).map(\.state), ["uncertain", "settled", "settled"], route.rawValue)
        }
    }

    /// Row 11, and the row that justifies the whole design. The acknowledgement
    /// was lost, so the outcome says nothing about whether the bytes landed — and
    /// they did. Without the readback this is indistinguishable from row 14a and
    /// every unlucky upload would be thrown away.
    func testAPutWhoseAcknowledgementWasLostButWhoseBytesLandedSettlesOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            await store.dropNextPutResponse()
            let mark = await mark()
            let response = try await put(target)
            XCTAssertEqual(response.status, .ok, route.rawValue + " → " + response.body.string)
            assertEqual(try await state(target), "ready", route.rawValue)
            let key = try unwrap(await originalKey(target))
            let calls = await calls(since: mark)
            XCTAssertEqual(calls.count, 3, route.rawValue + ": put, readback, then the rendition — \(calls)")
            XCTAssertEqual(calls[1], .read(key: key, maximumBytes: PrivateContent.maximumBytes), route.rawValue)
            assertEqual(try await intents(target).map(\.state), ["settled", "settled"], route.rawValue)
        }
    }

    // MARK: - The fence

    /// Rows 6 and 12, and the refusal this packet exists for. A fenced address
    /// belongs to an account that asked to be erased. No content lands on it —
    /// create-only sees to that — the intent is never settled, the client is told
    /// the photograph is gone rather than invited to retry something that can
    /// never succeed, and the fence's own bytes are never disclosed.
    func testAFencedAddressNeverAcceptsContentAndNeverReportsSuccessOnBothRoutes() async throws {
        for route in Route.allCases {
            for lostAcknowledgement in [false, true] {
                let target = try await allocated(route)
                let key = try await boundButEmpty(target)
                try await store.seedErasureFence(key: key)
                if lostAcknowledgement { await store.failNextPut() }
                let response = try await put(target)
                XCTAssertEqual(response.status, .gone, route.rawValue + " → " + response.body.string)
                XCTAssertTrue(response.body.string.contains("media_erased"), response.body.string)
                XCTAssertTrue(response.body.string.contains("This photo is no longer available"), response.body.string)
                XCTAssertFalse(response.body.string.contains(ObjectErasureFenceService.marker), response.body.string)
                assertDiscloses(response, nothingAbout: target, key: key)
                assertEqual(try await state(target), "allocated", route.rawValue)
                assertTrue(await store.isFenced(key), route.rawValue + ": the fence still holds the address")
                assertFalse(try await intents(target).contains(where: { $0.state == "settled" }),
                               route.rawValue + ": no intent may settle onto a fence")
            }
        }
    }

    // MARK: - Somebody else's object

    /// Rows 7 and 13. The address is occupied by something that is not ours, and
    /// create-only will keep refusing, so the answer is terminal and says so.
    func testAnAddressHoldingSomebodyElsesObjectIsATerminalConflictOnBothRoutes() async throws {
        for route in Route.allCases {
            for lostAcknowledgement in [false, true] {
                let target = try await allocated(route)
                let key = try await boundButEmpty(target)
                try await store.seedContent(key: key, data: Self.foreign, contentType: "image/png")
                if lostAcknowledgement { await store.failNextPut() }
                let response = try await put(target)
                XCTAssertEqual(response.status, .conflict, route.rawValue + " → " + response.body.string)
                XCTAssertTrue(response.body.string.contains("media_key_conflict"), response.body.string)
                XCTAssertFalse(response.body.string.contains("a different photograph"), response.body.string)
                assertDiscloses(response, nothingAbout: target, key: key)
                assertEqual(try await state(target), "allocated", route.rawValue)
                assertEqual(await store.object(at: key)?.data, Self.foreign, route.rawValue + ": nothing overwrote it")
                assertFalse(try await intents(target).contains(where: { $0.state == "settled" }), route.rawValue)
            }
        }
    }

    // MARK: - The four unavailable rows, and the log kind that separates them

    /// Rows 8a, 8b, 14a and 14b. The client is told one thing — this could not be
    /// saved, try again — because the shape of the bucket is not a client's
    /// business. The operator is told which of the four it was, because "the write
    /// never landed" and "R2 is down" need different answers, and before B0.1
    /// split `absent` from a transport failure they were the same line.
    func testTheFourUnavailableRowsAreOneAnswerToTheClientOnBothRoutes() async throws {
        for route in Route.allCases {
            // 14a: the PUT's outcome was unknown and nothing is at the address.
            let notLanded = try await allocated(route)
            let notLandedKey = try await boundButEmpty(notLanded)
            assertEqual(try await state(notLanded), "allocated", route.rawValue)
            assertEqual(try await intents(notLanded).map(\.state), ["uncertain"], route.rawValue)

            // 14b: neither the PUT nor the readback answered.
            let unreachable = try await allocated(route)
            _ = try await boundButEmpty(unreachable)
            await store.failNextPut(); await store.failNextRead()
            let unreachableResponse = try await put(unreachable)
            XCTAssertEqual(unreachableResponse.status, .serviceUnavailable, route.rawValue + " → " + unreachableResponse.body.string)
            XCTAssertTrue(unreachableResponse.body.string.contains("media_unavailable"), unreachableResponse.body.string)

            // 8a: the address was taken, and then answered that nothing is there.
            let existsThenAbsent = try await allocated(route)
            let existsKey = try await boundButEmpty(existsThenAbsent)
            try await store.seedContent(key: existsKey, data: Self.png, contentType: "image/png")
            await store.failNextRead(with: PrivateContentStoreError.absent)
            let absentResponse = try await put(existsThenAbsent)
            XCTAssertEqual(absentResponse.status, .serviceUnavailable, route.rawValue + " → " + absentResponse.body.string)

            // 8b: the address was taken and the readback did not answer.
            let readbackUnavailable = try await allocated(route)
            let takenKey = try await boundButEmpty(readbackUnavailable)
            try await store.seedContent(key: takenKey, data: Self.png, contentType: "image/png")
            await store.failNextRead()
            let readbackResponse = try await put(readbackUnavailable)
            XCTAssertEqual(readbackResponse.status, .serviceUnavailable, route.rawValue + " → " + readbackResponse.body.string)

            for (response, key) in [(unreachableResponse, notLandedKey), (absentResponse, existsKey), (readbackResponse, takenKey)] {
                XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
                XCTAssertFalse(response.body.string.contains("media_storage_unavailable"), response.body.string)
                assertDiscloses(response, nothingAbout: notLanded, key: key)
            }
            for target in [notLanded, unreachable, existsThenAbsent, readbackUnavailable] {
                assertEqual(try await state(target), "allocated", route.rawValue)
                assertFalse(try await intents(target).contains(where: { $0.state == "settled" }), route.rawValue)
            }
        }
    }

    /// Row 15. Nobody is waiting for an answer and the PUT may yet land, so the
    /// intent goes uncertain rather than being settled or abandoned; if a response
    /// is delivered at all it is the same one every unknown outcome gets.
    func testACancelledPutLeavesAnUncertainIntentOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            await store.failNextPut(with: CancellationError())
            let response = try await put(target)
            XCTAssertEqual(response.status, .serviceUnavailable, route.rawValue + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("media_unavailable"), response.body.string)
            assertEqual(try await intents(target).map(\.state), ["uncertain"], route.rawValue)
            assertEqual(try await state(target), "allocated", route.rawValue)
        }
    }

    // MARK: - Refusals made before anything is recorded

    /// Row 16. The store is resolved before the intent exists, so a target with no
    /// store leaves nothing behind: no intent row to block the owner's deletion
    /// for a write that provably never happened, and no address in the row.
    func testWithNoStoreForTheTargetNothingIsRecordedAtAllOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            app.storage[PrivateContentStoreProvider.InjectionKey.self] = nil
            let response = try await put(target)
            installNamespace()
            XCTAssertEqual(response.status, .serviceUnavailable, route.rawValue + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("media_storage_unavailable"), response.body.string)
            assertTrue(try await intents(target).isEmpty, route.rawValue + ": no row for a write that never started")
            assertNil(try await originalKey(target), route.rawValue + ": and no address either")
        }
    }

    /// Row 10, through the route. Every refusal the content store makes before its
    /// first byte leaves the process is made before `begin`, so a payload that is
    /// not the image it claims to be leaves no `uncertain` row behind — which
    /// would otherwise block the owner's deletion until a fence resolved it.
    func testAMalformedPayloadRecordsNoIntentAndReachesNoStorageOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let mark = await mark()
            // The bytes match the allocated digest and size, and are not an image.
            let malformed = Data("not a photograph, even at more than twelve bytes".utf8)
            let reallocated = try await allocatedFor(target, bytes: malformed)
            let response = try await call(.PUT, reallocated.contentPath, reallocated.actor, bytes: malformed)
            XCTAssertTrue([HTTPResponseStatus.unsupportedMediaType, .unprocessableEntity].contains(response.status),
                          route.rawValue + " → " + response.body.string)
            assertTrue(try await intents(reallocated).isEmpty, route.rawValue)
            assertNil(try await originalKey(reallocated), route.rawValue)
            assertTrue(await calls(since: mark).isEmpty, route.rawValue + ": nothing reached storage")
        }
    }

    /// Row 17. A refusal the store makes about its caller, before the GET is
    /// issued, for an address this policy itself validated with the very
    /// configuration the store holds. Meeting one means a caller bug, and a caller
    /// bug is a 500 — not a 503 that invites a retry which cannot help.
    func testAReadbackRefusedBeforeItWasIssuedIsAServerFaultNotARetryOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let key = try await boundButEmpty(target)
            try await store.seedContent(key: key, data: Self.png, contentType: "image/png")
            await store.failNextRead(with: PrivateContentStoreError.invalidContent)
            let response = try await put(target)
            XCTAssertEqual(response.status, .internalServerError, route.rawValue + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("request_failed"), response.body.string)
            assertDiscloses(response, nothingAbout: target, key: key)
            assertEqual(try await state(target), "allocated", route.rawValue)
        }
    }

    // MARK: - A historical address

    /// Row 18 / R3. A row bound to a historical `platform/` address and not ready
    /// has no writer any more, and it is never re-bound to a namespaced key: an
    /// address is final, so the only way forward is a fresh allocation. Staging
    /// holds a handful of these; production holds none.
    func testAHistoricalAddressIsRefusedWithReallocateAndIsNeverReboundOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let historical = "platform/\(target.project.workspaceId)/\(target.project.project.id)/\(target.assetID)/original"
            try await VerifiedIdentityService.sql(app.db).raw("""
                UPDATE media_assets SET original_key = \(bind: historical) WHERE id = \(bind: target.assetID)
                """).run()
            let mark = await mark()
            let response = try await put(target)
            XCTAssertEqual(response.status, .gone, route.rawValue + " → " + response.body.string)
            XCTAssertTrue(response.body.string.contains("media_reallocate"), response.body.string)
            XCTAssertTrue(response.body.string.contains("Allocate this photo again"), response.body.string)
            assertDiscloses(response, nothingAbout: target)
            assertEqual(try await originalKey(target), historical, route.rawValue + ": never re-bound")
            assertEqual(try await state(target), "allocated", route.rawValue)
            assertTrue(try await intents(target).isEmpty, route.rawValue)
            assertTrue(await calls(since: mark).isEmpty, route.rawValue)
        }
    }

    // MARK: - An address is born once, and stays

    /// R1, end to end. An interrupted first attempt binds the address and leaves
    /// an `uncertain` intent; the abandoned PUT lands afterwards; the retry meets
    /// its own object at its own address, takes row 5 for the original and row 1
    /// for the rendition, and becomes ready. That is the ordinary shape of a
    /// resumed upload, and it works only because the address did not move.
    func testAnInterruptedUploadResumesOntoItsOwnAddressAndBecomesReady() async throws {
        let target = try await allocated(.manager)
        let key = try await boundButEmpty(target)
        // The PUT this process gave up on reached storage after all.
        try await store.seedContent(key: key, data: Self.png, contentType: "image/png")
        let mark = await mark()
        let response = try await put(target)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let ready = try response.content.decode(MediaAssetResponse.self)
        XCTAssertEqual(ready.state, "ready")
        assertEqual(try await originalKey(target), key, "the address a row is given is the address it keeps")
        let calls = await calls(since: mark)
        XCTAssertEqual(calls.count, 3, "row 5 for the original, then row 1 for the rendition — \(calls)")
        XCTAssertEqual(calls[1], .read(key: key, maximumBytes: PrivateContent.maximumBytes))
        let recorded = try await intents(target)
        XCTAssertEqual(recorded.map(\.state), ["uncertain", "settled", "settled"])
        XCTAssertEqual(recorded[0].key, key)
        XCTAssertEqual(recorded[1].key, key, "the retry recorded the same address, not a second one")
    }

    /// The database is the thing that makes that true, not a convention. Once an
    /// address is set it is final: under create-only the first one is spent, and a
    /// row that forgot it would abandon the object it named with nothing left in
    /// the database that knows the address.
    func testABoundAddressCannotBeMovedAndAReadyRowMustHaveBoth() async throws {
        let target = try await allocated(.manager)
        let key = try await boundButEmpty(target)
        let sql = try VerifiedIdentityService.sql(app.db)
        do {
            try await sql.raw("UPDATE media_assets SET original_key = \(bind: key + "-moved") WHERE id = \(bind: target.assetID)").run()
            XCTFail("a bound address must not be movable")
        } catch { /* 23514 from preserve_media_asset_keys */ }
        assertEqual(try await originalKey(target), key)
        do {
            try await sql.raw("UPDATE media_assets SET state = 'ready' WHERE id = \(bind: target.assetID)").run()
            XCTFail("a ready row must carry both addresses")
        } catch { /* media_ready_has_keys, and the readiness CHECK from CreatePrivateMedia */ }
    }

    /// Two first uploads of one asset cannot produce two addresses. The loser sees
    /// the row already bound inside the transaction that would have recorded its
    /// own intent, takes the row's address as the answer and re-runs the write
    /// against it — before any PUT has been issued for the address that lost, so
    /// no object and no intent exist for it.
    func testTwoConcurrentFirstUploadsOfOneAssetConvergeOnOneAddress() async throws {
        let target = try await allocated(.manager)
        async let first = put(target)
        async let second = put(target)
        let responses = try await [first, second]
        for response in responses { XCTAssertEqual(response.status, .ok, response.body.string) }
        assertEqual(try await state(target), "ready")
        let key = try unwrap(await originalKey(target))
        let recorded = try await intents(target)
        XCTAssertTrue(recorded.allSatisfy({ $0.state == "settled" }), "\(recorded.map(\.state))")
        XCTAssertEqual(Set(recorded.map(\.key)).count, 2, "one original address and one rendition address, no more")
        XCTAssertTrue(recorded.contains { $0.key == key })
        let stored = await store.recordedCalls().compactMap { call -> String? in
            if case .put(let key, _, _) = call { return key } else { return nil }
        }
        XCTAssertEqual(Set(stored).count, 2, "two addresses were written to in total: \(Set(stored))")
    }

    // MARK: - Readiness

    /// Readiness is a third transaction on purpose: processing and storage happen
    /// outside the membership locks, and a member removed while the bytes were in
    /// flight must not be able to finish. What must survive that refusal is the
    /// evidence: both intents are `settled`, because the bytes really are at those
    /// addresses and a deletion has to know it.
    func testReadinessIsRefusedAfterAccessIsRevokedMidUploadAndTheIntentsStaySettled() async throws {
        let owner = try await user(), member = try await user()
        let project = try await self.project(owner)
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: member.email!, role: "member", projects: [.init(projectId: project.project.id, role: "member")], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: member.requireID(), on: db) }
        let snag = try await self.snag(member, project)
        let path = "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media"
        let allocation = try await call(.POST, path, member, body: command(snag))
        XCTAssertEqual(allocation.status, .ok, allocation.body.string)
        let asset = try allocation.content.decode(MediaAssetResponse.self)
        let target = Target(route: .manager, actor: member, owner: owner, project: project, snag: snag,
                            assetID: asset.id, contentPath: path + "/\(asset.id)/content", token: nil)

        let box = UnsafeWriteTestBox(value: (app!, project.workspaceId, try member.requireID(), try owner.requireID()))
        installNamespace(PutInterceptingStore(inner: store, afterPut: 2) {
            let (app, workspaceID, memberID, ownerID) = box.value
            try await app.db.transaction { db in
                try await WorkspaceAccessService.changeMember(workspaceID: workspaceID, targetID: memberID, newRole: nil,
                                                              expectedRevision: 1, actorID: ownerID, on: db)
            }
        })
        let response = try await put(target)
        XCTAssertEqual(response.status, .notFound, response.body.string)
        assertEqual(try await state(target), "allocated", "readiness was refused")
        let recorded = try await intents(target)
        XCTAssertEqual(recorded.map(\.state), ["settled", "settled"],
                       "the bytes are there; the evidence a deletion needs must not be lost with the response")
        let key = try unwrap(await originalKey(target))
        assertEqual(await store.object(at: key)?.data, Self.png)
    }

    // MARK: - What the fence pass will be handed

    /// The end-to-end version of the fence suite's target assertion. Every intent
    /// a ready asset produced names the installed target, under `create_only_v1`,
    /// at exactly the addresses the row carries — which is what lets the erasure
    /// fence make those two objects permanently unreadable, and what makes the
    /// manifest's spelling of a key byte-identical to the intent's, because both
    /// came from one allocation.
    func testEveryIntentForAReadyAssetCarriesTheInstalledTargetOnBothRoutes() async throws {
        for route in Route.allCases {
            let target = try await allocated(route)
            let response = try await put(target)
            XCTAssertEqual(response.status, .ok, route.rawValue + " → " + response.body.string)
            let row = try await row(target)
            let original = try XCTUnwrap(row.decode(column: "original_key", as: String?.self))
            let rendition = try XCTUnwrap(row.decode(column: "rendition_key", as: String?.self))
            let recorded = try await intents(target)
            XCTAssertEqual(Set(recorded.map(\.key)), [original, rendition], route.rawValue)
            for intent in recorded {
                XCTAssertEqual(intent.state, "settled", route.rawValue)
                XCTAssertEqual(intent.writeProtocol, "create_only_v1", route.rawValue)
                XCTAssertEqual(intent.backend, configuration.target.backend, route.rawValue)
                XCTAssertEqual(intent.identity, configuration.target.backendIdentity, route.rawValue)
                XCTAssertEqual(intent.bucket, configuration.target.bucket, route.rawValue)
                XCTAssertEqual(intent.namespace, configuration.target.namespace, route.rawValue)
                XCTAssertTrue(intent.key.hasPrefix(configuration.target.namespace), route.rawValue)
            }
            assertEqual(await store.object(at: original)?.data, Self.png, route.rawValue)
            assertNotNil(await store.object(at: rendition), route.rawValue)
        }
    }

    // MARK: - The vocabulary itself

    /// The last two columns of the state table, asserted in one place: the
    /// complete set of identifiers B2 may return, and the four operator log kinds
    /// that separate the four rows a client cannot tell apart.
    ///
    /// Every reason is a fixed literal chosen at the call site. Nothing from a
    /// store error, a key, an ETag, a bucket, a namespace or a grant token is
    /// interpolated into one, because a 4xx reason ships to the client verbatim
    /// and only a 5xx is replaced wholesale by the middleware.
    func testTheRefusalVocabularyIsFixedAndTheFourLogKindsAreDistinct() throws {
        let box = LogKindBox()
        let logger = Logger(label: "private-media-write-test") { _ in CapturingLogHandler(box: box) }
        let expected: [(PrivateMediaWriteService.Refusal, HTTPResponseStatus, String)] = [
            (.erased, .gone, "media_erased"),
            (.reallocate, .gone, "media_reallocate"),
            (.keyConflict, .conflict, "media_key_conflict"),
            (.mismatch, .unprocessableEntity, "media_mismatch"),
            (.storageUnavailable, .serviceUnavailable, "media_storage_unavailable"),
            (.unavailable(nil), .serviceUnavailable, "media_unavailable"),
            (.requestFailed, .internalServerError, "request_failed"),
        ]
        for (refusal, status, identifier) in expected {
            let abort = try XCTUnwrap(PrivateMediaWriteService.abort(refusal, logger: logger) as? Abort)
            XCTAssertEqual(abort.status, status, identifier)
            XCTAssertEqual(abort.identifier, identifier)
            for secret in [configuration.target.namespace, configuration.target.bucket, configuration.target.backendIdentity] {
                XCTAssertFalse(abort.reason.contains(secret), identifier)
            }
        }
        XCTAssertEqual(Set(expected.map(\.2)).count, expected.count, "one identifier per meaning")
        XCTAssertTrue(box.kinds.isEmpty, "a refusal with no operator fact to report logs nothing")

        for kind in [PrivateMediaWriteService.LogKind.existsThenAbsent, .readbackUnavailable, .notLanded, .storageUnreachable] {
            _ = PrivateMediaWriteService.abort(PrivateMediaWriteService.Refusal.unavailable(kind), logger: logger)
        }
        XCTAssertEqual(box.kinds, ["exists_then_absent", "readback_unavailable", "not_landed", "storage_unreachable"])
    }

    // MARK: - Helpers that need the fixtures above

    /// A second allocation in the same snag, for bytes of the caller's choosing.
    private func allocatedFor(_ target: Target, bytes: Data) async throws -> Target {
        switch target.route {
        case .manager:
            let path = "api/v2/projects/\(target.project.project.id)/snags/\(target.snag.snag.id)/media"
            let response = try await call(.POST, path, target.owner, body: command(target.snag, bytes: bytes))
            XCTAssertEqual(response.status, .ok, response.body.string)
            let asset = try response.content.decode(MediaAssetResponse.self)
            return .init(route: target.route, actor: target.actor, owner: target.owner, project: target.project,
                         snag: target.snag, assetID: asset.id, contentPath: path + "/\(asset.id)/content", token: target.token)
        case .contractorLink:
            let token = try XCTUnwrap(target.token)
            let path = "api/v2/contractor/\(token)/snags/\(target.snag.snag.id)/media"
            let response = try await call(.POST, path, nil, body: command(target.snag, bytes: bytes, purpose: "completion", intent: UUID()))
            XCTAssertEqual(response.status, .ok, response.body.string)
            let asset = try response.content.decode(ContractorGrantController.PhotoResult.self)
            return .init(route: target.route, actor: nil, owner: target.owner, project: target.project,
                         snag: target.snag, assetID: asset.id, contentPath: path + "/\(asset.id)/content", token: token)
        }
    }
}

/// Carries a test's own values into a `@Sendable` hook. Test-local, and nothing
/// crosses a real concurrency boundary: the hook runs inside the request it hooks.
private struct UnsafeWriteTestBox<T>: @unchecked Sendable { let value: T }

/// The shared in-memory double, with one hook after the n-th `put` returns.
///
/// This is the only way to hold the state the readiness transaction exists for:
/// access that was valid when the intent was recorded and is not valid by the
/// time readiness is committed. It delegates rather than reimplements, so
/// create-only, the exact fence and `absent` are still the real rules.
private actor PutInterceptingStore: PrivateContentStorage {
    private let inner: InMemoryPrivateContentStore
    private let afterPut: Int
    private let hook: @Sendable () async throws -> Void
    private var puts = 0
    init(inner: InMemoryPrivateContentStore, afterPut: Int, hook: @escaping @Sendable () async throws -> Void) {
        self.inner = inner; self.afterPut = afterPut; self.hook = hook
    }
    nonisolated var target: ObjectStorageWriteTarget { inner.target }
    func put(key: String, data: Data, contentType: String) async throws -> PutOutcome {
        let outcome = try await inner.put(key: key, data: data, contentType: contentType)
        puts += 1
        if puts == afterPut { try await hook() }
        return outcome
    }
    func read(key: String, maximumBytes: Int) async throws -> Readback {
        try await inner.read(key: key, maximumBytes: maximumBytes)
    }
}

/// Collects the `kind` of each line a refusal logged. Test-local.
private final class LogKindBox: @unchecked Sendable { var kinds: [String] = [] }

private struct CapturingLogHandler: LogHandler {
    let box: LogKindBox
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        if let kind = metadata?["kind"] { box.kinds.append("\(kind)") }
    }
}
