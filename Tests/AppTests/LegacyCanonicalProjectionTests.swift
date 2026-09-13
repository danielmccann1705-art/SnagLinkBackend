@testable import App
import XCTVapor
import Fluent
import FluentSQL

private enum ProjectionFixture {
    static let namespace = UUID(uuidString:"5170f759-3ff8-4f0d-8a43-f6ea82921414")!
    static func id(_ label:String) -> UUID { LegacyCanonicalProjectionMapper.stableID(namespace,label) }
    static func data(_ change:((inout [String:Any])->Void)? = nil) throws -> Data {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json")
        let data = try Data(contentsOf:url)
        guard let change else { return data }
        var object = try JSONSerialization.jsonObject(with:data) as! [String:Any]; change(&object)
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }
    static func graph(_ data:Data) throws -> LegacyProjectImportGraph {
        let s = try JSONDecoder().decode(LegacyProjectImportSource.self,from:data)
        let decoded = try LegacyProjectImportDecoder.decode(data,expected:.init(exportSHA256:LegacyProjectImportDecoder.digest(data),exportByteCount:data.count,selectedProjectID:s.project.id,sourceFingerprint:s.source.sourceFingerprint))
        return try LegacyProjectImportGraphValidator.validate(decoded,capacity:.init(existingWorkspaceDirectoryRows:0))
    }
    static func receipt(_ graph:LegacyProjectImportGraph) -> StagedLegacyImportReceipt {
        let s = graph.decoded.source,date = Date(timeIntervalSince1970:1_800_000_000)
        return .init(formatVersion:1,sessionId:id("session"),createOperationId:id("source-op"),deviceId:id("device"),actorId:id("actor"),workspaceId:id("workspace"),workspaceKind:"personal",destination:.init(environment:"development",apiOrigin:"http://127.0.0.1:55480"),selectedProjectId:s.project.id,sourceFingerprint:s.source.sourceFingerprint,exportSHA256:graph.decoded.sha256,exportByteCount:graph.decoded.bytes.count,requestHash:String(repeating:"a",count:64),state:"staged_incomplete",revision:1,recordCounts:Dictionary(uniqueKeysWithValues:graph.sourceRecordIDs.map { ($0.key.rawValue,$0.value.count) }),edgeCount:graph.edges.count,fileRoleCounts:Dictionary(uniqueKeysWithValues:graph.fileRoleCounts.map { ($0.key.rawValue,$0.value) }),declaredFileCount:graph.declaredFiles.count,declaredFileBytes:graph.totalDeclaredFileBytes,sourceIssueCounts:Dictionary(grouping:graph.issues,by:\.code).mapValues(\.count),journalEventUpperBound:graph.publicationBudget.journalEventUpperBound,snapshotRowUpperBound:graph.publicationBudget.snapshotRowUpperBound,acknowledgementVersion:StagedLegacyImportCommand.Acknowledgement.supportedVersion,acknowledgedAt:date,createdAt:date,updatedAt:date,importExecutable:false,mediaVerification:graph.mediaVerification,historicalAcceptance:graph.historicalAcceptance)
    }
    static func values(_ graph:LegacyProjectImportGraph) throws -> ([LegacyCanonicalProjection.SourceRecord],[LegacyCanonicalProjectionMapper.Declaration],[LegacyCanonicalProjectionMapper.Use]) {
        let digests = try LegacyCanonicalProjectionMapper.sourceDigests(graph.decoded.source)
        let records = graph.sourceRecordIDs.flatMap { kind,ids in ids.map { value in
            LegacyCanonicalProjection.SourceRecord(kind:kind,sourceId:value,mappingId:id("mapping/\(kind)/\(value)"),sourceSHA256:digests[LegacyCanonicalProjectionMapper.recordKey(kind,value)]!)
        } }
        let declarations = graph.declaredFiles.map { LegacyCanonicalProjectionMapper.Declaration(archivePath:$0.archivePath,id:id($0.archivePath),sha256:$0.sha256,bytes:$0.bytes) }
        let uses = graph.fileUses.map { f -> LegacyCanonicalProjectionMapper.Use in
            let key = LegacyCanonicalProjectionMapper.useKey(f.kind,f.recordID,f.role,f.position);return .init(key:key,id:id(key))
        }
        return (records,declarations,uses)
    }
    static func projection(_ data:Data) throws -> LegacyCanonicalProjection {
        let g = try graph(data),(records,declarations,uses) = try values(g)
        return try LegacyCanonicalProjectionMapper.map(graph:g,receipt:receipt(g),projectionID:id("projection"),records:records,declarations:declarations,uses:uses)
    }
    static func secondProject(_ data:Data, suffix:String) throws -> Data {
        let graph = try graph(data)
        let mappings = Dictionary(uniqueKeysWithValues:graph.sourceRecordIDs.filter { ![.contractors,.trades,.folders,.tags].contains($0.key) }.flatMap { kind,ids in ids.map { ($0.uuidString,id("\(suffix)/\(kind)/\($0)").uuidString) } })
        func replace(_ input:Any) -> Any {
            if let value = input as? String, let uuid = UUID(uuidString:value),let new = mappings[uuid.uuidString] { return new }
            if let values = input as? [String:Any] { return values.mapValues(replace) }
            if let values = input as? [Any] { return values.map(replace) }
            return input
        }
        return try JSONSerialization.data(withJSONObject:replace(JSONSerialization.jsonObject(with:data)),options:[.sortedKeys])
    }
}

final class LegacyCanonicalProjectionMapperTests:XCTestCase {
    func testRichGraphPreservesEveryRecordRoleEdgeAndPreciseSourceValue() throws {
        let bytes = try ProjectionFixture.data(),g = try ProjectionFixture.graph(bytes),p = try ProjectionFixture.projection(bytes)
        XCTAssertEqual(p.sourceRecords.count,16);XCTAssertEqual(p.edges.count,40);XCTAssertEqual(p.files.count,12);XCTAssertEqual(p.fileUses.count,14)
        XCTAssertEqual(Set(p.fileUses.map(\.role)),Set(LegacyImportFileRole.allCases))
        XCTAssertEqual(p.project.reference,"WC/P12/26");XCTAssertEqual(p.snags[0].reference,"P12-A/07")
        XCTAssertEqual(p.snags[0].actualCostDecimal,"80.125");XCTAssertEqual(p.source.capturedAt.timeIntervalSinceReferenceDate,810561600.125)
        XCTAssertEqual(p.photos.map(\.id),g.decoded.source.photos.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(p.photos[1].sourceLegacyLabelJSON,"{\"type\":\"during\"}")
        XCTAssertEqual(p.drawings[0].sourcePageNumber,2);XCTAssertEqual(p.pins.count,2)
        XCTAssertEqual(p.drawings[0].assetPageId,CanonicalDrawingService.pageID(assetID:p.drawings[0].assetId,index:0))
        XCTAssertEqual(p.folders.count,2);XCTAssertEqual(p.tags.count,1);XCTAssertEqual(p.comments.count,2);XCTAssertEqual(p.statusHistory.count,1)
        XCTAssertTrue(p.deletions[0].historicalNeedsRemoteDeletion);XCTAssertEqual(p.deletions[0].execution,"never_enqueue_from_this_descriptor")
        XCTAssertFalse(p.importExecutable);XCTAssertEqual(p.publicationAcknowledgement,"not_requested_not_granted")
        XCTAssertEqual(p.journalEventUpperBound,135)
        XCTAssertTrue(p.findings.filter { $0.disposition == .blocker }.isEmpty)
        let raw = String(decoding:try LegacyCanonicalProjectionMapper.encode(p),as:UTF8.self)
        for file in g.declaredFiles { XCTAssertFalse(raw.contains(file.archivePath),"Private file handle must not enter typed projection") }
        XCTAssertEqual(try LegacyCanonicalProjectionMapper.digest(p),try LegacyCanonicalProjectionMapper.digest(ProjectionFixture.projection(bytes)))
        let decoded = try JSONDecoder().decode(LegacyCanonicalProjection.self,from:LegacyCanonicalProjectionMapper.encode(p))
        XCTAssertEqual(try LegacyCanonicalProjectionMapper.digest(decoded),try LegacyCanonicalProjectionMapper.digest(p))
    }
    func testHistoricalClosureAndSubmissionsNeverManufactureAcceptanceOrPendingAttempt() throws {
        for raw in ["closed","completed","approved","submitted","awaitingApproval","readyForInspection","rejected","sentBack","unknown-state"] {
            let bytes = try ProjectionFixture.data { root in var snags = root["snags"] as! [[String:Any]];snags[0]["localStatus"] = raw;root["snags"] = snags }
            let p = try ProjectionFixture.projection(bytes),state = p.snags[0].workflow
            XCTAssertEqual(state.sourceStatus,raw);XCTAssertFalse(state.actionableReview);XCTAssertFalse(state.verifiedAcceptance)
            XCTAssertEqual(state.qualification,"legacy_unverified");XCTAssertTrue(state.requiresReconciliation)
            if raw == "unknown-state" { XCTAssertNil(state.displayStatus) }
        }
    }
    func testEmptyProjectIsCompleteEmptyGraphNotInventedMedia() throws {
        let data = try ProjectionFixture.data { root in
            for key in ["snags","photos","drawings","contractors","trades","folders","tags","comments","statusHistory","deletionReceipts","findings","findingCounts"] { root[key] = [Any]() }
            root["omittedFindingCount"] = 0
            var p = root["project"] as! [String:Any];p["sourceSnagIDs"] = [Any]();p["sourceDrawingIDs"] = [Any]();p["tagIDs"] = [Any]();p.removeValue(forKey:"folderID")
            p["cover"] = ["availability":"notRecorded","usedLegacyDrawingLocation":false];root["project"] = p
        }
        let p = try ProjectionFixture.projection(data)
        XCTAssertEqual(p.sourceRecords.count,1);XCTAssertTrue(p.snags.isEmpty);XCTAssertTrue(p.files.isEmpty);XCTAssertEqual(p.fileUses.count,1)
        XCTAssertNil(p.fileUses[0].fileObjectId);XCTAssertTrue(p.findings.isEmpty);XCTAssertFalse(p.importExecutable)
    }
    func testDirectoryDigestExcludesOnlySelectedEdgesAndDetectsRealEdits() throws {
        let first = try ProjectionFixture.data(),second = try ProjectionFixture.secondProject(first,suffix:"plot-13")
        let a = try ProjectionFixture.projection(first),b = try ProjectionFixture.projection(second)
        XCTAssertNotEqual(a.project.id,b.project.id);XCTAssertNotEqual(a.contractors[0].selectedSnagIDs,b.contractors[0].selectedSnagIDs)
        XCTAssertEqual(a.directoryIdentities.map(\.intrinsicSHA256),b.directoryIdentities.map(\.intrinsicSHA256))
        let changed = try ProjectionFixture.data { root in var contractors = root["contractors"] as! [[String:Any]];contractors[0]["notes"] = "A material change";root["contractors"] = contractors }
        let c = try ProjectionFixture.projection(changed)
        XCTAssertNotEqual(a.directoryIdentities.first { $0.kind == .contractors }?.intrinsicSHA256,c.directoryIdentities.first { $0.kind == .contractors }?.intrinsicSHA256)
    }
    func testMissingGraphAndUnsafeOperationalValuesAreBlockersNotDroppedFields() throws {
        let data = try ProjectionFixture.data { root in
            var snags = root["snags"] as! [[String:Any]];snags[0]["title"] = " Needs repair ";snags[0]["costEstimate"] = -1;snags[0]["drawingPinX"] = 2;root["snags"] = snags
            var project = root["project"] as! [String:Any];project["name"] = String(repeating:"x",count:201);root["project"] = project
        }
        let p = try ProjectionFixture.projection(data)
        XCTAssertEqual(p.snags[0].values.title," Needs repair ");XCTAssertEqual(p.snags[0].values.costEstimate,-1)
        XCTAssertNil(p.snags[0].costEstimateDecimal);XCTAssertEqual(p.pins.first { $0.snagId == p.snags[0].values.id }?.x,2)
        XCTAssertTrue(p.findings.contains { $0.code == "invalid_pin" && $0.disposition == .blocker })
        XCTAssertTrue(p.findings.contains { $0.field == "costEstimate" && $0.disposition == .blocker })
    }
    func testMissingInventoryBaselineIsARecordedQualificationWhileMissingFilesStillBlock() throws {
        // Real device copies from the first staging build carry no inventory.json baseline.
        let unbaselined = try ProjectionFixture.data { root in
            var source = root["source"] as! [String:Any];source["inventoryComparison"] = "not_recorded_in_legacy_copy";root["source"] = source
            root["findings"] = [["code":"inventory_baseline_unavailable","field":"inventory"]];root["findingCounts"] = [["category":"inventory_baseline_unavailable","count":1]]
        }
        let p = try ProjectionFixture.projection(unbaselined)
        XCTAssertTrue(p.findings.contains { $0.code == "source_inventory_unavailable" && $0.disposition == .qualification })
        XCTAssertTrue(p.findings.contains { $0.code == "source_findings_require_review" && $0.disposition == .qualification })
        XCTAssertTrue(p.findings.filter { $0.disposition == .blocker }.isEmpty)
        let missing = try ProjectionFixture.data { root in
            var source = root["source"] as! [String:Any];source["inventoryComparison"] = "not_recorded_in_legacy_copy";root["source"] = source
            root["findings"] = [["code":"inventory_baseline_unavailable","field":"inventory"],["code":"archive_recorded_missing_files","field":"source_manifest"]]
            root["findingCounts"] = [["category":"inventory_baseline_unavailable","count":1],["category":"archive_recorded_missing_files","count":1]]
        }
        let blocked = try ProjectionFixture.projection(missing)
        XCTAssertTrue(blocked.findings.contains { $0.code == "source_findings_require_review" && $0.disposition == .blocker })
    }
    func testSourceDigestsAndFileDeclarationsCannotBeSwapped() throws {
        let g = try ProjectionFixture.graph(ProjectionFixture.data()),(records,declarations,uses) = try ProjectionFixture.values(g)
        let wrong = records.enumerated().map { index,r in LegacyCanonicalProjection.SourceRecord(kind:r.kind,sourceId:r.sourceId,mappingId:r.mappingId,sourceSHA256:index == 0 ? String(repeating:"0",count:64) : r.sourceSHA256) }
        XCTAssertThrowsError(try LegacyCanonicalProjectionMapper.map(graph:g,receipt:ProjectionFixture.receipt(g),projectionID:ProjectionFixture.id("projection"),records:wrong,declarations:declarations,uses:uses))
        XCTAssertThrowsError(try LegacyCanonicalProjectionMapper.map(graph:g,receipt:ProjectionFixture.receipt(g),projectionID:ProjectionFixture.id("projection"),records:records,declarations:Array(declarations.dropLast()),uses:uses))
    }
}

final class LegacyCanonicalProjectionStorageTests:XCTestCase {
    var app:Application!
    let binding = try! ImportServerBinding(environment:"development",apiOrigin:"http://127.0.0.1:55480")
    override func setUp() async throws {
        guard let url = Environment.get("DATABASE_URL"),let c = URLComponents(string:url),c.host == "127.0.0.1",c.port == 55439,c.path == "/snaglist_release_projection_0913" else { throw XCTSkip("Owned local synthetic PostgreSQL required") }
        try await start()
    }
    private func start() async throws {
        app = try await Application.make(.testing);try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func account() async throws -> (StagedLegacyImportActor,UUID) {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("projection-\(UUID())@example.test",name:"Synthetic builder",on:db) }
        let actor = try StagedLegacyImportActor(id:user.requireID(),authVersion:user.authVersion)
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for:actor.id,on:db) }
        return (actor,try workspace.requireID())
    }
    private func stage(_ data:Data,actor:StagedLegacyImportActor,workspace:UUID) async throws -> LegacyCanonicalProjectionCommand {
        let source = try JSONDecoder().decode(LegacyProjectImportSource.self,from:data)
        let command = StagedLegacyImportCommand(formatVersion:1,sessionId:UUID(),mutation:.init(operationId:UUID(),deviceId:UUID()),expectedActorId:actor.id,expectedAuthVersion:actor.authVersion,expectedWorkspaceKind:"personal",destination:binding.destination,selectedProjectId:source.project.id,sourceFingerprint:source.source.sourceFingerprint,exportSHA256:LegacyProjectImportDecoder.digest(data),exportByteCount:data.count,acknowledgement:.init(version:StagedLegacyImportCommand.Acknowledgement.supportedVersion,wording:StagedLegacyImportCommand.Acknowledgement.supportedWording,accepted:true))
        _ = try await StagedLegacyImportService.create(command,descriptor:data,workspaceID:workspace,actor:actor,binding:binding,on:app.db)
        return .init(projectionId:UUID(),scope:StagedLegacyImportService.scope(command,workspaceID:workspace),operationId:UUID(),expectedSourceRevision:1,policy:LegacyCanonicalProjection.policy)
    }
    func testPrepareRestartReplayKeepsAllocationsSourceAndCanonicalTablesUnchanged() async throws {
        let (actor,workspace) = try await account(),data = try ProjectionFixture.data(),command = try await stage(data,actor:actor,workspace:workspace)
        let sql = try VerifiedIdentityService.sql(app.db)
        let tables = ["projects","snags","contractors","trades","media_assets","drawings","completion_attempts","review_decisions","platform_changes"]
        var counts:[String:Int] = [:]
        for table in tables { counts[table] = try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table)").first()!.decode(column:"n",as:Int.self) }
        async let a = LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
        async let b = LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
        let results = try await [a,b];XCTAssertEqual(try LegacyCanonicalProjectionMapper.encode(results[0]),try LegacyCanonicalProjectionMapper.encode(results[1]))
        let p = try await LegacyCanonicalProjectionService.read(projectionID:command.projectionId,scope:command.scope,actor:actor,binding:binding,on:app.db)
        XCTAssertEqual(p.files.count,12);XCTAssertEqual(p.fileUses.count,14);XCTAssertEqual(p.edges.count,40);XCTAssertEqual(results[0].blockerCount,0)
        for table in tables { let count = try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table)").first()!.decode(column:"n",as:Int.self);XCTAssertEqual(count,counts[table],table) }
        let raw = try await sql.raw("SELECT encode(descriptor,'base64') AS source FROM staged_legacy_import_sources WHERE session_id = \(bind: command.scope.sessionId)").first()!.decode(column:"source",as:String.self)
        XCTAssertEqual(Data(base64Encoded:raw,options:.ignoreUnknownCharacters),data)
        try await app.asyncShutdown();app = nil;try await start()
        let replay = try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
        XCTAssertEqual(try LegacyCanonicalProjectionMapper.encode(replay),try LegacyCanonicalProjectionMapper.encode(results[0]))
        let again = try await LegacyCanonicalProjectionService.read(projectionID:command.projectionId,scope:command.scope,actor:actor,binding:binding,on:app.db)
        XCTAssertEqual(again.allocations,p.allocations);XCTAssertFalse(replay.importExecutable)
    }
    func testCrossProjectReuseRetainsOneDirectoryIdentityAndRejectsChangedIntrinsicBody() async throws {
        let (actor,workspace) = try await account(),data = try ProjectionFixture.data()
        let a = try await stage(data,actor:actor,workspace:workspace)
        let b = try await stage(ProjectionFixture.secondProject(data,suffix:"second"),actor:actor,workspace:workspace)
        _ = try await LegacyCanonicalProjectionService.prepare(a,actor:actor,binding:binding,on:app.db)
        _ = try await LegacyCanonicalProjectionService.prepare(b,actor:actor,binding:binding,on:app.db)
        let sql = try VerifiedIdentityService.sql(app.db)
        let n = try await sql.raw("SELECT count(*) AS n FROM legacy_canonical_directory_identities WHERE actor_id = \(bind: actor.id)").first()!.decode(column:"n",as:Int.self)
        XCTAssertEqual(n,5) // contractor, trade, two folders, tag.
        var object = try JSONSerialization.jsonObject(with:ProjectionFixture.secondProject(data,suffix:"third")) as! [String:Any]
        var contractors = object["contractors"] as! [[String:Any]];contractors[0]["notes"] = "Different directory source";object["contractors"] = contractors
        let c = try await stage(JSONSerialization.data(withJSONObject:object),actor:actor,workspace:workspace)
        do { _ = try await LegacyCanonicalProjectionService.prepare(c,actor:actor,binding:binding,on:app.db);XCTFail("Changed source must conflict") }
        catch { XCTAssertEqual(error as? LegacyCanonicalProjectionError,.changedDirectory) }
        let absent = try await sql.raw("SELECT 1 FROM legacy_canonical_projections WHERE id = \(bind: c.projectionId)").first();XCTAssertNil(absent)
    }
    func testProjectionOperationBindingAndCurrentAccountAuthorityCannotChange() async throws {
        let (actor,workspace) = try await account(),command = try await stage(ProjectionFixture.data(),actor:actor,workspace:workspace)
        _ = try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
        let wrong = LegacyCanonicalProjectionCommand(projectionId:UUID(),scope:command.scope,operationId:command.operationId,expectedSourceRevision:1,policy:LegacyCanonicalProjection.policy)
        do { _ = try await LegacyCanonicalProjectionService.prepare(wrong,actor:actor,binding:binding,on:app.db);XCTFail("Operation must be immutable") }
        catch { XCTAssertEqual(error as? LegacyCanonicalProjectionError,.projectionChanged) }
        let other = try await account().0
        do { _ = try await LegacyCanonicalProjectionService.read(projectionID:command.projectionId,scope:command.scope,actor:other,binding:binding,on:app.db);XCTFail("Other actor must not read source") } catch {}
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET auth_version = auth_version + 1 WHERE id = \(bind: actor.id)").run()
        do { _ = try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db);XCTFail("Stale account must not replay") } catch {}
    }
    func testCancellationAfterAllocationsRollsBackProjectionButRetainsOriginalSource() async throws {
        let (actor,workspace) = try await account(),command = try await stage(ProjectionFixture.data(),actor:actor,workspace:workspace)
        let sql = try VerifiedIdentityService.sql(app.db),suffix = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let function = "synthetic_projection_cancel_" + suffix,trigger = "synthetic_projection_pause_" + suffix
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: function)() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF NEW.projection_id = '\(unsafeRaw: command.projectionId.uuidString)'::uuid AND current_setting('snaglist.synthetic_projection_pause',true) IS DISTINCT FROM 'yes' THEN
                PERFORM set_config('snaglist.synthetic_projection_pause','yes',true); PERFORM pg_sleep(1);
            END IF; RETURN NEW; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE INSERT ON legacy_canonical_projection_directories FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: function)()").run()
        let task = Task { try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:self.binding,on:self.app.db) }
        var observed = false
        for _ in 0..<150 {
            let n = try await sql.raw("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'active' AND wait_event = 'PgSleep' AND query LIKE 'INSERT INTO legacy_canonical_projection_directories%'").first()!.decode(column:"n",as:Int.self)
            if n > 0 { observed = true;break };try await Task.sleep(nanoseconds:20_000_000)
        }
        task.cancel()
        do { _ = try await task.value;XCTFail("Cancelled projection must not commit") } catch { XCTAssertTrue(error is CancellationError) }
        try await sql.raw("DROP TRIGGER \(unsafeRaw: trigger) ON legacy_canonical_projection_directories").run()
        try await sql.raw("DROP FUNCTION \(unsafeRaw: function)()").run()
        XCTAssertTrue(observed)
        for (table,key) in [("legacy_canonical_projections","id"),("legacy_canonical_allocations","projection_id"),("legacy_canonical_directory_identities","first_projection_id"),("legacy_canonical_projection_directories","projection_id")] {
            let n = try await sql.raw("SELECT count(*) AS n FROM \(unsafeRaw: table) WHERE \(unsafeRaw: key) = \(bind: command.projectionId)").first()!.decode(column:"n",as:Int.self);XCTAssertEqual(n,0,table)
        }
        let source = try await StagedLegacyImportService.read(command.scope,actor:actor,binding:binding,on:app.db)
        XCTAssertEqual(source.state,"staged_incomplete")
        _ = try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
    }
    func testAbortedPreparationAndSQLMappingTamperAreRejected() async throws {
        let (actor,workspace) = try await account(),command = try await stage(ProjectionFixture.data(),actor:actor,workspace:workspace)
        _ = try await LegacyCanonicalProjectionService.prepare(command,actor:actor,binding:binding,on:app.db)
        do { try await VerifiedIdentityService.sql(app.db).raw("UPDATE legacy_canonical_allocations SET target_id = \(bind: UUID()) WHERE projection_id = \(bind: command.projectionId)").run();XCTFail("SQL identity overwrite must fail") } catch {}
        _ = try await StagedLegacyImportService.abort(.init(scope:command.scope,mutation:.init(operationId:UUID(),deviceId:command.scope.deviceId),expectedRevision:1),actor:actor,binding:binding,on:app.db)
        do { _ = try await LegacyCanonicalProjectionService.read(projectionID:command.projectionId,scope:command.scope,actor:actor,binding:binding,on:app.db);XCTFail("Aborted source must not load projection") } catch {}
    }
}
