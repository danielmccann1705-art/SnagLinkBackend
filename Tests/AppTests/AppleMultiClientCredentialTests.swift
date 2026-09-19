@testable import App
import XCTVapor
import Fluent
import FluentSQL
import Crypto

final class AppleMultiClientCredentialTests: XCTestCase {
    var app: Application!
    let native = "com.snaglist.app.staging"
    let web = "com.snaglist.app.staging.web"
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
        app.storage[AppleCredentialKeyStorage.self] = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> UUID {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("multi-apple-\(UUID())@example.test", name: "Synthetic member", on: db).requireID()
        }
    }
    private func job(userID: UUID) async throws -> AccountDeletionWorker.Lease {
        let id = UUID(), lease = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_jobs(id,user_id,receipt_hash,requested_at,state,available_at,lease_token,lease_expires_at,
                database_cleanup_state,object_cleanup_state,apple_revocation_state)
            VALUES(\(bind: id),\(bind: userID),\(bind: UUID().uuidString),NOW(),'leased',NOW(),\(bind: lease),NOW()+INTERVAL '5 minutes','completed','completed','pending')
            """).run()
        return .init(id: id, userID: userID, token: lease, attempt: 1)
    }
    private func child(_ lease: AccountDeletionWorker.Lease, client: String?, ciphertext: String?, state: String = "pending") async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_apple_credentials(id,job_id,client_id,credential_ciphertext,state)
            VALUES(\(bind: UUID()),\(bind: lease.id),\(bind: client),\(bind: ciphertext),\(bind: state))
            """).run()
    }
    actor Calls {
        var clients: [String] = []
        func record(_ client: String) { clients.append(client) }
        func values() -> [String] { clients }
    }

    func testNativeAndWebCredentialsCoexistAndReplaceOnlyTheirOwnClient() async throws {
        let id = try await user()
        try await AppleCredentialService.store(refreshToken: "native-first", userID: id, clientID: native, app: app, on: app.db)
        let before = try await VerifiedIdentityService.sql(app.db).raw("SELECT refresh_token_ciphertext FROM apple_credentials WHERE user_id=\(bind: id) AND client_id=\(bind: native)").first()?.decode(column: "refresh_token_ciphertext", as: String.self)
        try await AppleCredentialService.store(refreshToken: "web-first", userID: id, clientID: web, app: app, on: app.db)
        try await AppleCredentialService.store(refreshToken: "web-new", userID: id, clientID: web, app: app, on: app.db)
        let after = try await VerifiedIdentityService.sql(app.db).raw("SELECT refresh_token_ciphertext FROM apple_credentials WHERE user_id=\(bind: id) AND client_id=\(bind: native)").first()?.decode(column: "refresh_token_ciphertext", as: String.self)
        XCTAssertEqual(before, after, "Adding/updating web must leave native ciphertext unchanged")
        let loadedNative = try await AppleCredentialService.load(userID: id, clientID: native, app: app, on: app.db)
        let loadedWeb = try await AppleCredentialService.load(userID: id, clientID: web, app: app, on: app.db)
        XCTAssertEqual(loadedNative?.refreshToken, "native-first")
        XCTAssertEqual(loadedWeb?.refreshToken, "web-new")
        do {
            _ = try await AppleCredentialService.load(userID: id, app: app, on: app.db)
            XCTFail("Ambiguous compatibility load must not choose the wrong audience")
        } catch is AppleCredentialError { }
    }

    func testEveryClientMustSucceedAndRetrySkipsAlreadyRevokedClient() async throws {
        let id = try await user(), calls = Calls()
        let lease = try await job(userID: id)
        try await child(lease, client: native, ciphertext: "native-cipher")
        try await child(lease, client: web, ciphertext: "web-cipher")
        let webClient = web
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, client in
            await calls.record(client)
            return client == webClient ? .misconfigured : .revoked
        }, deleteObject: { _, _ in })
        try await AccountDeletionAppleRevocationService.perform(lease, app: app, on: app.db)
        let blocked = try await AccountDeletionWorker.finish(lease, on: app.db)
        XCTAssertEqual(blocked, "blocked")
        let rows = try await VerifiedIdentityService.sql(app.db).raw("SELECT client_id,state,credential_ciphertext FROM account_deletion_apple_credentials WHERE job_id=\(bind: lease.id)").all()
        for row in rows {
            let client = try row.decode(column: "client_id", as: String.self)
            XCTAssertEqual(try row.decode(column: "state", as: String.self), client == native ? "revoked" : "misconfigured")
            XCTAssertEqual(try row.decode(column: "credential_ciphertext", as: String?.self), client == native ? nil : "web-cipher")
        }
        let replacement = UUID()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind: replacement),lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE id=\(bind: lease.id)").run()
        let retry = AccountDeletionWorker.Lease(id: lease.id, userID: id, token: replacement, attempt: 2)
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, client in await calls.record(client); return .alreadyRevoked }, deleteObject: { _, _ in })
        try await AccountDeletionAppleRevocationService.perform(retry, app: app, on: app.db)
        let completed = try await AccountDeletionWorker.finish(retry, on: app.db)
        XCTAssertEqual(completed, "completed")
        let contacted = await calls.values()
        XCTAssertEqual(contacted.filter { $0 == native }.count, 1)
        XCTAssertEqual(contacted.filter { $0 == web }.count, 2)
    }

    func testMissingClientCredentialBlocksEvenWhenOtherClientRevokes() async throws {
        let lease = try await job(userID: user())
        try await child(lease, client: native, ciphertext: "native-cipher")
        try await child(lease, client: web, ciphertext: nil, state: "unavailable")
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in .revoked }, deleteObject: { _, _ in })
        try await AccountDeletionAppleRevocationService.perform(lease, app: app, on: app.db)
        let state = try await AccountDeletionWorker.finish(lease, on: app.db)
        XCTAssertEqual(state, "blocked")
    }

    func testDatabaseRejectsCompletionWithAnUnfinishedChild() async throws {
        let lease = try await job(userID: user())
        try await child(lease, client: web, ciphertext: "web-cipher")
        do {
            try await VerifiedIdentityService.sql(app.db).raw("""
                UPDATE account_deletion_jobs SET state='completed',completed_at=NOW(),apple_revocation_state='revoked',lease_token=NULL,lease_expires_at=NULL WHERE id=\(bind: lease.id)
                """).run()
            XCTFail("Even a legacy worker cannot bypass pending client revocations")
        } catch { }
    }

    func testExpiredLeaseCannotRevokeOrClearAnyChild() async throws {
        let lease = try await job(userID: user()), calls = Calls()
        try await child(lease, client: native, ciphertext: "native-cipher")
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET lease_expires_at=NOW()-INTERVAL '1 second' WHERE id=\(bind: lease.id)").run()
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, client in await calls.record(client); return .revoked }, deleteObject: { _, _ in })
        try await AccountDeletionAppleRevocationService.perform(lease, app: app, on: app.db)
        let contacted = await calls.values()
        XCTAssertTrue(contacted.isEmpty)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state,credential_ciphertext FROM account_deletion_apple_credentials WHERE job_id=\(bind: lease.id)").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "pending")
        XCTAssertEqual(try row?.decode(column: "credential_ciphertext", as: String?.self), "native-cipher")
    }

    func testProviderResponseFromReplacedLeaseCannotMarkChildRevoked() async throws {
        let lease = try await job(userID: user()), replacement = UUID()
        try await child(lease, client: native, ciphertext: "native-cipher")
        let database = app.db
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(revokeApple: { _, _, _ in
            try await VerifiedIdentityService.sql(database).raw("UPDATE account_deletion_jobs SET lease_token=\(bind: replacement) WHERE id=\(bind: lease.id)").run()
            return .revoked
        }, deleteObject: { _, _ in })
        try await AccountDeletionAppleRevocationService.perform(lease, app: app, on: app.db)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT state,credential_ciphertext,attempts FROM account_deletion_apple_credentials WHERE job_id=\(bind: lease.id)").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "pending")
        XCTAssertEqual(try row?.decode(column: "credential_ciphertext", as: String?.self), "native-cipher")
        XCTAssertEqual(try row?.decode(column: "attempts", as: Int.self), 0)
    }

    func testLegacyJobIsCopiedWithoutReencryptingOrChangingAudience() async throws {
        let lease = try await job(userID: user())
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET apple_credential_ciphertext='unchanged-legacy-envelope',apple_client_id=\(bind: native) WHERE id=\(bind: lease.id)").run()
        try await AccountDeletionAppleRevocationService.preserveLegacyWork(lease, on: app.db)
        try await AccountDeletionAppleRevocationService.preserveLegacyWork(lease, on: app.db)
        let rows = try await VerifiedIdentityService.sql(app.db).raw("SELECT client_id,credential_ciphertext FROM account_deletion_apple_credentials WHERE job_id=\(bind: lease.id)").all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows.first?.decode(column: "client_id", as: String.self), native)
        XCTAssertEqual(try rows.first?.decode(column: "credential_ciphertext", as: String.self), "unchanged-legacy-envelope")
    }
    func testMigrationIsAtomicAndPreservesBothLiveAndQueuedCiphertextBytes() async throws {
        let schema = "apple_migration_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let userID = UUID(), jobID = UUID()
        try await IsolatedMigrationDatabase.withSchema(app: app, schema: schema) { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("CREATE TABLE apple_credentials(user_id UUID PRIMARY KEY,client_id TEXT NOT NULL,refresh_token_ciphertext TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL,updated_at TIMESTAMPTZ NOT NULL)").run()
            try await sql.raw("CREATE TABLE account_deletion_jobs(id UUID PRIMARY KEY,state TEXT NOT NULL,apple_client_id TEXT,apple_credential_ciphertext TEXT,apple_revocation_state TEXT NOT NULL)").run()
            try await sql.raw("INSERT INTO apple_credentials VALUES(\(bind: userID),\(bind: self.native),'opaque-original-live-envelope',NOW(),NOW())").run()
            try await sql.raw("INSERT INTO account_deletion_jobs VALUES(\(bind: jobID),'ready',\(bind: self.native),'opaque-original-job-envelope','pending')").run()
            // Deliberate collision after table creation/backfill: the complete
            // migration, including the original primary key, must roll back.
            try await sql.raw("CREATE FUNCTION require_complete_apple_revocations() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$").run()
            do {
                try await CreateAppleMultiClientCredentials().prepare(on: db)
                XCTFail("Injected function collision must fail the migration")
            } catch { }
            let partial = try await sql.raw("SELECT count(*) AS total FROM information_schema.tables WHERE table_schema=\(bind: schema) AND table_name='account_deletion_apple_credentials'").first()
            XCTAssertEqual(try partial?.decode(column: "total", as: Int.self), 0)
            do {
                try await sql.raw("INSERT INTO apple_credentials VALUES(\(bind: userID),\(bind: self.web),'must-not-persist',NOW(),NOW())").run()
                XCTFail("Rollback must retain the old single-user primary key")
            } catch { }
            try await sql.raw("DROP FUNCTION require_complete_apple_revocations()").run()
            try await CreateAppleMultiClientCredentials().prepare(on: db)
            let live = try await sql.raw("SELECT refresh_token_ciphertext,client_id FROM apple_credentials WHERE user_id=\(bind: userID)").first()
            XCTAssertEqual(try live?.decode(column: "refresh_token_ciphertext", as: String.self), "opaque-original-live-envelope")
            XCTAssertEqual(try live?.decode(column: "client_id", as: String.self), self.native)
            let queued = try await sql.raw("SELECT credential_ciphertext,client_id FROM account_deletion_apple_credentials WHERE job_id=\(bind: jobID)").first()
            XCTAssertEqual(try queued?.decode(column: "credential_ciphertext", as: String.self), "opaque-original-job-envelope")
            XCTAssertEqual(try queued?.decode(column: "client_id", as: String.self), self.native)
            try await sql.raw("INSERT INTO apple_credentials VALUES(\(bind: userID),\(bind: self.web),'new-web-envelope',NOW(),NOW())").run()
        }
    }

}
