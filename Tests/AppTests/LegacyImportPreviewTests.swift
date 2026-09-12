@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

private enum ImportPreviewFixture {
    static func body(actor: UUID = UUID(), project: UUID = UUID(), kind: String = "personal") -> [String: Any] {
        var ids = Dictionary(uniqueKeysWithValues: LegacyImportPreviewCommand.kinds.map { ($0, [String]()) })
        ids["projects"] = [project.uuidString]
        return ["formatVersion": 1, "mutation": ["operationId": UUID().uuidString, "deviceId": UUID().uuidString],
                "expectedActorId": actor.uuidString, "expectedWorkspaceKind": kind,
                "source": ["archiveId": UUID().uuidString, "sourceFingerprint": String(repeating: "a", count: 64),
                           "databaseSHA256": String(repeating: "b", count: 64), "inventorySHA256": String(repeating: "c", count: 64),
                           "selectedProjectId": project.uuidString, "exportSHA256": String(repeating: "d", count: 64),
                           "exportByteCount": 900, "exportFormatVersion": 1],
                "destination": ["environment": "development", "apiOrigin": "http://127.0.0.1:55480"],
                "recordIds": ids, "requirements": Dictionary(uniqueKeysWithValues: LegacyImportPreviewCommand.requirementNames.map { ($0, 0) })]
    }
    static func data(_ body: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
    static func command(_ body: [String: Any]) throws -> LegacyImportPreviewCommand { try .decode(data(body)) }
    static func invalid(_ body: [String: Any], status: HTTPResponseStatus = .badRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try command(body), file: file, line: line) { error in
            XCTAssertEqual((error as? Abort)?.status, status, file: file, line: line)
        }
    }
}

final class LegacyImportPreviewManifestTests: XCTestCase {
    func testStrictManifestAcceptsOnlyTheBoundedIdentityProjection() throws {
        let body = ImportPreviewFixture.body(), result = try ImportPreviewFixture.command(body)
        XCTAssertEqual(result.recordIds["projects"], [result.source.selectedProjectId])
        XCTAssertEqual(Set(result.recordIds.keys), LegacyImportPreviewCommand.kinds)
        for key in ["consent", "accessToken", "clientPlanId", "upload", "projectName"] {
            var changed = body; changed[key] = "must not be accepted"
            ImportPreviewFixture.invalid(changed)
        }
        for nested in ["source", "destination", "mutation", "recordIds", "requirements"] {
            var changed = body, fields = changed[nested] as! [String: Any]
            fields["unknown"] = "no raw paths or contact details"; changed[nested] = fields
            ImportPreviewFixture.invalid(changed)
        }
    }
    func testVersionsDigestsAndCanonicalDestinationAreValidated() throws {
        let body = ImportPreviewFixture.body()
        var changed = body; changed["formatVersion"] = 2; ImportPreviewFixture.invalid(changed)
        for digest in ["sourceFingerprint", "databaseSHA256", "inventorySHA256", "exportSHA256"] {
            var changed = body, source = changed["source"] as! [String: Any]
            source[digest] = String(repeating: "A", count: 64); changed["source"] = source; ImportPreviewFixture.invalid(changed)
        }
        for origin in ["http://127.0.0.1:55480/", "https://API.EXAMPLE.TEST:443", "https://example.test/path", "https://u:p@example.test", "http://example.test"] {
            var changed = body; changed["destination"] = ["environment": "development", "apiOrigin": origin]
            ImportPreviewFixture.invalid(changed)
        }
        XCTAssertEqual(try ImportServerBinding(environment: "development", apiOrigin: "https://API.EXAMPLE.TEST:443/").apiOrigin, "https://api.example.test")
        XCTAssertThrowsError(try ImportServerBinding(environment: "staging", apiOrigin: "http://127.0.0.1"))
        XCTAssertThrowsError(try ImportServerBinding(environment: "local", apiOrigin: "https://api.example.test"))
    }
    func testDuplicateUnsortedAndWrongProjectIDsAreRejected() throws {
        let body = ImportPreviewFixture.body(), id = UUID().uuidString
        for list in [[id, id], ["FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "00000000-0000-0000-0000-000000000000"]] {
            var changed = body, ids = changed["recordIds"] as! [String: [String]]
            ids["snags"] = list; changed["recordIds"] = ids; ImportPreviewFixture.invalid(changed)
        }
        var changed = body, ids = changed["recordIds"] as! [String: [String]]
        ids["projects"] = [UUID().uuidString]; changed["recordIds"] = ids; ImportPreviewFixture.invalid(changed)
    }
    func testBoundsRejectCompleteOversizedManifestsInsteadOfTruncating() throws {
        var body = ImportPreviewFixture.body(), ids = body["recordIds"] as! [String: [String]]
        ids["snags"] = (0..<10_000).map { _ in UUID().uuidString }.sorted()
        body["recordIds"] = ids; ImportPreviewFixture.invalid(body, status: .payloadTooLarge)
        var export = ImportPreviewFixture.body(), source = export["source"] as! [String: Any]
        source["exportByteCount"] = 8 * 1024 * 1024 + 1; export["source"] = source
        ImportPreviewFixture.invalid(export, status: .payloadTooLarge)
        XCTAssertThrowsError(try LegacyImportPreviewCommand.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))) { error in
            XCTAssertEqual((error as? Abort)?.status, .payloadTooLarge)
        }
    }
    func testRequirementCountsCannotContradictTheirDeclaredRecordKind() {
        let body = ImportPreviewFixture.body()
        for (key, count) in [("originalPhotoCount", 1), ("pinCount", 1), ("coverCount", 2), ("sourceFindingCount", -1), ("relationshipFindingCount", 100_001)] {
            var changed = body, requirements = changed["requirements"] as! [String: Int]
            requirements[key] = count; changed["requirements"] = requirements; ImportPreviewFixture.invalid(changed)
        }
    }
}

final class LegacyImportPreviewIntegrationTests: XCTestCase {
    var app: Application!
    let binding = try! ImportServerBinding(environment: "development", apiOrigin: "http://127.0.0.1:55480")
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Pinned synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        app.storage[ImportServerBindingKey.self] = binding
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("import-preview-\(UUID())@example.test", name: "Synthetic manager", on: db) }
    }
    private func workspace(_ user: User, company: Bool = false) async throws -> Team {
        try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Builders", actorID: user.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: user.requireID(), on: db)
        }
    }
    private func request(_ body: [String: Any], workspace: UUID, user: User?, cookie: String? = nil,
                         origin: String? = nil, csrf: String? = nil) async throws -> XCTHTTPResponse {
        let jwt = try user.map { try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: $0.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: $0.requireID(), authVersion: $0.authVersion)) }
        let bytes = try ImportPreviewFixture.data(body)
        var result: XCTHTTPResponse!
        try await app.test(.POST, "api/v2/workspaces/\(workspace)/import-previews", beforeRequest: { req in
            req.headers.contentType = .json; req.body = .init(data: bytes)
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: BrowserSessionService.cookieName + "=" + cookie) }
            if let origin { req.headers.replaceOrAdd(name: "Origin", value: origin) }
            if let csrf { req.headers.replaceOrAdd(name: "X-CSRF-Token", value: csrf) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func receipt(_ command: LegacyImportPreviewCommand, actor: UUID) async throws -> String? {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT result_json FROM mutation_receipts WHERE actor_id = \(bind: actor) AND operation_id = \(bind: command.mutation.operationId)").first()?.decode(column: "result_json", as: String.self)
    }
    private func count(_ table: String) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM \(unsafeRaw: table)").first()!.decode(column: "n", as: Int.self)
    }

    func testPreviewIsNonExecutableAndOnlyWritesOneReplayableDiagnosticReceipt() async throws {
        let owner = try await user(), team = try await workspace(owner), actor = try owner.requireID(), id = UUID()
        let legacy = Project(id: id, name: "Keep on device", reference: "OLD-13", ownerId: actor)
        try await legacy.save(on: app.db)
        let body = ImportPreviewFixture.body(actor: actor, project: id), command = try ImportPreviewFixture.command(body)
        let tables = ["users", "teams", "workspace_memberships", "projects", "snags", "project_access", "media_assets", "drawings", "drawing_assets", "snag_deletions", "platform_changes", "workspace_activity", "completion_attempts", "review_decisions", "workflow_outbox", "project_comments", "assignment_history"]
        var before: [String: Int] = [:]
        for table in tables { before[table] = try await count(table) }
        let sequence = try await VerifiedIdentityService.sql(app.db).raw("SELECT change_sequence FROM teams WHERE id = \(bind: team.requireID())").first()!.decode(column: "change_sequence", as: Int64.self)
        let response = try await request(body, workspace: team.requireID(), user: owner)
        XCTAssertEqual(response.status, .ok, response.body.string); XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let preview = try response.content.decode(LegacyImportPreviewResponse.self)
        XCTAssertFalse(preview.importExecutable); XCTAssertFalse(preview.sourceBytesVerified)
        XCTAssertEqual(preview.ownershipConsent, "not_recorded"); XCTAssertEqual(preview.graphContentValidation, "not_performed")
        XCTAssertEqual(preview.state, "preview_only"); XCTAssertEqual(preview.workspaceId, team.id); XCTAssertNotEqual(preview.workspaceId, actor)
        XCTAssertTrue(preview.blockers.contains("import_commit_not_implemented")); XCTAssertEqual(preview.collisions.first?.code, "identifier_unavailable")
        let firstReceipt = try await receipt(command, actor: actor); XCTAssertNotNil(firstReceipt)
        let replay = try await request(body, workspace: team.requireID(), user: owner)
        XCTAssertEqual(replay.status, .ok)
        XCTAssertEqual(try PlatformMutationService.encode(preview), try PlatformMutationService.encode(replay.content.decode(LegacyImportPreviewResponse.self)))
        for table in tables { let actual = try await count(table); XCTAssertEqual(actual, before[table], table) }
        let retained = try await Project.find(id, on: app.db); XCTAssertNil(retained?.workspaceId); XCTAssertFalse(retained!.platformManaged)
        let afterSequence = try await VerifiedIdentityService.sql(app.db).raw("SELECT change_sequence FROM teams WHERE id = \(bind: team.requireID())").first()!.decode(column: "change_sequence", as: Int64.self)
        XCTAssertEqual(afterSequence, sequence)
        var different = body, source = different["source"] as! [String: Any]; source["exportByteCount"] = 901; different["source"] = source
        let reused = try await request(different, workspace: team.requireID(), user: owner)
        XCTAssertEqual(reused.status, .conflict); XCTAssertTrue(reused.body.string.contains("operation_reused"))
        let finalReceipt = try await receipt(command, actor: actor); XCTAssertEqual(finalReceipt, firstReceipt)
    }

    func testCurrentActorEnvironmentWorkspaceAndLifecycleCannotBeSubstituted() async throws {
        let owner = try await user(), other = try await user(), team = try await workspace(owner), otherTeam = try await workspace(other)
        let body = ImportPreviewFixture.body(actor: try owner.requireID())
        let unauth = try await request(body, workspace: team.requireID(), user: nil); XCTAssertEqual(unauth.status, .unauthorized)
        let wrongActor = try await request(body, workspace: team.requireID(), user: other); XCTAssertEqual(wrongActor.status, .conflict)
        let wrongScope = try await request(body, workspace: otherTeam.requireID(), user: owner); XCTAssertEqual(wrongScope.status, .notFound)
        var environment = body; environment["destination"] = ["environment": "staging", "apiOrigin": "https://api.example.test"]
        let wrongEnvironment = try await request(environment, workspace: team.requireID(), user: owner); XCTAssertEqual(wrongEnvironment.status, .conflict)
        var kind = body; kind["expectedWorkspaceKind"] = "company"
        let wrongKind = try await request(kind, workspace: team.requireID(), user: owner); XCTAssertEqual(wrongKind.status, .conflict)
        let missing = try await request(body, workspace: UUID(), user: owner); XCTAssertEqual(missing.status, .notFound)
        app.storage[ImportServerBindingKey.self] = nil
        let unconfigured = try await request(body, workspace: team.requireID(), user: owner); XCTAssertEqual(unconfigured.status, .serviceUnavailable)
        app.storage[ImportServerBindingKey.self] = binding
        team.lifecycleState = "closed"; try await team.save(on: app.db)
        let closed = try await request(body, workspace: team.requireID(), user: owner); XCTAssertEqual(closed.status, .notFound)
    }

    func testCompanyAdminMustRemainAnActiveMemberAndRejoinInvalidatesOldPreview() async throws {
        let owner = try await user(), admin = try await user(), member = try await user(), stranger = try await user()
        let team = try await workspace(owner, company: true), workspaceID = try team.requireID()
        try await app.db.transaction { db in
            try await WorkspaceAccessService.putMembership(workspaceID: workspaceID, userID: admin.requireID(), role: "admin", on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: workspaceID, userID: member.requireID(), role: "member", on: db)
        }
        for (person, status) in [(owner, HTTPResponseStatus.ok), (member, .forbidden), (stranger, .notFound)] {
            let result = try await request(ImportPreviewFixture.body(actor: person.requireID(), kind: "company"), workspace: workspaceID, user: person)
            XCTAssertEqual(result.status, status, result.body.string)
        }
        let body = ImportPreviewFixture.body(actor: try admin.requireID(), kind: "company"), command = try ImportPreviewFixture.command(body)
        let first = try await request(body, workspace: workspaceID, user: admin); XCTAssertEqual(first.status, .ok)
        let original = try await receipt(command, actor: admin.requireID())
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: workspaceID, targetID: admin.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let removed = try await request(body, workspace: workspaceID, user: admin); XCTAssertEqual(removed.status, .notFound)
        try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: workspaceID, userID: admin.requireID(), role: "admin", on: db) }
        let rejoined = try await request(body, workspace: workspaceID, user: admin)
        XCTAssertEqual(rejoined.status, .conflict); XCTAssertTrue(rejoined.body.string.contains("import_preview_stale"))
        let retained = try await receipt(command, actor: admin.requireID()); XCTAssertEqual(retained, original)
    }

    func testForeignCollisionsAndTombstonesRevealNoOtherOwnerOrProjectMetadata() async throws {
        let owner = try await user(), outsider = try await user(), team = try await workspace(owner), foreign = try await workspace(outsider)
        let project = Project(id: UUID(), name: "Foreign confidential project", reference: "SECRET", ownerId: try outsider.requireID())
        project.workspaceId = try foreign.requireID(); try await project.save(on: app.db)
        let deletedID = UUID(), tombstone = SnagDeletion(snagId: deletedID, ownerId: try outsider.requireID(), projectId: try project.requireID())
        try await tombstone.save(on: app.db)
        var body = ImportPreviewFixture.body(actor: try owner.requireID(), project: try project.requireID()), ids = body["recordIds"] as! [String: [String]]
        ids["snags"] = [deletedID.uuidString]; body["recordIds"] = ids
        let response = try await request(body, workspace: team.requireID(), user: owner); XCTAssertEqual(response.status, .ok)
        let preview = try response.content.decode(LegacyImportPreviewResponse.self)
        XCTAssertEqual(preview.collisions.count, 2); XCTAssertTrue(preview.collisions.allSatisfy { $0.code == "identifier_unavailable" })
        for secret in [project.name, project.reference, try outsider.requireID().uuidString, try foreign.requireID().uuidString] { XCTAssertFalse(response.body.string.contains(secret)) }
    }

    func testNewCollisionAndExpiryRequireANewOperationWithoutReplacingTheReceipt() async throws {
        let owner = try await user(), team = try await workspace(owner), actor = try owner.requireID()
        let body = ImportPreviewFixture.body(actor: actor), command = try ImportPreviewFixture.command(body)
        let first = try await request(body, workspace: team.requireID(), user: owner); XCTAssertEqual(first.status, .ok)
        let original = try await receipt(command, actor: actor)
        let project = Project(id: command.source.selectedProjectId, name: "Newer canonical project", reference: "NEW", ownerId: actor)
        project.workspaceId = try team.requireID(); project.platformManaged = true; try await project.save(on: app.db)
        let stale = try await request(body, workspace: team.requireID(), user: owner)
        XCTAssertEqual(stale.status, .conflict); XCTAssertTrue(stale.body.string.contains("import_preview_stale"))
        let retained = try await receipt(command, actor: actor); XCTAssertEqual(retained, original)
        let expiredBody = ImportPreviewFixture.body(actor: actor), expiredCommand = try ImportPreviewFixture.command(expiredBody)
        _ = try await app.db.transaction { db in try await LegacyImportPreviewService.preview(expiredCommand, workspaceID: team.requireID(), actorID: actor, binding: self.binding, on: db, now: Date().addingTimeInterval(-3600)) }
        let expired = try await request(expiredBody, workspace: team.requireID(), user: owner)
        XCTAssertEqual(expired.status, .conflict); XCTAssertTrue(expired.body.string.contains("import_preview_stale"))
    }

    func testUnsupportedGraphHistoryAndMissingEvidenceStayExplicitlyBlocked() async throws {
        let owner = try await user(), team = try await workspace(owner)
        var body = ImportPreviewFixture.body(actor: try owner.requireID()), ids = body["recordIds"] as! [String: [String]], requirements = body["requirements"] as! [String: Int]
        for kind in LegacyImportPreviewCommand.kinds where kind != "projects" { ids[kind] = [UUID().uuidString] }
        for key in ["originalPhotoCount", "annotationCount", "drawingFileCount", "pinCount", "localClosureCount", "missingMediaReferenceCount", "unresolvedDrawingAssociationCount"] { requirements[key] = 1 }
        body["recordIds"] = ids; body["requirements"] = requirements
        let response = try await request(body, workspace: team.requireID(), user: owner); XCTAssertEqual(response.status, .ok)
        let result = try response.content.decode(LegacyImportPreviewResponse.self)
        XCTAssertFalse(result.importExecutable); XCTAssertFalse(result.sourceBytesVerified)
        for blocker in ["drawing_source_graph_import_not_implemented", "media_source_graph_import_not_implemented", "historical_status_is_not_canonical_acceptance", "historical_comment_provenance_not_implemented", "organisation_graph_import_not_implemented", "directory_assignment_import_not_implemented", "legacy_deletion_reconciliation_not_implemented", "source_findings_require_review"] { XCTAssertTrue(result.blockers.contains(blocker), blocker) }
        for kind in ["folders", "tags", "statusHistory"] { XCTAssertTrue(result.identities.first { $0.kind == kind }!.namespacesChecked.isEmpty) }
    }

    func testCookieAuthenticationRequiresOriginAndCSRFAndRevocationStopsReplay() async throws {
        let owner = try await user(), team = try await workspace(owner), body = ImportPreviewFixture.body(actor: try owner.requireID())
        let config = try PlatformConfiguration.load(on: app)
        let session = try await BrowserSessionService.create(for: owner, config: config, on: app.db)
        let missing = try await request(body, workspace: team.requireID(), user: nil, cookie: session.token)
        XCTAssertEqual(missing.status, .forbidden)
        let wrong = try await request(body, workspace: team.requireID(), user: nil, cookie: session.token, origin: "https://foreign.example.test", csrf: session.principal.csrfToken)
        XCTAssertEqual(wrong.status, .forbidden)
        let noCSRF = try await request(body, workspace: team.requireID(), user: nil, cookie: session.token, origin: config.origin)
        XCTAssertEqual(noCSRF.status, .forbidden)
        let valid = try await request(body, workspace: team.requireID(), user: nil, cookie: session.token, origin: config.origin, csrf: session.principal.csrfToken)
        XCTAssertEqual(valid.status, .ok)
        try await BrowserSessionService.revoke(session.principal.sessionID, on: app.db)
        let revoked = try await request(body, workspace: team.requireID(), user: nil, cookie: session.token, origin: config.origin, csrf: session.principal.csrfToken)
        XCTAssertEqual(revoked.status, .unauthorized)
    }

    func testConcurrentRetryCannotMoveAnOperationToAnotherOwnedWorkspaceOrDevice() async throws {
        let owner = try await user(), first = try await workspace(owner, company: true), second = try await workspace(owner, company: true)
        let actor = try owner.requireID(), firstID = try first.requireID(), secondID = try second.requireID()
        let body = ImportPreviewFixture.body(actor: actor, kind: "company"), command = try ImportPreviewFixture.command(body)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask {
                let result = try await self.request(body, workspace: firstID, user: owner)
                XCTAssertEqual(result.status, .ok, result.body.string)
            } }
            try await group.waitForAll()
        }
        let original = try await receipt(command, actor: actor); XCTAssertNotNil(original)
        let moved = try await request(body, workspace: secondID, user: owner)
        XCTAssertEqual(moved.status, .conflict); XCTAssertTrue(moved.body.string.contains("operation_reused"))
        var deviceChanged = body, mutation = body["mutation"] as! [String: String]
        mutation["deviceId"] = UUID().uuidString; deviceChanged["mutation"] = mutation
        let changed = try await request(deviceChanged, workspace: firstID, user: owner)
        XCTAssertEqual(changed.status, .conflict); XCTAssertTrue(changed.body.string.contains("operation_reused"))
        let retained = try await receipt(command, actor: actor); XCTAssertEqual(retained, original)
        let count = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM mutation_receipts WHERE actor_id = \(bind: actor) AND operation_id = \(bind: command.mutation.operationId)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(count, 1)
        let value = try PlatformMutationService.decode(LegacyImportPreviewResponse.self, retained!)
        XCTAssertEqual(value.workspaceId, firstID); XCTAssertEqual(value.deviceId, command.mutation.deviceId)
    }

    func testFailedTransactionLeavesNoDiagnosticReceipt() async throws {
        let owner = try await user(), team = try await workspace(owner), actor = try owner.requireID()
        let command = try ImportPreviewFixture.command(ImportPreviewFixture.body(actor: actor))
        do {
            let _: LegacyImportPreviewResponse = try await app.db.transaction { db in
                _ = try await LegacyImportPreviewService.preview(command, workspaceID: team.requireID(), actorID: actor, binding: self.binding, on: db)
                throw Abort(.conflict, reason: "Synthetic interruption after recording")
            }
            XCTFail("Transaction should throw")
        } catch { XCTAssertEqual((error as? Abort)?.status, .conflict) }
        let saved = try await receipt(command, actor: actor); XCTAssertNil(saved)
    }
}
