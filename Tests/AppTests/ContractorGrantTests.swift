@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class ContractorGrantTests: XCTestCase {
    var app: Application!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJHRFWHRDb21tZW50AFBSSVZBVEVfTE9DQVRJT05fVEVTVF9NQVJLRVLma54XAAAAJElEQVR4nGPY56FDU8QwasGoBaMWjFowasGoBaMWjFowNCwAALvIli6pZSDtAAAAAElFTkSuQmCC")!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[LinkGrantTokenKey.self] = Data(repeating: 7, count: 32)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
        // B2: private media is allocated into the installed namespace or not at
        // all, and the only writer left is the private content store. Both are
        // injected so the upload route this suite drives has an address to draw
        // and somewhere to put bytes.
        let privateStorage = try InMemoryPrivateContentStore.syntheticConfiguration()
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = privateStorage
        app.storage[PrivateContentStoreProvider.InjectionKey.self] = InMemoryPrivateContentStore(configuration: privateStorage)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("media-\(UUID())@example.test", name: "Synthetic photo tester", on: db) }
    }
    private func meta() -> [String: Any] { ["operationId": UUID().uuidString, "deviceId": UUID().uuidString] }
    private func call(_ method: HTTPMethod, _ path: String, _ user: User?, body: [String: Any] = [:], bytes: Data? = nil, mime: String = "image/png", cookie: String? = nil, contractorHeader: Bool = true, origin: String? = nil) async throws -> XCTHTTPResponse {
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
            if contractorHeader { req.headers.replaceOrAdd(name: "X-Snaglist-Contractor", value: "1") }
            if let origin { req.headers.replaceOrAdd(name: .origin, value: origin) }
            if method != .GET {
                req.headers.replaceOrAdd(name: .contentType, value: bytes == nil ? "application/json" : mime)
                req.body = .init(data: payload)
            }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func project(_ user: User, company: Bool = true) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in
            if company { return try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Willow Construction", actorID: user.requireID(), on: db) }
            return try await WorkspaceAccessService.personal(for: user.requireID(), on: db)
        }
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
    private func command(_ snag: PlatformSnagResponse, bytes: Data = png, purpose: String = "capture", intent: UUID? = nil) -> [String: Any] {
        var value: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "expectedRevision": snag.revision, "purpose": purpose, "sha256": PrivateImageProcessor.digest(bytes), "byteCount": bytes.count, "mimeType": "image/png"]
        if let intent { value["intentId"] = intent.uuidString }
        return value
    }
    private func allocate(_ user: User, _ path: String, _ command: [String: Any]) async throws -> MediaAssetResponse {
        let result = try await call(.POST, path, user, body: command)
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(MediaAssetResponse.self)
    }
    private func join(_ user: User, owner: User, project: PlatformProjectResponse, role: String) async throws {
        let invite = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: project.workspaceId, email: user.email!, role: "member", projects: [.init(projectId: project.project.id, role: role)], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: invite.1, actorID: user.requireID(), on: db) }
    }
    private func logged(_ owner: User, _ project: PlatformProjectResponse) async throws -> PlatformSnagResponse {
        let draft = try await snag(owner, project)
        let result = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(draft.snag.id)/publish", owner, body: ["mutation": meta(), "expectedRevision": draft.revision])
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(PlatformSnagResponse.self)
    }
    private func workflowPath(_ project: PlatformProjectResponse, _ snag: PlatformSnagResponse) -> String { "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/workflow" }
    private func action(_ snag: PlatformSnagResponse, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = ["mutation": meta(), "expectedRevision": snag.revision, "expectedWorkflowRevision": snag.workflowRevision]
        body.merge(extra) { _, new in new }; return body
    }
    private func after(_ actor: User, project: PlatformProjectResponse, snag: PlatformSnagResponse, intent: UUID) async throws -> UUID {
        let path = path(project, snag)
        let media = try await allocate(actor, path, command(snag, purpose: "completion", intent: intent))
        let result = try await call(.PUT, path + "/\(media.id)/content", actor, bytes: Self.png)
        XCTAssertEqual(result.status, .ok, result.body.string); return media.id
    }
    private func submit(_ actor: User, project: PlatformProjectResponse, snag: PlatformSnagResponse) async throws -> WorkflowResponse {
        let intent = UUID(), media = try await after(actor, project: project, snag: snag, intent: intent)
        let result = try await call(.POST, workflowPath(project, snag) + "/submit", actor, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [media.uuidString], "notes": "Repaired and checked on site"]))
        XCTAssertEqual(result.status, .ok, result.body.string); return try result.content.decode(WorkflowResponse.self)
    }
    private func decide(_ actor: User, project: PlatformProjectResponse, submitted: WorkflowResponse, kind: String, reason: String? = nil) async throws -> WorkflowResponse {
        var extra: [String: Any] = ["attemptId": submitted.attempt!.id.uuidString, "expectedAttemptRevision": submitted.attempt!.revision]
        if let reason { extra["reason"] = reason }
        let response = try await call(.POST, workflowPath(project, submitted.snag) + "/" + kind, actor, body: action(submitted.snag, extra: extra))
        XCTAssertEqual(response.status, .ok, response.body.string); return try response.content.decode(WorkflowResponse.self)
    }
    private func contractor(_ user: User, _ project: PlatformProjectResponse) async throws -> UUID {
        let id = UUID(), response = try await call(.POST, "api/v2/workspaces/\(project.workspaceId)/contractors", user, body: ["mutation": meta(), "id": id.uuidString, "expectedRevision": 0, "fields": ["companyName": "Alder Joinery"]])
        XCTAssertEqual(response.status, .ok, response.body.string); return id
    }
    private func assign(_ user: User, _ project: PlatformProjectResponse, _ snag: PlatformSnagResponse, _ contractor: UUID?) async throws -> PlatformSnagResponse {
        let value: Any = contractor.map { $0.uuidString as Any } ?? NSNull()
        let result = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/assignment", user, body: ["mutation": meta(), "expectedRevision": snag.revision, "fields": ["contractorId": value]])
        XCTAssertEqual(result.status, .ok, result.body.string); return try result.content.decode(PlatformSnagResponse.self)
    }
    private func prepared(_ user: User, _ project: PlatformProjectResponse, snags: [UUID], contractor: UUID? = nil, assets: [UUID] = [], mode: String = "completion", pin: String? = nil) async throws -> LinkGrantResponse {
        var body: [String: Any] = ["mutation": meta(), "id": UUID().uuidString, "mode": mode, "snagIds": snags.map(\.uuidString), "assetIds": assets.map(\.uuidString)]
        if let contractor { body["contractorId"] = contractor.uuidString }; if let pin { body["pin"] = pin }
        let response = try await call(.POST, "api/v2/projects/\(project.project.id)/links/prepare", user, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string); return try response.content.decode(LinkGrantResponse.self)
    }
    private func activate(_ user: User, _ project: PlatformProjectResponse, _ grant: LinkGrantResponse) async throws -> (LinkActivationResponse, String) {
        let response = try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(grant.id)/activate", user, body: ["mutation": meta(), "expectedRevision": grant.revision])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let value = try response.content.decode(LinkActivationResponse.self)
        return (value, String(try XCTUnwrap(value.contractorPath).dropFirst(3)))
    }
    private func verify(_ token: String, pin: String) async throws -> String {
        let response = try await call(.POST, "api/v2/contractor/\(token)/verify-pin", nil, body: ["pin": pin])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let cookie = try XCTUnwrap(response.headers[.setCookie].first)
        XCTAssertTrue(cookie.contains("Secure")); XCTAssertTrue(cookie.contains("HttpOnly")); return String(cookie.split(separator: ";")[0])
    }
    private func fixture(pin: String? = nil, photo: Bool = false) async throws -> (User, PlatformProjectResponse, PlatformSnagResponse, LinkActivationResponse, String, UUID?) {
        let owner = try await user(), project = try await project(owner), contractor = try await contractor(owner, project)
        var snag = try await assign(owner, project, logged(owner, project), contractor)
        var assetID: UUID?
        if photo {
            let media = try await allocate(owner, path(project, snag), command(snag)); assetID = media.id
            let put = try await call(.PUT, path(project, snag) + "/\(media.id)/content", owner, bytes: Self.png); XCTAssertEqual(put.status, .ok)
            let attach = try await call(.POST, path(project, snag) + "/\(media.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": snag.revision])
            snag = try attach.content.decode(PlatformSnagResponse.self)
        }
        let grant = try await prepared(owner, project, snags: [snag.snag.id], contractor: contractor, assets: assetID.map { [$0] } ?? [], pin: pin)
        let (activation, token) = try await activate(owner, project, grant)
        return (owner, project, snag, activation, token, assetID)
    }
    private func contractorAfter(_ token: String, _ snag: PlatformSnagResponse, intent: UUID, cookie: String? = nil) async throws -> UUID {
        let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media"
        let result = try await call(.POST, path, nil, body: command(snag, purpose: "completion", intent: intent), cookie: cookie)
        XCTAssertEqual(result.status, .ok, result.body.string)
        let media = try result.content.decode(ContractorGrantController.PhotoResult.self)
        let put = try await call(.PUT, path + "/\(media.id)/content", nil, bytes: Self.png, cookie: cookie)
        XCTAssertEqual(put.status, .ok, put.body.string); return media.id
    }
    /// Lane A P1a: the three-statement `load` and one-statement `item` against the pre-P1a sequence
    /// (`loadSequential` / `itemSequential`), refusal by refusal: same status, reason and identifier, or the
    /// same grant, project and snag.
    func testSingleStatementLoadMatchesTheSequentialChecksRefusalByRefusal() async throws {
        struct Outcome: Equatable { var ok: String? = nil; var status: UInt? = nil; var reason: String? = nil; var identifier: String? = nil }
        func run(_ mode: Int, token: String, snag: UUID, cookie: String?, write: Bool) async -> Outcome {
            let new = mode > 0
            let req = Request(application: app, on: app.eventLoopGroup.next())
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
            do {
                return .init(ok: try await app.db.transaction { db -> String in
                    let (grant, project) = mode == 2 ? try await LinkGrantService.load(token, req: req, shared: true, on: db)
                        : new ? try await LinkGrantService.load(token, req: req, on: db) : try await LinkGrantService.loadSequential(token, req: req, on: db)
                    let item = new ? try await LinkGrantService.item(snag, grant: grant, project: project, write: write, on: db)
                                   : try await LinkGrantService.itemSequential(snag, grant: grant, project: project, write: write, on: db)
                    return "\(try grant.decode(column: "id", as: UUID.self)) \(try project.requireID()) \(try item.requireID()) \(item.contractorId?.uuidString ?? "-")"
                })
            } catch let error as AbortError {
                return .init(status: error.status.code, reason: error.reason, identifier: (error as? DebuggableError)?.identifier)
            } catch { return .init(reason: "non-Abort \(type(of: error))") }
        }
        func compare(_ label: String, token: String, snag: UUID, cookie: String? = nil, write: Bool = true) async -> Outcome {
            let new = await run(1, token: token, snag: snag, cookie: cookie, write: write)
            let old = await run(0, token: token, snag: snag, cookie: cookie, write: write)
            let shared = await run(2, token: token, snag: snag, cookie: cookie, write: write)
            XCTAssertEqual(new, old, label); XCTAssertEqual(shared, old, "shared: " + label); return new
        }
        let sql = try VerifiedIdentityService.sql(app.db)
        func scenario(_ label: String, pin: String? = nil, expect: UInt?, identifier: String? = nil, _ mutate: (User, UUID, UUID, UUID, PlatformProjectResponse) async throws -> Void) async throws {
            let (owner, project, snag, activation, token, _) = try await fixture(pin: pin)
            try await mutate(owner, activation.grant.id, snag.snag.id, project.project.id, project)
            let outcome = await compare(label, token: token, snag: snag.snag.id)
            XCTAssertEqual(outcome.status, expect, "\(label): \(outcome)")
            if let identifier { XCTAssertEqual(outcome.identifier, identifier, label) }
        }
        try await scenario("valid link", expect: nil) { _, _, _, _, _ in }
        try await scenario("expired link", expect: 410) { _, grant, _, _, _ in try await sql.raw("UPDATE link_grants SET expires_at = now() - interval '1 minute' WHERE id = \(bind: grant)").run() }
        try await scenario("issuer is not a member of the workspace", expect: 410, identifier: "link_issuer_inactive") { _, grant, _, _, _ in
            let other = try await self.user(); try await sql.raw("UPDATE link_grants SET creator_id = \(bind: other.requireID()) WHERE id = \(bind: grant)").run()
        }
        try await scenario("issuer account no longer active", expect: 410, identifier: "link_issuer_inactive") { owner, _, _, _, _ in
            try await sql.raw("UPDATE users SET lifecycle_state = 'deleted' WHERE id = \(bind: owner.requireID())").run()
        }
        try await scenario("project archived", expect: 410, identifier: "project_archived") { _, _, _, project, _ in try await sql.raw("UPDATE projects SET archived_at = now() WHERE id = \(bind: project)").run() }
        try await scenario("project not platform-managed", expect: 409, identifier: "project_import_required") { _, _, _, project, _ in try await sql.raw("UPDATE projects SET platform_managed = false WHERE id = \(bind: project)").run() }
        try await scenario("contractor archived", expect: 410) { _, grant, _, _, _ in try await sql.raw("UPDATE contractors SET is_archived = true WHERE id = (SELECT contractor_id FROM link_grants WHERE id = \(bind: grant))").run() }
        try await scenario("snag revoked from the link", expect: 404) { _, grant, snag, _, _ in try await sql.raw("UPDATE link_items SET revoked_at = now() WHERE grant_id = \(bind: grant) AND snag_id = \(bind: snag)").run() }
        try await scenario("snag reassigned", expect: 404) { _, _, snag, _, _ in try await sql.raw("UPDATE snags SET contractor_id = NULL WHERE id = \(bind: snag)").run() }
        try await scenario("snag archived", expect: 404) { _, _, snag, _, _ in try await sql.raw("UPDATE snags SET archived_at = now() WHERE id = \(bind: snag)").run() }
        // Revocation through the route, as a manager does it.
        do {
            let (owner, _, snag, _, token, _) = try await fixture()
            let revoked = try await call(.POST, "api/v1/magic-links/\(token)/revoke", owner); XCTAssertEqual(revoked.status, .ok)
            let outcome = await compare("revoked through the route", token: token, snag: snag.snag.id); XCTAssertEqual(outcome.status, 410)
        }
        // Unknown token and a snag that is not on the link.
        do {
            let (_, _, snag, _, token, _) = try await fixture()
            let o1 = await compare("unknown token", token: "c2_" + String(repeating: "q", count: 43), snag: snag.snag.id)
            XCTAssertEqual(o1.status, 404)
            let o2 = await compare("snag not on this link", token: token, snag: UUID())
            XCTAssertEqual(o2.status, 404)
        }
        // PIN: no cookie, a live session, an expired session.
        do {
            let (_, _, snag, activation, token, _) = try await fixture(pin: "735291")
            let o3 = await compare("PIN, no session", token: token, snag: snag.snag.id)
            XCTAssertEqual(o3.identifier, "pin_required")
            let cookie = try await verify(token, pin: "735291")
            let o4 = await compare("PIN, live session", token: token, snag: snag.snag.id, cookie: cookie)
            XCTAssertNotNil(o4.ok)
            try await sql.raw("UPDATE link_sessions SET expires_at = now() - interval '1 minute' WHERE grant_id = \(bind: activation.grant.id)").run()
            let o5 = await compare("PIN, expired session", token: token, snag: snag.snag.id, cookie: cookie)
            XCTAssertEqual(o5.identifier, "pin_required")
        }
        // A read-only link on a write route, and on a read.
        do {
            let owner = try await user(), project = try await project(owner), contractor = try await contractor(owner, project)
            let snag = try await assign(owner, project, logged(owner, project), contractor)
            let grant = try await prepared(owner, project, snags: [snag.snag.id], contractor: contractor, mode: "read_only")
            let (_, token) = try await activate(owner, project, grant)
            let o6 = await compare("read-only link, write", token: token, snag: snag.snag.id)
            XCTAssertEqual(o6.status, 403)
            let o7 = await compare("read-only link, read", token: token, snag: snag.snag.id, write: false)
            XCTAssertNotNil(o7.ok)
        }
    }
    /// Lane A P5: the read routes' shared variant. Read-only (a write in that transaction fails), refuses instead of falling
    /// back to `check` (which may write and locks exclusively), and the lock semantics: an exclusive holder makes reads wait
    /// and then answer 503 workspace_busy; a shared holder does not; PostgreSQL's fair queue puts a later reader behind a
    /// waiting writer; verifyPIN stays exclusive and its failure counter commits.
    func testSharedReadPathIsReadOnlyRefusesInsteadOfFallingBackAndKeepsTheLockSemantics() async throws {
        let sql = try VerifiedIdentityService.sql(app.db)
        func workspace(_ project: PlatformProjectResponse) async throws -> UUID {
            try await sql.raw("SELECT workspace_id FROM projects WHERE id = \(bind: project.project.id)").first()!.decode(column: "workspace_id", as: UUID.self)
        }
        /// Holds the workspace key (exclusive or shared) on its own pooled connection for `seconds`.
        func hold(_ shared: Bool, _ ws: UUID, seconds: Double) -> Task<Void, Error> {
            Task {
                try await self.app.db.transaction { db in
                    let fn = shared ? "pg_advisory_xact_lock_shared" : "pg_advisory_xact_lock"
                    try await VerifiedIdentityService.sql(db).raw("SELECT \(unsafeRaw: fn)(hashtextextended(\(bind: "workspace:" + ws.uuidString), 0)) IS NULL AS held").run()
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
        let (owner, project, snag, activation, token, photo) = try await fixture(photo: true)
        let ws = try await workspace(project)
        // Read-only: after the shared load, a write in the same transaction is refused by PostgreSQL.
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            try await app.db.transaction { db in
                _ = try await LinkGrantService.load(token, req: req, shared: true, on: db)
                try await VerifiedIdentityService.sql(db).raw("UPDATE link_grants SET revision = revision WHERE id = \(bind: activation.grant.id)").run()
            }
            XCTFail("a write after the shared load must fail")
        } catch { XCTAssertTrue(String(reflecting: error).contains("25006") || String(reflecting: error).lowercased().contains("read-only"), String(reflecting: error)) }
        // The routes still answer (so they issue no write) and download is served.
        let page = try await call(.GET, "api/v2/contractor/\(token)", nil); XCTAssertEqual(page.status, .ok, page.body.string)
        let media = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(photo!)/content"
        let image = try await call(.GET, media, nil); XCTAssertEqual(image.status, .ok)
        // (b) A shared holder elsewhere does not block the read routes (they never take the key exclusively).
        do {
            let holder = hold(true, ws, seconds: 4); try await Task.sleep(nanoseconds: 300_000_000)
            let started = Date()
            let a = try await call(.GET, "api/v2/contractor/\(token)", nil), b = try await call(.GET, media, nil)
            XCTAssertEqual(a.status, .ok); XCTAssertEqual(b.status, .ok)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a read waited for a shared holder")
            try await holder.value
        }
        // (a) An exclusive holder makes a read wait for the 8 s read bound, then 503 workspace_busy with Retry-After.
        do {
            let holder = hold(false, ws, seconds: 11); try await Task.sleep(nanoseconds: 300_000_000)
            let started = Date()
            let busy = try await call(.GET, "api/v2/contractor/\(token)", nil)
            let waited = Date().timeIntervalSince(started)
            XCTAssertEqual(busy.status, .serviceUnavailable, busy.body.string); XCTAssertTrue(busy.body.string.contains("workspace_busy"), busy.body.string)
            XCTAssertNotNil(busy.headers.first(name: "Retry-After")); XCTAssertGreaterThan(waited, 7); XCTAssertLessThan(waited, 10.5)
            try await holder.value
        }
        // (c) Fair queue: with a shared holder, a writer (allocate) waits; a reader arriving after it queues behind it.
        do {
            let holder = hold(true, ws, seconds: 2.5); try await Task.sleep(nanoseconds: 300_000_000)
            let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media"
            let writer = Task { () -> (HTTPStatus, Date) in let r = try await self.call(.POST, path, nil, body: self.command(snag, purpose: "completion", intent: UUID())); return (r.status, Date()) }
            try await Task.sleep(nanoseconds: 500_000_000)
            let reader = Task { () -> (HTTPStatus, Date) in let r = try await self.call(.GET, "api/v2/contractor/\(token)", nil); return (r.status, Date()) }
            let w = try await writer.value, r = try await reader.value
            try await holder.value
            XCTAssertEqual(w.0, .ok); XCTAssertEqual(r.0, .ok)
            XCTAssertLessThanOrEqual(w.1, r.1, "the later reader must not overtake the waiting writer")
        }
        // (d) verifyPIN stays exclusive (it writes failure counters) and its failure counter commits.
        do {
            let (_, pinProject, _, pinActivation, pinToken, _) = try await fixture(pin: "482915")
            let pinWS = try await workspace(pinProject)
            let holder = hold(true, pinWS, seconds: 2); try await Task.sleep(nanoseconds: 300_000_000)
            let started = Date()
            let wrong = try await call(.POST, "api/v2/contractor/\(pinToken)/verify-pin", nil, body: ["pin": "000000"])
            XCTAssertEqual(wrong.status, .forbidden); XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.2, "verifyPIN did not wait for the shared holder")
            try await holder.value
            let failures = try await sql.raw("SELECT pin_failures FROM link_grants WHERE id = \(bind: pinActivation.grant.id)").first()!.decode(column: "pin_failures", as: Int.self)
            XCTAssertEqual(failures, 1)
        }
        // Fallback refuses without upgrading or writing: a project detached from its workspace (corrupted state).
        do {
            try await app.db.transaction { db in
                let s = try VerifiedIdentityService.sql(db)
                try await s.raw("SET LOCAL session_replication_role = replica").run()
                try await s.raw("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: project.project.id)").run()
            }
            let refused = try await call(.GET, "api/v2/contractor/\(token)", nil)
            XCTAssertEqual(refused.status, .gone, refused.body.string); XCTAssertTrue(refused.body.string.contains("link_issuer_inactive"), refused.body.string)
            let stillDetached = try await sql.raw("SELECT workspace_id FROM projects WHERE id = \(bind: project.project.id)").first()!.decode(column: "workspace_id", as: UUID?.self)
            XCTAssertNil(stillDetached, "the shared read path must not attach (write) the project")
            _ = owner
        }
    }
    /// Lane A P0: phase timing is staging-only (RUNTIME_DIAGNOSTICS=enabled) and carries fixed
    /// phase names with durations only — no token, id, key or image fact can appear in it.
    func testServerTimingIsStagingOnlyAndCarriesOnlyPhaseDurations() async throws {
        unsetenv(RuntimeDiagnostics.variable)
        func run() async throws -> [String?] {
            let (_, _, snag, _, token, _) = try await fixture()
            let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media", intent = UUID()
            let allocate = try await call(.POST, path, nil, body: command(snag, purpose: "completion", intent: intent))
            XCTAssertEqual(allocate.status, .ok, allocate.body.string)
            let media = try allocate.content.decode(ContractorGrantController.PhotoResult.self)
            let put = try await call(.PUT, path + "/\(media.id)/content", nil, bytes: Self.png)
            XCTAssertEqual(put.status, .ok, put.body.string)
            let submit = try await call(.POST, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit", nil, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [media.id.uuidString]]))
            XCTAssertEqual(submit.status, .ok, submit.body.string)
            for value in [allocate, put, submit].compactMap({ $0.headers.first(name: "Server-Timing") }) {
                XCTAssertFalse(value.contains(token)); XCTAssertFalse(value.lowercased().contains(media.id.uuidString.lowercased()))
                XCTAssertFalse(value.lowercased().contains(snag.snag.id.uuidString.lowercased()))
            }
            return [allocate, put, submit].map { $0.headers.first(name: "Server-Timing") }
        }
        let off = try await run()
        XCTAssertEqual(off.compactMap { $0 }, [], "no Server-Timing unless RUNTIME_DIAGNOSTICS is enabled")
        setenv(RuntimeDiagnostics.variable, "enabled", 1); defer { unsetenv(RuntimeDiagnostics.variable) }
        let on = try await run()
        // WP2 profiling adds the request's SQL statement count as `sql;desc="N"` — a number, nothing else.
        let shape = try NSRegularExpression(pattern: "^[a-z_]+(;dur=[0-9]+\\.[0-9])?(;desc=\"[0-9]+\")?(, [a-z_]+(;dur=[0-9]+\\.[0-9])?(;desc=\"[0-9]+\")?)*$")
        let allowed: Set<String> = ["allocate", "submit", "auth", "queue", "process", "lock", "lock_auth", "lock_intent_original", "lock_intent_rendition", "lock_ready", "intent_original", "put_original", "intent_rendition", "put_rendition", "ready", "item", "replay", "execute", "record", "sql", "total", "cold"]
        for value in on {
            let value = try XCTUnwrap(value)
            XCTAssertNotNil(shape.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), value)
            let names = Set(value.components(separatedBy: ", ").map { String($0.split(separator: ";")[0]) })
            XCTAssertTrue(names.isSubset(of: allowed), value); XCTAssertTrue(names.contains("total"), value)
        }
        XCTAssertTrue(on[0]!.hasPrefix("allocate;dur=") || on[0]!.hasPrefix("lock;dur="), on[0]!); XCTAssertTrue(on[0]!.contains("lock;dur="), on[0]!)
        for phase in ["auth", "process", "intent_original", "put_original", "intent_rendition", "put_rendition", "ready", "lock_auth", "lock_intent_original", "lock_intent_rendition", "lock_ready"] {
            XCTAssertTrue(on[1]!.contains(phase + ";dur="), "\(phase) missing from \(on[1]!)")
        }
        XCTAssertTrue(on[2]!.contains("submit;dur="), on[2]!); XCTAssertTrue(on[2]!.contains("lock;dur="), on[2]!)
        for phase in ["item", "replay", "execute", "record"] { XCTAssertTrue(on[2]!.contains(phase + ";dur="), "\(phase) missing from \(on[2]!)") }
        XCTAssertTrue(on[2]!.contains("sql;desc=\""), "statement count missing from \(on[2]!)")
    }
    // MARK: - Lane A WP2: the batched submission against the per-row reference (Fable §3.3)

    /// One workflow command, run as the Contractor-link route runs it (exclusive workspace lock first) through either
    /// the batched path or the per-row reference, in a transaction of its own. Everything the command wrote is read
    /// back inside that transaction — timestamps and freshly drawn decision ids masked — and the transaction is then
    /// rolled back, so the next run starts from exactly the same state. The statements are counted through a
    /// `StatementCountingDatabase` over the transaction; only the first words of each are kept, never a bound value.
    private struct WorkflowRun: Equatable {
        var outcome: String; var changes: [String] = []; var groups = 0; var evidence: [String] = []; var media: [String] = []
        var attempts: [String] = []; var outbox: [String] = []; var activity: [String] = []; var snag = ""
    }
    private struct CapturedRun: Error { let run: WorkflowRun; let statements: [String] }
    private final class StatementSink: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ sql: String) { lock.lock(); lines.append(sql.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")); lock.unlock() }
        func reset() { lock.lock(); lines = []; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    private static func masked(_ text: String, decisions: [UUID]) -> String {
        var value = text.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}(:\d{2})?)?"#, with: "<time>", options: .regularExpression)
        for (index, id) in decisions.enumerated() {
            value = value.replacingOccurrences(of: id.uuidString, with: "<decision-\(index)>").replacingOccurrences(of: id.uuidString.lowercased(), with: "<decision-\(index)>")
        }
        return value
    }
    private static func describe(_ error: any Error) -> String {
        if let abort = error as? any AbortError { return "refused \(abort.status.code) \(abort.reason) \((abort as? any DebuggableError)?.identifier ?? "")" }
        return "error \(String(reflecting: type(of: error)))"
    }
    private func capture(reference: Bool, action: WorkflowAction, snagID: UUID, projectID: UUID, actorID: UUID?, grantID: UUID?,
                         actions: Set<ProjectAccessPolicy.Action>, prepare: (@Sendable (Database) async throws -> Void)? = nil,
                         command: @escaping @Sendable (Snag) -> WorkflowCommand) async throws -> (WorkflowRun, [String]) {
        let sink = StatementSink()
        do {
            try await app.db.transaction { tx in
                let sql = try VerifiedIdentityService.sql(tx)
                guard let project = try await Project.find(projectID, on: tx), let snag = try await Snag.find(snagID, on: tx) else { throw Abort(.notFound) }
                let workspaceID = project.workspaceId!
                try await WorkspaceAccessService.lock(workspaceID, on: tx)
                if let prepare { try await prepare(tx) }
                let before = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: workspaceID)").first()!.decode(column: "change_sequence", as: Int64.self)
                let body = command(snag)
                let counted = StatementCountingDatabase.wrap(tx) { sink.add($0) }
                var run: WorkflowRun
                do {
                    let response = reference
                        ? try await PerRowWorkflowReference.execute(body, action: action, snag: snag, project: project, actorID: actorID, grantID: grantID, actions: actions, on: counted)
                        : try await CanonicalWorkflowService.execute(body, action: action, snag: snag, project: project, actorID: actorID, grantID: grantID, actions: actions, on: counted)
                    run = .init(outcome: try PlatformMutationService.encode(response))
                } catch {
                    throw CapturedRun(run: .init(outcome: Self.describe(error)), statements: sink.all)
                }
                let statements = sink.all
                func lines(_ query: SQLQueryString) async throws -> [String] {
                    try await sql.raw(SQLQueryString("SELECT row_to_json(t)::text AS line FROM (") + query + SQLQueryString(") t")).all().map { try $0.decode(column: "line", as: String.self) }
                }
                let decisions = try await sql.raw("SELECT id FROM review_decisions WHERE snag_id = \(bind: snagID) ORDER BY kind").all().map { try $0.decode(column: "id", as: UUID.self) }
                run.changes = try await lines("SELECT sequence, project_id, entity_type, entity_id, revision, kind, changed_fields, payload_json, actor_id, actor_grant_id FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND sequence > \(bind: before) ORDER BY sequence")
                run.groups = try await sql.raw("SELECT count(DISTINCT transaction_group) AS n FROM platform_changes WHERE workspace_id = \(bind: workspaceID) AND sequence > \(bind: before)").first()!.decode(column: "n", as: Int.self)
                run.evidence = try await lines("SELECT attempt_id, asset_id, snag_id, project_id, position FROM completion_evidence WHERE snag_id = \(bind: snagID) ORDER BY attempt_id, position")
                run.media = try await lines("SELECT id, state, revision, attached_at IS NOT NULL AS attached FROM media_assets WHERE snag_id = \(bind: snagID) ORDER BY id")
                run.attempts = try await lines("SELECT id, attempt_number, actor_id, actor_grant_id, actor_kind, notes, state, revision FROM completion_attempts WHERE snag_id = \(bind: snagID) ORDER BY attempt_number")
                run.outbox = try await lines("SELECT workspace_id, project_id, snag_id, actor_id, actor_grant_id, event_kind, payload_json, dedupe_key FROM workflow_outbox WHERE snag_id = \(bind: snagID) ORDER BY dedupe_key")
                run.activity = try await lines("SELECT workspace_id, actor_user_id, actor_grant_id, action, target_id, detail FROM workspace_activity WHERE workspace_id = \(bind: workspaceID) AND target_id = \(bind: snagID) ORDER BY created_at, action")
                run.snag = try await lines("SELECT status, revision, workflow_revision, closed_at IS NOT NULL AS closed, workflow_qualification FROM snags WHERE id = \(bind: snagID)").joined()
                run.outcome = Self.masked(run.outcome, decisions: decisions); run.changes = run.changes.map { Self.masked($0, decisions: decisions) }
                run.outbox = run.outbox.map { Self.masked($0, decisions: decisions) }
                throw CapturedRun(run: run, statements: statements)
            }
            XCTFail("a captured run always rolls back"); throw Abort(.internalServerError)
        } catch let captured as CapturedRun { return (captured.run, captured.statements) }
    }
    private func entityTypes(_ run: WorkflowRun) -> [String] {
        run.changes.compactMap { line in (try? JSONSerialization.jsonObject(with: Data(line.utf8))).flatMap { ($0 as? [String: Any])?["entity_type"] as? String } }
    }
    private func profile(_ label: String, _ statements: [String]) -> String {
        var counts: [(String, Int)] = []
        for statement in statements { if let index = counts.firstIndex(where: { $0.0 == statement }) { counts[index].1 += 1 } else { counts.append((statement, 1)) } }
        return "WP2-PROFILE \(label) statements=\(statements.count): " + counts.map { "\($0.0) x\($0.1)" }.joined(separator: " | ")
    }
    private func contractorAllocated(_ token: String, _ snag: PlatformSnagResponse, intent: UUID) async throws -> UUID {
        let result = try await call(.POST, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media", nil, body: command(snag, purpose: "completion", intent: intent))
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(ContractorGrantController.PhotoResult.self).id
    }
    private func submission(_ operation: MutationMetadata, attempt: UUID, evidence: [UUID], notes: String? = "Resealed and tested on site",
                            reason: String? = nil, waiver: String? = nil) -> @Sendable (Snag) -> WorkflowCommand {
        { snag in .init(mutation: operation, expectedRevision: snag.revision, expectedWorkflowRevision: snag.workflowRevision, attemptId: attempt,
                        expectedAttemptRevision: nil, notes: notes, reason: reason, evidenceIds: evidence, waiverReason: waiver) }
    }

    /// Lane A WP2 golden test (Fable §3.3): for 1, 3, 5 and 20 Contractor-link photos, and for the internal submit,
    /// internal fix and waiver paths, the batched path writes exactly what the per-row reference writes — the same
    /// response, the same `platform_changes` rows at the same sequences in one change group (media in evidence order,
    /// then decisions, the snag and the completionAttempt), the same evidence positions, media revisions, attempt,
    /// snag, activity and outbox rows. The batched statement count does not grow with the number of photos.
    func testBatchedSubmissionWritesExactlyWhatThePerRowReferenceWrites() async throws {
        var batchedCounts: [Int: Int] = [:]
        for count in [1, 3, 5, 20] {
            let (_, project, snag, activation, token, _) = try await fixture()
            let attempt = UUID(), operation = MutationMetadata(operationId: UUID(), deviceId: UUID())
            var ids: [UUID] = []
            for _ in 0..<count { ids.append(try await contractorAfter(token, snag, intent: attempt)) }
            let make = submission(operation, attempt: attempt, evidence: ids)
            let (reference, perRow) = try await capture(reference: true, action: .submit, snagID: snag.snag.id, projectID: project.project.id, actorID: nil, grantID: activation.grant.id, actions: [.submitCompletion], command: make)
            let (batched, batchedSQL) = try await capture(reference: false, action: .submit, snagID: snag.snag.id, projectID: project.project.id, actorID: nil, grantID: activation.grant.id, actions: [.submitCompletion], command: make)
            XCTAssertFalse(reference.outcome.hasPrefix("refused"), reference.outcome)
            XCTAssertEqual(batched, reference, "\(count) Contractor-link photos")
            XCTAssertEqual(entityTypes(batched), Array(repeating: "media", count: count) + ["snag", "completionAttempt"])
            XCTAssertEqual(batched.groups, 1); XCTAssertEqual(batched.evidence.count, count); XCTAssertEqual(batched.outbox.count, 1)
            batchedCounts[count] = batchedSQL.count
            print("WP2-PROFILE contractor submit photos=\(count) per-row=\(perRow.count) batched=\(batchedSQL.count)")
            if count == 3 { print(profile("per-row 3 photos", perRow)); print(profile("batched 3 photos", batchedSQL)) }
            XCTAssertLessThan(batchedSQL.count, perRow.count)
        }
        XCTAssertEqual(Set(batchedCounts.values).count, 1, "flat in the number of photos: \(batchedCounts)")
        XCTAssertLessThanOrEqual(batchedCounts[3] ?? 99, 20, "execute's own statements for three photos: \(batchedCounts)")

        // The internal paths share createAttempt and the change batch: submit, internal fix (a decision between the
        // media rows and the snag), and a reasoned waiver (no evidence; the decision comes first).
        for path in ["submit", "internal-fix", "waiver"] {
            let (owner, project, snag, _, _, _) = try await fixture()
            let attempt = UUID(), operation = MutationMetadata(operationId: UUID(), deviceId: UUID())
            var ids: [UUID] = []
            if path != "waiver" { for _ in 0..<3 { ids.append(try await after(owner, project: project, snag: snag, intent: attempt)) } }
            let action: WorkflowAction = path == "internal-fix" ? .internalFix : .submit
            let make = submission(operation, attempt: attempt, evidence: ids, reason: path == "internal-fix" ? "Fixed by our own team" : nil,
                                  waiver: path == "waiver" ? "The area was boarded over before a photo could be taken" : nil)
            let actor = try owner.requireID()
            let (reference, _) = try await capture(reference: true, action: action, snagID: snag.snag.id, projectID: project.project.id, actorID: actor, grantID: nil, actions: [.submitCompletion, .review], command: make)
            let (batched, _) = try await capture(reference: false, action: action, snagID: snag.snag.id, projectID: project.project.id, actorID: actor, grantID: nil, actions: [.submitCompletion, .review], command: make)
            XCTAssertFalse(reference.outcome.hasPrefix("refused"), path + ": " + reference.outcome)
            XCTAssertEqual(batched, reference, path)
            let expected: [String] = path == "submit" ? ["media", "media", "media", "snag", "completionAttempt"]
                : path == "internal-fix" ? ["media", "media", "media", "reviewDecision", "snag", "completionAttempt"]
                : ["reviewDecision", "snag", "completionAttempt"]
            XCTAssertEqual(entityTypes(batched), expected, path); XCTAssertEqual(batched.groups, 1, path)
        }
    }

    /// Lane A WP2 (Fable §3.3 refusal order): one read of every evidence row, then the per-photo checks in the order of
    /// `evidenceIds`, refuse exactly as the per-row reads did — the first failing photo decides, with its own answer.
    func testBatchedEvidenceChecksRefuseInTheSameOrderAsThePerRowReference() async throws {
        let (owner, project, snag, activation, token, _) = try await fixture()
        let attempt = UUID(), grant = activation.grant.id
        let ready = [try await contractorAfter(token, snag, intent: attempt), try await contractorAfter(token, snag, intent: attempt)]
        let notReady = try await contractorAllocated(token, snag, intent: attempt)
        let otherIntent = try await contractorAfter(token, snag, intent: UUID())
        let ownersPhoto = try await after(owner, project: project, snag: snag, intent: attempt)
        let missing = UUID()
        func update(_ id: UUID, _ assignment: String) -> @Sendable (Database) async throws -> Void {
            { db in try await VerifiedIdentityService.sql(db).raw("UPDATE media_assets SET \(unsafeRaw: assignment) WHERE id = \(bind: id)").run() }
        }
        let cases: [(String, [UUID], (@Sendable (Database) async throws -> Void)?, String)] = [
            ("a missing photo before one that is not ready", [ready[0], missing, notReady], nil, "refused 404 Photo unavailable"),
            ("another uploader's photo before a missing one", [ownersPhoto, ready[0], missing], nil, "refused 404 Upload unavailable"),
            ("a photo that is not ready", [ready[0], notReady, missing], nil, "refused 422 Use processed after photos"),
            ("a photo for another completion intention", [ready[0], otherIntent], nil, "refused 422 Use processed after photos"),
            ("a photo already attached", [ready[0], ready[1]], update(ready[1], "attached_at = now()"), "refused 422 Use processed after photos"),
            ("an expired unattached photo", [ready[0], ready[1]], update(ready[1], "expires_at = now() - interval '1 minute'"), "refused 410 This unattached upload expired"),
            ("a duplicate photo", [ready[0], ready[0]], nil, "refused 400 Choose up to 20 distinct after photos"),
        ]
        for (label, ids, prepare, expected) in cases {
            let make = submission(MutationMetadata(operationId: UUID(), deviceId: UUID()), attempt: attempt, evidence: ids)
            let (reference, _) = try await capture(reference: true, action: .submit, snagID: snag.snag.id, projectID: project.project.id, actorID: nil, grantID: grant, actions: [.submitCompletion], prepare: prepare, command: make)
            let (batched, _) = try await capture(reference: false, action: .submit, snagID: snag.snag.id, projectID: project.project.id, actorID: nil, grantID: grant, actions: [.submitCompletion], prepare: prepare, command: make)
            XCTAssertEqual(batched.outcome, reference.outcome, label)
            XCTAssertTrue(batched.outcome.hasPrefix(expected), label + ": " + batched.outcome)
        }
    }

    /// Lane A WP2 (Fable §3.3 change-group bound): each per-row change requires fewer than 1,000 rows in the command's
    /// change group before it, so 20 photos (22 rows) fit after 978 existing rows and not after 979 — on both paths,
    /// with the same 413 and nothing kept.
    func testTheChangeGroupBoundIsExactlyThePerRowOne() async throws {
        let (_, project, snag, activation, token, _) = try await fixture()
        let attempt = UUID(), operation = MutationMetadata(operationId: UUID(), deviceId: UUID())
        var ids: [UUID] = []
        for _ in 0..<20 { ids.append(try await contractorAfter(token, snag, intent: attempt)) }
        let workspaceID = project.workspaceId, projectID = project.project.id, snagID = snag.snag.id, grantID = activation.grant.id
        for (existing, fits) in [(978, true), (979, false)] {
            let prepare: @Sendable (Database) async throws -> Void = { db in
                let sql = try VerifiedIdentityService.sql(db), group = UUID()
                _ = try await sql.raw("SELECT set_config('snaglist.change_group', \(bind: group.uuidString), true)").first()
                try await sql.raw("""
                    INSERT INTO platform_changes (workspace_id, sequence, project_id, entity_type, entity_id, revision, kind, changed_fields, payload_json, actor_id, actor_grant_id, created_at, transaction_group)
                    SELECT \(bind: workspaceID), 1000000 + g, \(bind: projectID), 'snag', \(bind: snagID), 1, 'synthetic_bound', ARRAY[]::text[], '{}', NULL, \(bind: grantID), now(), \(bind: group)
                    FROM generate_series(1, \(bind: existing)) AS g
                    """).run()
            }
            let make = submission(operation, attempt: attempt, evidence: ids)
            let (reference, _) = try await capture(reference: true, action: .submit, snagID: snagID, projectID: projectID, actorID: nil, grantID: activation.grant.id, actions: [.submitCompletion], prepare: prepare, command: make)
            let (batched, _) = try await capture(reference: false, action: .submit, snagID: snagID, projectID: projectID, actorID: nil, grantID: activation.grant.id, actions: [.submitCompletion], prepare: prepare, command: make)
            XCTAssertEqual(batched, reference, "\(existing) existing rows")
            if fits { XCTAssertFalse(batched.outcome.hasPrefix("refused"), batched.outcome) }
            else { XCTAssertTrue(batched.outcome.hasPrefix("refused 413") && batched.outcome.hasSuffix("change_group_too_large"), batched.outcome) }
        }
    }

    /// Lane A WP2 (Fable §3.3 replay and concurrency), through the Contractor-link route: the same request twice is
    /// answered from the receipt with one attempt and one set of evidence; a changed body under the same operation is
    /// 409 `operation_reused`; a manager's edit between upload and submit is 409 `revision_conflict`; a second
    /// submission against the old revisions is a 409 conflict.
    func testBatchedSubmissionReplaysRefusesReuseAndConflictsAsBefore() async throws {
        let (owner, project, snag, _, token, _) = try await fixture()
        let attempt = UUID()
        var ids: [UUID] = []
        for _ in 0..<3 { ids.append(try await contractorAfter(token, snag, intent: attempt)) }
        let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit"
        let body = action(snag, extra: ["attemptId": attempt.uuidString, "evidenceIds": ids.map(\.uuidString), "notes": "Resealed and tested on site"])
        let first = try await call(.POST, path, nil, body: body)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let again = try await call(.POST, path, nil, body: body)
        XCTAssertEqual(again.status, .ok, again.body.string)
        // The receipt's answer is the same value (the live encoder does not sort keys, so compare decoded objects).
        let firstObject = try JSONSerialization.jsonObject(with: Data(first.body.string.utf8)) as? NSDictionary
        let againObject = try JSONSerialization.jsonObject(with: Data(again.body.string.utf8)) as? NSDictionary
        XCTAssertNotNil(firstObject); XCTAssertEqual(againObject, firstObject)
        let sql = try VerifiedIdentityService.sql(app.db)
        func count(_ query: SQLQueryString) async throws -> Int { try await sql.raw(query).first()!.decode(column: "n", as: Int.self) }
        let attempts = try await count("SELECT count(*) AS n FROM completion_attempts WHERE snag_id = \(bind: snag.snag.id)")
        let evidence = try await count("SELECT count(*) AS n FROM completion_evidence WHERE snag_id = \(bind: snag.snag.id)")
        let outbox = try await count("SELECT count(*) AS n FROM workflow_outbox WHERE snag_id = \(bind: snag.snag.id)")
        let attemptChanges = try await count("SELECT count(*) AS n FROM platform_changes WHERE entity_type = 'completionAttempt' AND entity_id = \(bind: attempt)")
        XCTAssertEqual([attempts, evidence, outbox, attemptChanges], [1, 3, 1, 1])
        var changed = body; changed["notes"] = "Different words under the same operation"
        let reused = try await call(.POST, path, nil, body: changed)
        XCTAssertEqual(reused.status, .conflict, reused.body.string); XCTAssertTrue(reused.body.string.contains("operation_reused"), reused.body.string)
        let stale = try await call(.POST, path, nil, body: action(snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": [ids[0].uuidString]]))
        XCTAssertEqual(stale.status, .conflict, stale.body.string)

        // A manager edits the snag after the contractor uploaded and before they submit.
        let (owner2, project2, snag2, _, token2, _) = try await fixture()
        let attempt2 = UUID(), photo = try await contractorAfter(token2, snag2, intent: attempt2)
        let edit = try await call(.PATCH, "api/v2/projects/\(project2.project.id)/snags/\(snag2.snag.id)", owner2, body: ["mutation": meta(), "expectedRevision": snag2.revision, "fields": ["title": "Seal shower tray and regrout"]])
        XCTAssertEqual(edit.status, .ok, edit.body.string)
        let late = try await call(.POST, "api/v2/contractor/\(token2)/snags/\(snag2.snag.id)/workflow/submit", nil, body: action(snag2, extra: ["attemptId": attempt2.uuidString, "evidenceIds": [photo.uuidString]]))
        XCTAssertEqual(late.status, .conflict, late.body.string); XCTAssertTrue(late.body.string.contains("revision_conflict"), late.body.string)
        _ = owner; _ = project
    }
    // MARK: - Lane A WP4 (server): retiring unattached uploads, drafts on the page, the hourly retire + fence

    private var memoryStore: InMemoryPrivateContentStore { app.storage[PrivateContentStoreProvider.InjectionKey.self] as! InMemoryPrivateContentStore }
    private func pageItem(_ token: String, _ snagID: UUID) async throws -> ContractorItem {
        let response = try await call(.GET, "api/v2/contractor/\(token)", nil, contractorHeader: false)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try XCTUnwrap(try response.content.decode(ContractorPage.self).items.first { $0.id == snagID })
    }
    private func retirements(_ assetID: UUID) async throws -> [String] {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT role || ':' || state AS line FROM upload_retirements WHERE asset_id = \(bind: assetID) ORDER BY role").all().map { try $0.decode(column: "line", as: String.self) }
    }
    private func mediaState(_ assetID: UUID) async throws -> (String, Bool) {
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state, retired_at IS NOT NULL AS retired FROM media_assets WHERE id = \(bind: assetID)").first()!
        return (try row.decode(column: "state", as: String.self), try row.decode(column: "retired", as: Bool.self))
    }

    /// WP4 §4.4: the link retires its own unattached upload (ready or only allocated); a repeat answers 200; every later
    /// PUT or attachment of it is refused 410 inside its own authorisation; an attached photo is 409; someone else's upload
    /// is 404; the page's `drafts` lists exactly this link's unattached, unretired uploads (§4.6).
    func testTheLinkRetiresItsOwnUnattachedUploadsAndNothingCanUseThemAfterwards() async throws {
        let (owner, project, snag, _, token, _) = try await fixture()
        let attempt = UUID()
        let ready = try await contractorAfter(token, snag, intent: attempt)
        let allocated = try await contractorAllocated(token, snag, intent: attempt)
        let kept = try await contractorAfter(token, snag, intent: attempt)
        let ownersDraft = try await after(owner, project: project, snag: snag, intent: UUID())
        let before = try await pageItem(token, snag.snag.id)
        XCTAssertEqual(Set(before.drafts.map(\.id)), [ready, allocated, kept], "own drafts only, never the manager's")
        XCTAssertEqual(before.drafts.first { $0.id == ready }?.state, "ready"); XCTAssertEqual(before.drafts.first { $0.id == allocated }?.state, "allocated")

        let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media"
        let unheadered = try await call(.DELETE, path + "/\(ready)", nil, contractorHeader: false)
        XCTAssertEqual(unheadered.status, .forbidden, unheadered.body.string)
        for _ in 0..<2 {
            let retired = try await call(.DELETE, path + "/\(ready)", nil)
            XCTAssertEqual(retired.status, .ok, retired.body.string); XCTAssertTrue(retired.body.string.contains("\"retired\""), retired.body.string)
        }
        let (state, stamped) = try await mediaState(ready)
        XCTAssertEqual(state, "retired"); XCTAssertTrue(stamped)
        let queued = try await retirements(ready)
        XCTAssertEqual(queued, ["original:pending", "rendition:pending"], "a ready upload queues both of its keys for the fence")
        let retiredAllocation = try await call(.DELETE, path + "/\(allocated)", nil)
        XCTAssertEqual(retiredAllocation.status, .ok, retiredAllocation.body.string)
        let none = try await retirements(allocated)
        XCTAssertEqual(none, [], "an allocation that never received bytes has no key to fence")
        let foreign = try await call(.DELETE, path + "/\(ownersDraft)", nil)
        XCTAssertEqual(foreign.status, .notFound, foreign.body.string)

        let reupload = try await call(.PUT, path + "/\(ready)/content", nil, bytes: Self.png)
        XCTAssertEqual(reupload.status, .gone, reupload.body.string); XCTAssertTrue(reupload.body.string.contains("retired"), reupload.body.string)
        let workflow = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit"
        let withRetired = try await call(.POST, workflow, nil, body: action(snag, extra: ["attemptId": attempt.uuidString, "evidenceIds": [kept.uuidString, ready.uuidString]]))
        XCTAssertEqual(withRetired.status, .gone, withRetired.body.string)

        let afterRetire = try await pageItem(token, snag.snag.id)
        XCTAssertEqual(afterRetire.drafts.map(\.id), [kept])
        let submitted = try await call(.POST, workflow, nil, body: action(snag, extra: ["attemptId": attempt.uuidString, "evidenceIds": [kept.uuidString]]))
        XCTAssertEqual(submitted.status, .ok, submitted.body.string)
        let attached = try await call(.DELETE, path + "/\(kept)", nil)
        XCTAssertEqual(attached.status, .conflict, attached.body.string); XCTAssertTrue(attached.body.string.contains("media_attached"), attached.body.string)
        let finished = try await pageItem(token, snag.snag.id)
        XCTAssertEqual(finished.drafts.map(\.id), [], "an attached photo is no longer a draft")
        let managerList = try await call(.GET, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media", owner)
        XCTAssertEqual(managerList.status, .ok, managerList.body.string)
        XCTAssertFalse(managerList.body.string.lowercased().contains(ready.uuidString.lowercased()), "a retired upload is not listed")
        XCTAssertFalse(managerList.body.string.lowercased().contains(allocated.uuidString.lowercased()))
    }

    /// WP4 §4.3: a link's drafts (allocated and ready) stay invisible to the manager's list and get, to another link on the
    /// project, and to the change feed, until a submission attaches them.
    func testDraftsStayPrivateToTheirLinkUntilAttached() async throws {
        let (owner, project, snag, _, token, _) = try await fixture()
        let attempt = UUID()
        let ready = try await contractorAfter(token, snag, intent: attempt)
        let allocated = try await contractorAllocated(token, snag, intent: attempt)
        let managerList = try await call(.GET, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media", owner)
        XCTAssertEqual(managerList.status, .ok, managerList.body.string)
        for id in [ready, allocated] {
            XCTAssertFalse(managerList.body.string.lowercased().contains(id.uuidString.lowercased()), "manager list")
            let get = try await call(.GET, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)/media/\(id)", owner)
            XCTAssertNotEqual(get.status, .ok, "manager get: " + get.body.string)
        }
        let changes = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM platform_changes WHERE entity_id = ANY(\(bind: [ready, allocated])::UUID[])").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(changes, 0, "no change row before attachment")
        // A second link on the same project sees nothing of the first link's drafts.
        let other = try await logged(owner, project)
        let contractor2 = try await contractor(owner, project)
        let assigned = try await assign(owner, project, other, contractor2)
        let (_, token2) = try await activate(owner, project, try await prepared(owner, project, snags: [assigned.snag.id], contractor: contractor2))
        let otherPage = try await call(.GET, "api/v2/contractor/\(token2)", nil, contractorHeader: false)
        XCTAssertEqual(otherPage.status, .ok, otherPage.body.string)
        for id in [ready, allocated] { XCTAssertFalse(otherPage.body.string.lowercased().contains(id.uuidString.lowercased()), "another link's page") }
        let download = try await call(.GET, "api/v2/contractor/\(token2)/snags/\(snag.snag.id)/media/\(ready)/content", nil, contractorHeader: false)
        XCTAssertNotEqual(download.status, .ok, "another link cannot download a draft")
    }

    /// WP4 §4.5: the hourly pass retires unattached uploads 7 days past expiry (leaving one with an `active` write intent
    /// for the next pass), then fences their keys with the same zero-byte erasure object account deletion writes. A
    /// fence that fails stays pending and is completed by a later pass; without a store nothing is written.
    func testTheHourlyPassRetiresAbandonedUploadsAndFencesTheirKeys() async throws {
        let (_, _, snag, _, token, _) = try await fixture()
        let attempt = UUID()
        let abandoned = try await contractorAfter(token, snag, intent: attempt)
        let fresh = try await contractorAfter(token, snag, intent: attempt)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE media_assets SET expires_at = now() - interval '8 days' WHERE id = \(bind: abandoned)").run()
        let keys = try await sql.raw("SELECT original_key, rendition_key FROM media_assets WHERE id = \(bind: abandoned)").first()!
        let original = try keys.decode(column: "original_key", as: String.self), rendition = try keys.decode(column: "rendition_key", as: String.self)
        let hadBytes = await memoryStore.object(at: original) != nil
        XCTAssertTrue(hadBytes)

        // The first pass runs while another upload's write is in flight (its intent is `active`): inside that upload's
        // readback, the upload is made 8 days expired and the pass runs, with a fence store that fails every write.
        final class Box: @unchecked Sendable { var counts: RetentionMaintenanceService.Counts?; var inFlightState: String? }
        let box = Box(), db = app.db, failing = FailingFenceStore(target: memoryStore.target)
        let inFlight = try await contractorAllocated(token, snag, intent: attempt)
        await memoryStore.failNextPut()
        await memoryStore.afterNextRead {
            let hookSQL = db as! SQLDatabase
            try await hookSQL.raw("UPDATE media_assets SET expires_at = now() - interval '8 days' WHERE id = \(bind: inFlight)").run()
            box.counts = try await RetentionMaintenanceService.run(on: db, fenceStore: failing)
            box.inFlightState = try await hookSQL.raw("SELECT state FROM media_assets WHERE id = \(bind: inFlight)").first()?.decode(column: "state", as: String.self)
        }
        let late = try await call(.PUT, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(inFlight)/content", nil, bytes: Self.png)
        XCTAssertEqual(late.status, .gone, "the expired upload is not retried: " + late.body.string)
        let first = try XCTUnwrap(box.counts)
        XCTAssertEqual(first.failed, [])
        XCTAssertGreaterThanOrEqual(first.uploadsRetired ?? 0, 1); XCTAssertGreaterThanOrEqual(first.uploadRetirementsDeferred ?? 0, 1)
        XCTAssertEqual(box.inFlightState, "allocated", "an active write intent defers retirement")
        let states = [try await mediaState(abandoned).0, try await mediaState(fresh).0]
        XCTAssertEqual(states, ["retired", "ready"], "retired; an unexpired upload is untouched")
        let pendingAfterFailure = try await retirements(abandoned)
        XCTAssertEqual(pendingAfterFailure, ["original:pending", "rendition:pending"], "a failed fence stays pending")
        let attempts = try await sql.raw("SELECT min(attempts) AS n FROM upload_retirements WHERE asset_id = \(bind: abandoned)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(attempts, 1)

        let unconfigured = try await RetentionMaintenanceService.run(on: app.db)
        XCTAssertEqual(unconfigured.uploadFencesWritten, 0); XCTAssertGreaterThanOrEqual(unconfigured.uploadFencesPending ?? 0, 2)

        let second = try await RetentionMaintenanceService.run(on: app.db, fenceStore: memoryStore)
        XCTAssertEqual(second.failed, []); XCTAssertGreaterThanOrEqual(second.uploadFencesWritten ?? 0, 2)
        let fencedRows = try await retirements(abandoned)
        XCTAssertEqual(fencedRows, ["original:fenced", "rendition:fenced"])
        let fencedOriginal = await memoryStore.isFenced(original), fencedRendition = await memoryStore.isFenced(rendition)
        XCTAssertTrue(fencedOriginal); XCTAssertTrue(fencedRendition)
        // A late PUT of the retired upload is refused before it can write anything.
        let retiredPut = try await call(.PUT, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(abandoned)/content", nil, bytes: Self.png)
        XCTAssertEqual(retiredPut.status, .gone, retiredPut.body.string)
        let stillFenced = await memoryStore.isFenced(original)
        XCTAssertTrue(stillFenced)
    }

    func testPINProtectsReadWorkflowAllocateUploadAndDownloadAndLocksGuesses() async throws {
        let (_, project, snag, activation, token, photo) = try await fixture(pin: "618294", photo: true)
        let root = "api/v2/contractor/\(token)", media = root + "/snags/\(snag.snag.id)/media"
        for (method, path, body) in [(HTTPMethod.GET, root, [:]), (.POST, root + "/snags/\(snag.snag.id)/workflow/start", action(snag)), (.POST, media, command(snag, purpose: "completion", intent: UUID())), (.GET, media + "/\(photo!)/content", [:])] {
            let result = try await call(method, path, nil, body: body); XCTAssertEqual(result.status, .forbidden, result.body.string)
        }
        let put = try await call(.PUT, media + "/\(photo!)/content", nil, bytes: Self.png); XCTAssertEqual(put.status, .forbidden)
        for n in 1...5 {
            let wrong = try await call(.POST, root + "/verify-pin", nil, body: ["pin": "000000"])
            XCTAssertEqual(wrong.status, n == 5 ? .tooManyRequests : .forbidden)
        }
        let locked = try await call(.POST, root + "/verify-pin", nil, body: ["pin": "618294"]); XCTAssertEqual(locked.status, .tooManyRequests)
        let sql = try VerifiedIdentityService.sql(app.db), id = activation.grant.id
        let failures = try await sql.raw("SELECT pin_failures FROM link_grants WHERE id = \(bind: id)").first()!.decode(column: "pin_failures", as: Int.self); XCTAssertEqual(failures, 5)
        try await sql.raw("UPDATE link_grants SET pin_locked_until = \(bind: Date().addingTimeInterval(-1)) WHERE id = \(bind: id)").run()
        let cookie = try await verify(token, pin: "618294")
        let read = try await call(.GET, root, nil, cookie: cookie); XCTAssertEqual(read.status, .ok)
        XCTAssertEqual(try read.content.decode(ContractorPage.self).items.count, 1)
        let download = try await call(.GET, media + "/\(photo!)/content", nil, cookie: cookie); XCTAssertEqual(download.status, .ok)
        XCTAssertEqual(download.headers.first(name: .contentType), "image/jpeg"); XCTAssertFalse(download.body.string.contains("PRIVATE_LOCATION_TEST_MARKER"))
        let crossOrigin = try await call(.POST, root + "/verify-pin", nil, body: ["pin": "618294"], origin: "https://unrelated.example.test"); XCTAssertEqual(crossOrigin.status, .forbidden)
        let noHeader = try await call(.POST, root + "/verify-pin", nil, body: ["pin": "618294"], contractorHeader: false); XCTAssertEqual(noHeader.status, .forbidden)
        try await sql.raw("UPDATE link_sessions SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE grant_id = \(bind: id)").run()
        let expiredSession = try await call(.GET, root, nil, cookie: cookie); XCTAssertEqual(expiredSession.status, .forbidden)
        XCTAssertFalse(read.body.string.contains(project.workspaceId.uuidString)); XCTAssertFalse(read.body.string.contains("ownerId"))
    }
    func testVerifiedContractorPINAndGrantTokenCannotReadManagerOriginals() async throws {
        let (_, project, snag, _, token, photo) = try await fixture(pin: "618294", photo: true)
        let asset = try XCTUnwrap(photo), cookie = try await verify(token, pin: "618294")
        let contractorMedia = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(asset)"
        let selected = try await call(.GET, contractorMedia + "/content", nil, cookie: cookie)
        XCTAssertEqual(selected.status, .ok); XCTAssertEqual(selected.headers.contentType?.description, "image/jpeg")
        XCTAssertFalse(selected.body.string.contains("PRIVATE_LOCATION_TEST_MARKER"))
        let nonexistent = try await call(.GET, contractorMedia + "/original", nil, cookie: cookie)
        XCTAssertEqual(nonexistent.status, .notFound)
        let managerOriginal = path(project, snag) + "/\(asset)/original"
        let pinOnly = try await call(.GET, managerOriginal, nil, cookie: cookie)
        XCTAssertEqual(pinOnly.status, .unauthorized)
        try await app.test(.GET, managerOriginal, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.replaceOrAdd(name: .cookie, value: cookie)
            req.headers.replaceOrAdd(name: "X-Snaglist-Contractor", value: "1")
        }, afterResponse: { response async in
            XCTAssertEqual(response.status, .unauthorized)
            XCTAssertFalse(response.body.string.contains("PRIVATE_LOCATION_TEST_MARKER"))
        })
        let page = try await call(.GET, "api/v2/contractor/\(token)", nil, cookie: cookie)
        XCTAssertEqual(page.status, .ok)
        XCTAssertFalse(page.body.string.contains("/original")); XCTAssertFalse(page.body.string.contains("originalSHA256"))
    }
    func testContractorSubmitIsHonestAndAnotherManagerAcceptsWithoutDirectClosure() async throws {
        let (owner, project, snag, activation, token, _) = try await fixture()
        let reviewer = try await user(); try await join(reviewer, owner: owner, project: project, role: "manager")
        let intent = UUID(), asset = try await contractorAfter(token, snag, intent: intent)
        let root = "api/v2/contractor/\(token)", workflow = root + "/snags/\(snag.snag.id)/workflow"
        let body = action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [asset.uuidString], "notes": "Repaired and checked with the foreman"])
        var results: [ContractorWorkflowResult] = []
        try await withThrowingTaskGroup(of: ContractorWorkflowResult.self) { group in
            for _ in 0..<3 { group.addTask {
                let response = try await self.call(.POST, workflow + "/submit", nil, body: body)
                XCTAssertEqual(response.status, .ok, response.body.string); return try response.content.decode(ContractorWorkflowResult.self)
            } }; for try await result in group { results.append(result) }
        }
        XCTAssertEqual(Set(results.map(\.status)), ["awaiting_review"]); XCTAssertEqual(Set(results.compactMap(\.attemptId)), [intent])
        let history = try await call(.GET, workflowPath(project, snag), reviewer)
        let pending = try history.content.decode(CanonicalWorkflowController.History.self)
        XCTAssertEqual(pending.pending?.actorKind, "contractor_link"); XCTAssertEqual(pending.pending?.actorId, activation.grant.id)
        let sql = try VerifiedIdentityService.sql(app.db)
        let row = try await sql.raw("SELECT actor_id, actor_grant_id FROM completion_attempts WHERE id = \(bind: intent)").first()!
        XCTAssertNil(try row.decode(column: "actor_id", as: UUID?.self)); XCTAssertEqual(try row.decode(column: "actor_grant_id", as: UUID.self), activation.grant.id)
        let attempts = try await sql.raw("SELECT count(*) AS n FROM completion_attempts WHERE snag_id = \(bind: snag.snag.id)").first()!.decode(column: "n", as: Int.self); XCTAssertEqual(attempts, 1)
        let forged = try await call(.POST, workflow + "/accept", nil, body: body); XCTAssertEqual(forged.status, .notFound)
        let submitted = WorkflowResponse(snag: pending.snag, attempt: pending.pending, decisions: [])
        let accepted = try await decide(reviewer, project: project, submitted: submitted, kind: "accept")
        XCTAssertEqual(accepted.snag.snag.status, "closed"); XCTAssertEqual(accepted.decisions.first?.actorId, reviewer.id)
        let read = try await call(.GET, root, nil), visible = try read.content.decode(ContractorPage.self)
        XCTAssertEqual(visible.items.first?.status, "closed"); XCTAssertEqual(visible.items.first?.submissions.first?.state, "accepted")
        let source = try await sql.raw("SELECT issuance_json FROM link_grants WHERE id = \(bind: activation.grant.id)").first()!.decode(column: "issuance_json", as: String.self)
        let issued = try PlatformMutationService.decode(ContractorPage.self, source); XCTAssertEqual(issued.items.first?.status, "open")
        let changes = try await sql.raw("SELECT count(*) AS n FROM platform_changes WHERE actor_grant_id = \(bind: activation.grant.id)").first()!.decode(column: "n", as: Int.self); XCTAssertEqual(changes, 3)
        let jobs = try await sql.raw("SELECT count(*) AS n FROM workflow_outbox WHERE actor_grant_id = \(bind: activation.grant.id)").first()!.decode(column: "n", as: Int.self); XCTAssertEqual(jobs, 1)
    }
    func testFixedSelectionsRemainEmptyAfterReassignmentBackAndArchiveRestore() async throws {
        let (owner, project, snag, activation, token, photo) = try await fixture(photo: true)
        let root = "api/v2/contractor/\(token)", contractor = activation.grant.contractorId
        let removed = try await assign(owner, project, snag, nil)
        let restored = try await assign(owner, project, removed, contractor)
        let empty = try await call(.GET, root, nil); XCTAssertEqual(try empty.content.decode(ContractorPage.self).total, 0)
        let media = try await call(.GET, root + "/snags/\(snag.snag.id)/media/\(photo!)/content", nil); XCTAssertEqual(media.status, .notFound)
        let start = try await call(.POST, root + "/snags/\(snag.snag.id)/workflow/start", nil, body: action(restored)); XCTAssertEqual(start.status, .notFound)
        let zero = try await prepared(owner, project, snags: [], mode: "read_only"), (_, zeroToken) = try await activate(owner, project, zero)
        let zeroRead = try await call(.GET, "api/v2/contractor/\(zeroToken)", nil); XCTAssertEqual(try zeroRead.content.decode(ContractorPage.self).total, 0)
        let other = try await logged(owner, project)
        let outside = try await call(.POST, "api/v2/contractor/\(zeroToken)/snags/\(other.snag.id)/workflow/start", nil, body: action(other)); XCTAssertEqual(outside.status, .notFound)
        let next = try await prepared(owner, project, snags: [restored.snag.id], contractor: contractor), (_, nextToken) = try await activate(owner, project, next)
        let archive = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(restored.snag.id)/archive", owner, body: ["mutation": meta(), "expectedRevision": restored.revision, "reason": "Duplicate entry"])
        let archived = try archive.content.decode(PlatformSnagResponse.self)
        let restore = try await call(.POST, "api/v2/projects/\(project.project.id)/snags/\(restored.snag.id)/restore", owner, body: ["mutation": meta(), "expectedRevision": archived.revision, "reason": "Confirmed original item"]); XCTAssertEqual(restore.status, .ok)
        let hidden = try await call(.GET, "api/v2/contractor/\(nextToken)", nil); XCTAssertEqual(try hidden.content.decode(ContractorPage.self).total, 0)
    }
    func testActivationRetriesKeepOneSecretAndAnotherManagerCanRevokeRepeatedly() async throws {
        let (owner, project, _, activation, token, _) = try await fixture(pin: "12345678")
        let manager = try await user(); try await join(manager, owner: owner, project: project, role: "manager")
        let get = try await call(.GET, "api/v2/projects/\(project.project.id)/links/\(activation.grant.id)", manager)
        XCTAssertEqual(try get.content.decode(LinkActivationResponse.self).contractorPath, activation.contractorPath)
        let sql = try VerifiedIdentityService.sql(app.db)
        let stored = try await sql.raw("SELECT token_hash, token_ciphertext, pin_hash FROM link_grants WHERE id = \(bind: activation.grant.id)").first()!
        XCTAssertEqual(try stored.decode(column: "token_hash", as: String.self), SHA256Hasher.hash(token: token))
        XCTAssertFalse(try stored.decode(column: "token_ciphertext", as: String.self).contains(token)); XCTAssertTrue(try stored.decode(column: "pin_hash", as: String.self).hasPrefix("$2"))
        let receiptRows = try await sql.raw("SELECT result_json FROM mutation_receipts WHERE workspace_id = \(bind: project.workspaceId)").all()
        for row in receiptRows { XCTAssertFalse(try row.decode(column: "result_json", as: String.self).contains(token)); XCTAssertFalse(try row.decode(column: "result_json", as: String.self).contains("12345678")) }
        let cookie = try await verify(token, pin: "12345678")
        for _ in 0..<2 {
            let revoke = try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(activation.grant.id)/revoke", manager, body: ["mutation": meta(), "expectedRevision": activation.grant.revision])
            XCTAssertEqual(revoke.status, .ok); XCTAssertEqual(try revoke.content.decode(LinkGrantResponse.self).state, "revoked")
        }
        let blocked = try await call(.GET, "api/v2/contractor/\(token)", nil, cookie: cookie); XCTAssertEqual(blocked.status, .gone)
        let after = try await call(.GET, "api/v2/projects/\(project.project.id)/links/\(activation.grant.id)", manager); XCTAssertNil(try after.content.decode(LinkActivationResponse.self).contractorPath)
    }
    func testPreviewReadOnlyAndCrossScopeMediaCannotSubmitOrLeak() async throws {
        let (owner, project, snag, activation, token, _) = try await fixture()
        for mode in ["preview", "read_only"] {
            let prepared = try await prepared(owner, project, snags: [snag.snag.id], mode: mode), (_, otherToken) = try await activate(owner, project, prepared)
            let path = "api/v2/contractor/\(otherToken)/snags/\(snag.snag.id)"
            let start = try await call(.POST, path + "/workflow/start", nil, body: action(snag)); XCTAssertEqual(start.status, .forbidden)
            let upload = try await call(.POST, path + "/media", nil, body: command(snag, purpose: "completion", intent: UUID())); XCTAssertEqual(upload.status, .forbidden)
        }
        let otherProject = try await self.project(owner), foreign = try await logged(owner, otherProject)
        let bad = try await call(.POST, "api/v2/projects/\(project.project.id)/links/prepare", owner, body: ["mutation": meta(), "id": UUID().uuidString, "mode": "read_only", "snagIds": [foreign.snag.id.uuidString], "assetIds": []]); XCTAssertEqual(bad.status, .notFound)
        let otherGrant = try await prepared(owner, project, snags: [snag.snag.id], contractor: activation.grant.contractorId), (_, secondToken) = try await activate(owner, project, otherGrant)
        let intent = UUID(), media = try await contractorAfter(token, snag, intent: intent)
        let stolen = try await call(.POST, "api/v2/contractor/\(secondToken)/snags/\(snag.snag.id)/workflow/submit", nil, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [media.uuidString]])); XCTAssertEqual(stolen.status, .notFound)
        let view = try await call(.GET, "api/v2/contractor/\(secondToken)/snags/\(snag.snag.id)/media/\(media)/content", nil); XCTAssertEqual(view.status, .notFound)
        let waived = try await call(.POST, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit", nil, body: action(snag, extra: ["attemptId": UUID().uuidString, "evidenceIds": [], "waiverReason": "No camera"])); XCTAssertEqual(waived.status, .forbidden)
    }
    func testMissingMediaBlocksActivationAndRetryDoesNotIssueAnotherLink() async throws {
        let owner = try await user(), project = try await project(owner), snag = try await logged(owner, project)
        let media = try await allocate(owner, path(project, snag), command(snag))
        let grant = try await prepared(owner, project, snags: [snag.snag.id], assets: [media.id], mode: "read_only")
        let body: [String: Any] = ["mutation": meta(), "expectedRevision": grant.revision], endpoint = "api/v2/projects/\(project.project.id)/links/\(grant.id)/activate"
        let failed = try await call(.POST, endpoint, owner, body: body); XCTAssertEqual(failed.status, .unprocessableEntity)
        let get = try await call(.GET, "api/v2/projects/\(project.project.id)/links/\(grant.id)", owner); XCTAssertNil(try get.content.decode(LinkActivationResponse.self).contractorPath)
        let put = try await call(.PUT, path(project, snag) + "/\(media.id)/content", owner, bytes: Self.png); XCTAssertEqual(put.status, .ok)
        let attach = try await call(.POST, path(project, snag) + "/\(media.id)/attach", owner, body: ["mutation": meta(), "expectedRevision": snag.revision]); XCTAssertEqual(attach.status, .ok)
        let first = try await call(.POST, endpoint, owner, body: body), retry = try await call(.POST, endpoint, owner, body: body)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(try PlatformMutationService.encode(first.content.decode(LinkActivationResponse.self)), try PlatformMutationService.encode(retry.content.decode(LinkActivationResponse.self)))
        let result = try first.content.decode(LinkActivationResponse.self), token = String(result.contractorPath!.dropFirst(3))
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE link_grants SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE id = \(bind: grant.id)").run()
        let expired = try await call(.GET, "api/v2/contractor/\(token)", nil); XCTAssertEqual(expired.status, .gone)
        let oldRetry = try await call(.POST, endpoint, owner, body: body); XCTAssertNil(try oldRetry.content.decode(LinkActivationResponse.self).contractorPath)
    }
    func testCanonicalBrowserResourcesLegacyAdaptersAndActorBoundConflicts() async throws {
        let (owner, project, snag, activation, token, _) = try await fixture(pin: "4321")
        let shell = try await call(.GET, "m/\(token)", nil)
        XCTAssertEqual(shell.status, .ok); XCTAssertTrue(shell.body.string.contains("Contractor link")); XCTAssertTrue(shell.body.string.contains("/assets/contractor/v2/contractor.js"))
        XCTAssertEqual(shell.headers.first(name: "X-Frame-Options"), "SAMEORIGIN"); XCTAssertTrue(shell.headers.first(name: "Content-Security-Policy")?.contains("frame-ancestors 'self'") == true)
        XCTAssertFalse(shell.body.string.contains(project.project.name)); XCTAssertFalse(shell.body.string.contains(snag.snag.title))
        let font = try await call(.GET, "assets/contractor/v2/IBMPlexSans-Regular.ttf", nil); XCTAssertEqual(font.status, .ok); XCTAssertEqual(font.headers.first(name: .contentType), "font/ttf")
        let script = try await call(.GET, "assets/contractor/v2/contractor.js", nil); XCTAssertTrue(script.body.string.contains("Submit for review"))
        let legacy = try await call(.GET, "api/v1/magic-links/\(token)/validate", nil); XCTAssertEqual(legacy.status, .conflict); XCTAssertTrue(legacy.body.string.contains("contractor_browser_required"))
        let cookie = try await verify(token, pin: "4321")
        let intent = UUID(), asset = try await contractorAfter(token, snag, intent: intent, cookie: cookie)
        // Manager edits after the recipient loaded the record. Conflict responses
        // must not leak internal cost/owner/directory fields.
        let edit = try await call(.PATCH, "api/v2/projects/\(project.project.id)/snags/\(snag.snag.id)", owner, body: ["mutation": meta(), "expectedRevision": snag.revision, "fields": ["title": "Updated repair instruction"]]); XCTAssertEqual(edit.status, .ok)
        let stale = try await call(.POST, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit", nil, body: action(snag, extra: ["attemptId": intent.uuidString, "evidenceIds": [asset.uuidString]]), cookie: cookie)
        XCTAssertEqual(stale.status, .conflict); XCTAssertFalse(stale.body.string.contains("ownerId")); XCTAssertFalse(stale.body.string.contains("costEstimate")); XCTAssertFalse(stale.body.string.contains("current"))
        let outsider = try await user()
        let denied = try await call(.POST, "api/v1/magic-links/\(token)/revoke", outsider); XCTAssertNotEqual(denied.status, .ok)
        for _ in 0..<2 { let revoked = try await call(.POST, "api/v1/magic-links/\(token)/revoke", owner); XCTAssertEqual(revoked.status, .ok) }
        let deleted = try await call(.DELETE, "api/v1/magic-links/\(activation.grant.id)", owner); XCTAssertEqual(deleted.status, .noContent)
        let blocked = try await call(.GET, "api/v2/contractor/\(token)", nil, cookie: cookie); XCTAssertEqual(blocked.status, .gone)
    }
    func testSendBackAllowsFreshEvidenceAndIssuerRemovalBlocksOldCapabilities() async throws {
        let (owner, project, snag, activation, token, _) = try await fixture()
        let firstIntent = UUID(), asset = try await contractorAfter(token, snag, intent: firstIntent)
        let path = "api/v2/contractor/\(token)/snags/\(snag.snag.id)/workflow/submit"
        let first = try await call(.POST, path, nil, body: action(snag, extra: ["attemptId": firstIntent.uuidString, "evidenceIds": [asset.uuidString], "notes": "First repair"])); XCTAssertEqual(first.status, .ok)
        let history = try await call(.GET, workflowPath(project, snag), owner), pending = try history.content.decode(CanonicalWorkflowController.History.self)
        let rejected = try await decide(owner, project: project, submitted: .init(snag: pending.snag, attempt: pending.pending, decisions: []), kind: "send-back", reason: "Seal the remaining gap at the corner")
        let read = try await call(.GET, "api/v2/contractor/\(token)", nil), item = try XCTUnwrap(read.content.decode(ContractorPage.self).items.first)
        XCTAssertEqual(item.status, "changes_requested"); XCTAssertEqual(item.submissions.first?.feedback, "Seal the remaining gap at the corner")
        let nextIntent = UUID(), nextAsset = try await contractorAfter(token, rejected.snag, intent: nextIntent)
        let second = try await call(.POST, path, nil, body: action(rejected.snag, extra: ["attemptId": nextIntent.uuidString, "evidenceIds": [nextAsset.uuidString], "notes": "Sealed and checked the corner"])); XCTAssertEqual(second.status, .ok)
        let reread = try await call(.GET, "api/v2/contractor/\(token)", nil), attempts = try reread.content.decode(ContractorPage.self).items[0].submissions
        XCTAssertEqual(attempts.count, 2); XCTAssertEqual(attempts[0].state, "pending"); XCTAssertEqual(attempts[1].state, "sent_back")
        // A removed issuer cannot leave a capability with continuing company access.
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE workspace_memberships SET state = 'removed' WHERE workspace_id = \(bind: project.workspaceId) AND user_id = \(bind: owner.requireID())").run()
        let unavailable = try await call(.GET, "api/v2/contractor/\(token)", nil); XCTAssertNotEqual(unavailable.status, .ok)
        // F09: still refused, and explained to the contractor as an inactive link, not as the issuer's role error.
        XCTAssertEqual(unavailable.status, .gone); XCTAssertTrue(unavailable.body.string.contains("link_issuer_inactive"))
        let photo = try await call(.GET, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(nextAsset)/content", nil); XCTAssertNotEqual(photo.status, .ok)
        let grant = try await sql.raw("SELECT state FROM link_grants WHERE id = \(bind: activation.grant.id)").first()!.decode(column: "state", as: String.self); XCTAssertEqual(grant, "active")
    }

    func testAdministratorListsLinksAMemberIssuedAndRemovalStillStopsThem() async throws {
        // F09: an Owner/Admin sees the active links a manager issued before removing them; the
        // secure default is unchanged (removal stops them) and they stay listed for reissue.
        let owner = try await user(), project = try await project(owner), contractor = try await contractor(owner, project)
        let manager = try await user(); try await join(manager, owner: owner, project: project, role: "manager")
        let snag = try await assign(owner, project, logged(owner, project), contractor)
        let grant = try await prepared(manager, project, snags: [snag.snag.id], contractor: contractor)
        XCTAssertEqual(grant.creatorId, try manager.requireID())
        let (activation, token) = try await activate(manager, project, grant)
        XCTAssertEqual(activation.grant.creatorId, try manager.requireID())
        let base = "api/v2/workspaces/\(project.workspaceId)/administration/members/\(try manager.requireID())/links"
        let listed = try await call(.GET, base, owner); XCTAssertEqual(listed.status, .ok, listed.body.string)
        let page = try listed.content.decode(CompanyAdministrationController.MemberLinkPage.self)
        XCTAssertEqual(page.items.map(\.id), [grant.id]); XCTAssertEqual(page.items.first?.projectName, "Plot 12")
        XCTAssertEqual(page.items.first?.contractorName, "Alder Joinery"); XCTAssertEqual(page.items.first?.mode, "completion")
        XCTAssertEqual(page.items.first?.projectArchived, false); XCTAssertEqual(page.member.state, "active")
        XCTAssertFalse(listed.body.string.contains(token)); XCTAssertFalse(listed.body.string.contains("c2_"))
        let own = try await call(.GET, "api/v2/workspaces/\(project.workspaceId)/administration/members/\(try owner.requireID())/links", owner)
        XCTAssertEqual(own.status, .ok); XCTAssertEqual(try own.content.decode(CompanyAdministrationController.MemberLinkPage.self).items.count, 0)
        let notAdmin = try await call(.GET, base, manager); XCTAssertNotEqual(notAdmin.status, .ok)
        let outsider = try await user(), stranger = try await call(.GET, base, outsider); XCTAssertNotEqual(stranger.status, .ok)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE workspace_memberships SET state = 'removed' WHERE workspace_id = \(bind: project.workspaceId) AND user_id = \(bind: manager.requireID())").run()
        let refused = try await call(.GET, "api/v2/contractor/\(token)", nil)
        XCTAssertEqual(refused.status, .gone); XCTAssertTrue(refused.body.string.contains("link_issuer_inactive"))
        let after = try await call(.GET, base, owner); XCTAssertEqual(after.status, .ok, after.body.string)
        let afterPage = try after.content.decode(CompanyAdministrationController.MemberLinkPage.self)
        XCTAssertEqual(afterPage.member.state, "removed"); XCTAssertEqual(afterPage.items.map(\.id), [grant.id])
        let revoked = try await call(.POST, "api/v2/projects/\(project.project.id)/links/\(grant.id)/revoke", owner, body: ["mutation": meta(), "expectedRevision": activation.grant.revision])
        XCTAssertEqual(revoked.status, .ok, revoked.body.string)
        let cleared = try await call(.GET, base, owner)
        XCTAssertEqual(try cleared.content.decode(CompanyAdministrationController.MemberLinkPage.self).items.count, 0)
    }
}

/// A fence store whose every write fails, for the "a failed fence stays pending" case.
private struct FailingFenceStore: ObjectErasureFenceStorage {
    let target: ObjectStorageWriteTarget
    struct Unavailable: Error {}
    func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String { throw Unavailable() }
    func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback { throw Unavailable() }
}
