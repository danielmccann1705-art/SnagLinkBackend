@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// Transactional signup authority; no provider network or analytics delivery.
final class IdentityCreationOutcomeTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testEmailRepeatIsNotNewEvenWhenTimestampsAreIdentical() async throws {
        let email = "creation-\(UUID())@example.test"
        let first = try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmailOutcome(email, name: nil, on: $0)
        }
        let id = try first.user.requireID()
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE users SET updated_at=created_at WHERE id=\(bind: id)").run()
        let second = try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmailOutcome(email, name: nil, on: $0)
        }
        XCTAssertTrue(first.insertedNewAccount)
        XCTAssertFalse(second.insertedNewAccount)
        XCTAssertEqual(second.user.id, first.user.id)
        XCTAssertEqual(second.user.createdAt, second.user.updatedAt)
    }

    func testAppleCreationRepeatAndLegacyAdoptionAreDistinct() async throws {
        let subject = "creation-apple-\(UUID())"
        let first = try await app.db.transaction {
            try await VerifiedIdentityService.resolveAppleOutcome(subject: subject, email: nil, name: nil, on: $0)
        }
        let second = try await app.db.transaction {
            try await VerifiedIdentityService.resolveAppleOutcome(subject: subject, email: nil, name: nil, on: $0)
        }
        let legacy = User(appleUserId: "legacy-\(UUID())", email: nil, name: nil)
        try await legacy.save(on: app.db)
        let adopted = try await app.db.transaction {
            try await VerifiedIdentityService.resolveAppleOutcome(subject: legacy.appleUserId!, email: nil, name: nil, on: $0)
        }
        XCTAssertTrue(first.insertedNewAccount)
        XCTAssertFalse(second.insertedNewAccount)
        XCTAssertFalse(adopted.insertedNewAccount)
        XCTAssertEqual(first.user.id, second.user.id)
        XCTAssertEqual(adopted.user.id, legacy.id)
    }

    func testGoogleCreationRepeatAndExplicitLinkAreDistinct() async throws {
        let proof = GoogleIdentityProof(subject: "creation-google-\(UUID())", contactEmail: nil,
                                        displayName: nil, contactEmailIsVerified: false)
        let first = try await app.db.transaction { try await GoogleIdentityService.resolveOutcome(proof, on: $0) }
        let second = try await app.db.transaction { try await GoogleIdentityService.resolveOutcome(proof, on: $0) }
        let owner = try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmail("linked-owner-\(UUID())@example.test", name: nil, on: $0)
        }
        let linked = GoogleIdentityProof(subject: "linked-google-\(UUID())", contactEmail: nil,
                                         displayName: nil, contactEmailIsVerified: false)
        try await app.db.transaction { try await GoogleIdentityService.link(linked, to: owner.requireID(), on: $0) }
        let resolved = try await app.db.transaction { try await GoogleIdentityService.resolveOutcome(linked, on: $0) }
        XCTAssertTrue(first.insertedNewAccount)
        XCTAssertFalse(second.insertedNewAccount)
        XCTAssertFalse(resolved.insertedNewAccount)
        XCTAssertEqual(first.user.id, second.user.id)
        XCTAssertEqual(resolved.user.id, owner.id)
    }

    func testConcurrentFirstAppleSignInsHaveExactlyOneCreator() async throws {
        let subject = "concurrent-creation-\(UUID())", db = app.db
        let results = try await withThrowingTaskGroup(of: VerifiedIdentityService.Resolution.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await VerifiedIdentityService.transactionRetryingIdentityRace(on: db) {
                        try await VerifiedIdentityService.resolveAppleOutcome(subject: subject, email: nil, name: nil, on: $0)
                    }
                }
            }
            var values: [VerifiedIdentityService.Resolution] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter(\.insertedNewAccount).count, 1)
        XCTAssertEqual(Set(results.compactMap { $0.user.id }).count, 1)
    }

    func testWebAppleCreationBecomesAnExistingNativeAccount() async throws {
        let proof = AppleWebProof(subject: "web-creation-\(UUID())", email: nil, emailVerified: false)
        let first = try await app.db.transaction { try await AppleWebIdentityService.resolveOutcome(proof, name: nil, on: $0) }
        let native = try await app.db.transaction {
            try await VerifiedIdentityService.resolveAppleOutcome(subject: proof.subject, email: nil, name: nil, on: $0)
        }
        let webAgain = try await app.db.transaction { try await AppleWebIdentityService.resolveOutcome(proof, name: nil, on: $0) }
        XCTAssertTrue(first.insertedNewAccount)
        XCTAssertFalse(native.insertedNewAccount)
        XCTAssertFalse(webAgain.insertedNewAccount)
        XCTAssertEqual(first.user.id, native.user.id)
        XCTAssertEqual(first.user.id, webAgain.user.id)
    }

    func testRolledBackCreationDoesNotTurnLaterInsertIntoExistingLogin() async throws {
        let email = "rollback-creation-\(UUID())@example.test"
        do {
            try await app.db.transaction { db in
                _ = try await VerifiedIdentityService.resolveEmailOutcome(email, name: nil, on: db)
                throw Abort(.conflict, reason: "Synthetic rollback")
            }
            XCTFail("Expected rollback")
        } catch { XCTAssertEqual((error as? Abort)?.status, .conflict) }
        let next = try await app.db.transaction {
            try await VerifiedIdentityService.resolveEmailOutcome(email, name: nil, on: $0)
        }
        XCTAssertTrue(next.insertedNewAccount)
        let count = try await User.query(on: app.db).filter(\.$email == EmailValidator.normalize(email)).count()
        XCTAssertEqual(count, 1)
    }
}
