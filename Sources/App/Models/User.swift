import Fluent
import Vapor

/// How a user account was created / authenticates.
enum AuthProvider: String, Codable {
    case apple
    case magicLink = "magic_link"
}

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    /// Apple's stable subject identifier. Nil for accounts created via magic-link sign-in.
    @OptionalField(key: "apple_user_id")
    var appleUserId: String?

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "name")
    var name: String?

    /// How the account was created. Defaults to `apple` for legacy rows.
    @Field(key: "auth_provider")
    var authProvider: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    /// Sign in with Apple account.
    init(id: UUID? = nil, appleUserId: String, email: String?, name: String?) {
        self.id = id
        self.appleUserId = appleUserId
        self.email = email
        self.name = name
        self.authProvider = AuthProvider.apple.rawValue
    }

    /// Generic initializer supporting any auth provider (e.g. magic-link accounts).
    init(
        id: UUID? = nil,
        appleUserId: String?,
        email: String?,
        name: String?,
        authProvider: AuthProvider
    ) {
        self.id = id
        self.appleUserId = appleUserId
        self.email = email
        self.name = name
        self.authProvider = authProvider.rawValue
    }
}
