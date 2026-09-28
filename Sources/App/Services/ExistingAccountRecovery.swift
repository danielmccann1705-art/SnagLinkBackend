import Vapor
import Fluent
import FluentSQL

/// The single refusal a first Sign in with Apple gets when its address already belongs to
/// another Snaglist account (audit F21; Dan's requirements, 28 Sep 2026). Native and web give
/// the same status, the same identifier and the same sentence, built here and nowhere else.
/// Accounts are never merged by email: the sentence tells the person how the existing
/// account signs in, and they sign in that way.
///
/// The sign-in method is named only when the provider has verified the address, so the
/// person asking has proved they control it; otherwise the sentence stays general.
enum ExistingAccountRecovery {
    enum Method: String, CaseIterable, Sendable, Comparable {
        case apple, google, emailLink = "email_link"
        static func < (a: Method, b: Method) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
        var phrase: String {
            switch self {
            case .apple: return "a different Apple ID"
            case .google: return "Google"
            case .emailLink: return "a sign-in link sent to this address"
            }
        }
    }

    static let identifier = "identity_proof_required"
    /// Every variant starts with this sentence; the iOS client already matches it.
    static let prefix = "This email already belongs to a Snaglist account"
    /// Carries the method list (a closed vocabulary) to the web callback, which turns it
    /// into a fixed query value next to the `apple_existing_account` marker.
    static let methodsHeader = "Snaglist-Existing-Sign-In"

    static func message(_ methods: [Method]) -> String {
        let named = Array(Set(methods)).sorted()
        guard !named.isEmpty else {
            return prefix + ". Sign in the way you first did to reach it. Accounts are never joined by email."
        }
        let phrases = named.map(\.phrase)
        let list = phrases.count == 1 ? phrases[0] : phrases.dropLast().joined(separator: ", ") + " or " + phrases.last!
        return prefix + " that signs in with " + list + ". Sign in that way to reach it. Accounts are never joined by email."
    }

    static func refusal(_ methods: [Method]) -> Abort {
        var headers = HTTPHeaders()
        let named = Array(Set(methods)).sorted()
        headers.replaceOrAdd(name: methodsHeader, value: named.isEmpty ? "unknown" : named.map(\.rawValue).joined(separator: ","))
        return Abort(.conflict, headers: headers, reason: message(methods), identifier: identifier)
    }

    /// The methods the live account(s) holding `email` sign in with. Identity rows decide;
    /// an older account with no identity rows falls back to how it was created.
    /// `excluding` leaves out the account being created in the caller's own transaction.
    static func methods(holding email: String, excluding: UUID? = nil, on db: Database) async throws -> [Method] {
        let skip = excluding ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let rows = try await VerifiedIdentityService.sql(db).raw("""
            WITH holders AS (
                SELECT id FROM (
                    SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) AND lifecycle_state <> 'deleted'
                    UNION SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)
                ) held WHERE id <> \(bind: skip)
            )
            SELECT DISTINCT i.provider AS method FROM user_identities i JOIN holders h ON h.id = i.user_id
            UNION
            SELECT DISTINCT CASE u.auth_provider WHEN 'magic_link' THEN 'email' ELSE u.auth_provider END
              FROM users u JOIN holders h ON h.id = u.id
             WHERE NOT EXISTS (SELECT 1 FROM user_identities i WHERE i.user_id = u.id)
            """).all()
        return try rows.compactMap { row -> Method? in
            switch try row.decode(column: "method", as: String?.self) {
            case "apple": return .apple
            case "google": return .google
            case "email": return .emailLink
            default: return nil
            }
        }.sorted()
    }
}
