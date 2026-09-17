@testable import App
import XCTVapor
import Fluent
import FluentSQL
import SotoS3

/// Real rich-fixture publication on the owned local PostgreSQL. Every original is the
/// fixture's actual 1×1 PNG bytes, transferred through the tested original service and
/// an in-memory Soto S3 stub, so decode/rendition/drawing facts are actual outputs.
final class LegacyImportCommitTests: XCTestCase {
    var app: Application!
    var http: StagedOriginalHTTPStub!
    var client: AWSClient!
    var store: SotoStagedImportOriginalStore!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55480")
    struct Staged {
        let actor: StagedLegacyImportActor; let workspace: UUID; let stage: StagedLegacyImportCommand; let scope: StagedLegacyImportScope
        let descriptor: Data; let files: [String: Data]
    }
    override func setUp() async throws {
        guard let value = Environment.get("DATABASE_URL"), let url = URLComponents(string: value),
              url.host == "127.0.0.1", url.port == 55439, url.path == "/snaglist_release_import_commit_0913" else {
            throw XCTSkip("Explicit owned local synthetic import-commit test database required")
        }
        try await start()
        http = StagedOriginalHTTPStub()
        client = AWSClient(credentialProvider: .static(accessKeyId: "synthetic", secretAccessKey: "synthetic"), retryPolicy: .noRetry, httpClient: http)
        store = .init(s3: S3(client: client, endpoint: "https://synthetic.invalid"), privateBucket: "synthetic-private")
    }
    private func start() async throws { app = try await Application.make(.testing); try await configure(app) }
    override func tearDown() async throws {
        if let client { try await client.shutdown() }
        if let app { try await app.asyncShutdown() }
    }
    private var sql: SQLDatabase { get throws { try VerifiedIdentityService.sql(app.db) } }
    private func fixtureFiles() throws -> [String: Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-files-v1.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"] as! String, Data(base64Encoded: $0["base64"] as! String)!) })
    }
    private func user(_ label: String) async throws -> (User, StagedLegacyImportActor) {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("\(label)-\(UUID())@example.test", name: "Synthetic \(label)", on: db) }
        return (user, try .init(id: user.requireID(), authVersion: user.authVersion))
    }
    /// Every test gets its own lineage: all fixture UUIDs (records and directory) are remapped
    /// deterministically per lineage so tests sharing one database never collide. `secondStaged`
    /// derives a second project from the same lineage, keeping its directory IDs.
    static func remap(_ root: [String: Any], suffix: String, keep: Set<String>) -> [String: Any] {
        var mapping: [String: String] = [:]
        func map(_ value: Any) -> Any {
            if let text = value as? String, let uuid = UUID(uuidString: text), !keep.contains(uuid.uuidString) {
                if mapping[uuid.uuidString] == nil { mapping[uuid.uuidString] = LegacyCanonicalProjectionMapper.stableID(uuid, suffix).uuidString }
                return mapping[uuid.uuidString]!
            }
            if let object = value as? [String: Any] { return object.mapValues(map) }
            if let array = value as? [Any] { return array.map(map) }
            return value
        }
        return map(root) as! [String: Any]
    }
    private func stage(company: Bool = false, actor given: (User, StagedLegacyImportActor)? = nil, workspace givenWorkspace: UUID? = nil,
                       lineage: String = UUID().uuidString, transform: ((inout [String: Any]) -> Void)? = nil) async throws -> Staged {
        let (user, actor): (User, StagedLegacyImportActor)
        if let given { (user, actor) = given } else { (user, actor) = try await self.user("manager") }
        let workspace: UUID
        if let givenWorkspace { workspace = givenWorkspace }
        else if company { workspace = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: user.requireID(), on: db).requireID() } }
        else { workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: actor.id, on: db).requireID() } }
        let raw = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json"))
        let fixture = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let archive = (fixture["source"] as! [String: Any])["archiveID"] as! String
        var object = Self.remap(fixture, suffix: lineage, keep: [archive])
        transform?(&object)
        let descriptor = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: descriptor)
        let kind = try await Team.find(workspace, on: app.db)!.kind
        let stage = StagedLegacyImportCommand(formatVersion: 1, sessionId: UUID(), mutation: .init(operationId: UUID(), deviceId: UUID()), expectedActorId: actor.id,
            expectedAuthVersion: actor.authVersion, expectedWorkspaceKind: kind, destination: binding.destination,
            selectedProjectId: source.project.id, sourceFingerprint: source.source.sourceFingerprint, exportSHA256: LegacyProjectImportDecoder.digest(descriptor), exportByteCount: descriptor.count,
            acknowledgement: .init(version: StagedLegacyImportCommand.Acknowledgement.supportedVersion, wording: StagedLegacyImportCommand.Acknowledgement.supportedWording, accepted: true))
        _ = try await StagedLegacyImportService.create(stage, descriptor: descriptor, workspaceID: workspace, actor: actor, binding: binding, on: app.db)
        return .init(actor: actor, workspace: workspace, stage: stage, scope: StagedLegacyImportService.scope(stage, workspaceID: workspace), descriptor: descriptor, files: try fixtureFiles())
    }
    /// Transfers every declared original except `skipping` through the real original service.
    private func transfer(_ staged: Staged, skipping: Set<String> = []) async throws {
        let rows = try await sql.raw("SELECT f.declaration_id, f.archive_path FROM staged_legacy_import_files f LEFT JOIN staged_import_original_receipts r ON r.session_id = f.session_id AND r.declaration_id = f.declaration_id WHERE f.session_id = \(bind: staged.scope.sessionId) AND r.declaration_id IS NULL").all()
        for row in rows {
            let path = try row.decode(column: "archive_path", as: String.self)
            if skipping.contains(path) { continue }
            let command = StagedImportOriginalCommand(scope: staged.scope, declarationId: try row.decode(column: "declaration_id", as: UUID.self), operationId: UUID(), expectedSessionRevision: 1)
            _ = try await StagedImportOriginalService.retain(command, actor: staged.actor, binding: binding, body: stagedTestBody(staged.files[path]!), store: store, on: app.db)
        }
    }
    private func prepare(_ staged: Staged) async throws -> LegacyCanonicalProjectionCommand {
        let command = LegacyCanonicalProjectionCommand(projectionId: UUID(), scope: staged.scope, operationId: UUID(), expectedSourceRevision: 1, policy: LegacyCanonicalProjection.policy)
        _ = try await LegacyCanonicalProjectionService.prepare(command, actor: staged.actor, binding: binding, on: app.db)
        _ = try await LegacyImportProcessingService.process(projectionID: command.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, store: store, on: app.db)
        return command
    }
    private func commitCommand(_ staged: Staged, _ projection: LegacyCanonicalProjectionCommand) async throws -> LegacyImportCommitCommand {
        let value = try await LegacyCanonicalProjectionService.read(projectionID: projection.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, on: app.db)
        return .init(commitId: UUID(), scope: staged.scope, projectionId: projection.projectionId, operationId: UUID(), expectedSourceRevision: 1,
            expectedGraphSHA256: try LegacyCanonicalProjectionMapper.digest(value),
            acknowledgement: .init(version: LegacyImportCommitCommand.Acknowledgement.supportedVersion, wording: LegacyImportCommitCommand.Acknowledgement.supportedWording, accepted: true))
    }
    private func count(_ table: String, _ column: String, _ id: UUID) async throws -> Int {
        try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: id)").first()!.decode(column: "n", as: Int.self)
    }
    private func expectCount(_ table: String, _ column: String, _ id: UUID, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await count(table, column, id)
        XCTAssertEqual(actual, expected, table, file: file, line: line)
    }
    private func rejected(_ identifier: String? = nil, _ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected rejection", file: file, line: line) }
        catch { if let identifier { XCTAssertEqual((error as? Abort)?.identifier, identifier, "\(error)", file: file, line: line) } }
    }

    /// A snag carried over from the old app keeps its photos in `imported_photos`, not
    /// `media_assets`. The contractor page builds its photo list from `media_assets`
    /// alone, so before this these snags reached the contractor with no photos at all —
    /// asking someone to fix a defect they had never been shown.
    func testImportedPhotosAreOfferedToTheContractorSurface() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let projection = try await prepare(staged)
        let command = try await commitCommand(staged, projection)
        _ = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor), projectID = source.project.id
        let sql = try VerifiedIdentityService.sql(app.db)

        let snagIDs = try await sql.raw("SELECT id FROM snags WHERE project_id = \(bind: projectID) ORDER BY id").all()
            .map { try $0.decode(column: "id", as: UUID.self) }
        XCTAssertFalse(snagIDs.isEmpty)

        let offered = try await LinkGrantService.importedPhotos(snagIDs: snagIDs, projectID: projectID, on: app.db)
        XCTAssertFalse(offered.isEmpty, "the published import has photos; none reached the contractor query")

        // Every offered photo names a snag the caller asked for, and carries the
        // dimensions the page needs to lay it out without a reflow.
        for row in offered {
            XCTAssertTrue(snagIDs.contains(try row.decode(column: "snag_id", as: UUID.self)))
            XCTAssertNotNil(try row.decode(column: "width", as: Int?.self))
            XCTAssertNotNil(try row.decode(column: "height", as: Int?.self))
        }

        // A grant covers named snags. One it does not name discloses nothing.
        let unrelated = try await LinkGrantService.importedPhotos(snagIDs: [UUID()], projectID: projectID, on: app.db)
        XCTAssertTrue(unrelated.isEmpty)
        let none = try await LinkGrantService.importedPhotos(snagIDs: [], projectID: projectID, on: app.db)
        XCTAssertTrue(none.isEmpty)

        // Nor does the same snag under somebody else's project.
        let elsewhere = try await LinkGrantService.importedPhotos(snagIDs: snagIDs, projectID: UUID(), on: app.db)
        XCTAssertTrue(elsewhere.isEmpty)
    }

    /// A photo whose bytes were not retained, or could not be decoded, is left out
    /// rather than offered as a tile that will never load. The contractor cannot act on
    /// it either way, and a broken tile invites a question with no answer.
    func testAnImportedPhotoWithoutUsableBytesIsLeftOut() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let projection = try await prepare(staged)
        let command = try await commitCommand(staged, projection)
        _ = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor), projectID = source.project.id
        let sql = try VerifiedIdentityService.sql(app.db)
        let snagIDs = try await sql.raw("SELECT id FROM snags WHERE project_id = \(bind: projectID) ORDER BY id").all()
            .map { try $0.decode(column: "id", as: UUID.self) }

        let before = try await LinkGrantService.importedPhotos(snagIDs: snagIDs, projectID: projectID, on: app.db)
        XCTAssertFalse(before.isEmpty)
        let target = try before[0].decode(column: "id", as: UUID.self)

        // Mark both of that photo's file uses unavailable, as an import would when the
        // source file was missing from the export.
        try await sql.raw("""
            UPDATE imported_file_uses SET availability = 'missing'
            WHERE project_id = \(bind: projectID) AND id IN (
                SELECT thumbnail_use_id FROM imported_photos WHERE id = \(bind: target)
                UNION SELECT original_use_id FROM imported_photos WHERE id = \(bind: target))
            """).run()

        let after = try await LinkGrantService.importedPhotos(snagIDs: snagIDs, projectID: projectID, on: app.db)
        let remaining = try after.map { try $0.decode(column: "id", as: UUID.self) }
        XCTAssertFalse(remaining.contains(target), "a photo with no usable bytes must not be offered")
        XCTAssertEqual(remaining.count, before.count - 1, "only that one photo should have gone")
    }

    func testRichProjectPublishesCompleteGraphOnceWithQualifiedHistoryAndReadback() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let projection = try await prepare(staged)
        let status = try await LegacyImportCommitService.status(projectionID: projection.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertTrue(status.readyToPublish, "\(status)"); XCTAssertEqual(status.receivedFileCount, 12); XCTAssertEqual(status.decodedImageCount, 11); XCTAssertEqual(status.opaqueFileCount, 1)
        XCTAssertEqual(status.renderedDrawingCount, 1); XCTAssertEqual(status.missingRequiredFileCount, 0); XCTAssertNil(status.commit)
        let command = try await commitCommand(staged, projection)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor), projectID = source.project.id
        // Concurrent identical commits publish exactly once.
        async let a = LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        async let b = LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        let results = try await [a, b]
        XCTAssertEqual(try PlatformMutationService.encode(results[0]), try PlatformMutationService.encode(results[1]))
        let receipt = results[0]
        XCTAssertEqual(receipt.state, "published"); XCTAssertEqual(receipt.projectId, projectID); XCTAssertEqual(receipt.commitId, command.commitId)
        XCTAssertLessThanOrEqual(receipt.journalEventCount, 135); XCTAssertEqual(receipt.renderedDrawingCount, 1); XCTAssertEqual(receipt.opaqueDrawingCount, 0)
        XCTAssertEqual(receipt.decodedFileCount, 11); XCTAssertEqual(receipt.opaqueFileCount, 1); XCTAssertEqual(receipt.reusedDirectoryCount, 0)
        // Canonical project + snags.
        let project = try await Project.find(projectID, on: app.db)!
        XCTAssertTrue(project.platformManaged); XCTAssertEqual(project.workspaceId, staged.workspace); XCTAssertEqual(project.importSessionId, staged.scope.sessionId)
        XCTAssertEqual(project.reference, "WC/P12/26"); XCTAssertNotNil(project.coverFileId); XCTAssertEqual(project.sourceCreatedAt, source.project.createdAt)
        let snags = try await Snag.query(on: app.db).filter(\.$projectId == projectID).sort(\.$displayNumber).all()
        XCTAssertEqual(snags.count, 2); XCTAssertEqual(snags.map(\.displayNumber), [1, 2]); XCTAssertEqual(Set(snags.map(\.reference)), Set(source.snags.map(\.reference)))
        let closed = snags.first { $0.sourceStatus == "closed" }!, open = snags.first { $0.sourceStatus == "open" }!
        XCTAssertEqual(closed.status, "closed"); XCTAssertNil(closed.closedAt); XCTAssertNotNil(closed.sourceClosedAt); XCTAssertEqual(closed.workflowQualification, "legacy_unverified")
        XCTAssertNil(open.workflowQualification); XCTAssertEqual(open.status, "open"); XCTAssertNotNil(open.publishedAt)
        let closedResponse = PlatformSnagResponse(closed)
        XCTAssertEqual(closedResponse.workflow?.legacyClosureUnverified, true); XCTAssertEqual(closedResponse.workflow?.actionableReview, false)
        try await expectCount("completion_attempts", "project_id", projectID, 0); try await expectCount("review_decisions", "project_id", projectID, 0)
        try await expectCount("project_comments", "project_id", projectID, 0)
        let nextNumber = try await sql.raw("SELECT next_snag_number FROM projects WHERE id = \(bind: projectID)").first()!.decode(column: "next_snag_number", as: Int64.self); XCTAssertEqual(nextNumber, 3)
        for s in source.snags {
            let snag = snags.first { $0.id == s.id }!
            XCTAssertEqual(snag.title, s.title); XCTAssertEqual(snag.drawingPinX, s.drawingPinX); XCTAssertEqual(snag.drawingId, s.drawingID); XCTAssertEqual(snag.tags, s.tags)
            XCTAssertEqual(snag.sourceCreatedAt, s.createdAt); XCTAssertEqual(snag.contractorId, s.contractorID); XCTAssertEqual(snag.tradeId, s.tradeID)
        }
        // Directory, organisation, files, photos, drawings, pins, history.
        try await expectCount("contractors", "id", source.contractors[0].id, 1); try await expectCount("trades", "id", source.trades[0].id, 1)
        try await expectCount("contractor_trades", "contractor_id", source.contractors[0].id, source.contractors[0].tradeIDs.count)
        try await expectCount("workspace_folders", "workspace_id", staged.workspace, 2); try await expectCount("workspace_tags", "workspace_id", staged.workspace, 1)
        try await expectCount("project_folder_links", "project_id", projectID, 1); try await expectCount("project_tag_links", "project_id", projectID, 1)
        try await expectCount("imported_file_objects", "project_id", projectID, 12); try await expectCount("imported_file_uses", "project_id", projectID, 14)
        try await expectCount("imported_photos", "project_id", projectID, 3); try await expectCount("drawings", "project_id", projectID, 1)
        try await expectCount("drawing_assets", "project_id", projectID, 1); try await expectCount("drawing_version_pages", "project_id", projectID, 1)
        try await expectCount("snag_drawing_pins", "project_id", projectID, 2); try await expectCount("drawing_pin_events", "project_id", projectID, 2)
        try await expectCount("imported_snag_comments", "project_id", projectID, 2); try await expectCount("imported_status_changes", "project_id", projectID, 1)
        try await expectCount("imported_snag_deletions", "project_id", projectID, 1); try await expectCount("legacy_import_commits", "project_id", projectID, 1)
        try await expectCount("legacy_import_published_records", "commit_id", receipt.commitId, 16)
        // Source retained and unchanged; no second project; journal bound to one group.
        try await expectCount("staged_legacy_import_records", "session_id", staged.scope.sessionId, 16)
        let retained = try await sql.raw("SELECT encode(descriptor,'base64') AS s FROM staged_legacy_import_sources WHERE session_id = \(bind: staged.scope.sessionId)").first()!.decode(column: "s", as: String.self)
        XCTAssertEqual(Data(base64Encoded: retained, options: .ignoreUnknownCharacters), staged.descriptor)
        let importedProjects = try await sql.raw("SELECT count(*) AS n FROM projects WHERE import_session_id = \(bind: staged.scope.sessionId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(importedProjects, 1)
        let journal = try await sql.raw("SELECT count(*) AS n, count(DISTINCT transaction_group) AS g FROM platform_changes WHERE workspace_id = \(bind: staged.workspace) AND sequence BETWEEN \(bind: receipt.firstSequence) AND \(bind: receipt.lastSequence)").first()!
        XCTAssertEqual(try journal.decode(column: "n", as: Int.self), receipt.journalEventCount); XCTAssertEqual(try journal.decode(column: "g", as: Int.self), 1)
        let source_state = try await StagedLegacyImportService.read(staged.scope, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(source_state.state, "staged_incomplete"); XCTAssertEqual(source_state.revision, 1)
        // Publication fence: abort, uploads and re-preparation are refused; receipt/status still readable.
        await rejected("import_preparation_published") { _ = try await StagedLegacyImportService.abort(.init(scope: staged.scope, mutation: .init(operationId: UUID(), deviceId: staged.scope.deviceId), expectedRevision: 1), actor: staged.actor, binding: self.binding, on: self.app.db) }
        let declaration = try await sql.raw("SELECT declaration_id FROM staged_legacy_import_files WHERE session_id = \(bind: staged.scope.sessionId) ORDER BY declaration_id LIMIT 1").first()!.decode(column: "declaration_id", as: UUID.self)
        await rejected("import_preparation_published") { _ = try await StagedImportOriginalService.retain(.init(scope: staged.scope, declarationId: declaration, operationId: UUID(), expectedSessionRevision: 1), actor: staged.actor, binding: self.binding, body: stagedTestBody(Data()), store: self.store, on: self.app.db) }
        await rejected("import_publication_conflict") { _ = try await LegacyImportCommitService.commit(.init(commitId: UUID(), scope: staged.scope, projectionId: projection.projectionId, operationId: UUID(), expectedSourceRevision: 1, expectedGraphSHA256: command.expectedGraphSHA256, acknowledgement: command.acknowledgement), actor: staged.actor, binding: self.binding, on: self.app.db) }
        let after = try await LegacyImportCommitService.status(projectionID: projection.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(after.commit?.commitId, receipt.commitId); XCTAssertFalse(after.readyToPublish)
        let readReceipt = try await LegacyImportCommitService.receipt(commitID: receipt.commitId, scope: staged.scope, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(readReceipt.commitId, receipt.commitId)
        // Restart replay returns the immutable receipt without a second publication.
        try await app.asyncShutdown(); app = nil; try await start()
        let replay = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(try PlatformMutationService.encode(replay), try PlatformMutationService.encode(receipt))
        try await expectCount("legacy_import_commits", "session_id", staged.scope.sessionId, 1)
        // Full typed readback + verified bytes under project read authority.
        let graph = try await app.db.transaction { db in
            _ = try await ProjectAccessService.require(.read, projectID: projectID, actorID: staged.actor.id, on: db)
            return try await LegacyImportReadService.graph(projectID: projectID, workspaceID: staged.workspace, on: db)
        }
        XCTAssertEqual(graph.files.count, 12); XCTAssertEqual(graph.photos.count, 3); XCTAssertEqual(graph.drawings.count, 1); XCTAssertEqual(graph.pins.count, 2)
        XCTAssertEqual(graph.drawings[0].pages.count, 1); XCTAssertEqual(graph.drawings[0].pages[0].geometry.width, 1); XCTAssertEqual(graph.drawings[0].imported?.sourcePageNumber, 2)
        XCTAssertEqual(graph.comments.count, 2); XCTAssertEqual(graph.statusChanges.count, 1); XCTAssertEqual(graph.deletions.count, 1); XCTAssertEqual(graph.organisation.tagIds.count, 1)
        XCTAssertEqual(graph.receipt?.commitId, receipt.commitId)
        let encoded = try PlatformMutationService.encode(graph)
        XCTAssertFalse(encoded.contains("archivePath")); XCTAssertFalse(encoded.contains("staged-import/")); XCTAssertFalse(encoded.contains("Documents/Photos"))
        for file in graph.files {
            let target = try await app.db.transaction { db in try await LegacyImportReadService.fileBytes(file.id, projectID: projectID, rendition: false, store: self.store, on: db) }
            let bytes = try await LegacyImportReadService.verifiedBytes(target, store: store)
            XCTAssertEqual(LegacyProjectImportDecoder.digest(bytes.data), file.sha256)
            guard file.rendition != nil else { XCTAssertNil(file.decodedMime); continue }
            let renditionTarget = try await app.db.transaction { db in try await LegacyImportReadService.fileBytes(file.id, projectID: projectID, rendition: true, store: self.store, on: db) }
            let rendition = try await LegacyImportReadService.verifiedBytes(renditionTarget, store: store)
            XCTAssertEqual(rendition.mime, "image/jpeg"); XCTAssertEqual(LegacyProjectImportDecoder.digest(rendition.data), file.rendition?.sha256)
        }
        let page = graph.drawings[0].pages[0]
        let pageTarget = try await app.db.transaction { db in try await LegacyImportReadService.drawingPageBytes(page.id, projectID: projectID, thumbnail: true, on: db) }
        let thumbnail = try await LegacyImportReadService.verifiedBytes(pageTarget, store: store)
        XCTAssertEqual(thumbnail.sha256, page.thumbnail.sha256)
        // Register snapshot carries the extended coverage and paginates completely.
        let snapshot = try await app.db.transaction { db in try await RegisterSyncService.create(projectID: projectID, actorID: staged.actor.id, on: db) }
        XCTAssertTrue(Set(LegacyImportCommitService.coverage).isSubset(of: Set(snapshot.coverage)))
        var items = snapshot.items, next = snapshot.nextOffset
        while let offset = next {
            let more = try await app.db.transaction { db in try await RegisterSyncService.page(token: snapshot.snapshotToken, offset: offset, projectID: projectID, actorID: staged.actor.id, on: db) }
            items += more.items; next = more.nextOffset
        }
        XCTAssertEqual(items.count, snapshot.total)
        let types = Dictionary(grouping: items, by: \.type).mapValues(\.count)
        XCTAssertEqual(types["snag"], 2); XCTAssertEqual(types["importedFile"], 12); XCTAssertEqual(types["importedPhoto"], 3); XCTAssertEqual(types["drawing"], 1)
        XCTAssertEqual(types["drawingPin"], 2); XCTAssertEqual(types["importedComment"], 2); XCTAssertEqual(types["folder"], 2); XCTAssertEqual(types["importReceipt"], 1)
        // Register summary: legacy closure is not an actionable review.
        let register = try await app.db.transaction { db in try await SnagRegisterService.list(.init(), project: ProjectAccessService.require(.read, projectID: projectID, actorID: staged.actor.id, on: db).0, on: db) }
        XCTAssertEqual(register.summary.awaitingReview, 0); XCTAssertEqual(register.summary.legacyUnverified, 1); XCTAssertEqual(register.total, 2)
    }

    func testMissingRequiredOriginalBlocksPublicationWithZeroCanonicalWrites() async throws {
        let staged = try await stage()
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor)
        try await transfer(staged, skipping: [source.photos[0].original.archivePath!])
        let projection = try await prepare(staged)
        let status = try await LegacyImportCommitService.status(projectionID: projection.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertFalse(status.readyToPublish); XCTAssertEqual(status.missingRequiredFileCount, 1); XCTAssertEqual(status.receivedFileCount, 11)
        let command = try await commitCommand(staged, projection)
        await rejected("import_files_incomplete") { _ = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: self.binding, on: self.app.db) }
        try await expectCount("projects", "id", source.project.id, 0); try await expectCount("legacy_import_commits", "session_id", staged.scope.sessionId, 0)
        // Transferring the missing original later completes the same preparation.
        try await transfer(staged)
        _ = try await LegacyImportProcessingService.process(projectionID: projection.projectionId, scope: staged.scope, actor: staged.actor, binding: binding, store: store, on: app.db)
        let receipt = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(receipt.decodedFileCount, 11)
    }

    func testCancellationInsidePublicationRollsBackEverythingAndRetrySucceeds() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let projection = try await prepare(staged), command = try await commitCommand(staged, projection)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor), projectID = source.project.id
        let sql = try sql, suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let function = "synthetic_commit_pause_" + suffix, trigger = "synthetic_commit_trigger_" + suffix
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: function)() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF NEW.project_id = '\(unsafeRaw: projectID.uuidString)'::uuid AND current_setting('snaglist.synthetic_commit_pause',true) IS DISTINCT FROM 'yes' THEN
                PERFORM set_config('snaglist.synthetic_commit_pause','yes',true); PERFORM pg_sleep(1);
            END IF; RETURN NEW; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE INSERT ON imported_photos FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: function)()").run()
        let sequenceBefore = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: staged.workspace)").first()!.decode(column: "change_sequence", as: Int64.self)
        let task = Task { try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: self.binding, on: self.app.db) }
        var observed = false
        for _ in 0..<200 {
            let n = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND wait_event = 'PgSleep' AND query LIKE 'INSERT INTO imported_photos%'").first()!.decode(column: "n", as: Int.self)
            if n > 0 { observed = true; break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled publication must not commit") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try await sql.raw("DROP TRIGGER \(unsafeRaw: trigger) ON imported_photos").run(); try await sql.raw("DROP FUNCTION \(unsafeRaw: function)()").run()
        XCTAssertTrue(observed)
        for (table, column) in [("projects", "id"), ("legacy_import_commits", "project_id"), ("imported_file_objects", "project_id"), ("snags", "project_id"), ("drawings", "project_id"), ("imported_photos", "project_id")] {
            try await expectCount(table, column, projectID, 0)
        }
        let sequenceAfter = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: staged.workspace)").first()!.decode(column: "change_sequence", as: Int64.self)
        XCTAssertEqual(sequenceAfter, sequenceBefore)
        try await expectCount("staged_import_original_receipts", "session_id", staged.scope.sessionId, 12)
        let receipt = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(receipt.state, "published"); try await expectCount("projects", "id", projectID, 1)
    }

    func testSecondManagerReadsWhileNonmemberIsDeniedAndQualifiedSnagNeedsReviewerReopen() async throws {
        let (owner, ownerActor) = try await user("owner")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: owner.requireID(), on: db).requireID() }
        let (admin, _) = try await user("admin")
        try await sql.raw("INSERT INTO workspace_memberships(workspace_id,user_id,role,state,revision,created_at,updated_at) VALUES (\(bind: company),\(bind: admin.requireID()),'admin','active',1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)").run()
        let staged = try await stage(actor: (owner, ownerActor), workspace: company)
        try await transfer(staged)
        let projection = try await prepare(staged), command = try await commitCommand(staged, projection)
        let receipt = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: binding, on: app.db), projectID = receipt.projectId
        let adminGraph = try await app.db.transaction { db in
            _ = try await ProjectAccessService.require(.read, projectID: projectID, actorID: admin.requireID(), on: db)
            return try await LegacyImportReadService.graph(projectID: projectID, workspaceID: company, on: db)
        }
        XCTAssertEqual(adminGraph.files.count, 12)
        let (stranger, strangerActor) = try await user("stranger")
        await rejected { _ = try await self.app.db.transaction { db in try await ProjectAccessService.require(.read, projectID: projectID, actorID: stranger.requireID(), on: db) } }
        await rejected { _ = try await LegacyImportCommitService.receipt(commitID: receipt.commitId, scope: staged.scope, actor: strangerActor, binding: self.binding, on: self.app.db) }
        // Workflow on the qualified closed snag: accept/start refused; reviewer reopen reconciles.
        let closedID = try await sql.raw("SELECT id FROM snags WHERE project_id = \(bind: projectID) AND workflow_qualification IS NOT NULL").first()!.decode(column: "id", as: UUID.self)
        let (project, actions) = try await app.db.transaction { db in try await ProjectAccessService.require(.review, projectID: projectID, actorID: admin.requireID(), on: db) }
        var snag = try await Snag.find(closedID, on: app.db)!
        await rejected("workflow_reconciliation_required") {
            _ = try await self.app.db.transaction { db in try await CanonicalWorkflowService.execute(.init(mutation: .init(operationId: UUID(), deviceId: UUID()), expectedRevision: snag.revision, expectedWorkflowRevision: snag.workflowRevision, attemptId: nil, expectedAttemptRevision: nil, notes: nil, reason: nil, evidenceIds: nil, waiverReason: nil), action: .start, snag: snag, project: project, actorID: admin.requireID(), actions: actions, on: db) }
        }
        let result = try await app.db.transaction { db in
            try await CanonicalWorkflowService.execute(.init(mutation: .init(operationId: UUID(), deviceId: UUID()), expectedRevision: snag.revision, expectedWorkflowRevision: snag.workflowRevision, attemptId: nil, expectedAttemptRevision: nil, notes: nil, reason: "Reconciled after import review", evidenceIds: nil, waiverReason: nil), action: .reopen, snag: snag, project: project, actorID: admin.requireID(), actions: actions, on: db)
        }
        XCTAssertEqual(result.snag.snag.status, "open"); XCTAssertNil(result.snag.workflow); XCTAssertEqual(result.decisions.first?.kind, "reopen")
        snag = try await Snag.find(closedID, on: app.db)!
        XCTAssertNil(snag.workflowQualification); XCTAssertEqual(snag.sourceStatus, "closed"); XCTAssertNotNil(snag.sourceClosedAt)
    }

    func testSameSourceSecondProjectReusesDirectoryAndEditedEntryConflicts() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let first = try await LegacyImportCommitService.commit(commitCommand(staged, prepare(staged)), actor: staged.actor, binding: binding, on: app.db)
        XCTAssertEqual(first.reusedDirectoryCount, 0)
        let staged2 = try await secondStaged(staged, suffix: "plot-13")
        try await transfer(staged2)
        let receipt2 = try await LegacyImportCommitService.commit(commitCommand(staged2, prepare(staged2)), actor: staged2.actor, binding: binding, on: app.db)
        XCTAssertEqual(receipt2.reusedDirectoryCount, 5); XCTAssertNotEqual(receipt2.projectId, first.projectId)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor)
        try await expectCount("contractors", "id", source.contractors[0].id, 1); try await expectCount("workspace_folders", "workspace_id", staged.workspace, 2)
        // A later edit to the shared contractor makes a third import from this source conflict.
        try await sql.raw("UPDATE contractors SET notes = 'Edited by another manager', revision = revision + 1 WHERE id = \(bind: source.contractors[0].id)").run()
        let staged3 = try await secondStaged(staged, suffix: "plot-14")
        try await transfer(staged3)
        let projection3 = try await prepare(staged3), command3 = try await commitCommand(staged3, projection3)
        await rejected("import_directory_changed") { _ = try await LegacyImportCommitService.commit(command3, actor: staged3.actor, binding: self.binding, on: self.app.db) }
        try await expectCount("legacy_import_commits", "session_id", staged3.scope.sessionId, 0)
    }
    /// Same archive lineage and actor/workspace, different project-owned IDs.
    private func secondStaged(_ original: Staged, suffix: String) async throws -> Staged {
        let base = try JSONDecoder().decode(LegacyProjectImportSource.self, from: original.descriptor)
        let user = try await User.find(original.actor.id, on: app.db)!
        let keep = Set((base.contractors.map(\.id) + base.trades.map(\.id) + base.folders.map(\.id) + base.tags.map(\.id) + [base.source.archiveID]).map(\.uuidString))
        let originalObject = try JSONSerialization.jsonObject(with: original.descriptor) as! [String: Any]
        return try await stage(actor: (user, original.actor), workspace: original.workspace, lineage: "unused", transform: { root in
            root = Self.remap(originalObject, suffix: suffix, keep: keep)
        })
    }

    func testOccupiedProjectIdentityIsRejectedNotAdopted() async throws {
        let staged = try await stage()
        try await transfer(staged)
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: staged.descriptor)
        let existing = Project(id: source.project.id, name: "Existing unrelated", reference: "X/1", ownerId: staged.actor.id)
        existing.workspaceId = staged.workspace; existing.platformManaged = true
        try await existing.save(on: app.db)
        let projection = try await prepare(staged), command = try await commitCommand(staged, projection)
        await rejected("import_identity_collision") { _ = try await LegacyImportCommitService.commit(command, actor: staged.actor, binding: self.binding, on: self.app.db) }
        try await expectCount("snags", "project_id", source.project.id, 0); try await expectCount("legacy_import_commits", "session_id", staged.scope.sessionId, 0)
        let untouched = try await Project.find(source.project.id, on: app.db)
        XCTAssertEqual(untouched?.name, "Existing unrelated")
    }
}
