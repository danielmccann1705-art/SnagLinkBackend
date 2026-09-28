@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// Audit F21 / D1 §7 "F2": a first native Sign in with Apple whose Apple email already
/// belongs to another Snaglist account is refused with 409 `identity_proof_required`
/// and creates nothing — the rule email links, Google and web Apple already follow.
/// Accounts are never merged by email. Real PostgreSQL, synthetic identities only.
final class AppleIdentityContinuityTests: XCTestCase {
    var app: Application!
    struct Throwing: AsyncResponder {
        let error: Error
        func respond(to request: Request) async throws -> Response { throw error }
    }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func native(_ subject: String, _ email: String?) async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveApple(subject: subject, email: email, name: "Synthetic Apple person", on: db)
        }
    }
    private func refusal(_ subject: String, _ email: String?) async -> Abort? {
        do { _ = try await native(subject, email); return nil } catch { return error as? Abort }
    }
    private func footprint(_ subject: String) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT (SELECT count(*) FROM user_identities WHERE provider = 'apple' AND subject = \(bind: subject))
                 + (SELECT count(*) FROM users WHERE apple_user_id = \(bind: subject)) AS n
            """).first()!.decode(column: "n", as: Int.self)
    }
    private func userCount() async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM users").first()!.decode(column: "n", as: Int.self)
    }
    private func assertRefused(_ abort: Abort?, file: StaticString = #filePath, line: UInt = #line) {
        guard let abort else { return XCTFail("expected a 409 refusal", file: file, line: line) }
        XCTAssertEqual(abort.status, .conflict, file: file, line: line)
        XCTAssertEqual(abort.identifier, "identity_proof_required", file: file, line: line)
        XCTAssertTrue(abort.reason.hasPrefix("This email already belongs to a Snaglist account"), abort.reason, file: file, line: line)
    }

    func testNewAppleUserIsCreatedWithItsAddress() async throws {
        let subject = "apple-new-\(UUID())", email = "apple-new-\(UUID().uuidString.lowercased())@example.test"
        let user = try await native(subject, email)
        XCTAssertEqual(user.email, email)
        let rows = try await footprint(subject)
        XCTAssertEqual(rows, 2)
        let again = try await native(subject, email)                   // the same person again
        XCTAssertEqual(again.id, user.id)
    }

    func testKnownAppleSubjectSignsInWhateverAddressItCarries() async throws {
        let email = "held-\(UUID().uuidString.lowercased())@example.test"
        let owner = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(email, name: "Email owner", on: db) }
        let subject = "apple-known-\(UUID())"
        let apple = try await native(subject, nil)
        let signedIn = try await native(subject, email)
        XCTAssertEqual(signedIn.id, apple.id)
        // An older Apple account known only by users.apple_user_id is also a known subject.
        let legacySubject = "apple-legacy-\(UUID())"
        let legacy = User(appleUserId: legacySubject, email: nil, name: "Older Apple account")
        try await legacy.save(on: app.db)
        let legacySignIn = try await native(legacySubject, email)
        XCTAssertEqual(legacySignIn.id, legacy.id)
        // Nothing moved: the address still belongs to its owner only.
        let ownerEmails = try await VerifiedIdentityService.verifiedEmails(for: owner.requireID(), on: app.db)
        let appleEmails = try await VerifiedIdentityService.verifiedEmails(for: apple.requireID(), on: app.db)
        XCTAssertEqual(ownerEmails, [email])
        XCTAssertEqual(appleEmails, [])
    }

    func testFirstAppleSignInWithAnAddressHeldElsewhereIsRefusedAndCreatesNothing() async throws {
        let email = "held-\(UUID().uuidString.lowercased())@example.test"
        _ = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(email, name: "Email owner", on: db) }
        let subject = "apple-dup-\(UUID())", before = try await userCount()
        assertRefused(await refusal(subject, "  " + email.uppercased() + " "))
        let refusedRows = try await footprint(subject), after = try await userCount()
        XCTAssertEqual(refusedRows, 0)
        XCTAssertEqual(after, before)
        // The same Apple subject without an email still creates an account (D1 §7).
        _ = try await native(subject, nil)
        let createdRows = try await footprint(subject)
        XCTAssertEqual(createdRows, 2)
    }

    func testLegacyProfileAddressIsHeldToo() async throws {
        let email = "legacy-\(UUID().uuidString.lowercased())@example.test"
        let legacy = User(appleUserId: "apple-other-\(UUID())", email: "  " + email.uppercased(), name: "Legacy profile")
        try await legacy.save(on: app.db)
        let subject = "apple-dup-\(UUID())"
        assertRefused(await refusal(subject, email))
        let rows = try await footprint(subject)
        XCTAssertEqual(rows, 0)
    }

    func testPrivateRelayAddressIsAnAddressLikeAnyOther() async throws {
        let relay = "r\(UUID().uuidString.prefix(8).lowercased())@privaterelay.appleid.com"
        let first = "apple-relay-\(UUID())"
        let user = try await native(first, relay)                        // a fresh relay creates the account
        XCTAssertEqual(user.email, relay)
        let second = "apple-relay-\(UUID())"
        assertRefused(await refusal(second, relay))                       // held by that account now
        let secondRows = try await footprint(second)
        XCTAssertEqual(secondRows, 0)
        let relayed = "r\(UUID().uuidString.prefix(8).lowercased())@privaterelay.appleid.com"
        _ = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(relayed, name: "Link user", on: db) }
        assertRefused(await refusal("apple-relay-\(UUID())", relayed))   // held as a verified email identity
    }

    func testDeletedAccountsAddressDoesNotBlockANewAccount() async throws {
        let email = "deleted-\(UUID().uuidString.lowercased())@example.test"
        let gone = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(email, name: "Deleted person", on: db) }
        let sql = try VerifiedIdentityService.sql(app.db)
        // What account deletion leaves (AccountDeletionService): no email, no identities.
        try await sql.raw("UPDATE users SET lifecycle_state = 'deleted', email = NULL, name = NULL WHERE id = \(bind: gone.requireID())").run()
        try await sql.raw("DELETE FROM user_identities WHERE user_id = \(bind: gone.requireID())").run()
        let subject = "apple-after-deletion-\(UUID())"
        let user = try await native(subject, email)
        XCTAssertNotEqual(user.id, gone.id)
        let rows = try await footprint(subject)
        XCTAssertEqual(rows, 2)
    }

    func testTheAppReceivesExactly409IdentityProofRequired() async throws {
        let email = "held-\(UUID().uuidString.lowercased())@example.test"
        _ = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(email, name: "Email owner", on: db) }
        let refused = await refusal("apple-dup-\(UUID())", email)
        let abort = try XCTUnwrap(refused)
        let request = Request(application: app, method: .POST, url: URI(string: "/api/v1/auth/apple"), on: app.eventLoopGroup.next())
        let response = try await PrivateRequestLoggingMiddleware().respond(to: request, chainingTo: Throwing(error: abort))
        XCTAssertEqual(response.status, .conflict)
        let body = try response.content.decode(PrivateRequestLoggingMiddleware.Failure.self)
        XCTAssertTrue(body.error)
        XCTAssertEqual(body.identifier, "identity_proof_required")
        // Not verified by the provider here, so the sentence does not name the method.
        XCTAssertEqual(body.reason, "This email already belongs to a Snaglist account. Sign in the way you first did to reach it. Accounts are never joined by email.")
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        XCTAssertEqual(response.headers.first(name: ExistingAccountRecovery.methodsHeader), "unknown")
    }

    // MARK: - Wave 3: the recovery sentence, and concurrency decided by the database

    private func verified(_ subject: String, _ email: String?, on db: (any Database)? = nil) async throws -> User {
        try await VerifiedIdentityService.transactionRetryingIdentityRace(on: db ?? app.db) { tx in
            try await VerifiedIdentityService.resolveApple(subject: subject, email: email, emailVerified: true, name: "Synthetic Apple person", on: tx)
        }
    }
    /// Two databases on different event loops, so two transactions really run at once.
    private func twoConnections() -> (any Database, any Database) {
        var loops = app.eventLoopGroup.makeIterator()
        let first = loops.next()!, second = loops.next() ?? first
        return (app.databases.database(.psql, logger: app.logger, on: first)!, app.databases.database(.psql, logger: app.logger, on: second)!)
    }
    private func count(_ query: SQLQueryString) async throws -> Int {
        try await VerifiedIdentityService.sql(app.db).raw(query).first()!.decode(column: "n", as: Int.self)
    }
    /// Distinct live accounts holding an address, by profile email or email identity.
    private func holders(_ email: String) async throws -> Int {
        try await count("""
            SELECT count(DISTINCT id) AS n FROM (
                SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) AND lifecycle_state <> 'deleted'
                UNION ALL SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)) h
            """)
    }
    private func appleFootprint(_ subject: String) async throws -> (users: Int, identities: Int) {
        (try await count("SELECT count(*) AS n FROM users WHERE apple_user_id = \(bind: subject)"),
         try await count("SELECT count(*) AS n FROM user_identities WHERE provider = 'apple' AND subject = \(bind: subject)"))
    }

    private func attemptApple(_ subject: String, _ email: String, on db: any Database) async -> Result<User, any Error> {
        do { return .success(try await verified(subject, email, on: db)) } catch { return .failure(error) }
    }
    private func attemptLink(_ email: String, on db: any Database) async -> Result<User, any Error> {
        do {
            return .success(try await VerifiedIdentityService.transactionRetryingIdentityRace(on: db) { tx in
                try await VerifiedIdentityService.resolveEmail(email, name: "Link person", on: tx)
            })
        } catch { return .failure(error) }
    }

    func testTheRecoverySentenceNamesHowTheExistingAccountSignsIn() async throws {
        XCTAssertEqual(ExistingAccountRecovery.message([.google]),
                       "This email already belongs to a Snaglist account that signs in with Google. Sign in that way to reach it. Accounts are never joined by email.")
        XCTAssertEqual(ExistingAccountRecovery.message([.emailLink]),
                       "This email already belongs to a Snaglist account that signs in with a sign-in link sent to this address. Sign in that way to reach it. Accounts are never joined by email.")
        XCTAssertEqual(ExistingAccountRecovery.message([.emailLink, .google, .emailLink]),
                       "This email already belongs to a Snaglist account that signs in with Google or a sign-in link sent to this address. Sign in that way to reach it. Accounts are never joined by email.")
        XCTAssertEqual(ExistingAccountRecovery.message([.apple, .google, .emailLink]),
                       "This email already belongs to a Snaglist account that signs in with a different Apple ID, Google or a sign-in link sent to this address. Sign in that way to reach it. Accounts are never joined by email.")
        for methods in [[], [ExistingAccountRecovery.Method.apple], [.google], [.emailLink], [.google, .emailLink]] {
            XCTAssertTrue(ExistingAccountRecovery.message(methods).hasPrefix("This email already belongs to a Snaglist account"),
                          "the iOS client matches this prefix")
        }

        // A verified first sign-in is told the existing account's method; the identifier never changes.
        let linkAddress = "link-\(UUID().uuidString.lowercased())@example.test"
        _ = try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail(linkAddress, name: "Link owner", on: db) }
        do { _ = try await verified("apple-\(UUID())", linkAddress); XCTFail("expected a refusal") } catch let abort as Abort {
            XCTAssertEqual(abort.status, .conflict); XCTAssertEqual(abort.identifier, "identity_proof_required")
            XCTAssertEqual(abort.reason, ExistingAccountRecovery.message([.emailLink]))
            XCTAssertEqual(abort.headers.first(name: ExistingAccountRecovery.methodsHeader), "email_link")
        }
        // An older account with no identity rows is described by how it was created.
        let legacy = "legacy-\(UUID().uuidString.lowercased())@example.test"
        let old = User(appleUserId: nil, email: legacy, name: "Older Google profile", authProvider: .google)
        try await old.save(on: app.db)
        do { _ = try await verified("apple-\(UUID())", legacy); XCTFail("expected a refusal") } catch let abort as Abort {
            XCTAssertEqual(abort.reason, ExistingAccountRecovery.message([.google]))
        }
    }

    func testTwoSimultaneousFirstSignInsForOneNewAppleSubjectMakeOneAccount() async throws {
        let (first, second) = twoConnections()
        for round in 0..<6 {
            let subject = "apple-race-\(round)-\(UUID())", email = "race-\(UUID().uuidString.lowercased())@privaterelay.appleid.com"
            async let a = verified(subject, email, on: first)
            async let b = verified(subject, email, on: second)
            let (one, two) = try await (a, b)
            XCTAssertEqual(one.id, two.id, "both sign-ins reach the one account")
            let footprint = try await appleFootprint(subject)
            XCTAssertEqual(footprint.users, 1); XCTAssertEqual(footprint.identities, 1)
            let owned = try await count("SELECT count(*) AS n FROM user_identities WHERE provider = 'email' AND subject = \(bind: email) AND user_id = \(bind: one.requireID())")
            XCTAssertEqual(owned, 1)
            let holding = try await holders(email)
            XCTAssertEqual(holding, 1)
        }
    }

    func testSimultaneousAppleAndEmailCreationForOneAddressMakeOneAccount() async throws {
        let (first, second) = twoConnections()
        for round in 0..<6 {
            let subject = "apple-vs-link-\(round)-\(UUID())", email = "both-\(UUID().uuidString.lowercased())@example.test"
            async let apple = attemptApple(subject, email, on: first)
            async let link = attemptLink(email, on: second)
            let (appleResult, linkResult) = await (apple, link)
            let holding = try await holders(email)
            XCTAssertEqual(holding, 1, "exactly one account holds the address")
            let footprint = try await appleFootprint(subject)
            switch (appleResult, linkResult) {
            case (.success(let viaApple), .success(let viaLink)):
                // Apple first: the link then proves the address the Apple account already holds.
                XCTAssertEqual(viaApple.id, viaLink.id)
                XCTAssertEqual(footprint.users, 1); XCTAssertEqual(footprint.identities, 1)
            case (.failure(let error), .success):
                // The link first: Apple is refused and leaves nothing behind.
                XCTAssertEqual((error as? Abort)?.identifier, "identity_proof_required", "\(error)")
                XCTAssertEqual(footprint.users, 0); XCTAssertEqual(footprint.identities, 0)
            default:
                XCTFail("unexpected outcome: \(appleResult) / \(linkResult)")
            }
        }
    }

    /// The checks are not what makes this safe: a writer that takes no advisory lock (a
    /// stand-in for any future path) still cannot create a second account, because the
    /// unique constraints decide and the loser's transaction rolls back whole.
    func testTheDatabaseDecidesASameSubjectRaceEvenWithoutTheLock() async throws {
        let (first, second) = twoConnections()
        let subject = "apple-nolock-\(UUID())"
        let winner = Task {
            try await first.transaction { tx -> UUID in
                let user = User(appleUserId: subject, email: nil, name: "Lock-free writer")
                try await user.save(on: tx)
                _ = try await VerifiedIdentityService.claimIdentity(provider: "apple", subject: subject, userID: user.requireID(), on: tx)
                try await Task.sleep(nanoseconds: 1_500_000_000)   // hold the uncommitted rows
                return try user.requireID()
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let late = try await verified(subject, nil, on: second)       // blocks on the unique key, then retries
        let won = try await winner.value
        XCTAssertEqual(late.id, won, "the retry signs in to the winner")
        let footprint = try await appleFootprint(subject)
        XCTAssertEqual(footprint.users, 1); XCTAssertEqual(footprint.identities, 1)
    }

    func testTheDatabaseDecidesAnAddressRaceEvenWithoutTheLock() async throws {
        let (first, second) = twoConnections()
        let subject = "apple-nolock-address-\(UUID())", email = "nolock-\(UUID().uuidString.lowercased())@example.test"
        let winner = Task {
            try await first.transaction { tx -> UUID in
                let user = User(appleUserId: nil, email: email, name: "Lock-free link writer", authProvider: .magicLink)
                try await user.save(on: tx)
                _ = try await VerifiedIdentityService.claimIdentity(provider: "email", subject: email, userID: user.requireID(), on: tx)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return try user.requireID()
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await verified(subject, email, on: second)
            XCTFail("the address was claimed first; Apple must be refused")
        } catch let abort as Abort {
            XCTAssertEqual(abort.identifier, "identity_proof_required")
            XCTAssertEqual(abort.reason, ExistingAccountRecovery.message([.emailLink]))
        }
        _ = try await winner.value
        let footprint = try await appleFootprint(subject)
        XCTAssertEqual(footprint.users, 0, "the refused account's row rolled back"); XCTAssertEqual(footprint.identities, 0, "no orphan identity")
        let holding = try await holders(email)
        XCTAssertEqual(holding, 1)
    }
}
