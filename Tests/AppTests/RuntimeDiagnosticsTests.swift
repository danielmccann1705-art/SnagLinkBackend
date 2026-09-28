@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

/// Wave 3 (28 Sep 2026): the database pool size is configuration, absent means the previous
/// pool, and the numbers that confirm a capacity limit at runtime are recorded by every
/// maintenance pass and, on staging only, readable by a signed-in user.
final class RuntimeDiagnosticsTests: XCTestCase {
    var app: Application!
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testThePoolSizeIsATotalFromOneToSixteenAndAbsentMeansThePreviousPool() {
        XCTAssertEqual(DatabasePool.settings(requested: nil, eventLoops: 1).total, 1)
        XCTAssertEqual(DatabasePool.settings(requested: nil, eventLoops: 6).perEventLoop, 1, "Vapor's default: one per event loop")
        XCTAssertEqual(DatabasePool.settings(requested: "4", eventLoops: 1).total, 4)
        XCTAssertEqual(DatabasePool.settings(requested: "16", eventLoops: 4).perEventLoop, 4)
        XCTAssertEqual(DatabasePool.settings(requested: "2", eventLoops: 4).perEventLoop, 1, "never fewer than one per event loop")
        for bad in ["0", "17", "-1", "four", "", " 4", "4.0"] {
            let pool = DatabasePool.settings(requested: bad, eventLoops: 1)
            XCTAssertTrue(pool.invalid, bad); XCTAssertEqual(pool.total, 1, bad)
        }
        XCTAssertEqual(RuntimeDiagnostics.cpuLimit("25000 100000\n"), 0.25)
        XCTAssertNil(RuntimeDiagnostics.cpuLimit("max 100000"))
        XCTAssertNil(RuntimeDiagnostics.cpuLimit(nil))
        XCTAssertEqual(RuntimeDiagnostics.keyed("usage_usec 1500000\nnr_throttled 7\nbad line here\n"), ["usage_usec": 1_500_000, "nr_throttled": 7])
    }

    func testEveryPassRecordsTheRuntimeNumbersAndTheRouteExistsOnlyWhenAskedFor() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        let pool = try XCTUnwrap(app.storage[DatabasePool.Key.self])
        XCTAssertEqual(pool.perEventLoop, 1, "no variable in the test environment: the previous pool")

        try await CleanupService.runCleanup(app: app, trigger: .test)
        let row = try await (app.db as! SQLDatabase).raw("SELECT removed_json FROM cleanup_runs ORDER BY started_at DESC LIMIT 1").first()
        let json = try XCTUnwrap(try row?.decode(column: "removed_json", as: String?.self))
        let runtime = try XCTUnwrap(try JSONDecoder().decode(CleanupService.Removed.self, from: Data(json.utf8)).runtime)
        XCTAssertEqual(runtime.databasePoolTotal, pool.total)
        XCTAssertEqual(runtime.databaseRoundTripMs.count, 5)
        XCTAssertNil(runtime.databaseAcquireMs, "a pass measures on its own pinned connection")
        XCTAssertGreaterThan(runtime.cpuCount, 0)
        XCTAssertFalse(json.contains("@")); XCTAssertFalse(json.contains("postgres"))

        // Not registered unless RUNTIME_DIAGNOSTICS=enabled (the test environment does not set it).
        let jwt = try await signedIn()
        try await app.test(.GET, "api/v2/runtime/diagnostics", beforeRequest: { $0.headers.bearerAuthorization = .init(token: jwt) },
                           afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
    }

    private func signedIn() async throws -> String {
        let user = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("diag-\(UUID())@example.test", name: "Synthetic", on: db) }
        let id = try user.requireID()
        return try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(600)), userId: id))
    }

    func testWhenRegisteredASignedInUserReadsNumbersOnly() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        let pool = try XCTUnwrap(app.storage[DatabasePool.Key.self])
        // Registered before the first request, as routes() does when the variable is set.
        try app.register(collection: RuntimeDiagnosticsController())
        let jwt = try await signedIn()
        try await app.test(.GET, "api/v2/runtime/diagnostics", afterResponse: { response async in
            // Refused before the handler runs (401, or 503 where no browser platform is configured).
            XCTAssertTrue([.unauthorized, .serviceUnavailable].contains(response.status), "\(response.status)")
            XCTAssertFalse(response.body.string.contains("databasePoolTotal"))
        })
        try await app.test(.GET, "api/v2/runtime/diagnostics", beforeRequest: { $0.headers.bearerAuthorization = .init(token: jwt) },
                           afterResponse: { response async throws in
            XCTAssertEqual(response.status, .ok, response.body.string)
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
            let facts = try response.content.decode(RuntimeFacts.self)
            XCTAssertEqual(facts.databasePoolTotal, pool.total)
            XCTAssertNotNil(facts.databaseAcquireMs)
            XCTAssertEqual(facts.databaseRoundTripMs.count, 5)
            XCTAssertFalse(response.body.string.contains("@"))
        })
    }
}
