@testable import App
import XCTVapor
import Fluent
import JWT

/// Isolated PostgreSQL fixtures only; these tests do not deliver email.
final class AccountIdentityGuardTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user(email: String) async throws -> (User, String) {
        let user = User(appleUserId: nil, email: email, name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        return (user, jwt)
    }

    private func request(_ method: HTTPMethod, _ path: String, token: String? = nil, body: [String: String]) async throws -> XCTHTTPResponse {
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            try req.content.encode(body)
        }, afterResponse: { response async in result = response })
        return result
    }

    func testProfileCannotReplaceEmailOrPartiallySaveOtherFields() async throws {
        let original = "identity-\(UUID())@example.test"
        let (record, jwt) = try await user(email: original)
        let response = try await request(.PATCH, "api/v1/users/me", token: jwt, body: ["email": "someone-else@example.test", "name": "Changed name"])
        XCTAssertEqual(response.status, .conflict)
        let reloaded = try await User.find(record.requireID(), on: app.db)
        XCTAssertEqual(reloaded?.email, original)
        XCTAssertEqual(reloaded?.name, "Synthetic manager")
    }

    func testUnchangedNormalizedEmailStillAllowsOrdinaryProfileUpdate() async throws {
        let original = "identity-\(UUID().uuidString.lowercased())@example.test"
        let (record, jwt) = try await user(email: original)
        let response = try await request(.PATCH, "api/v1/users/me", token: jwt, body: ["email": " \(original.uppercased()) ", "name": "Updated manager"])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let reloaded = try await User.find(record.requireID(), on: app.db)
        XCTAssertEqual(reloaded?.email, original)
        XCTAssertEqual(reloaded?.name, "Updated manager")
    }

    func testAmbiguousLegacyEmailDoesNotPickAnAccountOrConsumeTheToken() async throws {
        let email = "duplicate-\(UUID().uuidString.lowercased())@example.test"
        _ = try await user(email: email)
        _ = try await user(email: email.uppercased())
        let raw = "identity-\(UUID())"
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw), email: email, expiresAt: Date().addingTimeInterval(900))
        try await token.save(on: app.db)
        let response = try await request(.POST, "api/v1/auth/magic-link/verify", body: ["token": raw])
        XCTAssertEqual(response.status, .conflict, response.body.string)
        let reloaded = try await MagicLinkAuthToken.find(token.requireID(), on: app.db)
        XCTAssertNil(reloaded?.consumedAt)
    }

    func testCaseVariantSignInResolvesTheVerifiedExistingIdentity() async throws {
        let email = "identity-\(UUID().uuidString.lowercased())@example.test"
        let (record, _) = try await user(email: email.uppercased())
        try await app.db.transaction { db in
            try await VerifiedIdentityService.linkEmail(email, to: record.requireID(), on: db)
        }
        let raw = "identity-\(UUID())"
        let token = MagicLinkAuthToken(tokenHash: SHA256Hasher.hash(token: raw), email: email, expiresAt: Date().addingTimeInterval(900))
        try await token.save(on: app.db)
        let response = try await request(.POST, "api/v1/auth/magic-link/verify", body: ["token": raw])
        XCTAssertEqual(response.status, .ok, response.body.string)
        let body = try response.content.decode(AuthResponse.self)
        XCTAssertEqual(body.user.id, try record.requireID())
    }
}
