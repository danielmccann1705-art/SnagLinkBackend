@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// PostgreSQL transactions with synthetic identities only. Cryptographic provider
/// proof is covered separately; these are not live Google login acceptance tests.
final class GoogleIdentityIntegrationTests: XCTestCase {
    var app: Application!
    let platform = PlatformConfiguration(origin: "https://portal.example.test", environment: "local")
    let provider = GoogleIdentityConfiguration(webClientID: "12345-syntheticweb.apps.googleusercontent.com", iosClientID: "12345-syntheticios.apps.googleusercontent.com")
    let binding = String(repeating: "browser-proof-", count: 3)

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func proof(email: String? = nil) -> GoogleIdentityProof {
        .init(subject: "synthetic-google-\(UUID())", contactEmail: email.map(EmailValidator.normalize), displayName: "Synthetic manager")
    }
    func apple() async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveApple(subject: "synthetic-apple-\(UUID())", email: nil, name: "Existing manager", on: db)
        }
    }
    func challenge() async throws -> GoogleIdentityChallengeService.Issued {
        try await GoogleIdentityChallengeService.issue(purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: app.db)
    }
    func consume(_ raw: String, db: Database) async throws -> GoogleIdentityChallengeService.Context {
        try await GoogleIdentityChallengeService.consume(raw, purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: db)
    }
    func assertStatus(_ status: HTTPStatus, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual((error as? Abort)?.status, status, file: file, line: line) }
    }

    func testStableGoogleIdentityDoesNotBecomeVerifiedEmailOrChangeOnContactHint() async throws {
        let first = proof(email: "google-\(UUID())@example.test")
        let user = try await app.db.transaction { db in try await GoogleIdentityService.resolve(first, on: db) }
        let returned = try await app.db.transaction { db in
            try await GoogleIdentityService.resolve(.init(subject: first.subject, contactEmail: "changed-\(UUID())@example.test", displayName: "Changed"), on: db)
        }
        XCTAssertEqual(returned.id, user.id); XCTAssertEqual(returned.authProvider, "google")
        XCTAssertEqual(returned.email, first.contactEmail)
        let emails = try await VerifiedIdentityService.verifiedEmails(for: user.requireID(), on: app.db)
        XCTAssertTrue(emails.isEmpty, "Google contact hints cannot satisfy company invitation email proof")
    }

    func testExplicitGoogleLinkKeepsExistingAppleUserAndPurchaseIdentity() async throws {
        let user = try await apple(), google = proof()
        user.subscriptionTier = "pro"; user.subscriptionVerifiedUntil = Date().addingTimeInterval(3600)
        try await user.save(on: app.db)
        for _ in 0..<2 {
            try await app.db.transaction { db in try await GoogleIdentityService.link(google, to: user.requireID(), on: db) }
        }
        let returned = try await app.db.transaction { db in try await GoogleIdentityService.resolve(google, on: db) }
        XCTAssertEqual(returned.id, user.id); XCTAssertEqual(returned.appleUserId, user.appleUserId)
        XCTAssertEqual(returned.authProvider, "apple"); XCTAssertEqual(returned.subscriptionTier, "pro")
        XCTAssertEqual(returned.name, "Existing manager")
    }

    func testEmailCollisionNeverSelectsOrTransfersExistingAccount() async throws {
        let user = try await apple(), email = "existing-\(UUID())@example.test"
        user.email = email; try await user.save(on: app.db)
        let google = proof(email: email)
        await assertStatus(.conflict) {
            _ = try await self.app.db.transaction { db in try await GoogleIdentityService.resolve(google, on: db) }
        }
        let n = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM user_identities WHERE provider = 'google' AND subject = \(bind: google.subject)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(n, 0)
        try await app.db.transaction { db in try await GoogleIdentityService.link(google, to: user.requireID(), on: db) }
        let resolved = try await app.db.transaction { db in try await GoogleIdentityService.resolve(google, on: db) }
        XCTAssertEqual(resolved.id, user.id)
    }

    func testGoogleIdentityCannotMoveAccountsOrReplaceAnExistingGoogleLink() async throws {
        let one = try await apple(), two = try await apple(), google = proof(), another = proof()
        try await app.db.transaction { db in try await GoogleIdentityService.link(google, to: one.requireID(), on: db) }
        await assertStatus(.conflict) { try await self.app.db.transaction { db in try await GoogleIdentityService.link(google, to: two.requireID(), on: db) } }
        await assertStatus(.conflict) { try await self.app.db.transaction { db in try await GoogleIdentityService.link(another, to: one.requireID(), on: db) } }
    }

    func testChallengeStoresOnlyHashesAndRejectsWrongContextWithoutConsumption() async throws {
        let issued = try await challenge()
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT token_hash, nonce_hash, binding_hash FROM google_identity_challenges WHERE token_hash = \(bind: SHA256Hasher.hash(token: issued.token))").first()!
        XCTAssertNotEqual(try row.decode(column: "token_hash", as: String.self), issued.token)
        XCTAssertEqual(try row.decode(column: "nonce_hash", as: String.self), SHA256Hasher.hash(token: issued.nonce))
        XCTAssertNotEqual(try row.decode(column: "binding_hash", as: String.self), binding)
        await assertStatus(.conflict) {
            _ = try await GoogleIdentityChallengeService.context(issued.token, purpose: .signIn, surface: .web, binding: String(repeating: "wrong", count: 10), platform: self.platform, provider: self.provider, on: self.app.db)
        }
        await assertStatus(.gone) {
            _ = try await GoogleIdentityChallengeService.context(issued.token, purpose: .signIn, surface: .ios, binding: self.binding, platform: self.platform, provider: self.provider, on: self.app.db)
        }
        await assertStatus(.gone) {
            _ = try await GoogleIdentityChallengeService.context(issued.token, purpose: .signIn, surface: .web, binding: self.binding, platform: .init(origin: self.platform.origin, environment: "staging"), provider: self.provider, on: self.app.db)
        }
        _ = try await app.db.transaction { db in try await self.consume(issued.token, db: db) }
        await assertStatus(.gone) { _ = try await self.app.db.transaction { db in try await self.consume(issued.token, db: db) } }
    }

    func testConcurrentSignInConsumesOnceAndCreatesExactlyOneSession() async throws {
        let issued = try await challenge(), google = proof()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask {
                do {
                    try await self.app.db.transaction { db in
                        _ = try await self.consume(issued.token, db: db)
                        let user = try await GoogleIdentityService.resolve(google, on: db)
                        _ = try await BrowserSessionService.create(for: user, config: self.platform, on: db)
                    }
                    return true
                } catch { return false }
            } }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let n = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM browser_sessions s JOIN user_identities i ON i.user_id = s.user_id WHERE i.provider = 'google' AND i.subject = \(bind: google.subject)").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(n, 1)
    }

    func testFailedIdentityResolutionRollsBackConsumptionAndExpiryRejects() async throws {
        let issued = try await challenge(), user = try await apple(), email = "collision-\(UUID())@example.test"
        user.email = email; try await user.save(on: app.db)
        let google = proof(email: email)
        await assertStatus(.conflict) {
            _ = try await self.app.db.transaction { db in
                _ = try await self.consume(issued.token, db: db)
                return try await GoogleIdentityService.resolve(google, on: db)
            }
        }
        _ = try await GoogleIdentityChallengeService.context(issued.token, purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: app.db)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE google_identity_challenges SET expires_at = \(bind: Date().addingTimeInterval(-1)) WHERE token_hash = \(bind: SHA256Hasher.hash(token: issued.token))").run()
        await assertStatus(.gone) { _ = try await self.app.db.transaction { db in try await self.consume(issued.token, db: db) } }
    }

    func testLinkChallengeCannotCrossAccountsOrSurviveSessionRevocation() async throws {
        let user = try await apple(), other = try await apple()
        let session = try await BrowserSessionService.create(for: user, config: platform, on: app.db)
        let issued = try await GoogleIdentityChallengeService.issue(purpose: .link, surface: .web, binding: binding,
            targetUserID: user.requireID(), browserSessionID: session.principal.sessionID, platform: platform, provider: provider, on: app.db)
        await assertStatus(.conflict) {
            _ = try await GoogleIdentityChallengeService.context(issued.token, purpose: .link, surface: .web, binding: self.binding, targetUserID: other.requireID(), browserSessionID: session.principal.sessionID, platform: self.platform, provider: self.provider, on: self.app.db)
        }
        try await BrowserSessionService.revoke(session.principal.sessionID, on: app.db)
        await assertStatus(.unauthorized) {
            _ = try await self.app.db.transaction { db in
                try await GoogleIdentityChallengeService.consume(issued.token, purpose: .link, surface: .web, binding: self.binding, targetUserID: user.requireID(), browserSessionID: session.principal.sessionID, platform: self.platform, provider: self.provider, on: db)
            }
        }
        let native = try await GoogleIdentityChallengeService.issue(purpose: .link, surface: .ios, binding: binding, targetUserID: user.requireID(), platform: platform, provider: provider, on: app.db)
        try await BrowserSessionService.revokeAll(for: user.requireID(), on: app.db)
        await assertStatus(.unauthorized) {
            _ = try await self.app.db.transaction { db in try await GoogleIdentityChallengeService.consume(native.token, purpose: .link, surface: .ios, binding: self.binding, targetUserID: user.requireID(), platform: self.platform, provider: self.provider, on: db) }
        }
    }
}
