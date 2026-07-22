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

    override func setUp() async throws {
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        guard dbAvailable else { return }
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
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
        for _ in 0..<5 { try await MagicLinkSend(userId: user.id!, magicLinkId: UUID()).save(on: app.db) }

        let link = try await makeLink(ownedBy: user.id!)
        let r = try await send(link.id!, token: token)
        XCTAssertEqual(r.status, .forbidden)
    }

    func testProTierIsUnlimited() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (user, token) = try await makeUser()
        user.onboardingLinkConsumed = true
        user.subscriptionTier = SubscriptionTier.pro.rawValue
        try await user.save(on: app.db)
        for _ in 0..<5 { try await MagicLinkSend(userId: user.id!, magicLinkId: UUID()).save(on: app.db) }

        let link = try await makeLink(ownedBy: user.id!)
        let r = try await send(link.id!, token: token)
        XCTAssertEqual(r.status, .ok, "pro tier must not hit the paywall")
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

    func testTierUpdateViaProfile() async throws {
        try XCTSkipUnless(dbAvailable, "DATABASE_URL not set")
        let (_, token) = try await makeUser()
        try await app.test(.PATCH, "api/v1/users/me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(UpdateUserProfileRequest(name: nil, email: nil, subscriptionTier: "pro"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let p = try? res.content.decode(UserProfileResponse.self)
            XCTAssertEqual(p?.subscriptionTier, "pro")
        })
    }
}
