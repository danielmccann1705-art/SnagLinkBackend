import Foundation

/// Lightweight email validation for magic-link auth (B1).
/// Format check is deliberately permissive (RFC-perfect validation is unnecessary —
/// deliverability is the real gate), plus a disposable-domain blocklist for fraud prevention.
struct EmailValidator {
    /// Normalises an email for storage / comparison: trimmed + lower-cased.
    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Basic structural validity: `local@domain.tld`, no spaces, single `@`.
    static func isValidFormat(_ email: String) -> Bool {
        let pattern = #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#
        return email.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Known disposable / throwaway email domains. Kept small and conservative; extend as
    /// abuse patterns emerge. (Spec references an "existing list maintained for fraud
    /// prevention" — none was wired in the repo, so this is the seed.)
    static let disposableDomains: Set<String> = [
        "mailinator.com", "guerrillamail.com", "10minutemail.com", "tempmail.com",
        "temp-mail.org", "throwawaymail.com", "yopmail.com", "trashmail.com",
        "getnada.com", "dispostable.com", "maildrop.cc", "fakeinbox.com",
        "sharklasers.com", "guerrillamailblock.com", "mailnesia.com", "mintemail.com"
    ]

    static func isDisposable(_ email: String) -> Bool {
        guard let domain = email.split(separator: "@").last.map(String.init)?.lowercased() else {
            return false
        }
        return disposableDomains.contains(domain)
    }

    /// True when the email is structurally valid and not from a disposable domain.
    static func isAcceptable(_ email: String) -> Bool {
        isValidFormat(email) && !isDisposable(email)
    }
}
