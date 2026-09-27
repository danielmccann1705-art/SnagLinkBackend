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
        XCTAssertEqual(body.reason, "This email already belongs to a Snaglist account. Sign in the way you first did — with Google, or with a sign-in link to that address")
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
    }
}
