@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import FluentPostgresDriver

/// Fable final remediation design §5.4 (28 Sep 2026), for the shared read locks of 4e41f6a:
/// removal racing a read, report preview beside a register read, bounded lock waits (F-L4),
/// no write on the shared path (F-L3), and a source guard over every read-only transaction.
final class WorkspaceLockBoundsTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        try XCTSkipIf(DatabasePool.eventLoopCount(app.eventLoopGroup) < 2, "Two event loops are needed for two concurrent connections")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user(_ tag: String) async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("\(tag)-\(UUID())@example.test", name: "Synthetic \(tag)", on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User, body: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            if method != .GET { req.headers.contentType = .json; req.body = .init(data: bytes) }
        }, afterResponse: { response async in result = response })
        return result
    }
    private func project(_ owner: User, workspace: UUID) async throws -> PlatformProjectResponse {
        let body: [String: Any] = ["mutation": ["operationId": UUID().uuidString, "deviceId": UUID().uuidString], "workspaceId": workspace.uuidString,
                                   "project": ["id": UUID().uuidString, "name": "Lock bounds · Plot 5", "reference": "LB05", "address": "Synthetic site"]]
        let response = try await request(.POST, "api/v2/projects", user: owner, body: body)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try response.content.decode(PlatformProjectResponse.self)
    }
    private func twoConnections() -> (any Database, any Database) {
        var loops = app.eventLoopGroup.makeIterator()
        let first = loops.next()!, second = loops.next()!
        return (app.databases.database(.psql, logger: app.logger, on: first)!, app.databases.database(.psql, logger: app.logger, on: second)!)
    }
    private func hold(_ db: any Database, seconds: Double, _ body: @escaping @Sendable (any Database) async throws -> Void) -> Task<Void, any Error> {
        Task { try await db.transaction { tx in try await body(tx); try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } }
    }
    /// True once `signal` yields; false if it finishes without yielding or `seconds` pass first.
    private func armed(_ signal: AsyncStream<Void>, within seconds: Double = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in signal { return true }; return false }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
    private func seconds(_ body: () async throws -> Void) async throws -> Double {
        let started = Date(); try await body(); return Date().timeIntervalSince(started)
    }
    private func status(_ body: () async throws -> Void) async -> Int {
        do { try await body(); return 200 } catch let abort as AbortError { return Int(abort.status.code) } catch { return -1 }
    }

    func testRemovalAndAReadExcludeEachOtherAndTheNextReadIsRefused() async throws {
        let owner = try await user("owner"), member = try await user("member")
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Lock Bounds Ltd", actorID: owner.requireID(), on: db) }
        let companyID = try company.requireID(), memberID = try member.requireID(), ownerID = try owner.requireID()
        try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: memberID, role: "member", on: db) }
        let envelope = try await project(owner, workspace: companyID)
        let projectID = envelope.project.id
        try await VerifiedIdentityService.sql(app.db).raw("INSERT INTO project_access (project_id, workspace_id, user_id, role) VALUES (\(bind: projectID), \(bind: companyID), \(bind: memberID), 'member')").run()
        let (first, second) = twoConnections()
        // Read before the hold (Fable ruling 6, 3 Oct 2026; A217/A219): `app.db` can land on the reader's event loop, whose one pooled
        // connection the hold occupies - the read then waits for the hold to end and the removal is measured after it.
        let revision = try await VerifiedIdentityService.sql(app.db).raw("SELECT revision FROM workspace_memberships WHERE workspace_id = \(bind: companyID) AND user_id = \(bind: memberID)").first()!.decode(column: "revision", as: Int64.self)
        // A member's read is open: the removal waits for it. The removal starts once the reader says it holds its lock (bounded),
        // not after a fixed sleep a slow scheduler could outlast.
        let (holding, held) = AsyncStream<Void>.makeStream()
        let reader = hold(first, seconds: 1.5) { tx in
            defer { held.finish() }
            _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: memberID, on: tx)
            held.yield()
        }
        guard await armed(holding) else {
            try await reader.value
            return XCTFail("the reader did not hold its lock within 10 s")
        }
        let removalWaited = try await seconds {
            try await second.transaction { tx in try await WorkspaceAccessService.changeMember(workspaceID: companyID, targetID: memberID, newRole: nil, expectedRevision: revision, actorID: ownerID, on: tx) }
        }
        try await reader.value
        XCTAssertGreaterThan(removalWaited, 0.9, "a removal waits for an open read of its workspace")
        let after = await status { try await self.app.db.transaction { tx in _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: memberID, on: tx) } }
        XCTAssertEqual(after, 404, "the removed member's next read is refused")

        // The reverse: a change to access is open, a new read waits for it and then sees it.
        let other = try await user("other")
        let otherID = try other.requireID()
        try await app.db.transaction { db in try await WorkspaceAccessService.putMembership(workspaceID: companyID, userID: otherID, role: "admin", on: db) }
        let otherRevision = try await VerifiedIdentityService.sql(app.db).raw("SELECT revision FROM workspace_memberships WHERE workspace_id = \(bind: companyID) AND user_id = \(bind: otherID)").first()!.decode(column: "revision", as: Int64.self)
        let removal = hold(first, seconds: 1.5) { tx in
            try await WorkspaceAccessService.changeMember(workspaceID: companyID, targetID: otherID, newRole: nil, expectedRevision: otherRevision, actorID: ownerID, on: tx)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        var refused = 0
        let readWaited = try await seconds {
            refused = await self.status { try await second.transaction { tx in _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: otherID, on: tx) } }
        }
        try await removal.value
        XCTAssertGreaterThan(readWaited, 0.9, "a read waits for an open change to who may read")
        XCTAssertEqual(refused, 404, "and then answers from the committed change")
    }

    func testReportPreviewRunsBesideARegisterReadAndExcludesAnEdit() async throws {
        let owner = try await user("owner")
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let envelope = try await project(owner, workspace: try workspace.requireID())
        let projectID = envelope.project.id, ownerID = try owner.requireID()
        let (first, second) = twoConnections()
        let preview = hold(first, seconds: 1.5) { tx in
            let (project, _) = try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx)
            _ = try await IssuedReportService.build(title: nil, scope: nil, project: project, on: tx)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let registerWaited = try await seconds {
            _ = try await second.transaction { tx in
                let context = try await ProjectAccessService.readContext(projectID: projectID, actorID: ownerID, on: tx)
                return try await SnagRegisterService.list(.init(), project: context.project, timezone: context.workspaceTimezone, on: tx)
            }
        }
        XCTAssertLessThan(registerWaited, 1.0, "a register read runs beside an open preview")
        let editWaited = try await seconds {
            _ = try await second.transaction { tx in try await ProjectAccessService.require(.edit, projectID: projectID, actorID: ownerID, on: tx) }
        }
        try await preview.value
        XCTAssertGreaterThan(editWaited, 0.7, "a command waits for the open preview")
    }

    private func shownTimeout(_ body: @escaping @Sendable (any Database) async throws -> Void) async throws -> String {
        try await app.db.transaction { tx -> String in
            try await body(tx)
            return try await VerifiedIdentityService.sql(tx).raw("SHOW lock_timeout").first()!.decode(column: "lock_timeout", as: String.self)
        }
    }
    private struct Throwing: AsyncResponder {
        let error: any Error
        func respond(to request: Request) async throws -> Response { throw error }
    }

    func testWorkspaceLockWaitsAreBoundedAndAnsweredAsBusy() async throws {
        let owner = try await user("owner")
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let workspaceID = try workspace.requireID()
        let envelope = try await project(owner, workspace: workspaceID)
        let projectID = envelope.project.id, ownerID = try owner.requireID()
        // The bound each path sets for the rest of its transaction.
        let command = try await shownTimeout { tx in try await WorkspaceAccessService.lock(workspaceID, on: tx) }
        let read = try await shownTimeout { tx in try await WorkspaceAccessService.readLock(workspaceID, on: tx) }
        let context = try await shownTimeout { tx in _ = try await ProjectAccessService.readContext(projectID: projectID, actorID: ownerID, on: tx) }
        let general = try await shownTimeout { tx in _ = try await ProjectAccessService.require(.edit, projectID: projectID, actorID: ownerID, on: tx) }
        XCTAssertEqual(command, "15s"); XCTAssertEqual(read, "8s"); XCTAssertEqual(context, "8s"); XCTAssertEqual(general, "15s")
        let outside = try await VerifiedIdentityService.sql(app.db).raw("SHOW lock_timeout").first()!.decode(column: "lock_timeout", as: String.self)
        XCTAssertEqual(outside, "0", "the bound ends with its transaction")
        // A read queued behind a change that does not finish gives up at the bound instead of holding its connection.
        let (first, second) = twoConnections()
        let change = hold(first, seconds: 10) { tx in try await WorkspaceAccessService.lock(workspaceID, on: tx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        var caught: (any Error)? = nil
        let waited = try await seconds {
            do { _ = try await second.transaction { tx in try await ProjectAccessService.readContext(projectID: projectID, actorID: ownerID, on: tx) } }
            catch { caught = error }
        }
        let psql = try XCTUnwrap(caught as? PSQLError, "a lock timeout is a PostgreSQL error, got \(String(describing: caught))")
        XCTAssertEqual(psql.serverInfo?[.sqlState], "55P03")
        XCTAssertGreaterThan(waited, 7.0); XCTAssertLessThan(waited, 9.8)
        // The same connection is free again at once: another read of a different workspace answers now.
        let otherOwner = try await user("other")
        let otherWorkspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: otherOwner.requireID(), on: db) }
        let quick = try await seconds { try await second.transaction { tx in try await WorkspaceAccessService.readLock(otherWorkspace.requireID(), on: tx) } }
        XCTAssertLessThan(quick, 1.0)
        try await change.value
        // Answered as 503 workspace_busy with Retry-After, and nothing else about the error is shown.
        let response = try await PrivateRequestLoggingMiddleware().respond(to: Request(application: app, on: app.eventLoopGroup.next()), chainingTo: Throwing(error: psql))
        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(response.headers.first(name: "Retry-After"), "2")
        let body = response.body.string ?? ""
        XCTAssertTrue(body.contains("\"identifier\":\"workspace_busy\""), body)
        XCTAssertFalse(body.contains("55P03"), body)
        let recovered = try await request(.GET, "api/v2/projects/\(projectID)/snags", user: owner)
        XCTAssertEqual(recovered.status, .ok, "the same request succeeds once the change commits")
    }

    func testAttachingAPreWorkspaceProjectNeverRunsOnTheSharedPath() async throws {
        let owner = try await user("owner")
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let workspaceID = try workspace.requireID(), ownerID = try owner.requireID()
        let legacy = Project(name: "Legacy · no workspace", reference: "LG", ownerId: ownerID)
        try await legacy.save(on: app.db)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE projects SET workspace_id = NULL WHERE id = \(bind: legacy.requireID())").run()
        let legacyID = try legacy.requireID()
        let (first, second) = twoConnections()
        // Another reader holds the shared lock: a shared-path attach would not wait; the exclusive one does.
        let reader = hold(first, seconds: 1.5) { tx in try await WorkspaceAccessService.readLock(workspaceID, on: tx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let waited = try await seconds {
            _ = try await second.transaction { tx in try await ProjectAccessService.requireRead(projectID: legacyID, actorID: ownerID, on: tx) }
        }
        try await reader.value
        XCTAssertGreaterThan(waited, 0.9, "the attaching read took the workspace lock exclusively")
        let attached = try await Project.find(legacyID, on: app.db)
        XCTAssertEqual(attached?.workspaceId, workspaceID)
    }

    /// Every transaction that reads under the shared lock writes nothing and never asks for the
    /// exclusive lock (source-order guard over the controllers, as the iOS suites guard sources).
    func testReadOnlyTransactionsContainNoWrites() throws {
        let controllers = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Controllers")
        let files = try FileManager.default.contentsOfDirectory(at: controllers, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let markers = ["requireRead(", "readContext(", "WorkspaceReadScope.load(", "SnagRegisterService.read("]
        let forbidden = ["WorkspaceAccessService.lock(", ".change(", ".record(", "activity(", ".save(on", "INSERT ", "UPDATE ", "DELETE ", "require(."]
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var search = text.startIndex
            while let open = text.range(of: ".transaction {", range: search..<text.endIndex) ?? text.range(of: ".transaction { db", range: search..<text.endIndex) {
                var depth = 0, index = open.upperBound, end = text.endIndex
                // The closure body: from the "{" just before `open.upperBound` to its matching "}".
                depth = 1
                while index < text.endIndex {
                    let c = text[index]
                    if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { end = index; break } }
                    index = text.index(after: index)
                }
                let body = String(text[open.upperBound..<end])
                if markers.contains(where: body.contains) {
                    checked += 1
                    for token in forbidden { XCTAssertFalse(body.contains(token), "\(file.lastPathComponent): a read-only transaction contains \(token)") }
                }
                search = end < text.endIndex ? text.index(after: end) : text.endIndex
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 15, "the guard found the read-only transactions")
    }
}
