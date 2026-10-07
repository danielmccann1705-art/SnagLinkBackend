import Vapor

/// The exchange with Apple's attribution API (IOS-2.0.2-SLICE1.md item 14; MEASUREMENT-DECISION.md §3.4; Apple
/// AdServices API: `POST https://api-adservices.apple.com/api/v1/`, `Content-Type: text/plain`, the token as the
/// body).
///
/// Apple's answer is reduced to the stored Standard fields plus a transient
/// organisation identifier used only to verify server-owned campaigns. The
/// organisation identifier and raw response are never persisted or logged.
enum AppleAttributionExchangeService {
    static let endpoint = URI(string: "https://api-adservices.apple.com/api/v1/")

    /// Apple's Standard record, as stored.
    struct StandardFields: Sendable, Equatable {
        var attribution: Bool?
        var organizationId: Int64? = nil
        var campaignId: Int64?
        var adGroupId: Int64?
        var keywordId: Int64?
        var adId: Int64?
        var claimType: String?
        var conversionType: String?
        var countryOrRegion: String?
    }

    enum Outcome: Sendable, Equatable {
        /// `200` with a readable Standard record: stored, token dropped, `done`.
        case attributed(StandardFields)
        /// `404` on every attempt of this pass ("not yet available"): stays `pending`, token kept until expiry.
        case notYetAvailable
        /// `400`: Apple rejects the token. `invalid`, token dropped; never retried.
        case invalid
        /// `5xx`, `429`, any other status, no answer, or a `200` whose body cannot be read: `failing`, retried by the
        /// next pass while the token is still valid.
        case failing
    }

    struct Reply: Sendable {
        let status: HTTPStatus
        let body: ByteBuffer?
    }

    /// Replaces the HTTP call under `.testing` only, never as a production fallback.
    typealias Transport = @Sendable (_ uri: URI, _ headers: HTTPHeaders, _ body: String) async throws -> Reply
    struct TransportKey: StorageKey { typealias Value = Transport }
    /// Replaces the five-second wait between `404` attempts under `.testing` only.
    typealias Sleep = @Sendable (_ seconds: Int) async -> Void
    struct SleepKey: StorageKey { typealias Value = Sleep }

    /// The live transport, or under `.testing` the stored one; `nil` under `.testing` without one, so a test never
    /// reaches Apple.
    static func transport(_ app: Application) -> Transport? {
        if app.environment == .testing { return app.storage[TransportKey.self] }
        let client = app.client
        return { uri, headers, body in
            let response = try await client.post(uri, headers: headers) { request in
                request.body = ByteBuffer(string: body)
                request.timeout = .seconds(AdMeasurementPolicy.appleRequestTimeoutSeconds)
            }
            return Reply(status: response.status, body: response.body)
        }
    }

    static func sleep(_ app: Application) -> Sleep {
        if app.environment == .testing, let stored = app.storage[SleepKey.self] { return stored }
        return { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
    }

    /// One row's exchange: up to `appleAttemptsPerPass` requests, the next only after a `404` and a five-second
    /// wait. Returns the outcome, the number of requests made and a status word for the log (`200`, `404`,
    /// `no_answer`, …) — never a body.
    static func exchange(token: String, transport: Transport, sleep: Sleep) async -> (outcome: Outcome, attempts: Int, status: String) {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/plain")
        var attempts = 0
        for attempt in 1...AdMeasurementPolicy.appleAttemptsPerPass {
            if attempt > 1 { await sleep(AdMeasurementPolicy.appleRetryDelaySeconds) }
            attempts += 1
            let reply: Reply
            do { reply = try await transport(endpoint, headers, token) } catch { return (.failing, attempts, "no_answer") }
            let code = Int(reply.status.code)
            switch code {
            case 200:
                guard let fields = standardFields(reply.body) else { return (.failing, attempts, "200_unreadable") }
                return (.attributed(fields), attempts, "200")
            case 404:
                continue
            case 400:
                return (.invalid, attempts, "400")
            default:
                return (.failing, attempts, String(code))
            }
        }
        return (.notYetAvailable, attempts, "404")
    }

    /// Decodes only the Standard fields. `attribution` must be present as a boolean, or the answer is unreadable.
    /// A field of the wrong type or shape is left empty rather than stored: identifiers are non-negative integers,
    /// `claimType` and `conversionType` are single words, `countryOrRegion` is a two-letter code.
    static func standardFields(_ body: ByteBuffer?) -> StandardFields? {
        guard let body, body.readableBytes > 0, body.readableBytes <= AdMeasurementPolicy.appleResponseMaxBytes,
              let wire = try? JSONDecoder().decode(StandardWire.self, from: Data(body.readableBytesView)),
              let attribution = wire.attribution else { return nil }
        return StandardFields(attribution: attribution, organizationId: wire.orgId,
                              campaignId: wire.campaignId, adGroupId: wire.adGroupId,
                              keywordId: wire.keywordId, adId: wire.adId,
                              claimType: word(wire.claimType), conversionType: word(wire.conversionType),
                              countryOrRegion: region(wire.countryOrRegion))
    }

    private static func word(_ value: String?) -> String? {
        guard let value, (1...32).contains(value.utf8.count),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return value
    }

    private static func region(_ value: String?) -> String? {
        guard let value, value.utf8.count == 2, value.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return value
    }

    /// The decoder's whole vocabulary. Each field is decoded on its own, so one malformed field empties that field
    /// only.
    private struct StandardWire: Decodable {
        let attribution: Bool?
        let orgId: Int64?
        let campaignId: Int64?, adGroupId: Int64?, keywordId: Int64?, adId: Int64?
        let claimType: String?, conversionType: String?, countryOrRegion: String?

        enum CodingKeys: String, CodingKey {
            case attribution, orgId, campaignId, adGroupId, keywordId, adId, claimType, conversionType, countryOrRegion
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attribution = try? c.decodeIfPresent(Bool.self, forKey: .attribution)
            func identifier(_ key: CodingKeys) -> Int64? {
                guard let value = (try? c.decodeIfPresent(Int64.self, forKey: key)) ?? nil, value >= 0 else { return nil }
                return value
            }
            orgId = identifier(.orgId); campaignId = identifier(.campaignId); adGroupId = identifier(.adGroupId)
            keywordId = identifier(.keywordId); adId = identifier(.adId)
            claimType = (try? c.decodeIfPresent(String.self, forKey: .claimType)) ?? nil
            conversionType = (try? c.decodeIfPresent(String.self, forKey: .conversionType)) ?? nil
            countryOrRegion = (try? c.decodeIfPresent(String.self, forKey: .countryOrRegion)) ?? nil
        }
    }
}
