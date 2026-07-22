import Fluent
import FluentSQL

/// B4: tier + onboarding-link tracking on users.
/// - `onboarding_link_consumed`: flips true on the user's first magic-link send (that send is
///   exempt from the monthly counter) and never resets. Existing users default to FALSE, so they
///   never retroactively get the bonus link.
/// - `subscription_tier`: "free" / "pro", updated by the client after RevenueCat purchase/restore;
///   drives the server-side allowance (5/mo free, unlimited pro).
struct AddOnboardingLinkConsumedToUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            ALTER TABLE users
            ADD COLUMN IF NOT EXISTS onboarding_link_consumed BOOLEAN NOT NULL DEFAULT FALSE
            """).run()
        try await sql.raw("""
            ALTER TABLE users
            ADD COLUMN IF NOT EXISTS subscription_tier TEXT NOT NULL DEFAULT 'free'
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS subscription_tier").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS onboarding_link_consumed").run()
    }
}
