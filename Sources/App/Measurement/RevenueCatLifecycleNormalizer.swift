import Foundation
import CoreFoundation

/// Reduces an authenticated RevenueCat webhook to the smallest lifecycle fact
/// needed for deduplication and measurement. Raw provider/customer payloads are
/// never retained by this type's caller.
struct RevenueCatLifecycleFact: Sendable {
    enum Kind: String, Sendable {
        case initialPurchase = "initial_purchase"
        case renewal
        case cancellation
        case expiration
        case refundReversed = "refund_reversed"
    }

    enum Effect: String, Sendable {
        case charge
        case cancellationNotice = "cancellation_notice"
        case expirationNotice = "expiration_notice"
        case refund
        case refundReversal = "refund_reversal"
        case zeroValue = "zero_value"
        case unresolved
    }

    let providerEventKeyHash: String
    let normalizedHash: String
    let accountID: UUID
    let environment: LinkedInConversion.Environment
    let kind: Kind
    let effect: Effect
    let chargeKeyHash: String
    let subscriptionChainKeyHash: String
    let eventGeneratedAt: Date
    let purchasedAt: Date
    let expirationAt: Date?
    let reason: String?
    let currency: String?
    let monetaryDelta: String?
    let productID: String

    var isResolved: Bool { effect != .unresolved }
    var isPositiveCharge: Bool { effect == .charge }

    var chargeFactHash: String {
        SHA256Hasher.hash(token: [kind.rawValue, environment.rawValue, productID,
            String(purchasedAt.timeIntervalSince1970), currency ?? "", monetaryDelta ?? ""].joined(separator: "|"))
    }
}

enum RevenueCatLifecycleNormalizer {
    private static let products: Set<String> = ["com.snaglist.pro.monthly", "com.snaglist.pro.annual"]
    private static let periods: Set<String> = ["NORMAL", "INTRO", "TRIAL"]
    private static let cancellationReasons: Set<String> = [
        "UNSUBSCRIBE", "BILLING_ERROR", "DEVELOPER_INITIATED", "PRICE_INCREASE", "CUSTOMER_SUPPORT", "UNKNOWN"
    ]
    private static let expirationReasons: Set<String> = [
        "UNSUBSCRIBE", "BILLING_ERROR", "DEVELOPER_INITIATED", "PRICE_INCREASE", "CUSTOMER_SUPPORT", "UNKNOWN",
        "SUBSCRIPTION_PAUSED"
    ]

    static func parse(_ body: Data, expectedAppID: String) -> RevenueCatLifecycleFact? {
        guard body.count <= 65_536, !expectedAppID.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["api_version"] as? String == "1.0",
              let event = root["event"] as? [String: Any],
              event["app_id"] as? String == expectedAppID,
              let providerEventID = boundedIdentifier(event["id"]),
              let type = event["type"] as? String,
              let kind = kind(type),
              let environmentText = event["environment"] as? String,
              let environment = ["PRODUCTION": LinkedInConversion.Environment.production,
                                 "SANDBOX": .sandbox][environmentText],
              event["store"] as? String == "APP_STORE",
              let accountText = event["app_user_id"] as? String,
              let accountID = UUID(uuidString: accountText),
              let product = event["product_id"] as? String, products.contains(product),
              let entitlements = event["entitlement_ids"] as? [String], entitlements.contains("Snaglist Pro"),
              let family = event["is_family_share"] as? NSNumber,
              CFGetTypeID(family) == CFBooleanGetTypeID(), !family.boolValue,
              let period = event["period_type"] as? String, periods.contains(period),
              let transaction = boundedIdentifier(event["transaction_id"]),
              let originalTransaction = boundedIdentifier(event["original_transaction_id"]),
              let eventMilliseconds = integerMilliseconds(event["event_timestamp_ms"]),
              let purchasedMilliseconds = integerMilliseconds(event["purchased_at_ms"]) else { return nil }
        let price = price(event["price_in_purchased_currency"])
        let currencyField = currency(event["currency"])
        guard price.valid, currencyField.valid,
              !((price.value != nil) && currencyField.value == nil) else { return nil }
        let currency = currencyField.value

        let eventAt = Date(timeIntervalSince1970: eventMilliseconds / 1_000)
        let purchasedAt = Date(timeIntervalSince1970: purchasedMilliseconds / 1_000)
        let maximumFuturePeriodStart: TimeInterval = kind == .renewal ? 86_400 : 300
        guard purchasedAt <= eventAt.addingTimeInterval(maximumFuturePeriodStart) else { return nil }

        let expirationAt: Date?
        if event["expiration_at_ms"] == nil || event["expiration_at_ms"] is NSNull {
            expirationAt = nil
        } else {
            guard let milliseconds = integerMilliseconds(event["expiration_at_ms"]) else { return nil }
            expirationAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        }

        let reason: String?
        switch kind {
        case .cancellation:
            guard let value = event["cancel_reason"] as? String, cancellationReasons.contains(value) else { return nil }
            reason = value
        case .expiration:
            guard let value = event["expiration_reason"] as? String, expirationReasons.contains(value),
                  expirationAt != nil else { return nil }
            reason = value
        default:
            reason = nil
        }

        let amount = price.value
        let effect: RevenueCatLifecycleFact.Effect
        switch kind {
        case .initialPurchase, .renewal:
            effect = (amount ?? 0) > 0 ? .charge : (amount == 0 ? .zeroValue : .unresolved)
        case .cancellation:
            if reason == "CUSTOMER_SUPPORT" {
                effect = (amount ?? 0) < 0 ? .refund : .unresolved
            } else {
                effect = .cancellationNotice
            }
        case .expiration:
            effect = .expirationNotice
        case .refundReversed:
            effect = (amount ?? 0) > 0 ? .refundReversal : .unresolved
        }

        let amountText = amount.map { NSDecimalNumber(decimal: $0).stringValue }
        let monetaryDelta = [RevenueCatLifecycleFact.Effect.cancellationNotice, .expirationNotice].contains(effect)
            ? nil : amountText
        let chargeKey = SHA256Hasher.hash(token:
            "linkedin:v1:payment:\(environment.rawValue):APP_STORE:\(transaction)")
        let chainKey = SHA256Hasher.hash(token:
            "revenuecat:v1:chain:\(environment.rawValue):APP_STORE:\(originalTransaction)")
        let eventKey = SHA256Hasher.hash(token:
            "revenuecat:v1:event:\(expectedAppID):\(environment.rawValue):\(providerEventID)")
        let normalized = [kind.rawValue, effect.rawValue, accountID.uuidString.lowercased(), environment.rawValue,
            product, transaction, originalTransaction, String(eventAt.timeIntervalSince1970),
            String(purchasedAt.timeIntervalSince1970), expirationAt.map { String($0.timeIntervalSince1970) } ?? "",
            reason ?? "", currency ?? "", amountText ?? ""].joined(separator: "|")
        return .init(providerEventKeyHash: eventKey, normalizedHash: SHA256Hasher.hash(token: normalized),
                     accountID: accountID, environment: environment, kind: kind, effect: effect,
                     chargeKeyHash: chargeKey, subscriptionChainKeyHash: chainKey,
                     eventGeneratedAt: eventAt, purchasedAt: purchasedAt, expirationAt: expirationAt,
                     reason: reason, currency: currency, monetaryDelta: monetaryDelta, productID: product)
    }

    private static func kind(_ value: String) -> RevenueCatLifecycleFact.Kind? {
        switch value {
        case "INITIAL_PURCHASE": return .initialPurchase
        case "RENEWAL": return .renewal
        case "CANCELLATION": return .cancellation
        case "EXPIRATION": return .expiration
        case "REFUND_REVERSED": return .refundReversed
        default: return nil
        }
    }

    private static func boundedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String, (1...256).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        return value
    }

    private static func integerMilliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0,
              number.doubleValue < 32_503_680_000_000,
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.doubleValue
    }

    private static func price(_ value: Any?) -> (valid: Bool, value: Decimal?) {
        guard let value, !(value is NSNull) else { return (true, nil) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              abs(NSDecimalNumber(decimal: decimal).doubleValue) < 1_000_000 else { return (false, nil) }
        return (true, decimal)
    }

    private static func currency(_ value: Any?) -> (valid: Bool, value: String?) {
        guard let value, !(value is NSNull) else { return (true, nil) }
        guard let value = value as? String, Locale.commonISOCurrencyCodes.contains(value) else { return (false, nil) }
        return (true, value)
    }
}
