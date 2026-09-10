import Foundation

/// An optional delivery restriction for isolated environments. An explicitly
/// configured empty list disables delivery; an absent setting keeps normal use.
enum EmailDeliveryPolicy {
    static func allows(_ recipient: String, configuredRecipients: String?) -> Bool {
        guard let configuredRecipients else { return true }
        let allowed = Set(configuredRecipients.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        return allowed.contains(recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
