@testable import App
import XCTVapor
import Fluent
import JWT

/// Uses only a disposable PostgreSQL database and synthetic identities.
final class MagicLinkHardeningTests: XCTestCase {
    var app: Application!
    // Give each case its own documentation-range proxy IP. Rate limiting remains
    // enabled; one case must not consume the next case's public-link allowance.
    let clientIP = "2001:db8::" + String(UUID().uuidString.prefix(4)) + ":" + String(UUID().uuidString.prefix(4))
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    struct Fixture {
        let owner: UUID
        let project: UUID
        let snag: UUID
        let jwt: String
        let link: MagicLink
        let original: String
    }

    private func fixture(canonical: Bool = false) async throws -> Fixture {
        let user = User(appleUserId: nil, email: "hardening-\(UUID())@example.com", name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        let owner = try user.requireID(), project = UUID(), snag = UUID()
        if canonical {
            let record = Project(name: "Synthetic project", reference: "TEST", ownerId: owner)
            record.id = project
            try await record.save(on: app.db)
            try await Snag(id: snag, reference: "TEST-001", title: "Synthetic snag", projectId: project, ownerId: owner).save(on: app.db)
        }
        let link = MagicLink(token: "hardening-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600), snagIds: [snag], projectId: project, createdById: owner)
        try await link.save(on: app.db)
        let original = """
        {"projectName":"Synthetic project","project":{"id":"\(project)","futureField":"keep"},
        "drawings":[{"futureField":"keep drawing"}],"snags":[{"id":"\(snag)",
        "title":"Synthetic snag","status":"open","futureField":{"keep":true}}]}
        """
        try await SyncedReport(magicLinkToken: link.token, reportJSON: original).save(on: app.db)
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: owner.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: owner))
        return Fixture(owner: owner, project: project, snag: snag, jwt: jwt, link: link, original: original)
    }

    private func request(_ method: HTTPMethod, _ path: String, jwt: String? = nil, body: String? = nil, cookie: String? = nil) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: self.clientIP)
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
            if let body { req.headers.contentType = .json; req.body = ByteBuffer(string: body) }
        }, afterResponse: { response async in result = response })
        return result
    }

    private func body(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func sync(_ f: Fixture, token: String? = nil, hasPIN: Bool = true, hash: String? = nil, salt: String? = nil, jwt: String? = nil) async throws -> XCTHTTPResponse {
        var object: [String: Any] = ["token": token ?? f.link.token, "accessLevel": "update", "hasPIN": hasPIN,
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
            "snagIds": [f.snag.uuidString], "projectId": f.project.uuidString]
        if let hash { object["pinHash"] = hash }
        if let salt { object["pinSalt"] = salt }
        return try await request(.POST, "api/v1/magic-links/sync", jwt: jwt ?? f.jwt, body: body(object))
    }

    private func submit(_ f: Fixture, link: MagicLink? = nil) async throws -> XCTHTTPResponse {
        try await request(.POST, "api/v1/magic-links/\((link ?? f.link).token)/snags/\(f.snag)/complete", body: "{\"contractorName\":\"Synthetic contractor\"}")
    }

    private func completionID(_ response: XCTHTTPResponse) throws -> UUID {
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try XCTUnwrap(response.content.decode(CompletionActionResponse.self).completionId)
    }

    private func status(_ f: Fixture) async throws -> String? {
        let response = try await request(.GET, "api/v1/magic-links/\(f.link.token)/snags")
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(SnagListResponse.self).snags.first?.status
    }

    func testNativePINImportProtectsReadsWritesUploadsAndUpgradesToBcrypt() async throws {
        let f = try await fixture()
        let salt = Data(repeating: 7, count: 16).base64EncodedString()
        let hash = SHA256Hasher.hash(token: "4826" + salt)
        let published = try await sync(f, hash: hash, salt: salt)
        XCTAssertEqual(published.status, .ok, published.body.string)
        XCTAssertTrue(try published.content.decode(MagicLinkSyncResponse.self).pinProtectionVerified)
        for path in ["snags", "pdf"] {
            let response = try await request(.GET, "api/v1/magic-links/\(f.link.token)/\(path)")
            XCTAssertEqual(response.status, .forbidden)
        }
        let write = try await submit(f)
        XCTAssertEqual(write.status, .forbidden)
        let upload = try await request(.POST, "api/v1/uploads/photo?token=\(f.link.token)")
        XCTAssertEqual(upload.status, .forbidden)
        let wrong = try await request(.POST, "api/v1/magic-links/token/\(f.link.token)/verify-pin", body: "{\"pin\":\"9999\"}")
        XCTAssertEqual(wrong.status, .unauthorized)
        let correct = try await request(.POST, "api/v1/magic-links/token/\(f.link.token)/verify-pin", body: "{\"pin\":\"4826\"}")
        XCTAssertEqual(correct.status, .ok)
        let cookie = try XCTUnwrap(correct.headers.first(name: .setCookie)?.components(separatedBy: ";").first)
        let read = try await request(.GET, "api/v1/magic-links/\(f.link.token)/snags", cookie: cookie)
        XCTAssertEqual(read.status, .ok)
        let stored = try await MagicLink.find(f.link.id, on: app.db)
        XCTAssertTrue(stored?.pinHash?.hasPrefix("$2") == true)
        XCTAssertNil(stored?.pinSalt)
        let repeated = try await sync(f, hash: hash, salt: salt)
        XCTAssertEqual(repeated.status, .ok)
        let reloaded = try await MagicLink.find(f.link.id, on: app.db)
        XCTAssertEqual(reloaded?.pinHash, stored?.pinHash, "Republication must not downgrade bcrypt")
        let downgrade = try await sync(f, hasPIN: false)
        XCTAssertEqual(downgrade.status, .conflict)
    }

    func testPINPublicationFailsClosedForLegacyAndMalformedPayloads() async throws {
        let f = try await fixture()
        for (hash, salt) in [(nil, nil), ("bad", nil), ("bad", "bad")] as [(String?, String?)] {
            let token = "new-\(UUID())"
            let response = try await sync(f, token: token, hash: hash, salt: salt)
            XCTAssertEqual(response.status, .badRequest)
            let count = try await MagicLink.query(on: app.db).filter(\.$token == token).count()
            XCTAssertEqual(count, 0)
        }
        let ordinary = try await sync(f, token: "ordinary-\(UUID())", hasPIN: false)
        XCTAssertEqual(ordinary.status, .ok)
        let other = try await fixture()
        let wrongOwner = try await sync(f, hasPIN: false, jwt: other.jwt)
        XCTAssertEqual(wrongOwner.status, .notFound)
    }

    func testTokenRevocationIsOwnerOnlyRetrySafeAndCannotBeRepublished() async throws {
        let f = try await fixture(), other = try await fixture()
        let route = "api/v1/magic-links/\(f.link.token)/revoke"
        let anonymous = try await request(.POST, route)
        XCTAssertEqual(anonymous.status, .unauthorized)
        let wrongOwner = try await request(.POST, route, jwt: other.jwt)
        XCTAssertEqual(wrongOwner.status, .notFound)
        for _ in 0..<2 {
            let response = try await request(.POST, route, jwt: f.jwt)
            XCTAssertEqual(response.status, .ok)
        }
        let read = try await request(.GET, "api/v1/magic-links/\(f.link.token)/snags")
        XCTAssertEqual(read.status, .gone)
        let publication = try await sync(f, hasPIN: false)
        XCTAssertEqual(publication.status, .gone)
        let snapshot = try await request(.POST, "api/v1/magic-links/\(f.link.token)/report", jwt: f.jwt, body: f.original)
        XCTAssertEqual(snapshot.status, .gone)
        for _ in 0..<2 {
            let legacy = try await request(.DELETE, "api/v1/magic-links/\(f.link.id!)", jwt: f.jwt)
            XCTAssertEqual(legacy.status, .noContent)
        }
    }

    func testContractorCannotCloseAndStartingWorkPreservesUnknownReportFields() async throws {
        let f = try await fixture(canonical: true)
        let path = "api/v1/magic-links/\(f.link.token)/snags/\(f.snag)/status"
        for state in ["closed", "complete", "completed", "approved", "submitted"] {
            let response = try await request(.PATCH, path, body: body(["status": state]))
            XCTAssertEqual(response.status, .forbidden)
        }
        let before = try await status(f)
        XCTAssertEqual(before, "open")
        let response = try await request(.PATCH, path, body: "{\"status\":\"in_progress\"}")
        XCTAssertEqual(response.status, .ok)
        let canonical = try await Snag.find(f.snag, on: app.db)
        XCTAssertEqual(canonical?.status, "in_progress")
        let report = try await SyncedReport.query(on: app.db).filter(\.$magicLinkToken == f.link.token).first()
        let json = try XCTUnwrap(report?.reportJSON)
        XCTAssertTrue(json.contains("keep drawing")); XCTAssertTrue(json.contains("futureField"))
        XCTAssertTrue(json.contains(f.project.uuidString))
        let count = try await Completion.query(on: app.db).filter(\.$snagId == f.snag).count()
        XCTAssertEqual(count, 0)
    }

    func testForgedLinkCannotChangeAnotherOwnersCanonicalSnag() async throws {
        let victim = try await fixture(canonical: true), attacker = try await fixture()
        let forged = MagicLink(token: "forged-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600), snagIds: [victim.snag], projectId: victim.project, createdById: attacker.owner)
        try await forged.save(on: app.db)
        for (method, suffix, payload) in [(HTTPMethod.PATCH, "status", "{\"status\":\"in_progress\"}"), (.POST, "complete", "{\"contractorName\":\"Synthetic contractor\"}")] {
            let response = try await request(method, "api/v1/magic-links/\(forged.token)/snags/\(victim.snag)/\(suffix)", body: payload)
            XCTAssertEqual(response.status, .notFound) // Do not reveal another owner's project.
        }
        let canonical = try await Snag.find(victim.snag, on: app.db)
        XCTAssertEqual(canonical?.status, "open")
    }

    func testReportOnlyApprovalSurvivesStalePublicationAndBlocksResubmission() async throws {
        let f = try await fixture()
        let id = try completionID(await submit(f))
        let submitted = try await status(f)
        XCTAssertEqual(submitted, "submitted")
        let decision = try await request(.POST, "api/v1/completions/\(id)/approve", jwt: f.jwt, body: "{}")
        XCTAssertEqual(decision.status, .ok)
        let replay = try await request(.POST, "api/v1/magic-links/\(f.link.token)/report", jwt: f.jwt, body: f.original)
        XCTAssertEqual(replay.status, .ok)
        let approved = try await status(f)
        XCTAssertEqual(approved, "approved")
        let canonical = try await Snag.find(f.snag, on: app.db)
        XCTAssertNil(canonical, "Sharing must not silently invent a canonical record")
        let repeated = try await submit(f)
        XCTAssertEqual(repeated.status, .conflict)
        let restart = try await request(.PATCH, "api/v1/magic-links/\(f.link.token)/snags/\(f.snag)/status", body: "{\"status\":\"in_progress\"}")
        XCTAssertEqual(restart.status, .conflict)
    }

    func testRejectionAllowsFurtherSubmissionWithoutLosingDecisionHistory() async throws {
        let f = try await fixture()
        let first = try completionID(await submit(f))
        let decision = try await request(.POST, "api/v1/completions/\(first)/reject", jwt: f.jwt, body: "{\"reason\":\"Needs another adjustment\"}")
        XCTAssertEqual(decision.status, .ok)
        let rejected = try await status(f)
        XCTAssertEqual(rejected, "sentBack")
        let second = try completionID(await submit(f))
        XCTAssertNotEqual(first, second)
        let records = try await Completion.query(on: app.db).filter(\.$snagId == f.snag).all()
        XCTAssertEqual(records.filter { $0.status == .rejected }.count, 1)
        XCTAssertEqual(records.filter { $0.status == .pending }.count, 1)
    }

    func testGenericStaleEditCannotUndoApprovalButDescriptionCanBeEdited() async throws {
        let f = try await fixture(canonical: true)
        let id = try completionID(await submit(f))
        let decision = try await request(.POST, "api/v1/completions/\(id)/approve", jwt: f.jwt, body: "{}")
        XCTAssertEqual(decision.status, .ok)
        let stale = try await request(.PATCH, "api/v1/snags/\(f.snag)", jwt: f.jwt, body: "{\"status\":\"open\",\"title\":\"Stale title\"}")
        XCTAssertEqual(stale.status, .conflict)
        let edit = try await request(.PATCH, "api/v1/snags/\(f.snag)", jwt: f.jwt, body: "{\"title\":\"Corrected description\"}")
        XCTAssertEqual(edit.status, .ok, edit.body.string)
        let record = try await Snag.find(f.snag, on: app.db)
        XCTAssertEqual(record?.status, "approved"); XCTAssertNotNil(record?.closedAt)
        XCTAssertEqual(record?.title, "Corrected description")
    }

    func testConcurrentSubmissionsAcrossLinksCreateOnlyOnePendingRecord() async throws {
        let f = try await fixture()
        let other = MagicLink(token: "second-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(3600), snagIds: [f.snag], projectId: f.project, createdById: f.owner)
        try await other.save(on: app.db)
        try await SyncedReport(magicLinkToken: other.token, reportJSON: f.original).save(on: app.db)
        async let first = submit(f)
        async let second = submit(f, link: other)
        let responses = try await [first, second]
        XCTAssertEqual(responses.map(\.status.code).sorted(), [200, 409])
        let records = try await Completion.query(on: app.db).filter(\.$snagId == f.snag).all()
        XCTAssertEqual(records.count, 1)
    }

    func testConcurrentManagerDecisionsCannotDisagree() async throws {
        let f = try await fixture(canonical: true)
        let id = try completionID(await submit(f))
        async let approve = request(.POST, "api/v1/completions/\(id)/approve", jwt: f.jwt, body: "{}")
        async let reject = request(.POST, "api/v1/completions/\(id)/reject", jwt: f.jwt, body: "{\"reason\":\"Needs adjustment\"}")
        let responses = try await [approve, reject]
        XCTAssertEqual(responses.map(\.status.code).sorted(), [200, 409])
        let record = try await Completion.find(id, on: app.db)
        let visible = try await status(f)
        XCTAssertEqual(visible, record?.status == .approved ? "approved" : "sentBack")
        let canonical = try await Snag.find(f.snag, on: app.db)
        XCTAssertEqual(canonical?.status, visible)
    }

    func testBrowserAndAPIKeepSubmissionSeparateFromApproval() async throws {
        let f = try await fixture()
        let initial = try await request(.GET, "m/\(f.link.token)")
        XCTAssertTrue(initial.body.string.contains("Submit for review"))
        let id = try completionID(await submit(f))
        let response = try await request(.GET, "api/v1/magic-links/\(f.link.token)/snags")
        let dto = try response.content.decode(SnagListResponse.self)
        XCTAssertEqual(dto.completedCount, 0); XCTAssertEqual(dto.inProgressCount, 1)
        let pending = try await request(.GET, "m/\(f.link.token)")
        XCTAssertTrue(pending.body.string.contains("Submitted for review"))
        XCTAssertTrue(pending.body.string.contains("0 of 1 snags approved"))
        XCTAssertFalse(pending.body.string.contains("All snags completed!"))
        let decision = try await request(.POST, "api/v1/completions/\(id)/approve", jwt: f.jwt, body: "{}")
        XCTAssertEqual(decision.status, .ok)
        let approved = try await request(.GET, "m/\(f.link.token)")
        XCTAssertTrue(approved.body.string.contains("1 of 1 snags approved"))
        let printable = try await request(.GET, "api/v1/magic-links/\(f.link.token)/pdf")
        XCTAssertTrue(printable.body.string.contains("Approved"))
        // A review artifact containing synthetic data only, for JavaScript/UI checks.
        if let output = Environment.get("SNAGLIST_TEST_HTML_OUTPUT") {
            try initial.body.string.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }
}
