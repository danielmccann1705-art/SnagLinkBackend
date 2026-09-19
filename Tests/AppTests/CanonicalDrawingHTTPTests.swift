@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CanonicalDrawingHTTPTests: XCTestCase {
    final actor StreamState {
        let data: Data
        var sent = false
        init(_ data: Data) { self.data = data }
        func next() -> Data? { if sent { return nil }; sent = true; return data }
    }
    final actor Runtime: CanonicalDrawingRuntime {
        nonisolated let identity: DrawingProcessorRuntimeIdentity
        private var originals: [UUID: Data] = [:]
        private var pages: [String: Data] = [:]
        func originalCount() -> Int { originals.count }
        init() throws {
            identity = try .init(processorProfile: "drawing-linux-byte-v1:" + String(repeating: "a", count: 64),
                                 imageDigest: "sha256:" + String(repeating: "b", count: 64))
        }
        func putOriginal(_ binding: DrawingUploadBinding, bytes: Data) async throws {
            if let old = originals[binding.assetId], old != bytes {
                throw Abort(.conflict, reason: "Immutable original differs")
            }
            originals[binding.assetId] = bytes
        }
        func openOriginal(_ target: DrawingOriginalReadTarget) async throws -> DrawingOriginalObjectRead {
            guard let data = originals[target.binding.assetId] else { throw Abort(.notFound) }
            let stream = StreamState(data)
            return .init(mimeType: target.binding.mimeType,
                         nextChunk: { await stream.next() }, cancel: {})
        }
        func process(_ value: DrawingProcessingIdentity) async throws -> DrawingProcessingManifest {
            guard let original = originals[value.assetId] else { throw Abort(.notFound) }
            let rendition = try PrivateImageProcessor.process(original, mime: value.sourceMIME)
            let thumbnail = try PrivateImageProcessor.process(original, mime: value.sourceMIME, maximumPixelSize: 512)
            let width = Double(rendition.sourceWidth), height = Double(rendition.sourceHeight)
            let box = DrawingPageGeometry.Box(x: 0, y: 0, width: width, height: height)
            let geometry = DrawingPageGeometry(mediaBox: box, cropBox: box, displayBox: box,
                rotation: 0, userUnit: 1, width: rendition.width, height: rendition.height,
                sourceToDisplay: [1 / width, 0, 0, 1 / height, 0, 0],
                coordinateSystem: "display_top_left_v1")
            let page = DrawingProcessedPage(sourcePageIndex: 0, sourcePageLabel: "1", geometry: geometry,
                renditionSHA256: PrivateImageProcessor.digest(rendition.jpeg), renditionBytes: rendition.jpeg.count,
                thumbnailSHA256: PrivateImageProcessor.digest(thumbnail.jpeg), thumbnailBytes: thumbnail.jpeg.count)
            pages[key(value.assetId, .rendition)] = rendition.jpeg
            pages[key(value.assetId, .thumbnail)] = thumbnail.jpeg
            return .init(sourceSHA256: value.sourceSHA256, sourceBytes: value.sourceBytes,
                sourceMIME: value.sourceMIME, processorProfile: value.processorProfile, pages: [page])
        }
        func readPage(_ target: CanonicalDrawingPageReadTarget) async throws -> Data {
            guard let data = pages[key(target.assetId, target.kind)] else { throw Abort(.notFound) }
            return data
        }
        private func key(_ asset: UUID, _ kind: CanonicalDrawingPageReadTarget.Kind) -> String {
            asset.uuidString + ":" + kind.rawValue
        }
    }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    var app: Application!
    var runtime: Runtime!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        runtime = try Runtime(); app.storage[CanonicalDrawingRuntimeKey.self] = runtime
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user() async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("drawing-http-\(UUID())@example.test",
                name: "Synthetic drawing manager", on: db)
        }
    }
    private func jwt(_ user: User) throws -> String {
        let id = try user.requireID()
        return try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
    }
    private func call(_ method: HTTPMethod, _ path: String, user: User?,
                      json: [String: Any]? = nil, bytes: Data? = nil,
                      mime: String = "image/png") async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { request in
            if let user { request.headers.bearerAuthorization = .init(token: try self.jwt(user)) }
            if let bytes {
                request.headers.contentType = HTTPMediaType(type: mime.split(separator: "/")[0].description,
                                                            subType: mime.split(separator: "/")[1].description)
                request.body = .init(data: bytes)
            } else if let json {
                request.headers.contentType = .json
                request.body = .init(data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func mutation() -> [String: Any] {
        ["operationId": UUID().uuidString, "deviceId": UUID().uuidString]
    }
    private func project(_ owner: User) async throws -> Project {
        try await app.db.transaction { db in
            let workspace = try await WorkspaceAccessService.personal(for: owner.requireID(), on: db)
            let project = Project(id: UUID(), name: "Willow Court", reference: "WC12", ownerId: try owner.requireID())
            project.workspaceId = try workspace.requireID(); project.platformManaged = true
            try await project.save(on: db); return project
        }
    }
    private func snag(_ owner: User, _ project: Project) async throws -> Snag {
        let value = Snag(id: UUID(), reference: "WC12-001", title: "Seal shower tray",
            projectId: try project.requireID(), ownerId: try owner.requireID())
        value.workspaceId = project.workspaceId; try await value.save(on: app.db); return value
    }

    func testAuthorisedUploadProcessPublishPinBootstrapAndPrivateRead() async throws {
        let owner = try await user(), project = try await project(owner), projectID = try project.requireID()
        let assetID = UUID(), allocate: [String: Any] = ["mutation": mutation(), "id": assetID.uuidString,
            "purpose": "drawing_source", "sha256": PrivateImageProcessor.digest(Self.png),
            "byteCount": Self.png.count, "mimeType": "image/png", "originalFilename": "Ground floor.png"]
        let base = "api/v2/projects/\(projectID)/drawings"
        let allocatedResponse = try await call(.POST, base + "/sources", user: owner, json: allocate)
        XCTAssertEqual(allocatedResponse.status,.ok,allocatedResponse.body.string)
        let allocated = try allocatedResponse.content.decode(DrawingAssetRecord.self)
        XCTAssertEqual(allocated.id,assetID); XCTAssertEqual(allocated.revision,1)

        let uploadedResponse = try await call(.PUT,base + "/sources/\(assetID)/content",user:owner,bytes:Self.png)
        XCTAssertEqual(uploadedResponse.status,.ok,uploadedResponse.body.string)
        let uploaded = try uploadedResponse.content.decode(DrawingAssetRecord.self)
        XCTAssertEqual(uploaded.revision,2)
        let retry = try await call(.PUT,base + "/sources/\(assetID)/content",user:owner,bytes:Self.png)
        XCTAssertEqual(try retry.content.decode(DrawingAssetRecord.self).revision,2)

        let processedResponse = try await call(.POST,base + "/sources/\(assetID)/process",user:owner,
            json:["expectedAssetRevision":uploaded.revision])
        XCTAssertEqual(processedResponse.status,.ok,processedResponse.body.string)
        let processed = try processedResponse.content.decode(DrawingAssetRecord.self)
        XCTAssertEqual(processed.state,"ready")
        let sheetID = UUID(), versionID = UUID(), pageID = UUID()
        let publication: [String: Any] = ["mutation":mutation(),"assetId":assetID.uuidString,
            "expectedAssetRevision":processed.revision,"acknowledgeInternalOriginalAccess":true,
            "sheets":[["id":sheetID.uuidString,"versionId":versionID.uuidString,
                       "versionPageId":pageID.uuidString,"name":"Ground floor","sortOrder":0,"sourcePageIndex":0]]]
        let published = try await call(.POST,base + "/publish",user:owner,json:publication)
        XCTAssertEqual(published.status,.ok,published.body.string)

        let snag = try await snag(owner,project)
        let pin: [String: Any] = ["mutation":mutation(),"expectedSnagRevision":1,"expectedPinRevision":0,
            "pin":["drawingId":sheetID.uuidString,"versionId":versionID.uuidString,
                   "versionPageId":pageID.uuidString,"x":0.25,"y":0.75]]
        let pinned = try await call(.POST,base + "/snags/\(try snag.requireID())/pin",user:owner,json:pin)
        XCTAssertEqual(pinned.status,.ok,pinned.body.string)
        XCTAssertEqual(try pinned.content.decode(DrawingPinRecord.self).snagRevision,2)

        let sheets = try await call(.GET,base,user:owner)
        let graph = try sheets.content.decode([DrawingSheetResponse].self)
        XCTAssertEqual(graph.map(\.id),[sheetID]); XCTAssertEqual(graph[0].pages.map(\.id),[pageID])
        let page = try await call(.GET,base + "/pages/\(pageID)/rendition",user:owner)
        XCTAssertEqual(page.status,.ok); XCTAssertEqual(page.headers.contentType?.description,"image/jpeg")
        XCTAssertEqual(PrivateImageProcessor.digest(Data(buffer:page.body)),graph[0].pages[0].rendition.sha256)

        let snapshot = try await app.db.transaction { db in
            try await RegisterSyncService.create(projectID:projectID,actorID:owner.requireID(),on:db)
        }
        XCTAssertTrue(snapshot.coverage.contains("drawings")); XCTAssertTrue(snapshot.coverage.contains("drawingPins"))
        XCTAssertEqual(snapshot.total,5); XCTAssertEqual(snapshot.items.count,snapshot.total)
        XCTAssertEqual(snapshot.items.filter { $0.type == "drawing" }.map(\.id),[sheetID])
        XCTAssertEqual(snapshot.items.filter { $0.type == "drawingPin" }.map(\.id),[try snag.requireID()])
    }

    func testExpiredAllocationRejectsUploadBeforeAnyObjectWrite() async throws {
        let owner = try await user(), project = try await project(owner)
        let projectID = try project.requireID(), allocatedID = UUID(), expiredID = UUID()
        let base = "api/v2/projects/\(projectID)/drawings/sources"
        let allocated = try await call(.POST, base, user: owner, json: [
            "mutation": mutation(), "id": allocatedID.uuidString, "purpose": "drawing_source",
            "sha256": PrivateImageProcessor.digest(Self.png), "byteCount": Self.png.count,
            "mimeType": "image/png", "originalFilename": "Ground floor.png",
        ])
        XCTAssertEqual(allocated.status, .ok)
        let now = Date()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,
                original_mime,original_filename,original_key,processor_profile,state,revision,created_at,expires_at)
            SELECT \(bind: expiredID),workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,
                original_mime,original_filename,\(bind: "drawings/\(project.workspaceId!)/\(projectID)/\(expiredID)/original"),
                processor_profile,'allocated',1,\(bind: now.addingTimeInterval(-90000)),\(bind: now.addingTimeInterval(-1))
            FROM drawing_assets WHERE id=\(bind: allocatedID)
            """).run()
        let upload = try await call(.PUT, base + "/\(expiredID)/content", user: owner, bytes: Self.png)
        XCTAssertEqual(upload.status, .conflict)
        let stored = await runtime.originalCount()
        XCTAssertEqual(stored, 0)
    }

    func testMissingCoordinatorAndCrossAccountScopeFailClosed() async throws {
        let owner = try await user(), stranger = try await user(), project = try await project(owner)
        let path = "api/v2/projects/\(try project.requireID())/drawings/sources"
        let body: [String: Any] = ["mutation":mutation(),"id":UUID().uuidString,"purpose":"drawing_source",
            "sha256":PrivateImageProcessor.digest(Self.png),"byteCount":Self.png.count,
            "mimeType":"image/png","originalFilename":"Plan.png"]
        let crossAccount = try await call(.POST,path,user:stranger,json:body)
        XCTAssertEqual(crossAccount.status,.notFound)
        app.storage[CanonicalDrawingRuntimeKey.self] = nil
        let unavailable = try await call(.POST,path,user:owner,json:body)
        XCTAssertEqual(unavailable.status,.serviceUnavailable)
        XCTAssertTrue(unavailable.body.string.contains("drawing_processor_unavailable"))
    }
}
