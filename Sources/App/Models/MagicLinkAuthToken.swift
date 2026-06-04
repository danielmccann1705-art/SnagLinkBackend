import Fluent
import Vapor

/// A short-lived, single-use token used for passwordless ("magic link") Project Manager sign-in.
///
/// The raw token is never stored — only its SHA256 hash (`tokenHash`). The raw value is
/// emailed to the user as `https://snaglist.dev/auth/{token}` and exchanged via
/// `POST /api/v1/auth/magic-link/verify`. Tokens expire after 15 minutes (`expiresAt`) and
/// are marked `consumedAt` on first successful verification.
final class MagicLinkAuthToken: Model, Content, @unchecked Sendable {
    static let schema = "magic_link_auth_tokens"

    @ID(key: .id)
    var id: UUID?

    /// SHA256 hex digest of the raw URL-safe token. Indexed for lookup.
    @Field(key: "token_hash")
    var tokenHash: String

    /// The email the sign-in link was issued for. Lower-cased on write.
    @Field(key: "email")
    var email: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Set on first successful verification — enforces single use.
    @OptionalField(key: "consumed_at")
    var consumedAt: Date?

    /// Display name supplied on request, used when creating a brand-new account.
    @OptionalField(key: "requested_name")
    var requestedName: String?

    /// IP of the requester, retained for rate-limit auditing / abuse review only.
    @OptionalField(key: "requesting_ip")
    var requestingIP: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tokenHash: String,
        email: String,
        expiresAt: Date,
        requestedName: String? = nil,
        requestingIP: String? = nil
    ) {
        self.id = id
        self.tokenHash = tokenHash
        self.email = email
        self.expiresAt = expiresAt
        self.requestedName = requestedName
        self.requestingIP = requestingIP
    }

    var isExpired: Bool { Date() > expiresAt }
    var isConsumed: Bool { consumedAt != nil }
}
