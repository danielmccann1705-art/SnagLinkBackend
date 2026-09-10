import Fluent

struct AddSubscriptionVerification: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users").field("subscription_verified_until", .datetime).update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("users").deleteField("subscription_verified_until").update()
    }
}
