import Fluent
import Vapor

/// Short-lived, server-verified entitlements. A client tier string is only a refresh hint.
struct SubscriptionVerificationService {
    struct Customer: Decodable {
        struct Subscriber: Decodable {
            struct Entitlement: Decodable {
                let expires_date: String?
                let grace_period_expires_date: String?

                enum CodingKeys: String, CodingKey {
                    case expires_date, grace_period_expires_date
                }

                init(expires_date: String?, grace_period_expires_date: String?) {
                    self.expires_date = expires_date
                    self.grace_period_expires_date = grace_period_expires_date
                }

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    // RevenueCat uses an explicit null for lifetime access. A missing
                    // field is malformed data and must never grant a paid entitlement.
                    expires_date = try values.decode(String?.self, forKey: .expires_date)
                    grace_period_expires_date = try values.decodeIfPresent(String.self, forKey: .grace_period_expires_date)
                }
            }
            let entitlements: [String: Entitlement]
        }
        let subscriber: Subscriber
    }

    static func verifiedUntil(_ entitlement: Customer.Subscriber.Entitlement?, now: Date) throws -> Date? {
        guard let entitlement else { return nil }
        let cap = now.addingTimeInterval(300)
        guard let rawExpiry = entitlement.expires_date else { return cap }
        func parse(_ value: String) throws -> Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw Abort(.badGateway, reason: "Invalid subscription verification response") }
            return date
        }
        var expiry = try parse(rawExpiry)
        if let grace = entitlement.grace_period_expires_date { expiry = max(expiry, try parse(grace)) }
        return expiry > now ? min(expiry, cap) : nil
    }

    @discardableResult
    static func refresh(user: User, on req: Request) async throws -> SubscriptionTier {
        guard let key = Environment.get("REVENUECAT_SECRET_API_KEY"), !key.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Purchase verification is temporarily unavailable. Please try again.")
        }
        let id = try user.requireID().uuidString
        let response = try await req.client.get(URI(string: "https://api.revenuecat.com/v1/subscribers/\(id)")) { request in
            request.headers.bearerAuthorization = .init(token: key)
            request.headers.add(name: .accept, value: "application/json")
        }
        guard response.status == .ok else {
            throw Abort(.serviceUnavailable, reason: "Purchase verification is temporarily unavailable. Please try again.")
        }
        let customer: Customer
        do {
            customer = try response.content.decode(Customer.self)
        } catch {
            throw Abort(.badGateway, reason: "Invalid subscription verification response")
        }
        let until = try verifiedUntil(customer.subscriber.entitlements["pro"], now: Date())
        user.subscriptionTier = until == nil ? "free" : "pro"
        user.subscriptionVerifiedUntil = until
        try await user.save(on: req.db)
        return until == nil ? .free : .pro
    }

    static func currentTier(user: User, on req: Request) async throws -> SubscriptionTier {
        guard user.subscriptionTier == "pro" else { return .free }
        guard let until = user.subscriptionVerifiedUntil, until > Date() else {
            return try await refresh(user: user, on: req)
        }
        return .pro
    }
}
