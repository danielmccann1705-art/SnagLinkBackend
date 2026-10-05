@testable import App
import XCTVapor
import Fluent
import FluentSQL

// 2.0.2 Apple ads measurement, server side (IOS-2.0.2-SLICE1.md items 11-16). Every token, reference and app user ID
// here is synthetic, and no request leaves the process: Apple's endpoint is a recorder (`AppleStub`).

// MARK: - Rules (no database, no network)

final class AdMeasurementRulesTests: XCTestCase {
    typealias Store = AdAttributionStore
    typealias Exchange = AppleAttributionExchangeService

    /// Item 11: the key the app reads, its variable, and a hard default of false.
    func testTheSwitchIsRegisteredWithAHardDefaultOfFalse() {
        let entry = FeatureFlagService.registry.first { $0.key == "adMeasurementEnabled" }
        XCTAssertEqual(entry?.envVar, "FEATURE_AD_MEASUREMENT_ENABLED")
        XCTAssertEqual(entry?.hardDefault, false)
        XCTAssertEqual(AdMeasurementPolicy.flagKey, entry?.key)
        XCTAssertEqual(AdMeasurementPolicy.flagEnvironmentVariable, entry?.envVar)
        XCTAssertEqual(FeatureFlagService.registry.filter { $0.key == "adMeasurementEnabled" }.count, 1)
    }

    /// Fail closed: only a resolved boolean true enables; missing, false and an unreadable resolution do not.
    func testTheGateOpensOnlyOnAResolvedTrue() async {
        struct Unreachable: Error {}
        let open = await AdMeasurementPolicy.isEnabled { ["adMeasurementEnabled": true] }
        let shut = await AdMeasurementPolicy.isEnabled { ["adMeasurementEnabled": false] }
        let missing = await AdMeasurementPolicy.isEnabled { ["useNewDesign": true] }
        let empty = await AdMeasurementPolicy.isEnabled { [:] }
        let failed = await AdMeasurementPolicy.isEnabled { throw Unreachable() }
        XCTAssertTrue(open)
        XCTAssertFalse(shut); XCTAssertFalse(missing); XCTAssertFalse(empty); XCTAssertFalse(failed)
    }

    /// D6 is pending: the number is written once, and a change to it has to be deliberate.
    func testRetentionIsTheOneProposedValue() {
        XCTAssertEqual(AdMeasurementPolicy.retentionDays, 180, "PROPOSED, pending D6 - change only with the policy text")
        XCTAssertEqual(AdMeasurementPolicy.retention, 180 * 86_400)
        XCTAssertEqual(AdMeasurementPolicy.tokenValidity, 86_400)
        XCTAssertEqual(AdMeasurementPolicy.appleAttemptsPerPass, 3)
        XCTAssertEqual(AdMeasurementPolicy.appleRetryDelaySeconds, 5)
    }

    func testReferencesAre128RandomBitsInBase32() {
        XCTAssertEqual(Store.base32(Array("foobar".utf8)), "MZXW6YTBOI", "RFC 4648 test vector, unpadded")
        XCTAssertEqual(Store.base32(Array("f".utf8)), "MY")
        var seen = Set<String>()
        for _ in 0..<2_000 {
            let reference = Store.newReference()
            XCTAssertEqual(reference.count, 26)
            XCTAssertNotNil(reference.range(of: "^[A-Z2-7]{26}$", options: .regularExpression))
            seen.insert(reference)
        }
        XCTAssertEqual(seen.count, 2_000)
        XCTAssertEqual(Store.normalisedReference("mzxw6ytboimzxw6ytboimzxw6y"), "MZXW6YTBOIMZXW6YTBOIMZXW6Y")
        for bad in ["", "MZXW6YTBOI", "MZXW6YTBOIMZXW6YTBOIMZXW61", "MZXW6YTBOIMZXW6YTBOIMZXW6YA", "../../etc/passwd", "MZXW6YTBOIMZXW6YTBOIMZXW6%"] {
            XCTAssertNil(Store.normalisedReference(bad), bad)
        }
    }

    func testTheUploadAcceptsExactlyWhatTheAppSends() {
        func body(_ token: Any?, _ id: Any?, _ version: Any?) -> Data {
            var object: [String: Any] = [:]
            if let token { object["token"] = token }
            if let id { object["rcAppUserID"] = id }
            if let version { object["appVersion"] = version }
            return try! JSONSerialization.data(withJSONObject: object)
        }
        let token = String(repeating: "QUJD", count: 60) + "+/=="
        let anonymous = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
        let account = "7D3C9C3E-0000-4000-8000-00000000000A"
        XCTAssertEqual(Store.Upload.validated(body(token, anonymous, "2.0.2")), .init(token: token, rcAppUserID: anonymous, appVersion: "2.0.2"))
        XCTAssertNotNil(Store.Upload.validated(body(token, account, "2.0")))
        XCTAssertNotNil(Store.Upload.validated(body("SYNTHETIC-SIMULATOR-TOKEN-1A2B3C4D", anonymous, "2.0.2")), "base64url alphabet")
        var withExtras = try! JSONSerialization.jsonObject(with: body(token, anonymous, "2.0.2")) as! [String: Any]
        withExtras["idfa"] = "00000000-0000-0000-0000-000000000000"
        XCTAssertNotNil(Store.Upload.validated(try! JSONSerialization.data(withJSONObject: withExtras)), "extra keys are ignored, never stored")
        let refused: [Data] = [
            body(nil, anonymous, "2.0.2"), body("", anonymous, "2.0.2"), body(String(repeating: "A", count: 4001), anonymous, "2.0.2"),
            body("abc def", anonymous, "2.0.2"), body("token\n", anonymous, "2.0.2"), body(42, anonymous, "2.0.2"),
            body(token, nil, "2.0.2"), body(token, account.lowercased(), "2.0.2"), body(token, "$RCAnonymousID:0123456789ABCDEF0123456789ABCDEF", "2.0.2"),
            body(token, "$RCAnonymousID:0123", "2.0.2"), body(token, "someone@example.test", "2.0.2"), body(token, "", "2.0.2"),
            body(token, anonymous, nil), body(token, anonymous, ""), body(token, anonymous, "2.0.2-beta"), body(token, anonymous, "1.2.3.4.5"),
            body(token, anonymous, 2), Data("not json".utf8), Data(), Data("[]".utf8)
        ]
        for (index, data) in refused.enumerated() { XCTAssertNil(Store.Upload.validated(data), "case \(index)") }
    }

    /// Apple's answer is reduced to the eight Standard fields; the engagement times, orgId, supplyPlacement and
    /// anything new are never decoded.
    func testOnlyTheStandardFieldsAreReadFromApplesAnswer() {
        let fields = Exchange.standardFields(ByteBuffer(string: AppleStub.attributed))
        XCTAssertEqual(fields, .init(attribution: true, campaignId: 542370539, adGroupId: 542317095, keywordId: 87675432, adId: 542317136,
                                     claimType: "Click", conversionType: "Download", countryOrRegion: "US"))
        XCTAssertEqual(Exchange.standardFields(ByteBuffer(string: #"{"attribution":false}"#)), .init(attribution: false))
        // A malformed field is left empty; a missing or non-boolean attribution makes the answer unreadable.
        XCTAssertEqual(Exchange.standardFields(ByteBuffer(string: #"{"attribution":true,"campaignId":"542370539","countryOrRegion":"United States","claimType":"Click; drop","adId":-1}"#)),
                       .init(attribution: true))
        for unreadable in [#"{"campaignId":1}"#, #"{"attribution":"true"}"#, "[]", "not json", ""] {
            XCTAssertNil(Exchange.standardFields(ByteBuffer(string: unreadable)), unreadable)
        }
        XCTAssertNil(Exchange.standardFields(nil))
        XCTAssertNil(Exchange.standardFields(ByteBuffer(string: #"{"attribution":true,"pad":""# + String(repeating: "x", count: 17_000) + #""}"#)))
    }

    /// The request Apple documents, and its 404 rule: three attempts five seconds apart, then the next pass.
    func testTheExchangeFollowsApplesContract() async {
        let stub = AppleStub()
        func run(_ answers: [Result<Exchange.Reply, Error>]) async -> (Exchange.Outcome, Int, String) {
            await stub.reset(answers)
            let r = await Exchange.exchange(token: "U1lOVEhFVElD", transport: stub.transport, sleep: stub.sleeper)
            return (r.outcome, r.attempts, r.status)
        }
        var result = await run([.success(AppleStub.reply(.ok, AppleStub.attributed))])
        XCTAssertEqual(result.1, 1); XCTAssertEqual(result.2, "200")
        guard case .attributed = result.0 else { return XCTFail("200 is attributed") }
        let call = await stub.calls().first
        XCTAssertEqual(call?.uri, "https://api-adservices.apple.com/api/v1/")
        XCTAssertEqual(call?.contentType, "text/plain")
        XCTAssertEqual(call?.body, "U1lOVEhFVElD", "the token is the whole body")
        var sleeps = await stub.sleeps()
        XCTAssertEqual(sleeps, [])

        result = await run(Array(repeating: .success(AppleStub.reply(.notFound)), count: 5))
        XCTAssertEqual(result.0, .notYetAvailable); XCTAssertEqual(result.1, 3)
        sleeps = await stub.sleeps()
        XCTAssertEqual(sleeps, [5, 5])

        result = await run([.success(AppleStub.reply(.notFound)), .success(AppleStub.reply(.notFound)), .success(AppleStub.reply(.ok, AppleStub.attributed))])
        XCTAssertEqual(result.1, 3)
        guard case .attributed = result.0 else { return XCTFail("a third-attempt 200 is attributed") }

        result = await run([.success(AppleStub.reply(.badRequest))])
        XCTAssertEqual(result.0, .invalid); XCTAssertEqual(result.1, 1)
        for status in [HTTPStatus.internalServerError, .serviceUnavailable, .tooManyRequests, .unauthorized, .forbidden] {
            result = await run([.success(AppleStub.reply(status))])
            XCTAssertEqual(result.0, .failing, "\(status.code)"); XCTAssertEqual(result.1, 1)
        }
        result = await run([.failure(AppleStub.Offline())])
        XCTAssertEqual(result.0, .failing); XCTAssertEqual(result.2, "no_answer")
        result = await run([.success(AppleStub.reply(.ok, "<html>"))])
        XCTAssertEqual(result.0, .failing); XCTAssertEqual(result.2, "200_unreadable")
    }

    /// Nothing in the module logs a token, a reference, an app user ID or a body; the routes do not log at all
    /// (the request logger records the route pattern and status), and no print() bypasses the logger.
    func testTheModuleNeverLogsAValue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/AdMeasurement")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["AdMeasurementPolicy.swift", "AdAttributionStore.swift", "AdMeasurementController.swift",
                                                             "AppleAttributionExchangeService.swift", "AdMeasurementMaintenance.swift"])
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(text.range(of: #"(^|[^A-Za-z0-9_.])print\("#, options: .regularExpression), file.lastPathComponent)
            for line in text.split(separator: "\n") where line.contains("logger.") {
                for value in ["token", "reference", "rcAppUserID", "upload", "body", "error", "fields", "row"] {
                    XCTAssertFalse(line.contains("\\(\(value)") || line.contains(".string(\(value)"), "\(file.lastPathComponent): \(line)")
                }
            }
            if file.lastPathComponent == "AdMeasurementController.swift" || file.lastPathComponent == "AdAttributionStore.swift" {
                XCTAssertFalse(text.contains("logger."), "\(file.lastPathComponent) does not log")
            }
        }
    }
}

// MARK: - Apple's endpoint, recorded

actor AppleStub {
    struct Call: Sendable { let uri: String; let contentType: String?; let body: String }
    struct Offline: Error {}
    private var answers: [Result<AppleAttributionExchangeService.Reply, Error>] = []
    private var recorded: [Call] = []
    private var slept: [Int] = []
    private var onCall: (@Sendable (String) async throws -> AppleAttributionExchangeService.Reply)?

    static let attributed = #"{"attribution":true,"orgId":40669820,"campaignId":542370539,"conversionType":"Download","claimType":"Click","adGroupId":542317095,"countryOrRegion":"US","keywordId":87675432,"adId":542317136,"clickDate":"2026-10-04T17:17Z","impressionDate":"2026-10-04T17:10Z","supplyPlacement":"APPSTORE_SEARCH_RESULTS","futureField":"never stored"}"#

    static func reply(_ status: HTTPStatus, _ json: String? = nil) -> AppleAttributionExchangeService.Reply {
        .init(status: status, body: json.map { ByteBuffer(string: $0) })
    }

    func reset(_ answers: [Result<AppleAttributionExchangeService.Reply, Error>]) {
        self.answers = answers; recorded = []; slept = []; onCall = nil
    }
    /// Answers by token instead of by queue.
    func answerByToken(_ answer: @escaping @Sendable (String) async throws -> AppleAttributionExchangeService.Reply) {
        onCall = answer; recorded = []; slept = []
    }
    func calls() -> [Call] { recorded }
    func sleeps() -> [Int] { slept }

    fileprivate func handle(_ uri: URI, _ headers: HTTPHeaders, _ body: String) async throws -> AppleAttributionExchangeService.Reply {
        recorded.append(.init(uri: uri.string, contentType: headers.first(name: .contentType), body: body))
        if let onCall { return try await onCall(body) }
        guard !answers.isEmpty else { return Self.reply(.internalServerError) }
        return try answers.removeFirst().get()
    }
    fileprivate func recordSleep(_ seconds: Int) { slept.append(seconds) }

    nonisolated var transport: AppleAttributionExchangeService.Transport {
        { uri, headers, body in try await self.handle(uri, headers, body) }
    }
    nonisolated var sleeper: AppleAttributionExchangeService.Sleep {
        { seconds in await self.recordSleep(seconds) }
    }
}

// MARK: - Shared database fixture

class AdMeasurementDatabaseCase: XCTestCase {
    var app: Application!
    let anonymous = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
    var sql: SQLDatabase { try! VerifiedIdentityService.sql(app.db) }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        if Environment.get("JWT_SECRET") == nil { setenv("JWT_SECRET", "test-secret-key", 1) }
        app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); app = nil; throw error }
        try await reset()
    }

    override func tearDown() async throws {
        if let app {
            try? await reset()
            try await app.asyncShutdown()
        }
        app = nil
    }

    /// This fixture owns the table and the switch's override row in disposable test databases.
    func reset() async throws {
        try await sql.raw("DELETE FROM ad_attribution_records").run()
        try await FeatureFlag.query(on: app.db).filter(\.$key == AdMeasurementPolicy.flagKey).delete()
    }

    /// The B6 override row, the switch's instant mechanism.
    func setSwitch(_ enabled: Bool) async throws {
        try await FeatureFlag.query(on: app.db).filter(\.$key == AdMeasurementPolicy.flagKey).delete()
        try await FeatureFlag(key: AdMeasurementPolicy.flagKey, enabled: enabled).save(on: app.db)
    }

    func token(_ label: String = UUID().uuidString) -> String {
        Data(("synthetic-adservices-token-" + label).utf8).base64EncodedString()
    }

    @discardableResult
    func insert(token: String? = nil, id: String? = nil, createdAgo: TimeInterval = 60) async throws -> String {
        try await AdAttributionStore.insert(.init(token: token ?? self.token(), rcAppUserID: id ?? anonymous, appVersion: "2.0.2"),
                                            now: Date().addingTimeInterval(-createdAgo), on: app.db)
    }

    struct Row: Equatable {
        var state: String; var token: String?; var attempts: Int; var attribution: Bool?
        var campaignId: Int64?; var adGroupId: Int64?; var keywordId: Int64?; var adId: Int64?
        var claimType: String?; var conversionType: String?; var countryOrRegion: String?
        var rcAppUserID: String; var appVersion: String; var exchanged: Bool
    }

    func row(_ reference: String) async throws -> Row? {
        guard let r = try await sql.raw("""
            SELECT exchange_state, token, exchange_attempts, attribution, campaign_id, adgroup_id, keyword_id, ad_id, claim_type,
                   conversion_type, country_or_region, rc_app_user_id, app_version, exchanged_at
            FROM ad_attribution_records WHERE reference = \(bind: reference)
            """).first() else { return nil }
        return Row(state: try r.decode(column: "exchange_state", as: String.self), token: try r.decode(column: "token", as: String?.self),
                   attempts: try r.decode(column: "exchange_attempts", as: Int.self), attribution: try r.decode(column: "attribution", as: Bool?.self),
                   campaignId: try r.decode(column: "campaign_id", as: Int64?.self), adGroupId: try r.decode(column: "adgroup_id", as: Int64?.self),
                   keywordId: try r.decode(column: "keyword_id", as: Int64?.self), adId: try r.decode(column: "ad_id", as: Int64?.self),
                   claimType: try r.decode(column: "claim_type", as: String?.self), conversionType: try r.decode(column: "conversion_type", as: String?.self),
                   countryOrRegion: try r.decode(column: "country_or_region", as: String?.self),
                   rcAppUserID: try r.decode(column: "rc_app_user_id", as: String.self), appVersion: try r.decode(column: "app_version", as: String.self),
                   exchanged: try r.decode(column: "exchanged_at", as: Date?.self) != nil)
    }

    func count() async throws -> Int {
        try await sql.raw("SELECT count(*) AS n FROM ad_attribution_records").first()?.decode(column: "n", as: Int.self) ?? -1
    }

    func install(_ stub: AppleStub) {
        app.storage[AppleAttributionExchangeService.TransportKey.self] = stub.transport
        app.storage[AppleAttributionExchangeService.SleepKey.self] = stub.sleeper
    }
}

// MARK: - Item 11: the switch as served

final class AdMeasurementSwitchTests: AdMeasurementDatabaseCase {
    /// Exactly the envelope the app decodes (`FeatureFlagsEnvelope`): a JSON boolean false by default.
    func testTheSwitchIsServedFalseByDefaultAsAJSONBoolean() async throws {
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["flags"])
            let flags = try XCTUnwrap(object["flags"] as? [String: Any])
            XCTAssertEqual(flags["adMeasurementEnabled"] as? Bool, false)
            XCTAssertTrue(res.body.string.contains(#""adMeasurementEnabled":false"#), "a JSON boolean, not a string or a number: \(res.body.string)")
            XCTAssertNotNil(flags["useNewDesign"], "the existing flag is still served")
        })
        let enabled = await AdMeasurementPolicy.isEnabled(on: app.db)
        XCTAssertFalse(enabled)
    }

    /// The environment value is honoured only as the exact literal `true`; anything else is false.
    func testOnlyTheExactLiteralTrueInTheEnvironmentEnables() async throws {
        func resolved(_ value: String?) async throws -> Bool? {
            try await FeatureFlagService.resolve(on: app.db) { $0 == "FEATURE_AD_MEASUREMENT_ENABLED" ? value : nil }["adMeasurementEnabled"]
        }
        let on = try await resolved("true")
        XCTAssertEqual(on, true)
        for malformed in [nil, "", "TRUE", "True", "1", "yes", "on", " true", "true ", "\"true\"", "false"] as [String?] {
            let value = try await resolved(malformed)
            XCTAssertEqual(value, false, String(describing: malformed))
        }
    }

    /// The override row wins over the environment in both directions, and the served value follows it.
    func testTheOverrideRowFlipsItInstantly() async throws {
        try await setSwitch(true)
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            XCTAssertTrue(res.body.string.contains(#""adMeasurementEnabled":true"#), res.body.string)
        })
        let open = await AdMeasurementPolicy.isEnabled(on: app.db)
        XCTAssertTrue(open)
        try await setSwitch(false)
        let overridden = try await FeatureFlagService.resolve(on: app.db) { $0 == "FEATURE_AD_MEASUREMENT_ENABLED" ? "true" : nil }
        XCTAssertEqual(overridden["adMeasurementEnabled"], false, "a false row beats a true environment value")
        let shut = await AdMeasurementPolicy.isEnabled(on: app.db)
        XCTAssertFalse(shut)
    }
}

// MARK: - Item 13: the routes

final class AdMeasurementRouteTests: AdMeasurementDatabaseCase {
    let client = "client-" + UUID().uuidString

    func post(_ body: String, client: String? = nil, headers extra: HTTPHeaders = [:]) async throws -> XCTHTTPResponse {
        var headers: HTTPHeaders = ["Content-Type": "application/json", "X-Forwarded-For": client ?? self.client]
        for (name, value) in extra { headers.replaceOrAdd(name: name, value: value) }
        return try await app.testable(method: .inMemory).sendRequest(.POST, "api/v1/ad-measurement/apple", headers: headers, body: ByteBuffer(string: body))
    }

    func delete(_ reference: String, client: String? = nil) async throws -> XCTHTTPResponse {
        try await app.testable(method: .inMemory).sendRequest(.DELETE, "api/v1/ad-measurement/apple/" + reference,
                                                              headers: ["X-Forwarded-For": client ?? self.client])
    }

    func upload(_ token: String, id: String? = nil, version: String = "2.0.2") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["token": token, "rcAppUserID": id ?? anonymous, "appVersion": version]), encoding: .utf8)!
    }

    /// Switched off (the default): 503 before the body is read, valid or not, and nothing is stored.
    func testWhileSwitchedOffEveryPostIsRefusedWith503AndNothingIsStored() async throws {
        let valid = try await post(upload(token()))
        XCTAssertEqual(valid.status, .serviceUnavailable)
        XCTAssertTrue(valid.body.string.contains("ad_measurement_off"), valid.body.string)
        let invalid = try await post("{\"token\": 42}")
        XCTAssertEqual(invalid.status, .serviceUnavailable, "refused before validation")
        try await setSwitch(false)
        let explicit = try await post(upload(token()))
        XCTAssertEqual(explicit.status, .serviceUnavailable)
        let rows = try await count()
        XCTAssertEqual(rows, 0)
    }

    /// Switched on: 201 {"reference"}, one pending row with the token held for the exchange, no-store.
    func testAnAcceptedPostReturnsAReferenceAndStoresOnePendingRow() async throws {
        try await setSwitch(true)
        let token = token()
        let response = try await post(upload(token))
        XCTAssertEqual(response.status, .created, response.body.string)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let receipt = try JSONDecoder().decode(AdMeasurementReceipt.self, from: Data(response.body.readableBytesView))
        XCTAssertNotNil(receipt.reference.range(of: "^[A-Z2-7]{26}$", options: .regularExpression))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: String], ["reference": receipt.reference])
        let stored = try await row(receipt.reference)
        XCTAssertEqual(stored?.state, "pending"); XCTAssertEqual(stored?.token, token); XCTAssertEqual(stored?.attempts, 0)
        XCTAssertEqual(stored?.rcAppUserID, anonymous); XCTAssertEqual(stored?.appVersion, "2.0.2"); XCTAssertNil(stored?.attribution)
        let account = try await post(upload(self.token(), id: "7D3C9C3E-0000-4000-8000-00000000000A"))
        XCTAssertEqual(account.status, .created, "an account UUID is the other shape the app sends")
        let rows = try await count()
        XCTAssertEqual(rows, 2)
    }

    /// 400 for anything the app does not send; the answer never repeats a value and nothing is stored.
    func testARejectedPostIs400NeverEchoesAndStoresNothing() async throws {
        try await setSwitch(true)
        let token = "U0VDUkVULVRPS0VO"
        for body in [upload(token, id: "7d3c9c3e-0000-4000-8000-00000000000a"), upload(token, id: "someone@example.test"),
                     upload(token, version: "2.0.2 (8)"), upload("not base64!"), "{\"rcAppUserID\": \"\(anonymous)\", \"appVersion\": \"2.0.2\"}",
                     "not json", ""] {
            let response = try await post(body)
            XCTAssertEqual(response.status, .badRequest, body)
            XCTAssertTrue(response.body.string.contains("ad_measurement_invalid"))
            XCTAssertFalse(response.body.string.contains(token)); XCTAssertFalse(response.body.string.contains("someone@"))
        }
        let rows = try await count()
        XCTAssertEqual(rows, 0)
    }

    /// The route's 4 KB limit, through the real server's body collection.
    func testABodyOverFourKilobytesIsRefusedUnread() async throws {
        try await setSwitch(true)
        let live = try app.testable(method: .running(hostname: "127.0.0.1", port: 0))
        let response = try await live.sendRequest(.POST, "api/v1/ad-measurement/apple",
                                                  headers: ["Content-Type": "application/json", "X-Forwarded-For": client],
                                                  body: ByteBuffer(string: upload(String(repeating: "A", count: 5_000))))
        XCTAssertEqual(response.status, .payloadTooLarge)
        let rows = try await count()
        XCTAssertEqual(rows, 0)
    }

    /// No account is consulted or linked: a bearer header changes nothing, and the row holds the ID the app sent.
    func testTheRecordBelongsToTheInstallationNotToABearer() async throws {
        try await setSwitch(true)
        let response = try await post(upload(token()), headers: ["Authorization": "Bearer not-a-session"])
        XCTAssertEqual(response.status, .created)
        let reference = try JSONDecoder().decode(AdMeasurementReceipt.self, from: Data(response.body.readableBytesView)).reference
        let stored = try await row(reference)
        XCTAssertEqual(stored?.rcAppUserID, anonymous)
        let columns = try await sql.raw("""
            SELECT column_name FROM information_schema.columns WHERE table_name = 'ad_attribution_records' AND table_schema = current_schema()
            """).all().map { try $0.decode(column: "column_name", as: String.self) }
        XCTAssertFalse(columns.contains("user_id")); XCTAssertFalse(columns.contains("ip_address")); XCTAssertFalse(columns.contains("user_agent"))
    }

    /// Withdrawal: 200 then 404 (both "gone" to the app), whatever the switch says; only that record goes.
    func testWithdrawalErasesTheRecordIsIdempotentAndIgnoresTheSwitch() async throws {
        let kept = try await insert()
        let pending = try await insert(createdAgo: 10)
        let first = try await delete(pending)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(try JSONDecoder().decode(AdMeasurementDeletion.self, from: Data(first.body.readableBytesView)), .init(deleted: true))
        let gone = try await row(pending)
        XCTAssertNil(gone, "the row and its unexchanged token are erased")
        let again = try await delete(pending)
        XCTAssertEqual(again.status, .notFound)
        XCTAssertTrue(again.body.string.contains("ad_measurement_not_found"))
        let stillThere = try await row(kept)
        XCTAssertNotNil(stillThere, "another installation's record is untouched")

        try await setSwitch(true)
        let lower = try await delete(kept.lowercased())
        XCTAssertEqual(lower.status, .ok, "a reference typed in lower case still names its record")
        let afterSwitchOn = try await count()
        XCTAssertEqual(afterSwitchOn, 0)

        let third = try await insert()
        try await setSwitch(false)
        let killed = try await delete(third)
        XCTAssertEqual(killed.status, .ok, "a kill is not a withdrawal and never blocks one")
        for malformed in ["not-a-reference", "AAAA", String(repeating: "A", count: 27), "%2E%2E"] {
            let response = try await delete(malformed)
            XCTAssertEqual(response.status, .notFound, malformed)
        }
    }

    /// Rate limited per client like the anonymous lookups (20 a minute); another client is unaffected.
    func testBothRoutesAreRateLimitedPerClient() async throws {
        let busy = "client-" + UUID().uuidString
        for index in 0..<20 {
            let response = try await post(upload(token()), client: busy)
            XCTAssertEqual(response.status, .serviceUnavailable, "request \(index)")
        }
        let limited = try await post(upload(token()), client: busy)
        XCTAssertEqual(limited.status, .tooManyRequests)
        let limitedDelete = try await delete(AdAttributionStore.newReference(), client: busy)
        XCTAssertEqual(limitedDelete.status, .tooManyRequests)
        let other = try await delete(AdAttributionStore.newReference())
        XCTAssertEqual(other.status, .notFound)
        let stored = try await sql.raw("SELECT count(*) AS n FROM rate_limit_entries WHERE key LIKE 'ad-measurement:%' AND key LIKE \(bind: "%" + busy + "%")").first()?
            .decode(column: "n", as: Int.self)
        XCTAssertEqual(stored, 0, "the client address is stored only as a hash")
    }

    /// The existing public surface is unchanged.
    func testExistingRoutesAreUnaffected() async throws {
        try await app.test(.GET, "health", afterResponse: { res async in XCTAssertEqual(res.status, .ok) })
        try await app.test(.GET, "api/v1/config/feature-flags", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("useNewDesign"))
        })
        try await app.test(.GET, "api/v1/ad-measurement/apple", afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound, "no read route exists")
        })
        try await app.test(.GET, "/", afterResponse: { res async in
            XCTAssertTrue(res.body.string.contains("POST /api/v1/ad-measurement/apple"))
            XCTAssertTrue(res.body.string.contains("DELETE /api/v1/ad-measurement/apple/:reference"))
        })
    }
}

// MARK: - Item 14: the exchange

final class AppleAttributionExchangeTests: AdMeasurementDatabaseCase {
    let stub = AppleStub()

    override func setUp() async throws {
        try await super.setUp()
        install(stub)
    }

    func pass(_ now: Date = Date()) async -> AdMeasurementMaintenance.Counts {
        await AdMeasurementMaintenance.run(app: app, on: app.db, now: now)
    }

    /// 200: the Standard fields are stored, the token is dropped, `done`; nothing else from Apple's answer exists.
    func testA200StoresTheStandardFieldsAndDropsTheToken() async throws {
        try await setSwitch(true)
        let reference = try await insert()
        await stub.reset([.success(AppleStub.reply(.ok, AppleStub.attributed))])
        let counts = await pass()
        XCTAssertEqual(counts.exchanged, 1); XCTAssertEqual(counts.deferred, 0); XCTAssertNil(counts.failed)
        let stored = try await row(reference)
        XCTAssertEqual(stored, Row(state: "done", token: nil, attempts: 1, attribution: true, campaignId: 542370539, adGroupId: 542317095,
                                   keywordId: 87675432, adId: 542317136, claimType: "Click", conversionType: "Download", countryOrRegion: "US",
                                   rcAppUserID: anonymous, appVersion: "2.0.2", exchanged: true))
        let dump = try await sql.raw("SELECT row_to_json(r)::text AS j FROM ad_attribution_records r").first()?.decode(column: "j", as: String.self) ?? ""
        for dropped in ["40669820", "2026-10-04T17", "APPSTORE_SEARCH_RESULTS", "never stored"] {
            XCTAssertFalse(dump.contains(dropped), dropped)
        }
        let again = await pass()
        XCTAssertEqual(again, .init(), "a done row is never sent again")
        let calls = await stub.calls()
        XCTAssertEqual(calls.count, 1)
    }

    /// 404 on three attempts five seconds apart: still `pending`, token kept for the next pass, which can succeed.
    func testThree404sLeaveTheRowPendingForTheNextPass() async throws {
        try await setSwitch(true)
        let reference = try await insert()
        await stub.reset(Array(repeating: .success(AppleStub.reply(.notFound)), count: 3))
        let counts = await pass()
        XCTAssertEqual(counts.notYet, 1)
        let sleeps = await stub.sleeps()
        XCTAssertEqual(sleeps, [5, 5])
        var stored = try await row(reference)
        XCTAssertEqual(stored?.state, "pending"); XCTAssertNotNil(stored?.token); XCTAssertEqual(stored?.attempts, 3)
        await stub.reset([.success(AppleStub.reply(.ok, #"{"attribution":false}"#))])
        _ = await pass()
        stored = try await row(reference)
        XCTAssertEqual(stored?.state, "done"); XCTAssertNil(stored?.token); XCTAssertEqual(stored?.attribution, false); XCTAssertNil(stored?.campaignId)
    }

    /// 400: `invalid`, token dropped, never retried. 5xx and no answer: `failing`, retried while the token is valid.
    func testA400IsInvalidAndOutagesAreRetried() async throws {
        try await setSwitch(true)
        let invalid = try await insert(token: token("A"), createdAgo: 300)
        let outage = try await insert(token: token("B"), createdAgo: 200)
        let silent = try await insert(token: token("C"), createdAgo: 100)
        let tokenB = token("B"), tokenC = token("C")
        await stub.answerByToken { body in
            if body == tokenB { return AppleStub.reply(.internalServerError) }
            if body == tokenC { throw AppleStub.Offline() }
            return AppleStub.reply(.badRequest)
        }
        let counts = await pass()
        XCTAssertEqual(counts.invalid, 1); XCTAssertEqual(counts.failing, 2)
        let a = try await row(invalid), b = try await row(outage), c = try await row(silent)
        XCTAssertEqual(a?.state, "invalid"); XCTAssertNil(a?.token)
        XCTAssertEqual(b?.state, "failing"); XCTAssertEqual(b?.token, tokenB)
        XCTAssertEqual(c?.state, "failing"); XCTAssertEqual(c?.token, tokenC)
        await stub.answerByToken { _ in AppleStub.reply(.ok, AppleStub.attributed) }
        let retry = await pass()
        XCTAssertEqual(retry.exchanged, 2, "failing rows are retried; the invalid one is not")
        let calls = await stub.calls()
        XCTAssertFalse(calls.contains { $0.body == token("A") })
    }

    /// A withdrawal that lands while Apple is answering wins: the result is discarded and no row comes back.
    func testARowWithdrawnMidExchangeDiscardsTheResult() async throws {
        try await setSwitch(true)
        let reference = try await insert()
        let db = app.db
        await stub.answerByToken { _ in
            _ = try await AdAttributionStore.delete(reference: reference, on: db)
            return AppleStub.reply(.ok, AppleStub.attributed)
        }
        let counts = await pass()
        XCTAssertEqual(counts.discarded, 1); XCTAssertEqual(counts.exchanged, 0)
        let rows = try await count()
        XCTAssertEqual(rows, 0)
    }

    /// Switched off: no request to Apple at all. Expiry still drops a token past Apple's 24 hours.
    func testWhileSwitchedOffNothingIsSentAndExpiryStillRuns() async throws {
        let fresh = try await insert(createdAgo: 60)
        let stale = try await insert(createdAgo: AdMeasurementPolicy.tokenValidity + 60)
        await stub.reset([.success(AppleStub.reply(.ok, AppleStub.attributed))])
        let counts = await pass()
        XCTAssertTrue(counts.exchangePaused); XCTAssertEqual(counts.expired, 1); XCTAssertEqual(counts.deferred, 1)
        let calls = await stub.calls()
        XCTAssertEqual(calls.count, 0)
        let f = try await row(fresh), s = try await row(stale)
        XCTAssertEqual(f?.state, "pending"); XCTAssertNotNil(f?.token)
        XCTAssertEqual(s?.state, "expired"); XCTAssertNil(s?.token)
        try await setSwitch(true)
        let resumed = await pass()
        XCTAssertEqual(resumed.exchanged, 1, "a pending row inside its validity is exchanged once the switch is on")
        let expiredAgain = try await row(stale)
        XCTAssertEqual(expiredAgain?.state, "expired", "an expired row is never sent")
    }

    /// One bounded pass: at most `exchangeBatch` rows; the rest wait.
    func testOnePassIsBounded() async throws {
        try await setSwitch(true)
        for index in 0..<(AdMeasurementPolicy.exchangeBatch + 3) { try await insert(createdAgo: Double(1_000 - index)) }
        await stub.answerByToken { _ in AppleStub.reply(.ok, #"{"attribution":false}"#) }
        let counts = await pass()
        XCTAssertEqual(counts.exchanged, AdMeasurementPolicy.exchangeBatch); XCTAssertEqual(counts.deferred, 3)
        let next = await pass()
        XCTAssertEqual(next.exchanged, 3); XCTAssertEqual(next.deferred, 0)
    }

    /// Log lines carry a state and an HTTP status, never a token, a reference, an app user ID or Apple's body.
    /// Captured at the level `configure` sets for every deployment (.info); query text and bound values are
    /// debug/trace in PostgresNIO, Fluent and SQLKit, for this table as for every other.
    func testTheExchangeLogsStatesAndStatusesOnly() async throws {
        XCTAssertEqual(app.logger.logLevel, .info, "the level every deployment runs at")
        let box = AdMeasurementLogBox()
        app.logger = Logger(label: "ad-measurement-test") { _ in AdMeasurementLogHandler(box: box) }
        app.logger.logLevel = .info
        try await setSwitch(true)
        let tokens = (0..<4).map { token("log-\($0)") }
        var references: [String] = []
        for (index, value) in tokens.enumerated() { references.append(try await insert(token: value, createdAgo: Double(100 - index))) }
        await stub.answerByToken { body in
            switch body {
            case tokens[0]: return AppleStub.reply(.ok, AppleStub.attributed)
            case tokens[1]: return AppleStub.reply(.badRequest, #"{"error":"\#(body)"}"#)
            case tokens[2]: return AppleStub.reply(.notFound)
            default: return AppleStub.reply(.internalServerError, body)
            }
        }
        _ = await pass()
        let text = box.all()
        XCTAssertTrue(text.contains("Ad attribution exchange"))
        for secret in tokens + references + [anonymous, "542370539", "Download"] {
            XCTAssertFalse(text.contains(secret), "a log line carried \(secret)")
        }
    }

    /// The step runs inside the hourly maintenance pass and its counts are recorded with the pass.
    func testTheMaintenancePassRunsTheStep() async throws {
        app.storage[CleanupLockKeyStorage.self] = Int64.random(in: 1_000_000...9_000_000)
        try await insert(createdAgo: AdMeasurementPolicy.retention + 3_600)
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test, budget: .init(total: 0, minimumPerJob: 30))
        let step = try XCTUnwrap(removed?.adMeasurement)
        XCTAssertEqual(step.swept, 1)
        let rows = try await count()
        XCTAssertEqual(rows, 0)
    }
}

// MARK: - Item 15: retention and account deletion

final class AdMeasurementRetentionTests: AdMeasurementDatabaseCase {
    /// D6 (PROPOSED 180 days): a record older than retention goes, one inside it stays, whatever the switch says.
    func testTheSweepDeletesRecordsOlderThanRetentionOnly() async throws {
        let now = Date()
        let old = try await insert(createdAgo: AdMeasurementPolicy.retention + 60)
        let young = try await insert(createdAgo: AdMeasurementPolicy.retention - 60)
        let swept = try await AdAttributionStore.sweep(now: now, on: app.db)
        XCTAssertEqual(swept, 1)
        let o = try await row(old), y = try await row(young)
        XCTAssertNil(o); XCTAssertNotNil(y)
    }

    func testTheSweepDrainsInBatches() async throws {
        for _ in 0..<5 { try await insert(createdAgo: AdMeasurementPolicy.retention + 60) }
        let first = try await AdAttributionStore.sweep(now: Date(), on: app.db, limit: 3)
        let second = try await AdAttributionStore.sweep(now: Date(), on: app.db, limit: 3)
        XCTAssertEqual(first, 3); XCTAssertEqual(second, 2)
    }
}

final class AdMeasurementAccountDeletionTests: AdMeasurementDatabaseCase {
    /// Account deletion erases the rows made while the account was signed in (its uppercase UUID), in the deletion
    /// request's own transaction; guest rows and other accounts' rows stay.
    func testAccountDeletionErasesTheAccountsRecordsOnly() async throws {
        app.storage[AccountDeletionTestActivation.self] = true
        let userID = try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("ads-\(UUID())@example.test", name: "Synthetic ads", on: db).requireID()
        }
        let mine = [try await insert(id: userID.uuidString), try await insert(id: userID.uuidString)]
        let guest = try await insert()
        let other = try await insert(id: UUID().uuidString)
        let receipt = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        _ = try await AccountDeletionService.request(userID: userID, body: .init(confirmation: "DELETE", receiptReference: receipt), app: app)
        for reference in mine {
            let gone = try await row(reference)
            XCTAssertNil(gone)
        }
        let g = try await row(guest), o = try await row(other)
        XCTAssertNotNil(g); XCTAssertNotNil(o)
    }
}

// MARK: - Item 12: the migration

final class AdMeasurementMigrationTests: AdMeasurementDatabaseCase {
    static let columns: Set<String> = ["id", "reference", "rc_app_user_id", "app_version", "token", "exchange_state", "exchange_attempts",
                                       "attribution", "campaign_id", "adgroup_id", "keyword_id", "ad_id", "claim_type", "conversion_type",
                                       "country_or_region", "created_at", "exchanged_at"]

    /// Additive (creates one table and nothing else) and reversible (revert removes it; prepare works again).
    func testTheMigrationIsAdditiveAndReversible() async throws {
        let schema = "ads_migration_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        try await IsolatedMigrationDatabase.withSchema(app: app, schema: String(schema)) { database in
            let sql = try VerifiedIdentityService.sql(database)
            func tables() async throws -> [String] {
                try await sql.raw("SELECT table_name FROM information_schema.tables WHERE table_schema = \(bind: String(schema)) ORDER BY table_name").all()
                    .map { try $0.decode(column: "table_name", as: String.self) }
            }
            func indexes() async throws -> Set<String> {
                Set(try await sql.raw("SELECT indexname FROM pg_indexes WHERE schemaname = \(bind: String(schema))").all()
                    .map { try $0.decode(column: "indexname", as: String.self) })
            }
            try await CreateAdAttributionRecords().prepare(on: database)
            let created = try await tables()
            XCTAssertEqual(created, ["ad_attribution_records"])
            let names = try await indexes()
            XCTAssertEqual(names, ["ad_attribution_records_pkey", "ad_attribution_records_reference", "ad_attribution_records_rc_app_user_id",
                                   "ad_attribution_records_created_at"])
            try await CreateAdAttributionRecords().revert(on: database)
            let reverted = try await tables()
            XCTAssertEqual(reverted, [])
            try await CreateAdAttributionRecords().prepare(on: database)
            let again = try await tables()
            XCTAssertEqual(again, ["ad_attribution_records"])
        }
    }

    /// The table holds the Standard subset and nothing else, and the database refuses a token kept past the exchange.
    func testTheTableHoldsTheStandardSubsetOnlyAndRefusesAKeptToken() async throws {
        let columns = Set(try await sql.raw("""
            SELECT column_name FROM information_schema.columns WHERE table_name = 'ad_attribution_records' AND table_schema = current_schema()
            """).all().map { try $0.decode(column: "column_name", as: String.self) })
        XCTAssertEqual(columns, Self.columns)
        let reference = try await insert()
        do {
            try await sql.raw("UPDATE ad_attribution_records SET exchange_state = 'done', exchanged_at = now() WHERE reference = \(bind: reference)").run()
            XCTFail("a done row with its token must be refused")
        } catch {}
        do {
            try await sql.raw("UPDATE ad_attribution_records SET token = NULL WHERE reference = \(bind: reference)").run()
            XCTFail("a pending row without its token must be refused")
        } catch {}
        let stored = try await row(reference)
        XCTAssertEqual(stored?.state, "pending")
    }
}

// MARK: - Log capture

final class AdMeasurementLogBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { mutex.lock(); lines.append(line); mutex.unlock() }
    func all() -> String { mutex.lock(); defer { mutex.unlock() }; return lines.joined(separator: "\n") }
}

struct AdMeasurementLogHandler: LogHandler {
    let box: AdMeasurementLogBox
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        box.append("\(message.description) \(merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
    }
}
