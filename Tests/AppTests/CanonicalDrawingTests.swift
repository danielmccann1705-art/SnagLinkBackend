@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class CanonicalDrawingTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Pinned synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func mutation() -> MutationMetadata { .init(operationId: UUID(), deviceId: UUID()) }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("drawing-\(UUID())@example.test", name: "Synthetic drawing manager", on: db) }
    }
    private func project(_ owner: User, company: Bool = false) async throws -> Project {
        try await app.db.transaction { db in
            let workspace: Team
            if company { workspace = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: owner.requireID(), on: db) }
            else { workspace = try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
            let project = Project(id: UUID(), name: "Willow Court · Plot 12", reference: "WC12", ownerId: try owner.requireID())
            project.workspaceId = try workspace.requireID(); project.platformManaged = true
            try await project.save(on: db); return project
        }
    }
    private func join(_ member: User, owner: User, project: Project, role: String = "member") async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId!, email: member.email!, role: "member", projects: [.init(projectId: project.requireID(), role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: member.requireID(), on: db) }
    }
    private func snag(_ owner: User, project: Project) async throws -> Snag {
        let snag = Snag(id: UUID(), reference: "WC12-001", title: "Seal around shower tray", projectId: try project.requireID(), ownerId: try owner.requireID())
        snag.workspaceId = project.workspaceId; try await snag.save(on: app.db); return snag
    }
    private func allocation(id: UUID = UUID(), mutation: MutationMetadata? = nil, mime: String = "application/pdf", filename: String = "Willow Court plans.pdf", bytes: Int = 1024) -> DrawingAllocateCommand {
        .init(mutation: mutation ?? self.mutation(), id: id, purpose: .drawingSource, sha256: String(repeating: "a", count: 64), byteCount: bytes, mimeType: mime, originalFilename: filename)
    }
    private func geometry(rotation: Int = 0, transform: [Double]? = nil, userUnit: Double = 1) -> DrawingPageGeometry {
        let t: [Double]
        // Independent explicit expectations for a nonzero-origin 580x780 crop.
        switch rotation {
        case 90: t = [0,1.0/580,1.0/780,0,-30.0/780,-20.0/580]
        case 180: t = [-1.0/580,0,0,1.0/780,1+20.0/580,-30.0/780]
        case 270: t = [0,-1.0/580,-1.0/780,0,1+30.0/780,1+20.0/580]
        default: t = [1.0/580,0,0,-1.0/780,-20.0/580,1+30.0/780]
        }
        return .init(mediaBox: .init(x: 10,y: 20,width: 600,height: 800), cropBox: .init(x: 20,y: 30,width: 580,height: 780), displayBox: .init(x: 20,y: 30,width: 580,height: 780), rotation: rotation, userUnit: userUnit, width: [90,270].contains(rotation) ? 780 : 580, height: [90,270].contains(rotation) ? 580 : 780, sourceToDisplay: transform ?? t, coordinateSystem: "display_top_left_v1")
    }
    private func manifest(_ source: DrawingAssetRecord, count: Int = 2, geometry: DrawingPageGeometry? = nil, hash: String? = nil) -> DrawingProcessingManifest {
        .init(sourceSHA256: hash ?? source.sha256, sourceBytes: source.byteCount, sourceMIME: source.mimeType, processorProfile: source.processorProfile,
              pages: (0..<count).map { .init(sourcePageIndex: $0, sourcePageLabel: "Sheet \($0 + 1)", geometry: geometry ?? self.geometry(), renditionSHA256: String(repeating: "b",count:64), renditionBytes:1024, thumbnailSHA256:String(repeating:"c",count:64), thumbnailBytes:256) })
    }
    private func ready(_ owner: User, project: Project, count: Int = 2) async throws -> (DrawingAssetRecord, DrawingProcessingLease) {
        let source = try await CanonicalDrawingService.allocate(allocation(), projectID: project.requireID(), actorID: owner.requireID(), on: app.db)
        let lease = try await CanonicalDrawingService.beginProcessing(assetID: source.id, projectID: project.requireID(), actorID: owner.requireID(), on: app.db)
        let result = try await CanonicalDrawingService.finishProcessing(lease, manifest: manifest(source, count: count), on: app.db)
        return (result,lease)
    }
    private func sheet(index: Int = 0, id: UUID = UUID()) -> DrawingSheetCommand {
        .init(id: id, versionId: UUID(), versionPageId: UUID(), name: "Ground floor · Plot 12", sortOrder: index, sourcePageIndex: index)
    }
    private func publication(_ source: DrawingAssetRecord, sheets: [DrawingSheetCommand], mutation: MutationMetadata? = nil, acknowledge: Bool = true) -> DrawingPublishCommand {
        .init(mutation: mutation ?? self.mutation(), assetId: source.id, expectedAssetRevision: source.revision, acknowledgeInternalOriginalAccess: acknowledge, sheets: sheets)
    }
    private func published(_ owner: User, project: Project) async throws -> DrawingSheetCommand {
        let source = try await ready(owner, project: project).0, sheet = sheet()
        _ = try await CanonicalDrawingService.publish(publication(source,sheets:[sheet]),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        return sheet
    }
    private func target(_ sheet: DrawingSheetCommand, x: Double = 0.25, y: Double = 0.75) -> DrawingPinTarget {
        .init(drawingId: sheet.id, versionId: sheet.versionId, versionPageId: sheet.versionPageId, x: x, y: y)
    }
    private func count(_ table: String, project: Project) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE project_id = \(bind: project.requireID())").first()!.decode(column:"n",as:Int.self)
    }
    private func fails(_ status: HTTPResponseStatus? = nil, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection",file:file,line:line) }
        catch { if let status { XCTAssertEqual((error as? Abort)?.status,status,"Unexpected error kind",file:file,line:line) } }
    }

    func testAllocationRetryKeepsOriginalReceiptAndRejectsInvalidOrCollidingSource() async throws {
        let owner = try await user(), project = try await project(owner), command = allocation()
        let first = try await CanonicalDrawingService.allocate(command,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        _ = try await CanonicalDrawingService.beginProcessing(assetID:first.id,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        let repeated = try await CanonicalDrawingService.allocate(command,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertEqual(repeated.id,first.id); XCTAssertEqual(repeated.revision,1)
        await fails(.conflict) { _ = try await CanonicalDrawingService.allocate(self.allocation(id:command.id,mutation:command.mutation,filename:"Changed.pdf"),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        let other = try await self.project(owner)
        await fails(.conflict) { _ = try await CanonicalDrawingService.allocate(self.allocation(id:command.id),projectID:other.requireID(),actorID:owner.requireID(),on:self.app.db) }
        for bad in [allocation(filename:"../secret.pdf"),allocation(filename:"a\nb.pdf"),allocation(mime:"text/html"),allocation(mime:"image/png",bytes:10485761),allocation(bytes:52428801)] {
            await fails(.badRequest) { _ = try await CanonicalDrawingService.allocate(bad,projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        }
        let total = try await count("drawing_assets",project:project); XCTAssertEqual(total,1)
    }
    func testProcessingManifestValidationAndCompletedRetryPreservePageIdentity() async throws {
        let owner = try await user(), project = try await project(owner)
        let source = try await CanonicalDrawingService.allocate(allocation(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        let lease = try await CanonicalDrawingService.beginProcessing(assetID:source.id,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        await fails(.badRequest) { _ = try await CanonicalDrawingService.finishProcessing(lease,manifest:self.manifest(source,hash:String(repeating:"d",count:64)),on:self.app.db) }
        await fails(.badRequest) { _ = try await CanonicalDrawingService.finishProcessing(lease,manifest:self.manifest(source,geometry:self.geometry(transform:[0,0,0,0,0,0])),on:self.app.db) }
        let none = try await count("drawing_asset_pages",project:project); XCTAssertEqual(none,0)
        let processed = try await CanonicalDrawingService.finishProcessing(lease,manifest:manifest(source),on:app.db)
        let repeated = try await CanonicalDrawingService.finishProcessing(lease,manifest:manifest(source),on:app.db)
        XCTAssertEqual(processed.revision,3); XCTAssertEqual(repeated.revision,3)
        let pages = try await count("drawing_asset_pages",project:project); XCTAssertEqual(pages,2)
        let id = CanonicalDrawingService.pageID(assetID:source.id,index:1)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT geometry_json FROM drawing_asset_pages WHERE id = \(bind: id)").first()!
        let saved = try PlatformMutationService.decode(DrawingPageGeometry.self,row.decode(column:"geometry_json",as:String.self))
        XCTAssertEqual(saved,geometry()); XCTAssertEqual(id,CanonicalDrawingService.pageID(assetID:source.id,index:1))
        await fails(.conflict) { _ = try await CanonicalDrawingService.finishProcessing(lease,manifest:self.manifest(source,geometry:self.geometry(rotation:90)),on:self.app.db) }
    }
    func testOnlyCurrentProcessingLeaseCanCommitAndRevokedUploaderCannotFinish() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner,company:true)
        try await join(member,owner:owner,project:project)
        let source = try await CanonicalDrawingService.allocate(allocation(),projectID:project.requireID(),actorID:member.requireID(),on:app.db)
        let first = try await CanonicalDrawingService.beginProcessing(assetID:source.id,projectID:project.requireID(),actorID:member.requireID(),on:app.db)
        await fails(.conflict) { _ = try await CanonicalDrawingService.beginProcessing(assetID:source.id,projectID:project.requireID(),actorID:member.requireID(),on:self.app.db) }
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE drawing_processing_jobs SET lease_expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE asset_id = \(bind: source.id)").run()
        let second = try await CanonicalDrawingService.beginProcessing(assetID:source.id,projectID:project.requireID(),actorID:member.requireID(),on:app.db)
        XCTAssertNotEqual(first.token,second.token)
        await fails(.conflict) { _ = try await CanonicalDrawingService.finishProcessing(first,manifest:self.manifest(source),on:self.app.db) }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID:project.workspaceId!,targetID:member.requireID(),newRole:nil,expectedRevision:1,actorID:owner.requireID(),on:db) }
        await fails(.notFound) { _ = try await CanonicalDrawingService.finishProcessing(second,manifest:self.manifest(source),on:self.app.db) }
        let pages = try await count("drawing_asset_pages",project:project); XCTAssertEqual(pages,0)
    }
    func testPublicationIsAtomicStableAndPreservesSelectedPageNumbers() async throws {
        let owner = try await user(), project = try await project(owner), source = try await ready(owner,project:project).0
        let first = sheet(index:1), second = sheet(index:0), command = publication(source,sheets:[first,second])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask {
                let result = try await CanonicalDrawingService.publish(command,projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db)
                XCTAssertEqual(result.sheets,[first,second])
            } }
            try await group.waitForAll()
        }
        let total = try await count("drawings",project:project); XCTAssertEqual(total,2)
        let page = try await VerifiedIdentityService.sql(app.db).raw("SELECT asset_page_id FROM drawing_version_pages WHERE id = \(bind: first.versionPageId)").first()!.decode(column:"asset_page_id",as:UUID.self)
        XCTAssertEqual(page,CanonicalDrawingService.pageID(assetID:source.id,index:1))
        await fails(.conflict) { _ = try await CanonicalDrawingService.publish(self.publication(source,sheets:[first],mutation:command.mutation),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
    }
    func testPublicationFailureRollsBackWholeBatchAndReceipt() async throws {
        let owner = try await user(), project = try await project(owner), source = try await ready(owner,project:project).0
        let first = sheet(), missing = sheet(index:8), command = publication(source,sheets:[first,missing])
        await fails(.badRequest) { _ = try await CanonicalDrawingService.publish(command,projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        let total = try await count("drawings",project:project); XCTAssertEqual(total,0)
        let sourceAfter = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertNil(sourceAfter.publishedAt); XCTAssertEqual(sourceAfter.revision,source.revision)
        let receipt = try await VerifiedIdentityService.sql(app.db).raw("SELECT 1 FROM mutation_receipts WHERE actor_id = \(bind: owner.requireID()) AND operation_id = \(bind: command.mutation.operationId)").first()
        XCTAssertNil(receipt)
        await fails(.badRequest) { _ = try await CanonicalDrawingService.publish(self.publication(source,sheets:[first],acknowledge:false),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        _ = try await CanonicalDrawingService.publish(publication(source,sheets:[first]),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        let refreshed = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        await fails(.conflict) { _ = try await CanonicalDrawingService.publish(self.publication(refreshed,sheets:[self.sheet(id:first.id)]),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
    }
    func testPublicationAndPinEmitCompleteAtomicCanonicalDeltaGroups() async throws {
        let owner = try await user(), project = try await project(owner)
        let source = try await ready(owner,project:project).0
        let first = sheet(index:0), second = sheet(index:1)
        _ = try await CanonicalDrawingService.publish(publication(source,sheets:[first,second]),
            projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        let published = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT * FROM platform_changes WHERE project_id = \(bind: project.requireID())
            ORDER BY sequence
            """).all()
        XCTAssertEqual(published.count,2)
        XCTAssertEqual(try published.map { try $0.decode(column:"entity_type",as:String.self) },["drawing","drawing"])
        XCTAssertEqual(Set(try published.map { try $0.decode(column:"transaction_group",as:UUID.self) }).count,1)
        let decoded = try PlatformMutationService.decode(DrawingSheetResponse.self,
            published[0].decode(column:"payload_json",as:String.self))
        XCTAssertEqual(decoded.id,first.id); XCTAssertEqual(decoded.pages.first?.id,first.versionPageId)

        let snag = try await snag(owner,project:project)
        _ = try await CanonicalDrawingService.setPin(.init(mutation:mutation(),expectedSnagRevision:1,
            expectedPinRevision:0,pin:target(first)),snagID:snag.requireID(),projectID:project.requireID(),
            actorID:owner.requireID(),on:app.db)
        let pinGroup = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT * FROM platform_changes WHERE project_id = \(bind: project.requireID())
              AND sequence > \(bind: try published.last!.decode(column:"sequence",as:Int64.self))
            ORDER BY sequence
            """).all()
        XCTAssertEqual(pinGroup.count,2)
        XCTAssertEqual(try pinGroup.map { try $0.decode(column:"entity_type",as:String.self) },["snag","drawingPin"])
        XCTAssertEqual(Set(try pinGroup.map { try $0.decode(column:"transaction_group",as:UUID.self) }).count,1)
        let pin = try PlatformMutationService.decode(DrawingPinResponse.self,
            pinGroup[1].decode(column:"payload_json",as:String.self))
        XCTAssertEqual(pin.snagId,snag.id); XCTAssertEqual(pin.drawingId,first.id); XCTAssertEqual(pin.snagRevision,2)
    }
    func testPendingSourcesAreUploaderOnlyAndReceiptsRecheckCurrentAccess() async throws {
        let owner = try await user(), member = try await user(), stranger = try await user(), project = try await project(owner,company:true)
        try await join(member,owner:owner,project:project)
        let source = try await ready(member,project:project).0
        await fails(.notFound) { _ = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        let command = publication(source,sheets:[sheet()])
        _ = try await CanonicalDrawingService.publish(command,projectID:project.requireID(),actorID:member.requireID(),on:app.db)
        let visible = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:owner.requireID(),on:app.db); XCTAssertNotNil(visible.publishedAt)
        await fails(.notFound) { _ = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:stranger.requireID(),on:self.app.db) }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID:project.workspaceId!,targetID:member.requireID(),newRole:nil,expectedRevision:1,actorID:owner.requireID(),on:db) }
        await fails(.notFound) { _ = try await CanonicalDrawingService.publish(command,projectID:project.requireID(),actorID:member.requireID(),on:self.app.db) }
        project.archivedAt = Date(); try await project.save(on:app.db)
        await fails(.gone) { _ = try await CanonicalDrawingService.readAsset(source.id,projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
    }
    func testPinMoveRemoveAndReplayPreserveImmutableActualRevisionHistory() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        let initial = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet))
        let first = try await CanonicalDrawingService.setPin(initial,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertEqual(first.snagRevision,2); XCTAssertEqual(first.recordedBy,owner.id)
        let updated = try await Snag.find(snag.requireID(),on:app.db)!
        updated.title = "Shower tray reseal required"; updated.revision += 3; try await updated.save(on:app.db)
        let move = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:5,expectedPinRevision:1,pin:target(sheet,x:0.9,y:0.1))
        let moved = try await CanonicalDrawingService.setPin(move,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertEqual(moved.snagRevision,6); XCTAssertEqual(moved.revision,2)
        let remove = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:6,expectedPinRevision:2,pin:nil)
        let removed = try await CanonicalDrawingService.setPin(remove,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        let old = try await CanonicalDrawingService.setPin(initial,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertEqual(old.eventId,first.eventId); XCTAssertEqual(removed.revision,3)
        let current = try await Snag.find(snag.requireID(),on:app.db)!; XCTAssertNil(current.drawingId); XCTAssertEqual(current.revision,7)
        let events = try await VerifiedIdentityService.sql(app.db).raw("SELECT * FROM drawing_pin_events WHERE snag_id = \(bind: snag.requireID()) ORDER BY pin_revision").all()
        XCTAssertEqual(events.count,3); XCTAssertEqual(try events[1].decode(column:"snag_revision",as:Int64.self),6)
        XCTAssertEqual(try events[2].decode(column:"previous_page_id",as:UUID.self),sheet.versionPageId)
        let restore = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:7,expectedPinRevision:3,pin:target(sheet))
        let restored = try await CanonicalDrawingService.setPin(restore,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        XCTAssertEqual(restored.revision,4)
    }
    func testPinRejectsStaleForeignMalformedAndProtectedWorkflowWithoutSideEffects() async throws {
        let owner = try await user(), project = try await project(owner), other = try await self.project(owner)
        let sheet = try await published(owner,project:project), foreign = try await published(owner,project:other), snag = try await snag(owner,project:project)
        for (pin,status) in [(target(sheet,x:1.1),HTTPResponseStatus.badRequest),(target(foreign),.notFound)] {
            await fails(status) { _ = try await CanonicalDrawingService.setPin(.init(mutation:self.mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:pin),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        }
        await fails(.conflict) { _ = try await CanonicalDrawingService.setPin(.init(mutation:self.mutation(),expectedSnagRevision:1,expectedPinRevision:7,pin:self.target(sheet)),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        for status in ["awaiting_review","closed"] {
            snag.status = status; try await snag.save(on:app.db)
            await fails(.conflict) { _ = try await CanonicalDrawingService.setPin(.init(mutation:self.mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:self.target(sheet)),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        }
        let total = try await count("drawing_pin_events",project:project); XCTAssertEqual(total,0)
        let unchanged = try await Snag.find(snag.requireID(),on:app.db)!; XCTAssertEqual(unchanged.revision,1)
    }
    func testUnimportedLegacyPinCannotBeSilentlyOverwritten() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        snag.drawingId = UUID(); snag.drawingPinX = 0.1; snag.drawingPinY = 0.2; try await snag.save(on:app.db)
        await fails(.conflict) { _ = try await CanonicalDrawingService.setPin(.init(mutation:self.mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:self.target(sheet)),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        let row = try await Snag.find(snag.requireID(),on:app.db)!; XCTAssertEqual(row.drawingId,snag.drawingId)
    }
    func testCompositeConstraintsRejectSameProjectCrossAssetAndForeignProjectPages() async throws {
        let owner = try await user(), project = try await project(owner), other = try await self.project(owner)
        let source = try await ready(owner,project:project).0, otherSource = try await ready(owner,project:project).0, foreign = try await ready(owner,project:other).0
        let sheet = self.sheet()
        _ = try await CanonicalDrawingService.publish(publication(source,sheets:[sheet]),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        // New unreferenced version-page index is forbidden too; use a fresh drawing/version
        // to isolate the asset composite-FK boundary from the existing one-page unique key.
        for badSource in [otherSource,foreign] {
            await fails {
                try await self.app.db.transaction { db in
                    let id = UUID(), version = UUID(), sql = try VerifiedIdentityService.sql(db)
                    try await sql.raw("INSERT INTO drawings(id,workspace_id,project_id,name,sort_order,revision,current_version_id,created_by,created_at,updated_at) VALUES(\(bind:id),\(bind:project.workspaceId!),\(bind:project.requireID()),'Uncommitted',0,1,\(bind:version),\(bind:owner.requireID()),now(),now())").run()
                    try await sql.raw("INSERT INTO drawing_versions(id,drawing_id,project_id,asset_id,version_number,published_by,published_at) VALUES(\(bind:version),\(bind:id),\(bind:project.requireID()),\(bind:source.id),1,\(bind:owner.requireID()),now())").run()
                    try await sql.raw("INSERT INTO drawing_version_pages(id,version_id,drawing_id,asset_id,asset_page_id,project_id,page_index) VALUES(\(bind:UUID()),\(bind:version),\(bind:id),\(bind:source.id),\(bind:CanonicalDrawingService.pageID(assetID:badSource.id,index:0)),\(bind:project.requireID()),0)").run()
                }
            }
        }
        let total = try await count("drawings",project:project); XCTAssertEqual(total,1)
    }
    func testSQLCannotRewriteSourceVersionPageOrPinHistory() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        _ = try await CanonicalDrawingService.setPin(.init(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet)),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        await fails { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE drawing_assets SET original_sha256 = \(bind:String(repeating:"d",count:64)) WHERE project_id = \(bind:project.requireID())").run() }
        await fails { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE drawing_versions SET published_by = \(bind:owner.requireID()) WHERE id = \(bind:sheet.versionId)").run() }
        await fails { try await VerifiedIdentityService.sql(self.app.db).raw("DELETE FROM drawing_version_pages WHERE id = \(bind:sheet.versionPageId)").run() }
        await fails { try await VerifiedIdentityService.sql(self.app.db).raw("UPDATE drawing_pin_events SET next_x = 0.9 WHERE snag_id = \(bind:snag.requireID())").run() }
        let total = try await count("drawing_pin_events",project:project); XCTAssertEqual(total,1)
    }
    func testRepeatedMigrationPreservesPriorSourceAndRefusesDestructiveRevert() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project)
        try await CreateCanonicalDrawings().prepare(on:app.db)
        try await CreateCanonicalDrawings().prepare(on:app.db)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT current_version_id FROM drawings WHERE id = \(bind:sheet.id)").first()!.decode(column:"current_version_id",as:UUID.self)
        XCTAssertEqual(row,sheet.versionId)
        await fails(.conflict) { try await CreateCanonicalDrawings().revert(on:self.app.db) }
        let total = try await count("drawings",project:project); XCTAssertEqual(total,1)
    }

    func testViewerCannotAllocateAndRemovedMemberCannotReplayPin() async throws {
        let owner = try await user(), member = try await user(), project = try await project(owner,company:true)
        try await join(member,owner:owner,project:project)
        let sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        let command = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet))
        _ = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:member.requireID(),on:app.db)
        // Viewer is a central server role but not currently provisioned by public invitations.
        // Isolate the central ACL boundary with a synthetic grant, not a claim about admin UI.
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(project.workspaceId!,on:db)
            try await VerifiedIdentityService.sql(db).raw("UPDATE project_access SET role = 'viewer', revision = revision + 1 WHERE project_id = \(bind:project.requireID()) AND user_id = \(bind:member.requireID())").run()
        }
        await fails(.forbidden) { _ = try await CanonicalDrawingService.allocate(self.allocation(),projectID:project.requireID(),actorID:member.requireID(),on:self.app.db) }
        await fails(.forbidden) { _ = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:member.requireID(),on:self.app.db) }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID:project.workspaceId!,targetID:member.requireID(),newRole:nil,expectedRevision:1,actorID:owner.requireID(),on:db) }
        await fails(.notFound) { _ = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:member.requireID(),on:self.app.db) }
        let total = try await count("drawing_pin_events",project:project); XCTAssertEqual(total,1)
    }
    func testCompetingPinWritesCommitOneRevisionAndRejectStalePeer() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        let first = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet))
        let second = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet,x:0.8,y:0.3))
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for command in [first,second] { group.addTask {
                do { _ = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db); return true }
                catch is RevisionConflict { return false }
            } }
            var results: [Bool] = []; for try await value in group { results.append(value) }; return results
        }
        XCTAssertEqual(results.filter { $0 }.count,1)
        let total = try await count("drawing_pin_events",project:project); XCTAssertEqual(total,1)
        let row = try await Snag.find(snag.requireID(),on:app.db)!; XCTAssertEqual(row.revision,2)
    }
    func testFreshDrawingSchemaCreatesAllConstraintsWithoutChangingExistingGraph() async throws {
        enum Rollback: Error { case fixture }
        // New test-only schema and minimal parent keys exercise fresh drawing DDL.
        // The outer rollback removes only this fixture; it does not reset retained DB data.
        let namespace = "dra_fixture_" + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        do {
            try await app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("CREATE SCHEMA \(unsafeRaw:namespace)").run()
                try await sql.raw("SET LOCAL search_path TO \(unsafeRaw:namespace), public").run()
                try await sql.raw("CREATE TABLE users(id UUID PRIMARY KEY)").run()
                try await sql.raw("CREATE TABLE projects(id UUID PRIMARY KEY, workspace_id UUID NOT NULL, UNIQUE(id,workspace_id))").run()
                try await sql.raw("CREATE TABLE snags(id UUID PRIMARY KEY, project_id UUID NOT NULL, UNIQUE(id,project_id))").run()
                try await CreateCanonicalDrawings().prepare(on:db)
                try await CreateCanonicalDrawings().prepare(on:db)
                let tables = try await sql.raw("SELECT count(*) AS n FROM information_schema.tables WHERE table_schema = \(bind:namespace)").first()!.decode(column:"n",as:Int.self)
                XCTAssertEqual(tables,11)
                let triggers = try await sql.raw("SELECT count(*) AS n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = \(bind:namespace) AND NOT t.tgisinternal").first()!.decode(column:"n",as:Int.self)
                XCTAssertEqual(triggers,5)
                throw Rollback.fixture
            }
        } catch Rollback.fixture { }
        let retained = try await VerifiedIdentityService.sql(app.db).raw("SELECT 1 FROM pg_namespace WHERE nspname = \(bind:namespace)").first()
        XCTAssertNil(retained)
    }

    func testPinReceiptRemainsRecoverableAfterReviewAndArchiveWithoutChangingState() async throws {
        let owner = try await user(), project = try await project(owner), sheet = try await published(owner,project:project), snag = try await snag(owner,project:project)
        let command = DrawingPinCommand(mutation:mutation(),expectedSnagRevision:1,expectedPinRevision:0,pin:target(sheet))
        let first = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
        for status in ["awaiting_review","closed","archived"] {
            let current = try await Snag.find(snag.requireID(),on:app.db)!
            current.status = status == "archived" ? "closed" : status
            if status == "archived" { current.archivedAt = Date() }
            current.revision += 1; current.workflowRevision += 1
            try await current.save(on:app.db)
            let replay = try await CanonicalDrawingService.setPin(command,snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:app.db)
            XCTAssertEqual(try PlatformMutationService.encode(replay),try PlatformMutationService.encode(first))
            let after = try await Snag.find(snag.requireID(),on:app.db)!
            XCTAssertEqual(after.revision,current.revision); XCTAssertEqual(after.status,current.status)
            XCTAssertEqual(after.workflowRevision,current.workflowRevision); XCTAssertEqual(after.archivedAt,current.archivedAt)
            await fails(.conflict) { _ = try await CanonicalDrawingService.setPin(.init(mutation:self.mutation(),expectedSnagRevision:current.revision,expectedPinRevision:1,pin:nil),snagID:snag.requireID(),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        }
        let events = try await count("drawing_pin_events",project:project); XCTAssertEqual(events,1)
    }
    func testPublicationRejectsUnrepresentableOrderBeforeWriting() async throws {
        let owner = try await user(), project = try await project(owner), source = try await ready(owner,project:project).0
        let sheet = DrawingSheetCommand(id:UUID(),versionId:UUID(),versionPageId:UUID(),name:"Ground floor",sortOrder:Int.max,sourcePageIndex:0)
        await fails(.badRequest) { _ = try await CanonicalDrawingService.publish(self.publication(source,sheets:[sheet]),projectID:project.requireID(),actorID:owner.requireID(),on:self.app.db) }
        let count = try await count("drawings",project:project); XCTAssertEqual(count,0)
    }
}
