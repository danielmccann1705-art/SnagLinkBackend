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
        let photo = try await call(.GET, "api/v2/contractor/\(token)/snags/\(snag.snag.id)/media/\(nextAsset)/content", nil); XCTAssertNotEqual(photo.status, .ok)
        let grant = try await sql.raw("SELECT state FROM link_grants WHERE id = \(bind: activation.grant.id)").first()!.decode(column: "state", as: String.self); XCTAssertEqual(grant, "active")
    }

}
