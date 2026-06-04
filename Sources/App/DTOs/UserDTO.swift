import Vapor

struct UpdateUserProfileRequest: Content {
    let name: String?
    let email: String?
}

struct UserProfileResponse: Content {
    let id: UUID
    /// Nil for magic-link accounts.
    let appleUserId: String?
    let authProvider: String
    let email: String?
    let name: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from user: User) {
        self.id = user.id!
        self.appleUserId = user.appleUserId
        self.authProvider = user.authProvider
        self.email = user.email
        self.name = user.name
        self.createdAt = user.createdAt
        self.updatedAt = user.updatedAt
    }
}
