import Fluent
import Vapor

struct CreateAppleWebChallenges: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            try await VerifiedIdentityService.sql(db).raw("""
                CREATE TABLE apple_web_challenges (
                    id UUID PRIMARY KEY, state_hash TEXT NOT NULL UNIQUE, nonce_hash TEXT NOT NULL UNIQUE,
                    binding_hash TEXT NOT NULL, environment TEXT NOT NULL CHECK(environment IN ('staging','production')),
                    origin TEXT NOT NULL, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL, consumed_at TIMESTAMPTZ,
                    CHECK(expires_at>created_at),CHECK(consumed_at IS NULL OR consumed_at>=created_at)
                )
                """).run()
            try await VerifiedIdentityService.sql(db).raw("CREATE INDEX apple_web_challenge_expiry ON apple_web_challenges(expires_at)").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Keep one-use authentication state; use a compatible image")
    }
}
