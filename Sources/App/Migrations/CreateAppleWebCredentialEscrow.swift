import Vapor
import Fluent

struct CreateAppleWebCredentialEscrow: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            try await VerifiedIdentityService.sql(db).raw("""
                CREATE TABLE apple_web_credential_escrow (
                    challenge_id UUID PRIMARY KEY REFERENCES apple_web_challenges(id), client_id TEXT NOT NULL,
                    credential_ciphertext TEXT, state TEXT NOT NULL CHECK(state IN ('held','ready','leased','blocked','adopted','revoked')),
                    lease_token UUID, available_at TIMESTAMPTZ NOT NULL, lease_expires_at TIMESTAMPTZ,
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), error_kind TEXT,
                    created_at TIMESTAMPTZ NOT NULL, completed_at TIMESTAMPTZ,
                    CHECK((state IN ('adopted','revoked'))=(credential_ciphertext IS NULL)),
                    CHECK((state IN ('adopted','revoked'))=(completed_at IS NOT NULL)),
                    CHECK((state IN ('held','leased'))=(lease_token IS NOT NULL)),
                    CHECK((state='leased')=(lease_expires_at IS NOT NULL))
                )
                """).run()
            try await VerifiedIdentityService.sql(db).raw("CREATE INDEX apple_web_escrow_work ON apple_web_credential_escrow(state,available_at)").run()
        }
    }
    func revert(on database: Database) async throws { throw Abort(.conflict, reason: "Provider revocation work must remain durable; use a compatible image") }
}
