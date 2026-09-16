@testable import App
import XCTVapor
import Fluent
import FluentSQL
import Crypto

/// Sign in with Apple: the audience this server accepts, and the credential account
/// deletion needs in order to revoke. No network is involved in any of these — the
/// exchange itself is exercised against staging, not here.
final class AppleCredentialTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AppleCredentialKeyStorage.self] = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
    }

    override func tearDown() async throws {
        for key in ["APPLE_BUNDLE_ID", "PLATFORM_ENVIRONMENT"] { unsetenv(key) }
        if let app { try await app.asyncShutdown() }
    }

    private func user() async throws -> User {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("apple-\(UUID())@example.test", name: "Synthetic site manager", on: db)
        }
    }

    // MARK: - Audience

    func testTheShippingAudienceIsAcceptedWithNoConfigurationAtAll() throws {
        unsetenv("APPLE_BUNDLE_ID")
        XCTAssertEqual(AppleIdentityConfiguration.load(on: app).audiences, ["com.snaglist.app"])
    }

    func testStagingAcceptsItsOwnAudienceOnlyWhenItNamesIt() throws {
        setenv("PLATFORM_ENVIRONMENT", "staging", 1)
        setenv("APPLE_BUNDLE_ID", "com.snaglist.app.staging", 1)
        XCTAssertEqual(AppleIdentityConfiguration.load(on: app).audiences,
                       ["com.snaglist.app", "com.snaglist.app.staging"])
    }

    /// The failure that would matter: a staging bundle accepted by a production
    /// deployment because the pairing was never checked.
    func testProductionNeverAcceptsTheStagingAudience() throws {
        setenv("PLATFORM_ENVIRONMENT", "production", 1)
        setenv("APPLE_BUNDLE_ID", "com.snaglist.app.staging", 1)
        XCTAssertEqual(AppleIdentityConfiguration.load(on: app).audiences, ["com.snaglist.app"])
    }

    func testAnUnrecognisedAudienceIsIgnoredRatherThanTrusted() throws {
        setenv("PLATFORM_ENVIRONMENT", "staging", 1)
        setenv("APPLE_BUNDLE_ID", "com.someone.else", 1)
        XCTAssertEqual(AppleIdentityConfiguration.load(on: app).audiences, ["com.snaglist.app"])
    }

    // MARK: - Credential storage

    func testACredentialSurvivesARoundTrip() async throws {
        let user = try await self.user(), id = try user.requireID()
        try await AppleCredentialService.store(refreshToken: "synthetic-refresh-token", userID: id,
                                               clientID: "com.snaglist.app.staging", app: app, on: app.db)
        let loaded = try await AppleCredentialService.load(userID: id, app: app, on: app.db)
        XCTAssertEqual(loaded?.refreshToken, "synthetic-refresh-token")
        XCTAssertEqual(loaded?.clientID, "com.snaglist.app.staging")
    }

    /// The user's identifier is the additional authenticated data, so a row lifted from
    /// one account cannot be opened as another.
    func testACredentialCannotBeOpenedAsADifferentUser() async throws {
        let owner = try await user(), other = try await user()
        let sealed = try AppleCredentialService.seal("synthetic-refresh-token", userID: try owner.requireID(), app: app)
        XCTAssertThrowsError(try AppleCredentialService.open(sealed, userID: try other.requireID(), app: app))
    }

    func testSigningInAgainReplacesTheCredentialRatherThanAccumulating() async throws {
        let user = try await self.user(), id = try user.requireID()
        try await AppleCredentialService.store(refreshToken: "first", userID: id, clientID: "com.snaglist.app", app: app, on: app.db)
        try await AppleCredentialService.store(refreshToken: "second", userID: id, clientID: "com.snaglist.app", app: app, on: app.db)
        let rows = try await VerifiedIdentityService.sql(app.db)
            .raw("SELECT count(*) AS total FROM apple_credentials WHERE user_id = \(bind: id)").first()
        XCTAssertEqual(try rows?.decode(column: "total", as: Int.self), 1)
        let loaded = try await AppleCredentialService.load(userID: id, app: app, on: app.db)
        XCTAssertEqual(loaded?.refreshToken, "second")
    }

    func testDiscardingLeavesNothingBehind() async throws {
        let user = try await self.user(), id = try user.requireID()
        try await AppleCredentialService.store(refreshToken: "spent", userID: id, clientID: "com.snaglist.app", app: app, on: app.db)
        try await AppleCredentialService.discard(userID: id, on: app.db)
        let loaded = try await AppleCredentialService.load(userID: id, app: app, on: app.db)
        XCTAssertNil(loaded)
    }

    // MARK: - The request contract

    /// The app has always sent this field; the server declared a type that dropped it.
    func testTheSignInRequestCarriesTheAuthorizationCode() throws {
        let body = #"{"identityToken":"t","authorizationCode":"c","firstName":"Dan","lastName":null}"#
        let decoded = try JSONDecoder().decode(AppleSignInRequest.self, from: Data(body.utf8))
        XCTAssertEqual(decoded.authorizationCode, "c")
    }

    /// An older client that sends no code still signs in.
    func testTheSignInRequestStillDecodesWithoutOne() throws {
        let body = #"{"identityToken":"t","firstName":null,"lastName":null}"#
        let decoded = try JSONDecoder().decode(AppleSignInRequest.self, from: Data(body.utf8))
        XCTAssertNil(decoded.authorizationCode)
    }

    // MARK: - Configuration

    func testAPartialExchangeConfigurationIsRefusedRatherThanHalfApplied() throws {
        for key in ["APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY", "APPLE_CLIENT_ID"] { unsetenv(key) }
        setenv("APPLE_TEAM_ID", "ABCDE12345", 1)
        setenv("APPLE_CLIENT_ID", "com.snaglist.app.staging", 1)
        XCTAssertNil(AppleTokenExchange.load(), "A team without a key or private key must not configure an exchange")
        for key in ["APPLE_TEAM_ID", "APPLE_CLIENT_ID"] { unsetenv(key) }
    }
}
