@testable import App
import XCTVapor
import Fluent
import FluentSQL
import FluentPostgresDriver
import Crypto

final class AppleWebCredentialEscrowTests: XCTestCase {
    var app: Application!
    var database: Database!
    let schema = "escrow_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let client = "com.snaglist.app.staging.web"
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AppleCredentialKeyStorage.self] = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
        try await VerifiedIdentityService.sql(app.db).raw("CREATE SCHEMA \(ident: schema)").run()
        var configuration = try SQLPostgresConfiguration(url: XCTUnwrap(Environment.get("DATABASE_URL")))
        if Environment.get("DATABASE_TLS_DISABLE") == "true" { configuration.coreConfiguration.tls = .disable }
        // Only these two queue tables are isolated. User/credential fixtures
        // remain synthetic public rows so normal ownership triggers still run.
        configuration.searchPath = [schema, "public"]
        let id = DatabaseID(string: schema)
        app.databases.use(.postgres(configuration: configuration), as: id)
        database = app.db(id)
        try await CreateAppleWebChallenges().prepare(on: database)
        try await CreateAppleWebCredentialEscrow().prepare(on: database)
    }
    override func tearDown() async throws {
        if let app {
            try? await VerifiedIdentityService.sql(app.db).raw("DROP SCHEMA IF EXISTS \(ident: schema) CASCADE").run()
            try await app.asyncShutdown()
        }
    }
    private func held() async throws -> AppleWebCredentialEscrowService.Held {
        let id = UUID(), now = Date()
        try await VerifiedIdentityService.sql(database).raw("""
            INSERT INTO apple_web_challenges(id,state_hash,nonce_hash,binding_hash,environment,origin,client_id,redirect_uri,created_at,expires_at,consumed_at)
            VALUES(\(bind: id),\(bind: SHA256Hasher.hash(token: UUID().uuidString)),\(bind: SHA256Hasher.hash(token: UUID().uuidString)),\(bind: SHA256Hasher.hash(token: UUID().uuidString)),
                'staging','https://staging-app.usesnaglist.com',\(bind: client),'https://staging-app.usesnaglist.com/api/v2/auth/apple/callback',\(bind: now),\(bind: now.addingTimeInterval(600)),\(bind: now))
            """).run()
        return try await AppleWebCredentialEscrowService.hold(refreshToken: "synthetic-abandoned-refresh", context: .init(id: id, nonceHash: "unused", createdAt: now), clientID: client, app: app, on: database)
    }
    private func row(_ held: AppleWebCredentialEscrowService.Held) async throws -> SQLRow {
        let result = try await VerifiedIdentityService.sql(database).raw("SELECT * FROM apple_web_credential_escrow WHERE challenge_id=\(bind: held.challengeID)").first()
        return try XCTUnwrap(result)
    }
    private func ready(_ held: AppleWebCredentialEscrowService.Held) async throws {
        try await AppleWebCredentialEscrowService.abandon(held, on: database)
    }
    private func user() async throws -> UUID {
        try await database.transaction { db in
            try await VerifiedIdentityService.resolveEmail("escrow-\(UUID())@example.test", name: "Synthetic user", on: db).requireID()
        }
    }
    func testFailedRevocationRetainsCiphertextAndRetryClearsOnlyAfterSuccess() async throws {
        let held = try await held()
        let initial = try await row(held).decode(column: "credential_ciphertext", as: String.self)
        XCTAssertNotEqual(initial, "synthetic-abandoned-refresh")
        XCTAssertThrowsError(try AppleCredentialService.open(initial, userID: held.challengeID, app: app), "Escrow and account credential domains must be distinct")
        try await ready(held)
        app.storage[AppleWebEscrowDependenciesKey.self] = .init(revoke: { token, client in
            XCTAssertEqual(token, "synthetic-abandoned-refresh"); XCTAssertEqual(client, "com.snaglist.app.staging.web")
            return .misconfigured
        })
        _ = try await AppleWebCredentialEscrowService.run(app: app, on: database, limit: 1)
        let failed = try await row(held)
        XCTAssertEqual(try failed.decode(column: "state", as: String.self), "blocked")
        XCTAssertEqual(try failed.decode(column: "credential_ciphertext", as: String.self), initial)
        try await VerifiedIdentityService.sql(database).raw("UPDATE apple_web_credential_escrow SET available_at=NOW()-INTERVAL '1 minute' WHERE challenge_id=\(bind: held.challengeID)").run()
        app.storage[AppleWebEscrowDependenciesKey.self] = .init(revoke: { _, _ in .revoked })
        _ = try await AppleWebCredentialEscrowService.run(app: app, on: database, limit: 1)
        let done = try await row(held)
        XCTAssertEqual(try done.decode(column: "state", as: String.self), "revoked")
        XCTAssertNil(try done.decode(column: "credential_ciphertext", as: String?.self))
        XCTAssertNotNil(try done.decode(column: "completed_at", as: Date?.self))
    }
    func testSuccessfulAdoptionMovesCredentialAndPreventsWorkerRevocation() async throws {
        let held = try await held(), userID = try await user()
        try await database.transaction { db in try await AppleWebCredentialEscrowService.adopt(held, userID: userID, app: self.app, on: db) }
        let adopted = try await row(held)
        XCTAssertEqual(try adopted.decode(column: "state", as: String.self), "adopted")
        XCTAssertNil(try adopted.decode(column: "credential_ciphertext", as: String?.self))
        let credential = try await AppleCredentialService.load(userID: userID, clientID: client, app: app, on: database)
        XCTAssertEqual(credential?.refreshToken, "synthetic-abandoned-refresh")
        try await ready(held)
        let unchanged = try await row(held)
        XCTAssertEqual(try unchanged.decode(column: "state", as: String.self), "adopted")
    }
    func testFailedSessionTransactionRollsBackAdoptionAndExpiredHoldCanBeRevoked() async throws {
        let held = try await held(), userID = try await user()
        do {
            try await database.transaction { db in
                try await AppleWebCredentialEscrowService.adopt(held, userID: userID, app: self.app, on: db)
                throw Abort(.serviceUnavailable)
            }
            XCTFail("Injected session failure must propagate")
        } catch { }
        let pending = try await row(held)
        XCTAssertEqual(try pending.decode(column: "state", as: String.self), "held")
        let credential = try await AppleCredentialService.load(userID: userID, clientID: client, app: app, on: database)
        XCTAssertNil(credential)
        // Simulate a callback process disappearing without calling abandon.
        try await VerifiedIdentityService.sql(database).raw("UPDATE apple_web_credential_escrow SET available_at=NOW()-INTERVAL '1 minute' WHERE challenge_id=\(bind: held.challengeID)").run()
        app.storage[AppleWebEscrowDependenciesKey.self] = .init(revoke: { _, _ in .revoked })
        _ = try await AppleWebCredentialEscrowService.run(app: app, on: database, limit: 1)
        let revoked = try await row(held)
        XCTAssertEqual(try revoked.decode(column: "state", as: String.self), "revoked")
    }
    func testReplacedLeaseCannotClearCredentialAfterProviderResponse() async throws {
        let held = try await held(), db = database!
        try await ready(held)
        app.storage[AppleWebEscrowDependenciesKey.self] = .init(revoke: { _, _ in
            do { try await VerifiedIdentityService.sql(db).raw("UPDATE apple_web_credential_escrow SET lease_token=\(bind: UUID()) WHERE challenge_id=\(bind: held.challengeID)").run() }
            catch { XCTFail("Synthetic lease replacement failed") }
            return .revoked
        })
        _ = try await AppleWebCredentialEscrowService.run(app: app, on: database, limit: 1)
        let pending = try await row(held)
        XCTAssertEqual(try pending.decode(column: "state", as: String.self), "leased")
        XCTAssertNotNil(try pending.decode(column: "credential_ciphertext", as: String?.self))
        XCTAssertNil(try pending.decode(column: "completed_at", as: Date?.self))
    }
    func testExpiredOrClaimedHoldCannotBeAdoptedIntoLiveAccount() async throws {
        let held = try await held(), userID = try await user()
        try await ready(held)
        do {
            try await database.transaction { db in try await AppleWebCredentialEscrowService.adopt(held, userID: userID, app: self.app, on: db) }
            XCTFail("Abandoned work cannot race back into a live session")
        } catch let error as Abort { XCTAssertEqual(error.status, .gone) }
        let credential = try await AppleCredentialService.load(userID: userID, clientID: client, app: app, on: database)
        XCTAssertNil(credential)
    }
}
