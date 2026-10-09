import Foundation

/// Request shapes for Singular's documented server APIs, checked against Singular's official
/// documentation on 9 October 2026 (outputs/measurement-2026-10-07/SINGULAR-CONTROLS-OCT9.md).
///
/// HELD: pure value builders only. Nothing here is wired into `MeasurementDispatchService` or
/// `MeasurementErasureService`, there is no transport and no credential, and the Singular
/// destination stays production-disabled. Fields whose server-side meaning Singular has not
/// confirmed (for example `use_ip`, and whether device make/model/locale/build are required
/// on server-originated V2 events) are deliberately not modelled: a request that cannot be
/// built from verified fields returns `nil`, and the caller must treat that as manual work.
enum SingularServerEventContract {
    /// `POST https://s2s.singular.net/api/v2/evt`, form-encoded body (JSON bodies are refused).
    static let endpoint = "https://s2s.singular.net/api/v2/evt"
    static let contentType = "application/x-www-form-urlencoded"

    /// Event names: Singular standard names from the pinned 12.14.2 `Events.h` and the
    /// subscription guide. Partner configuration maps them to Meta's events in the dashboard.
    enum Name: String, CaseIterable, Sendable {
        case signUp = "sng_complete_registration"
        case subscriptionStarted = "sng_subscribe"
        case subscriptionRenewed = "subscription_renewed"
    }

    /// Captured on the device at SDID binding time and stored with that binding.
    struct Device: Equatable, Sendable {
        let sdid: String
        let bundleID: String
        let osVersion: String
        let ipAddress: String
        /// Apple's raw ATT status (0 not determined, 1 restricted, 2 denied, 3 authorised).
        let attAuthorizationStatus: Int
    }

    /// Verified money from the RevenueCat ledger. Never computed on the client.
    struct Revenue: Equatable, Sendable {
        let amount: String
        let currencyCode: String
        let productID: String
        let transactionID: String
    }

    struct Event: Equatable, Sendable {
        let name: Name
        let occurredAt: Date
        /// The opaque cross-company subject: the same value the app sets as Singular's custom
        /// user ID, and the `user_id` identity OpenDSR erases.
        let customUserID: String
        let revenue: Revenue?
    }

    /// Returns the form body, or `nil` when any documented constraint is not met.
    static func formBody(sdkKey: String, device: Device, event: Event) -> Data? {
        guard !sdkKey.isEmpty, isUUID(device.sdid), !device.bundleID.isEmpty, !device.osVersion.isEmpty,
              isIPv4(device.ipAddress), (0...3).contains(device.attAuthorizationStatus),
              isUUID(event.customUserID) else { return nil }
        // Revenue only on the money events, and money events only with revenue.
        switch (event.name, event.revenue) {
        case (.signUp, nil): break
        case (.subscriptionStarted, .some), (.subscriptionRenewed, .some): break
        default: return nil
        }
        var fields: [(String, String)] = [
            ("a", sdkKey), ("p", "iOS"), ("i", device.bundleID), ("sdid", device.sdid.lowercased()),
            ("ip", device.ipAddress), ("ve", device.osVersion), ("n", event.name.rawValue),
            ("att_authorization_status", String(device.attAuthorizationStatus)),
            ("utime", String(Int(event.occurredAt.timeIntervalSince1970))),
            ("custom_user_id", event.customUserID.lowercased()),
        ]
        if let revenue = event.revenue {
            guard isAmount(revenue.amount), isCurrency(revenue.currencyCode),
                  !revenue.productID.isEmpty, !revenue.transactionID.isEmpty else { return nil }
            fields += [("is_revenue_event", "true"), ("amt", revenue.amount), ("cur", revenue.currencyCode),
                       ("purchase_product_id", revenue.productID), ("purchase_transaction_id", revenue.transactionID)]
        }
        return encode(fields)
    }

    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func isUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
                && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }
    static func isCurrency(_ value: String) -> Bool {
        value.count == 3 && value.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }
    static func isAmount(_ value: String) -> Bool {
        guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return number > 0 && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }
}

/// Singular OpenDSR (GDPR) erasure: a request and a separate status poll. Submission is never
/// completion; only a status reply for the same request ID whose `request_status` is
/// `completed` closes the job. Singular documents completion within up to 30 days.
///
/// HELD: the documentation shows `/api/gdpr/requests` in some places and `/gdpr/requests` in
/// others, and does not say which key the `Authorization` header carries, so no base URL or
/// credential is modelled here.
enum SingularOpenDSRContract {
    /// Documented identity types do not include the SDID; `user_id` is the custom user ID.
    static let identityType = "user_id"
    static let propertyID = "iOS:com.snaglist.app"

    static func erasureRequestBody(requestID: UUID, submittedAt: Date, customUserID: String) -> Data? {
        guard UUID(uuidString: customUserID) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let body: [String: Any] = [
            "subject_request_id": requestID.uuidString.lowercased(),
            "subject_request_type": "erasure",
            "submitted_time": formatter.string(from: submittedAt),
            "subject_identities": [["identity_type": identityType,
                                    "identity_value": customUserID.lowercased(),
                                    "identity_format": "raw"]],
            "property_id": propertyID,
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    enum Outcome: Equatable, Sendable {
        /// Accepted for processing; keep the durable receipt and poll.
        case accepted(expectedCompletion: String?)
        case pending
        case completed
        /// Anything not exactly documented: never treated as success.
        case manual
    }

    /// Classifies the reply to the erasure request itself. An accepted request is never complete.
    static func classifySubmission(status: Int, body: Data, requestID: UUID) -> Outcome {
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["subject_request_id"] as? String)?.lowercased() == requestID.uuidString.lowercased()
        else { return .manual }
        return .accepted(expectedCompletion: object["expected_completion_time"] as? String)
    }

    /// Classifies a status poll for the same request ID.
    static func classifyStatus(status: Int, body: Data, requestID: UUID) -> Outcome {
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["subject_request_id"] as? String)?.lowercased() == requestID.uuidString.lowercased(),
              let state = object["request_status"] as? String else { return .manual }
        switch state {
        case "completed": return .completed
        case "pending": return .pending
        default: return .manual
        }
    }
}
