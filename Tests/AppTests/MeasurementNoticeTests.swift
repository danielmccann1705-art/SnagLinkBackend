@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT
import Crypto

/// One final optional-measurement notice (FINAL-PRIVACY-NOTICE-2.0.1.md): the exact wording of
/// each version is pinned to its hash, the registry never lets an older grant cover more, and the
/// settings route records the version on the revision. No database needed for the text pins.
final class MeasurementNoticeTextTests: XCTestCase {
    /// Changing any word of a version's text changes its hash. That is a new version, never an edit:
    /// add the new version and its hash here (and in the app's and portal's pins); keep the old ones.
    static let pinned: [String: String] = [
        "measurement-notice-2026-10a": "7114774ba8575793a4663e5da26f5c6d26915a33430eb0ee1cc3250cf1c3fb0e",
        "measurement-notice-2026-10b-singular": "41b904cdfda06c9329b5ce532d7004e000fbd1d4c84235f62f804c27f449a9a0",
        "signup-measurement-v1": "a13966179d9c4674b63c44794aeb7b38fe5c64be4991807c92085ccb475d9363"
    ]

    func testEachVersionsWordingIsPinnedToItsHash() throws {
        XCTAssertEqual(MeasurementNotice.current, "measurement-notice-2026-10a")
        XCTAssertEqual(MeasurementNotice.singularAlternative, "measurement-notice-2026-10b-singular")
        XCTAssertEqual(MeasurementNotice.signupDraft, "signup-measurement-v1")
        for (version, hash) in Self.pinned {
            XCTAssertEqual(MeasurementNotice.textSHA256(version), hash, "\(version): wording changed without a new version")
        }
        XCTAssertNil(MeasurementNotice.textSHA256("measurement-notice-unknown"))
        let every = MeasurementNotice.signupIssueAccepted.union(MeasurementNotice.settingsAccepted)
            .union(MeasurementNotice.portalCovering).union(MeasurementNotice.singularCovering)
        XCTAssertEqual(every, Set(Self.pinned.keys), "every version the server knows has pinned wording")
        for version in every {
            XCTAssertNotNil(version.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression), version)
            let keys = try XCTUnwrap(MeasurementNotice.entries(version)).map(\.key)
            XCTAssertEqual(Set(keys).count, keys.count, "\(version): duplicate keys")
            XCTAssertTrue(try XCTUnwrap(MeasurementNotice.entries(version)).allSatisfy {
                !$0.text.isEmpty && !$0.text.contains("\n") && !$0.text.contains("\t") })
        }
    }

    func testTheCurrentNoticeNamesOnlyTheFlowsThisCandidateCanUse() throws {
        let text = try XCTUnwrap(MeasurementNotice.entries(MeasurementNotice.current)).map(\.text).joined(separator: " ")
        for named in ["PostHog in the EU", "through our server", "LinkedIn", "web portal", "company, team members or contractors",
                      "change or withdraw any choice at any time"] {
            XCTAssertTrue(text.contains(named), "missing \(named)")
        }
        for blocked in ["Singular", "Meta", "Facebook", "advertising identifier", "7 days", "seven days"] {
            XCTAssertFalse(text.contains(blocked), "the current candidate must not name \(blocked)")
        }
        let alternative = try XCTUnwrap(MeasurementNotice.entries(MeasurementNotice.singularAlternative))
        XCTAssertTrue(alternative.contains { $0.text.contains("Singular") && $0.text.contains("Meta") })
        // The two versions differ only in the other-adverts wording.
        let current = try XCTUnwrap(MeasurementNotice.entries(MeasurementNotice.current))
        XCTAssertEqual(current.filter { !$0.key.hasPrefix("purpose.crossCompanyAds.") || $0.key.hasSuffix(".title") },
                       alternative.filter { !$0.key.hasPrefix("purpose.crossCompanyAds.") || $0.key.hasSuffix(".title") })
    }

    func testNoAcceptedGrantCanCoverSingularOrBroadenAnOlderOne() {
        XCTAssertEqual(MeasurementNotice.signupIssueAccepted, ["signup-measurement-v1", "measurement-notice-2026-10a"])
        XCTAssertEqual(MeasurementNotice.settingsAccepted, ["measurement-notice-2026-10a"])
        XCTAssertEqual(SignupIntentService.acceptedNoticeVersions, MeasurementNotice.signupIssueAccepted)
        for version in MeasurementNotice.signupIssueAccepted.union(MeasurementNotice.settingsAccepted) {
            XCTAssertFalse(MeasurementNotice.coversSingular(version), "\(version) must never cover Singular")
        }
        XCTAssertFalse(MeasurementNotice.signupIssueAccepted.contains(MeasurementNotice.singularAlternative))
        XCTAssertFalse(MeasurementNotice.settingsAccepted.contains(MeasurementNotice.singularAlternative))
        XCTAssertFalse(MeasurementNotice.coversPortal(nil), "a revision recorded with no version stays app-only")
        XCTAssertFalse(MeasurementNotice.coversPortal(MeasurementNotice.signupDraft), "the draft stays app-only")
        XCTAssertFalse(MeasurementNotice.coversSingular(nil))
        XCTAssertTrue(MeasurementNotice.coversPortal(MeasurementNotice.current))
        XCTAssertEqual(MeasurementNotice.revisionCoversPortal("c"),
            "EXISTS(SELECT 1 FROM measurement_consent_events notice WHERE notice.account_id=c.account_id AND notice.id=c.revision " +
            "AND notice.notice_version IN ('measurement-notice-2026-10a','measurement-notice-2026-10b-singular'))")
    }

    func testThePortalSwitchIsIndependentAndDefaultsOff() async throws {
        let entry = try XCTUnwrap(FeatureFlagService.registry.first { $0.key == "portalProductAnalyticsEnabled" })
        XCTAssertEqual(entry.envVar, "FEATURE_PORTAL_PRODUCT_ANALYTICS_ENABLED")
        XCTAssertFalse(entry.hardDefault)
        XCTAssertEqual(FeatureFlagService.registry.filter { $0.key == "portalProductAnalyticsEnabled" }.count, 1)
    }
}

/// The settings consent route records the notice a revision was made under.
final class MeasurementNoticeRouteTests: XCTestCase {
    private var app: Application!
    private var user: User!
    private var jwt: String!
    private var userID: UUID { try! user.requireID() }
    private var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "synthetic-test-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        user = User(appleUserId: nil, email: "notice-\(UUID().uuidString.lowercased())@example.test",
                    name: "Synthetic manager", authProvider: .magicLink)
        try await user.save(on: app.db)
        jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)), userId: userID,
            authVersion: user.authVersion, authenticatedAt: Date()))
    }

    override func tearDown() async throws {
        if let app {
            for table in ["measurement_dispatch_jobs", "measurement_erasure_jobs", "measurement_att_assertions",
                          "measurement_permission_current", "measurement_consent_events", "measurement_subjects"] {
                try? await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE account_id=\(bind:userID)").run()
            }
            try? await sql.raw("DELETE FROM browser_sessions WHERE user_id=\(bind:userID)").run()
            try? await User.query(on: app.db).filter(\.$id == userID).delete()
            try await app.asyncShutdown()
        }
        app = nil; user = nil; jwt = nil
    }

    private func put(_ purpose: String, expected: UUID? = nil, decision: String = "granted", notice: String?,
                     requestID: UUID = UUID(), occurredAt: Date = Date(), extra: [String: Any] = [:],
                     portal: (token: String, principal: BrowserPrincipal)? = nil) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["requestId": requestID.uuidString, "decision": decision,
                                   "occurredAt": ISO8601DateFormatter().string(from: occurredAt)]
        if let expected { body["expectedRevision"] = expected.uuidString }
        if let notice { body["noticeVersion"] = notice }
        body.merge(extra) { _, new in new }
        var answer: XCTHTTPResponse!
        let token = jwt!
        try await app.test(.PUT, "api/v2/measurement/permissions/\(purpose)", beforeRequest: { req async throws in
            if let portal {
                req.headers.replaceOrAdd(name: "Origin", value: "http://127.0.0.1:8080")
                req.headers.replaceOrAdd(name: "Cookie", value: BrowserSessionService.cookieName + "=" + portal.token)
                req.headers.replaceOrAdd(name: "X-CSRF-Token", value: portal.principal.csrfToken)
            } else {
                req.headers.bearerAuthorization = .init(token: token)
            }
            req.headers.contentType = .json
            req.body = .init(data: try JSONSerialization.data(withJSONObject: body))
        }, afterResponse: { response async in answer = response })
        return answer
    }

    private func permission(_ purpose: String, in response: XCTHTTPResponse) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        return try XCTUnwrap((root["permissions"] as? [[String: Any]])?.first { $0["purpose"] as? String == purpose })
    }

    private func recorded() async throws -> [String?] {
        try await sql.raw("""
            SELECT notice_version FROM measurement_consent_events WHERE account_id=\(bind:userID) ORDER BY received_at,id
            """).all().map { try $0.decode(column: "notice_version", as: String?.self) }
    }

    func testSettingsRecordsTheCurrentNoticeOnTheRevisionAndReportsItsCoverage() async throws {
        let granted = try await put("productAnalytics", notice: MeasurementNotice.current)
        XCTAssertEqual(granted.status, .ok, granted.body.string)
        let product = try permission("productAnalytics", in: granted)
        XCTAssertEqual(product["noticeVersion"] as? String, "measurement-notice-2026-10a")
        XCTAssertEqual(product["coversPortal"] as? Bool, true)
        let afterFirst = try await recorded()
        XCTAssertEqual(afterFirst, ["measurement-notice-2026-10a"])

        // Apple Ads under the same notice: recorded, never "portal" coverage.
        let apple = try await put("appleAds", notice: MeasurementNotice.current)
        XCTAssertEqual(apple.status, .ok, apple.body.string)
        XCTAssertEqual(try permission("appleAds", in: apple)["coversPortal"] as? Bool, false)
        XCTAssertEqual(try permission("appleAds", in: apple)["noticeVersion"] as? String, "measurement-notice-2026-10a")

        // A withdrawal is recorded with whatever notice the client sends (none here) and covers nothing.
        let revision = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(product["revision"] as? String)))
        let withdrawn = try await put("productAnalytics", expected: revision, decision: "withdrawn", notice: nil)
        XCTAssertEqual(withdrawn.status, .ok, withdrawn.body.string)
        XCTAssertEqual(try permission("productAnalytics", in: withdrawn)["coversPortal"] as? Bool, false)
        XCTAssertNil(try permission("productAnalytics", in: withdrawn)["noticeVersion"] as? String)
    }

    func testAClientThatSendsNoNoticeKeepsAppOnlyCoverage() async throws {
        let granted = try await put("productAnalytics", notice: nil)
        XCTAssertEqual(granted.status, .ok, granted.body.string)
        let product = try permission("productAnalytics", in: granted)
        XCTAssertNil(product["noticeVersion"] as? String)
        XCTAssertEqual(product["coversPortal"] as? Bool, false, "an earlier grant is never silently broadened")
        XCTAssertEqual(product["effective"] as? Bool, true, "it still covers the app exactly as before")
        let stored = try await recorded()
        XCTAssertEqual(stored, [nil])
    }

    func testTheDraftTheSingularAlternativeAndUnknownNoticesAreRefusedWithoutWriting() async throws {
        for notice in [MeasurementNotice.signupDraft, MeasurementNotice.singularAlternative, "measurement-notice-2026-10c", "", "x"] {
            let refused = try await put("productAnalytics", notice: notice)
            XCTAssertEqual(refused.status, .badRequest, "\(notice): \(refused.body.string)")
            XCTAssertTrue(refused.body.string.contains("measurement_notice_invalid"), refused.body.string)
        }
        let wrongType = try await put("productAnalytics", notice: nil, extra: ["noticeVersion": 1])
        XCTAssertEqual(wrongType.status, .badRequest)
        let none = try await recorded()
        XCTAssertTrue(none.isEmpty, "a refused notice writes nothing")
    }

    /// The portal's server rules: a cookie session may turn on only product analytics, and only
    /// under the current notice; it may withdraw any choice; Apple Ads and other adverts can be
    /// turned on only in the app. Each answer is the same envelope the app reads.
    func testThePortalMayWithdrawAnythingButTurnOnOnlyProductAnalyticsUnderTheCurrentNotice() async throws {
        let session = try await BrowserSessionService.create(for: user, config: .init(origin: "http://127.0.0.1:8080", environment: "local"),
                                                             on: app.db)
        let legacy = try await put("productAnalytics", notice: nil, portal: session)
        XCTAssertEqual(legacy.status, .badRequest, legacy.body.string)
        XCTAssertTrue(legacy.body.string.contains("measurement_notice_invalid"))
        let granted = try await put("productAnalytics", notice: MeasurementNotice.current, portal: session)
        XCTAssertEqual(granted.status, .ok, granted.body.string)
        XCTAssertEqual(try permission("productAnalytics", in: granted)["coversPortal"] as? Bool, true)
        let apple = try await put("appleAds", notice: MeasurementNotice.current, portal: session)
        XCTAssertEqual(apple.status, .forbidden, apple.body.string)
        XCTAssertTrue(apple.body.string.contains("measurement_app_only"))
        let cross = try await put("crossCompanyAds", notice: MeasurementNotice.current,
            extra: ["installationId": UUID().uuidString, "attStatus": "authorized",
                    "attAssertedAt": ISO8601DateFormatter().string(from: Date())], portal: session)
        XCTAssertEqual(cross.status, .forbidden, cross.body.string)
        XCTAssertTrue(cross.body.string.contains("measurement_app_only"))

        // The app turns Apple Ads on; the portal can turn it off.
        let appGrant = try await put("appleAds", notice: MeasurementNotice.current)
        XCTAssertEqual(appGrant.status, .ok, appGrant.body.string)
        let appleRevision = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(try permission("appleAds", in: appGrant)["revision"] as? String)))
        let portalOff = try await put("appleAds", expected: appleRevision, decision: "withdrawn", notice: nil, portal: session)
        XCTAssertEqual(portalOff.status, .ok, portalOff.body.string)
        XCTAssertEqual(try permission("appleAds", in: portalOff)["decision"] as? String, "withdrawn")
        let productRevision = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(try permission("productAnalytics", in: portalOff)["revision"] as? String)))
        let productOff = try await put("productAnalytics", expected: productRevision, decision: "withdrawn", notice: nil, portal: session)
        XCTAssertEqual(productOff.status, .ok, productOff.body.string)
        let stored = try await recorded()
        XCTAssertEqual(stored, ["measurement-notice-2026-10a", "measurement-notice-2026-10a", nil, nil])
    }

    func testAReplayMustCarryTheSameNotice() async throws {
        let id = UUID(), at = Date()
        let first = try await put("productAnalytics", notice: MeasurementNotice.current, requestID: id, occurredAt: at)
        XCTAssertEqual(first.status, .ok, first.body.string)
        let same = try await put("productAnalytics", notice: MeasurementNotice.current, requestID: id, occurredAt: at)
        XCTAssertEqual(same.status, .ok, same.body.string)
        let different = try await put("productAnalytics", notice: nil, requestID: id, occurredAt: at)
        XCTAssertEqual(different.status, .conflict, different.body.string)
        let stored = try await recorded()
        XCTAssertEqual(stored, ["measurement-notice-2026-10a"])
    }
}
