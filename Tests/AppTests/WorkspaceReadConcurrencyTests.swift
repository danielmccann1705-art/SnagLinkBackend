@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Wave 3 throughput (28 Sep 2026). On staging every read of one workspace queued behind the
/// exclusive `workspace:<id>` advisory lock, so a pool of eight served no more register reads
/// than a pool of one (about one a second at a 40 ms database round trip). Reads now share
/// that lock; every change to membership, access or content still takes it exclusively.
/// These tests hold real transactions open on two connections of a real PostgreSQL.
final class WorkspaceReadConcurrencyTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        try XCTSkipIf(DatabasePool.eventLoopCount(app.eventLoopGroup) < 2, "Two event loops are needed for two concurrent connections")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("reads-\(UUID())@example.test", name: "Synthetic manager", on: db) }
    }
    private func project(_ owner: User) async throws -> PlatformProjectResponse {
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let id = try owner.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        let body: [String: Any] = ["mutation": ["operationId": UUID().uuidString, "deviceId": UUID().uuidString], "workspaceId": try workspace.requireID().uuidString,
                                   "project": ["id": UUID().uuidString, "name": "Read lock · Plot 3", "reference": "RL03", "address": "Synthetic site"]]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var result: XCTHTTPResponse!
        try await app.test(.POST, "api/v2/projects", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt); req.headers.contentType = .json; req.body = .init(data: bytes)
        }, afterResponse: { response async in result = response })
        XCTAssertEqual(result.status, .ok, result.body.string)
        return try result.content.decode(PlatformProjectResponse.self)
    }
    /// Two databases on different event loops, so two transactions really run at once.
    private func twoConnections() -> (any Database, any Database) {
        var loops = app.eventLoopGroup.makeIterator()
        let first = loops.next()!, second = loops.next()!
        return (app.databases.database(.psql, logger: app.logger, on: first)!, app.databases.database(.psql, logger: app.logger, on: second)!)
    }
    /// Runs `body` in a transaction on `db` and keeps the transaction (and its locks) open for `seconds`.
    private func hold(_ db: any Database, seconds: Double, _ body: @escaping @Sendable (any Database) async throws -> Void) -> Task<Void, any Error> {
        Task {
            try await db.transaction { tx in
                try await body(tx)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
    private func seconds(_ body: () async throws -> Void) async throws -> Double {
        let started = Date(); try await body(); return Date().timeIntervalSince(started)
    }

    func testReadsOfOneWorkspaceNoLongerWaitForEachOther() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let projectID = envelope.project.id, ownerID = try owner.requireID()
        let (first, second) = twoConnections()
        let reader = hold(first, seconds: 2) { tx in _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let waited = try await seconds {
            _ = try await second.transaction { tx in try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx) }
        }
        XCTAssertLessThan(waited, 1.0, "a second reader of the same workspace does not queue behind the first")
        try await reader.value
    }

    func testAChangeStillExcludesReadersAndReadersStillExcludeAChange() async throws {
        let owner = try await user(), envelope = try await project(owner)
        let projectID = envelope.project.id, ownerID = try owner.requireID(), workspaceID = envelope.workspaceId
        let (first, second) = twoConnections()

        // A reader holds the shared lock: a command (exclusive) waits for it to finish.
        let reader = hold(first, seconds: 1.5) { tx in _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let commandWaited = try await seconds {
            _ = try await second.transaction { tx in try await ProjectAccessService.require(.edit, projectID: projectID, actorID: ownerID, on: tx) }
        }
        try await reader.value
        XCTAssertGreaterThan(commandWaited, 0.9, "a command still waits for an open read of its workspace")

        // A membership or access change holds the exclusive lock: a reader waits for it.
        let change = hold(first, seconds: 1.5) { tx in try await WorkspaceAccessService.lock(workspaceID, on: tx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let readerWaited = try await seconds {
            _ = try await second.transaction { tx in try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx) }
        }
        try await change.value
        XCTAssertGreaterThan(readerWaited, 0.9, "a read still waits for an open change to who may read")

        // The project list takes the same shared lock.
        let change2 = hold(first, seconds: 1.5) { tx in try await WorkspaceAccessService.lock(workspaceID, on: tx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let listWaited = try await seconds { try await second.transaction { tx in try await WorkspaceAccessService.readLock(workspaceID, on: tx) } }
        try await change2.value
        XCTAssertGreaterThan(listWaited, 0.9)
    }

    func testSharedReadAccessMakesExactlyTheSameDecision() async throws {
        let owner = try await user(), outsider = try await user(), envelope = try await project(owner)
        let projectID = envelope.project.id, ownerID = try owner.requireID(), outsiderID = try outsider.requireID()
        let shared = try await app.db.transaction { tx -> (UUID, Set<ProjectAccessPolicy.Action>) in
            let (project, actions) = try await ProjectAccessService.requireRead(projectID: projectID, actorID: ownerID, on: tx)
            return (try project.requireID(), actions)
        }
        let exclusive = try await app.db.transaction { tx -> (UUID, Set<ProjectAccessPolicy.Action>) in
            let (project, actions) = try await ProjectAccessService.require(.read, projectID: projectID, actorID: ownerID, on: tx)
            return (try project.requireID(), actions)
        }
        XCTAssertEqual(shared.0, exclusive.0)
        XCTAssertEqual(shared.1, exclusive.1)
        for useShared in [true, false] {
            do {
                try await app.db.transaction { tx in
                    if useShared { _ = try await ProjectAccessService.requireRead(projectID: projectID, actorID: outsiderID, on: tx) }
                    else { _ = try await ProjectAccessService.require(.read, projectID: projectID, actorID: outsiderID, on: tx) }
                }
                XCTFail("an outsider must not read the project")
            } catch let abort as Abort {
                XCTAssertEqual(abort.status, .notFound, "shared=\(useShared)")
            }
        }
    }
}
