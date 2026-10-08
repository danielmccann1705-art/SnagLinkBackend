import Vapor
import CoreFoundation

/// LinkedIn CAPI contract for the 2.0.2 measurement package. Deliberately not registered as a route
/// or scheduled job yet: the account-consent ledger, durable outbox and verified source hooks must
/// be integrated before activation. No app SDK, client purchase claim or raw email is forwarded.
enum LinkedInConversion {
    enum Environment: String, Sendable { case production, sandbox }

    /// Supplied by the authoritative account consent service, never directly from a webhook.
    /// iOS advertising measurement requires both our opt-in and the device's ATT authorisation.
    struct Permission: Sendable {
        var accountID: UUID
        var revision: UUID
        var allowed: Bool
        var attAuthorised: Bool
        var grantedAt: Date
        var checkedAt: Date
        var expiresAt: Date
    }

    /// A successfully resolved server switch, with a short validity window. No implicit enablement.
    struct Configuration: Sendable {
        var enabled: Bool
        var environment: Environment
        var signupRule: String
        var subscriptionRule: String
        var accessToken: String
        var fetchedAt: Date
    }

    struct Value: Encodable, Sendable { let currencyCode: String; let amount: String }
    struct Payload: Encodable, Sendable {
        struct User: Encodable, Sendable {
            struct Identifier: Encodable, Sendable { let idType: String; let idValue: String }
            let userIds: [Identifier]
        }
        let conversion: String
        let conversionHappenedAt: Int64
        let eventId: String
        let user: User
        let conversionValue: Value?
    }

    struct Fact: Sendable {
        fileprivate let accountID: UUID
        fileprivate let occurredAt: Date
        fileprivate let effectiveAt: Date
        fileprivate let environment: Environment
        fileprivate let key: String
        fileprivate let value: Value?

        var durableKey: String { key }
        var canonicalAccountID: UUID { accountID }
        var timestamp: Date { occurredAt }
        var purchaseTimestamp: Date { effectiveAt }
        var sourceEnvironment: Environment { environment }
        var conversionValue: Value? { value }

        /// Call only after a NEW account has been committed. A login, identity link or legacy
        /// import is not a sign-up. The caller must establish email verification separately.
        static func accountCreated(accountID: UUID, occurredAt: Date, environment: Environment) -> Fact {
            .init(accountID: accountID, occurredAt: occurredAt, effectiveAt: occurredAt, environment: environment,
                  key: "linkedin:v1:signup:\(environment.rawValue):\(accountID.uuidString.lowercased())", value: nil)
        }

        static func subscriptionPayment(accountID: UUID, occurredAt: Date, purchasedAt: Date,
                                        environment: Environment,
                                        durableKeyHash: String, currency: String, amount: String) -> Fact {
            .init(accountID: accountID, occurredAt: occurredAt, effectiveAt: purchasedAt, environment: environment,
                  key: "linkedin:v1:durable:\(durableKeyHash)", value: .init(currencyCode: currency, amount: amount))
        }
    }

    struct Prepared: Sendable {
        let payload: Payload
        fileprivate let fact: Fact
        fileprivate let permissionRevision: UUID
    }

    private static let freshness: TimeInterval = 300
    private static let maximumEventAge: TimeInterval = 7 * 86_400

    private static func valid(_ permission: Permission, fact: Fact, now: Date) -> Bool {
        permission.accountID == fact.accountID && permission.allowed && permission.attAuthorised &&
        permission.checkedAt <= now && now.timeIntervalSince(permission.checkedAt) < freshness &&
        permission.expiresAt > now && permission.grantedAt <= fact.occurredAt && permission.grantedAt <= fact.effectiveAt &&
        fact.occurredAt <= now && now.timeIntervalSince(fact.occurredAt) < maximumEventAge
    }

    private static func rule(for fact: Fact, configuration: Configuration, now: Date) -> String? {
        guard configuration.enabled, fact.environment == configuration.environment,
              configuration.fetchedAt <= now, now.timeIntervalSince(configuration.fetchedAt) < freshness,
              !configuration.accessToken.isEmpty, configuration.accessToken.utf8.count <= 4096,
              configuration.accessToken.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        let id = fact.value == nil ? configuration.signupRule : configuration.subscriptionRule
        guard !id.isEmpty, id.utf8.count <= 20, id.first != "0",
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return "urn:lla:llaPartnerConversion:\(id)"
    }

    /// Hash only a server-verified address. Verification is a producer obligation, not something
    /// syntax validation can prove. Omit Apple's private relay addresses rather than seek or infer
    /// another identity. The hash remains personal data and is never logged.
    static func prepare(_ fact: Fact, verifiedEmail: String, permission: Permission,
                        configuration: Configuration, now: Date) -> Prepared? {
        guard let emailHash = verifiedEmailHash(verifiedEmail) else { return nil }
        return prepare(fact, verifiedEmailHash: emailHash, permission: permission,
                       configuration: configuration, now: now)
    }

    static func verifiedEmailHash(_ verifiedEmail: String) -> String? {
        let email = verifiedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              parts[1] != "privaterelay.appleid.com",
              email.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != "\\" }) else { return nil }
        return SHA256Hasher.hash(token: email)
    }

    static func prepare(_ fact: Fact, verifiedEmailHash: String, permission: Permission,
                        configuration: Configuration, now: Date) -> Prepared? {
        guard valid(permission, fact: fact, now: now), let conversion = rule(for: fact, configuration: configuration, now: now),
              verifiedEmailHash.count == 64,
              verifiedEmailHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let milliseconds = fact.occurredAt.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) else { return nil }
        return .init(payload: .init(conversion: conversion, conversionHappenedAt: Int64(milliseconds),
            eventId: SHA256Hasher.hash(token: fact.key),
            user: .init(userIds: [.init(idType: "SHA256_EMAIL", idValue: verifiedEmailHash)]),
            conversionValue: fact.value), fact: fact, permissionRevision: permission.revision)
    }

    /// The sole constructor for paid facts. This authenticates the RevenueCat webhook envelope;
    /// it is not independent Apple receipt validation. It deliberately ignores subscriber
    /// attributes and aliases. The future ingress must also resolve an ACTIVE matching account.
    static func subscriptionFact(body: Data, authorization: String, expectedAuthorization: String,
                                 expectedRevenueCatAppID: String) -> Fact? {
        guard body.count <= 65_536, expectedAuthorization.hasPrefix("Bearer "), expectedAuthorization.count >= 24,
              authorization.utf8.count <= 4096, !expectedRevenueCatAppID.isEmpty,
              ConstantTimeComparison.compare(SHA256Hasher.hash(token: authorization), SHA256Hasher.hash(token: expectedAuthorization)),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["api_version"] as? String == "1.0", let event = root["event"] as? [String: Any],
              event["app_id"] as? String == expectedRevenueCatAppID,
              let sourceID = event["id"] as? String, !sourceID.isEmpty,
              let type = event["type"] as? String, ["INITIAL_PURCHASE", "RENEWAL"].contains(type),
              let environmentText = event["environment"] as? String,
              let environment = ["PRODUCTION": Environment.production, "SANDBOX": .sandbox][environmentText],
              event["store"] as? String == "APP_STORE",
              let period = event["period_type"] as? String, ["NORMAL", "INTRO"].contains(period),
              let family = event["is_family_share"] as? NSNumber, CFGetTypeID(family) == CFBooleanGetTypeID(), !family.boolValue,
              let product = event["product_id"] as? String, ["com.snaglist.pro.monthly", "com.snaglist.pro.annual"].contains(product),
              let entitlements = event["entitlement_ids"] as? [String], entitlements.contains("Snaglist Pro"),
              let userID = event["app_user_id"] as? String, let accountID = UUID(uuidString: userID),
              let transaction = event["transaction_id"] as? String, !transaction.isEmpty, transaction.utf8.count <= 256,
              transaction.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              let eventTimestamp = event["event_timestamp_ms"] as? NSNumber,
              CFGetTypeID(eventTimestamp) != CFBooleanGetTypeID(), eventTimestamp.doubleValue.isFinite,
              eventTimestamp.doubleValue > 0, eventTimestamp.doubleValue < 32_503_680_000_000,
              eventTimestamp.doubleValue.rounded(.down) == eventTimestamp.doubleValue,
              let purchasedTimestamp = event["purchased_at_ms"] as? NSNumber,
              CFGetTypeID(purchasedTimestamp) != CFBooleanGetTypeID(), purchasedTimestamp.doubleValue.isFinite,
              purchasedTimestamp.doubleValue > 0, purchasedTimestamp.doubleValue < 32_503_680_000_000,
              purchasedTimestamp.doubleValue.rounded(.down) == purchasedTimestamp.doubleValue,
              let price = event["price_in_purchased_currency"] as? NSNumber, CFGetTypeID(price) != CFBooleanGetTypeID(),
              price.doubleValue.isFinite, let amount = Decimal(string: price.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              amount > 0, amount < 1_000_000,
              let currency = event["currency"] as? String, Locale.commonISOCurrencyCodes.contains(currency) else { return nil }
        // RevenueCat documents that App Store renewal billing periods can start up to
        // 24 hours after it collected the payment. The immutable event timestamp is
        // therefore the occurrence/consent time; the period start is validated but is
        // not retained because this relay does not maintain entitlement state.
        let maximumFuturePeriodStart: TimeInterval = type == "RENEWAL" ? 86_400 : 300
        guard purchasedTimestamp.doubleValue <= eventTimestamp.doubleValue + maximumFuturePeriodStart * 1_000 else {
            return nil
        }
        return .init(accountID: accountID,
            occurredAt: Date(timeIntervalSince1970: eventTimestamp.doubleValue / 1000),
            effectiveAt: Date(timeIntervalSince1970: purchasedTimestamp.doubleValue / 1000),
            environment: environment,
            // Account ID intentionally excluded: transferring/restoring a purchase must not make
            // the same Apple transaction a new payment. A renewal has a new transaction ID.
            key: "linkedin:v1:payment:\(environment.rawValue):APP_STORE:\(transaction)",
            value: .init(currencyCode: currency, amount: NSDecimalNumber(decimal: amount).stringValue))
    }

    struct Reply: Sendable { let status: Int; let retryAfter: String? }
    typealias Transport = @Sendable (URI, HTTPHeaders, Data) async throws -> Reply
    enum Delivery: Equatable, Sendable {
        /// API receipt only, NOT an attributed conversion or a matched member.
        case received, suppressed, rejected, configurationRequired, uncertain
        case rateLimited(retryAfterSeconds: Int)
    }

    /// Single attempt only. Caller must atomically claim a durable event key before sending.
    /// Timeout/5xx/unknown success stays uncertain: no exactly-once guarantee is assumed from
    /// LinkedIn's browser/server dedup documentation. Do not blindly resend ambiguous attempts.
    static func send(_ prepared: Prepared, configuration: Configuration, now: Date,
                     permission: @Sendable () async -> Permission?, transport: Transport) async -> Delivery {
        guard let latest = await permission(), latest.revision == prepared.permissionRevision,
              valid(latest, fact: prepared.fact, now: now),
              let currentRule = rule(for: prepared.fact, configuration: configuration, now: now),
              currentRule == prepared.payload.conversion,
              let body = try? JSONEncoder().encode(prepared.payload) else { return .suppressed }
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: configuration.accessToken)
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: "LinkedIn-Version", value: "202609")
        headers.replaceOrAdd(name: "X-Restli-Protocol-Version", value: "2.0.0")
        let reply: Reply
        do { reply = try await transport(URI(string: "https://api.linkedin.com/rest/conversionEvents"), headers, body) }
        catch { return .uncertain }
        switch reply.status {
        case 201: return .received
        case 401, 403: return .configurationRequired
        case 429: return .rateLimited(retryAfterSeconds: min(86_400, max(60, Int(reply.retryAfter ?? "") ?? 300)))
        case 300..<400, 400..<429, 430..<500: return .rejected
        default: return .uncertain
        }
    }
}
