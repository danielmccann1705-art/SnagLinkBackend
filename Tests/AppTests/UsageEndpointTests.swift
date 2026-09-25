@testable import App
import XCTVapor
import Fluent
import JWT
import Foundation

// MARK: - Pure unit tests (no database)

final class UsageServiceUnitTests: XCTestCase {

    func testFreeMonthlyLimit() {
        XCTAssertEqual(UsageService.freeMonthlyLimit, 5)
    }

    func testLinksRemainingFree() {
        XCTAssertEqual(UsageService.linksRemaining(tier: .free, count: 0), 5)
        XCTAssertEqual(UsageService.linksRemaining(tier: .free, count: 4), 1)
        XCTAssertEqual(UsageService.linksRemaining(tier: .free, count: 5), 0)
        XCTAssertEqual(UsageService.linksRemaining(tier: .free, count: 7), 0) // never negative
    }

    func testLinksRemainingProIsUnlimitedSentinel() {
        // Pro always reports the full allowance (meter hidden client-side).
        XCTAssertEqual(UsageService.linksRemaining(tier: .pro, count: 99), 5)
    }

    func testMonthBoundaries() {
        let now = Date()
        let start = UsageService.startOfCurrentMonth(now)
        let reset = UsageService.monthlyResetDate(now)
        XCTAssertLessThanOrEqual(start, now)
        XCTAssertLessThan(now, reset)
        // reset is exactly one month after start.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.date(byAdding: .month, value: 1, to: start), reset)
    }
}

// MARK: - Endpoint integration tests (require DATABASE_URL)

/// B4: /users/me/usage + the send counter. Skipped without `DATABASE_URL`; runs in CI (§5.T5).
final class UsageEndpointTests: XCTestCase {
    var app: Application!
    var dbAvailable: Bool { Environment.get("DATABASE_URL") != nil }
    private var previousProviderKey: String?

    override func setUp() async throws {
        previousProviderKey = Environment.get("REVENUECAT_SECRET_API_KEY")
        unsetenv("REVENUECAT_SECRET_API_KEY")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        guard dbAvailable else { return }
        app = try await Application.make(.testing)
        try await configure(app)
        // Fail unexpected outbound calls locally; these tests never contact RevenueCat.
        let blocked = SubscriptionProviderStub(expectedUserID: nil, status: .serviceUnavailable, json: "{}")
        app.clients.use { SubscriptionTestClient(eventLoop: $0.eventLoopGroup.next(), stub: blocked) }
    }

    override func tearDown() async throws {
        defer {
            if let previousProviderKey { setenv("REVENUECAT_SECRET_API_KEY", previousProviderKey, 1) }
            else { unsetenv("REVENUECAT_SECRET_API_KEY") }
        }
        if let app { try await app.asyncShutdown() }
        app = nil
    }

    private func provider(userID: UUID, status: HTTPResponseStatus = .ok, json: String) -> SubscriptionProviderStub {
        let stub = SubscriptionProviderStub(expectedUserID: userID, status: status, json: json)
        app.clients.use { SubscriptionTestClient(eventLoop: $0.eventLoopGroup.next(), stub: stub) }
        setenv("REVENUECAT_SECRET_API_KEY", "test-only-provider-key", 1)
        return stub
    }

    private func claimPro(token: String, expectedStatus: HTTPResponseStatus) async throws {
        try await app.test(.PATCH, "api/v1/users/me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(UpdateUserProfileRequest(name: nil, email: nil, subscriptionTier: "pro"))
        }, afterResponse: { res async in XCTAssertEqual(res.status, expectedStatus) })
    }

    private func makeUser() async throws -> (user: User, token: String) {
        let user = User(appleUserId: nil, email: "pm-\(UUID().uuidString)@example.com", name: "PM", authProvider: .magicLink)
        try await user.save(on: app.db)
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            userId: user.id!
        )
        return (user, try app.jwt.signers.sign(payload))
    }

    private func makeLink(ownedBy userId: UUID, preview: Bool = false) async throws -> MagicLink {
        let link = MagicLink(token: "t-\(UUID().uuidString)", accessLevel: .update,
                             expiresAt: Date().addingTimeInterval(86_400), snagIds: [UUID()],
                             projectId: UUID(), createdById: userId,
                             previewMode: preview, previewExpiresAt: preview ? Date().addingTimeInterval(3600) : nil)
        try await link.save(on: app.db)
        return link
    }

    private func send(_ linkId: UUID, token: String) async throws -> (status: HTTPStatus, usage: UsageResponse?) {
        var result: (HTTPStatus, UsageResponse?) = (.internalServerError, nil)
        try await app.test(.POST, "api/v1/magic-links/\(linkId.uuidString)/send", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(UsageResponse.self))
        })
        return result
    }

    func testUsageRequiresAuth() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        try await app.test(.GET, "api/v1/users/me/usage", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testInitialUsageState() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (_, token) = try await makeUser()
        try await app.test(.GET, "api/v1/users/me/usage", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let u = try? res.content.decode(UsageResponse.self)
            XCTAssertEqual(u?.linksRemainingThisMonth, 5)
            XCTAssertEqual(u?.tier, "free")
            XCTAssertEqual(u?.onboardingLinkConsumed, false)
        })
    }

    func testFirstSendIsExemptThenSecondCounts() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()

        // First send: exempt onboarding link — flips flag, stays at 5, no counted row.
        let link1 = try await makeLink(ownedBy: user.id!)
        let r1 = try await send(link1.id!, token: token)
        XCTAssertEqual(r1.status, .ok)
        XCTAssertEqual(r1.usage?.onboardingLinkConsumed, true)
        XCTAssertEqual(r1.usage?.linksRemainingThisMonth, 5)
        let countAfter1 = try await MagicLinkSend.query(on: app.db).filter(\.$userId == user.id!).count()
        XCTAssertEqual(countAfter1, 0)

        // Second send: counts, decrements to 4.
        let link2 = try await makeLink(ownedBy: user.id!)
        let r2 = try await send(link2.id!, token: token)
        XCTAssertEqual(r2.status, .ok)
        XCTAssertEqual(r2.usage?.linksRemainingThisMonth, 4)
        let countAfter2 = try await MagicLinkSend.query(on: app.db).filter(\.$userId == user.id!).count()
        XCTAssertEqual(countAfter2, 1)
    }

    func testFreeLimitReachedReturns403() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.onboardingLinkConsumed = true
        try await user.save(on: app.db)
        // Seed 5 counted sends this month.
        for _ in 0..<5 {
            let countedLink = try await makeLink(ownedBy: user.id!)
            try await MagicLinkSend(userId: user.id!, magicLinkId: countedLink.requireID()).save(on: app.db)
        }

        let link = try await makeLink(ownedBy: user.id!)
        let r = try await send(link.id!, token: token)
        XCTAssertEqual(r.status, .forbidden)
    }

    func testVerifiedCachedProTierIsUnlimited() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.onboardingLinkConsumed = true
        user.subscriptionTier = SubscriptionTier.pro.rawValue
        user.subscriptionVerifiedUntil = Date().addingTimeInterval(240)
        try await user.save(on: app.db)
        for _ in 0..<5 {
            let countedLink = try await makeLink(ownedBy: user.id!)
            try await MagicLinkSend(userId: user.id!, magicLinkId: countedLink.requireID()).save(on: app.db)
        }

        let link = try await makeLink(ownedBy: user.id!)
        let r = try await send(link.id!, token: token)
        XCTAssertEqual(r.status, .ok, "a current server-verified Pro entitlement permits sends beyond the free limit")
        XCTAssertEqual(r.usage?.tier, "pro")
    }

    func testSendRejectsPreviewLink() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.onboardingLinkConsumed = true
        try await user.save(on: app.db)
        let preview = try await makeLink(ownedBy: user.id!, preview: true)
        let r = try await send(preview.id!, token: token)
        XCTAssertEqual(r.status, .badRequest)
    }

    func testSendRequiresOwnership() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (_, token) = try await makeUser()
        let (other, _) = try await makeUser()
        let link = try await makeLink(ownedBy: other.id!)
        let r = try await send(link.id!, token: token)
        XCTAssertEqual(r.status, .forbidden)
    }

    func testClientProClaimWithoutProviderConfigurationReturns503AndRemainsFree() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        try await claimPro(token: token, expectedStatus: .serviceUnavailable)
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertEqual(persisted?.subscriptionTier, "free")
        XCTAssertNil(persisted?.subscriptionVerifiedUntil)
    }

    func testUnverifiedStoredProCannotGrantUsageOrConsumeASendWithoutProviderConfiguration() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.subscriptionTier = "pro"
        user.onboardingLinkConsumed = true
        try await user.save(on: app.db)
        for _ in 0..<5 {
            let countedLink = try await makeLink(ownedBy: user.id!)
            try await MagicLinkSend(userId: user.id!, magicLinkId: countedLink.requireID()).save(on: app.db)
        }
        let directUsage = try await UsageService.buildUsage(user: user, on: app.db)
        XCTAssertEqual(directUsage.tier, "free")
        XCTAssertEqual(directUsage.linksRemainingThisMonth, 0)
        try await app.test(.GET, "api/v1/users/me/usage", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .serviceUnavailable) })
        let link = try await makeLink(ownedBy: user.id!)
        let result = try await send(link.id!, token: token)
        XCTAssertEqual(result.status, .serviceUnavailable)
        XCTAssertNil(result.usage)
        let count = try await MagicLinkSend.query(on: app.db).filter(\.$userId == user.id!).count()
        XCTAssertEqual(count, 5, "failed verification must not record another send")
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertNil(persisted?.subscriptionVerifiedUntil)
    }

    func testProviderFailureCannotUpgradeFreeUser() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        let stub = provider(userID: user.id!, status: .serviceUnavailable, json: "{}")
        try await claimPro(token: token, expectedStatus: .serviceUnavailable)
        XCTAssertEqual(stub.requestCount, 1)
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertEqual(persisted?.subscriptionTier, "free")
        XCTAssertNil(persisted?.subscriptionVerifiedUntil)
    }

    func testMalformedProviderResponseCannotUpgradeFreeUser() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        for body in ["not-json", "{\"subscriber\":{}}", #"{"subscriber":{"entitlements":{"Snaglist Pro":{}}}}"#] {
            let stub = provider(userID: user.id!, json: body)
            try await app.test(.PATCH, "api/v1/users/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(UpdateUserProfileRequest(name: nil, email: nil, subscriptionTier: "pro"))
            }, afterResponse: { res async in
                XCTAssertTrue([HTTPResponseStatus.internalServerError, .badGateway, .serviceUnavailable].contains(res.status),
                              "Malformed provider data must return a server error, never a successful upgrade")
            })
            XCTAssertEqual(stub.requestCount, 1)
            let persisted = try await User.find(user.id, on: app.db)
            XCTAssertEqual(persisted?.subscriptionTier, "free")
            XCTAssertNil(persisted?.subscriptionVerifiedUntil)
        }
    }

    func testExpiredStoredProIsDowngradedWhenProviderHasNoEntitlement() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.subscriptionTier = "pro"
        user.subscriptionVerifiedUntil = Date().addingTimeInterval(-60)
        user.onboardingLinkConsumed = true
        try await user.save(on: app.db)
        for _ in 0..<5 {
            let countedLink = try await makeLink(ownedBy: user.id!)
            try await MagicLinkSend(userId: user.id!, magicLinkId: countedLink.requireID()).save(on: app.db)
        }
        let stub = provider(userID: user.id!, json: "{\"subscriber\":{\"entitlements\":{}}}")
        try await app.test(.GET, "api/v1/users/me/usage", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let usage = try? res.content.decode(UsageResponse.self)
            XCTAssertEqual(usage?.tier, "free")
            XCTAssertEqual(usage?.linksRemainingThisMonth, 0)
        })
        let link = try await makeLink(ownedBy: user.id!)
        let result = try await send(link.id!, token: token)
        XCTAssertEqual(result.status, .forbidden)
        XCTAssertEqual(stub.requestCount, 1, "the verified downgrade must persist")
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertEqual(persisted?.subscriptionTier, "free")
        XCTAssertNil(persisted?.subscriptionVerifiedUntil)
    }

    func testProviderVerifiedProPersistsWithShortVerificationUsingBackendUserID() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        // RevenueCat's entitlement Identifier is exactly "Snaglist Pro".
        let json = "{\"subscriber\":{\"entitlements\":{\"Snaglist Pro\":{\"expires_date\":\"\(expiry)\",\"grace_period_expires_date\":null}}}}"
        let stub = provider(userID: user.id!, json: json)
        let before = Date()
        try await claimPro(token: token, expectedStatus: .ok)
        XCTAssertEqual(stub.requestCount, 1)
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertEqual(persisted?.subscriptionTier, "pro")
        let verifiedUntil = try XCTUnwrap(persisted?.subscriptionVerifiedUntil)
        XCTAssertGreaterThanOrEqual(verifiedUntil, before.addingTimeInterval(299))
        XCTAssertLessThanOrEqual(verifiedUntil, Date().addingTimeInterval(300))
    }

    /// An active entitlement under any other identifier, including the older `pro`,
    /// is not Pro: the claim is answered, verified and recorded as Free.
    func testProviderEntitlementNamedOnlyProDoesNotUpgrade() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = "{\"subscriber\":{\"entitlements\":{\"pro\":{\"expires_date\":\"\(expiry)\",\"grace_period_expires_date\":null}}}}"
        let stub = provider(userID: user.id!, json: json)
        try await claimPro(token: token, expectedStatus: .ok)
        XCTAssertEqual(stub.requestCount, 1)
        let persisted = try await User.find(user.id, on: app.db)
        XCTAssertEqual(persisted?.subscriptionTier, "free")
        XCTAssertNil(persisted?.subscriptionVerifiedUntil)
    }
}

/// Injectable HTTP client with no network implementation. Shared recording survives event-loop delegation.
private final class SubscriptionProviderStub: @unchecked Sendable {
    let expectedUserID: UUID?
    let status: HTTPResponseStatus
    let json: String
    private let lock = NSLock()
    private var count = 0

    init(expectedUserID: UUID?, status: HTTPResponseStatus, json: String) {
        self.expectedUserID = expectedUserID
        self.status = status
        self.json = json
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private struct SubscriptionTestClient: Client {
    let eventLoop: EventLoop
    let stub: SubscriptionProviderStub

    func delegating(to eventLoop: EventLoop) -> Client {
        SubscriptionTestClient(eventLoop: eventLoop, stub: stub)
    }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        stub.record()
        guard let userID = stub.expectedUserID,
              request.method == .GET,
              request.url.string == "https://api.revenuecat.com/v1/subscribers/\(userID.uuidString)",
              request.headers.bearerAuthorization?.token == "test-only-provider-key" else {
            XCTFail("Unexpected outbound request in subscription test")
            return eventLoop.makeFailedFuture(Abort(.internalServerError))
        }
        return eventLoop.makeSucceededFuture(ClientResponse(status: stub.status,
            headers: ["Content-Type": "application/json"], body: ByteBuffer(string: stub.json)))
    }
}
