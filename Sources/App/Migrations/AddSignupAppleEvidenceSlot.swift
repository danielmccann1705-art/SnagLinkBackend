import Fluent
import FluentSQL
import Vapor

/// One optional, capability-bound Apple Ads evidence slot per pre-auth signup intent.
/// The slot is an ordinary token-free `ad_attribution_records` row reserved before the
/// account exists; adoption links it to the exact Apple consent revision, installation
/// and new account. No token is stored. Follows `CreateMeasurementSignupIntents`.
struct AddSignupAppleEvidenceSlot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                ALTER TABLE measurement_signup_intents
                    ADD COLUMN apple_slot_reference TEXT UNIQUE
                        CHECK (apple_slot_reference IS NULL OR apple_slot_reference ~ '^[A-Z2-7]{26}$'),
                    ADD COLUMN apple_slot_reserved_at TIMESTAMPTZ,
                    ADD CONSTRAINT measurement_signup_apple_slot_reserved
                        CHECK ((apple_slot_reference IS NULL) = (apple_slot_reserved_at IS NULL)),
                    ADD CONSTRAINT measurement_signup_apple_slot_purpose
                        CHECK (apple_slot_reference IS NULL OR apple_ads IS TRUE)
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Signup Apple evidence slots must survive rollback; use a compatible image")
    }
}
