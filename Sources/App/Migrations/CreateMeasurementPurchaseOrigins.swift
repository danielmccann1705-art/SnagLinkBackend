import Fluent
import FluentSQL
import Vapor

/// Short-lived purchase callback capabilities and immutable acquisition-installation
/// bindings. Raw App Store transaction references and capabilities never enter these tables.
struct CreateMeasurementPurchaseOrigins: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await sql.raw("""
                ALTER TABLE measurement_revenuecat_events
                  ADD COLUMN product_id TEXT CHECK (product_id IS NULL OR product_id IN
                    ('com.snaglist.pro.monthly','com.snaglist.pro.annual')),
                  ADD COLUMN transaction_key_hmac TEXT CHECK (transaction_key_hmac IS NULL OR char_length(transaction_key_hmac)=64),
                  ADD COLUMN chain_key_hmac TEXT CHECK (chain_key_hmac IS NULL OR char_length(chain_key_hmac)=64)
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX measurement_rc_transaction_hmac ON measurement_revenuecat_events(transaction_key_hmac) WHERE transaction_key_hmac IS NOT NULL").run()
            try await sql.raw("""
                CREATE TABLE measurement_purchase_intents (
                    id UUID PRIMARY KEY,
                    capability_hash TEXT NOT NULL UNIQUE CHECK (char_length(capability_hash)=64),
                    account_id UUID NOT NULL REFERENCES users(id),
                    installation_id UUID NOT NULL,
                    consent_revision UUID NOT NULL,
                    subject_id UUID NOT NULL REFERENCES measurement_subjects(id),
                    product_id TEXT NOT NULL CHECK (product_id IN ('com.snaglist.pro.monthly','com.snaglist.pro.annual')),
                    environment TEXT NOT NULL CHECK (environment IN ('sandbox','production')),
                    state TEXT NOT NULL CHECK (state IN ('prepared','witnessed','matched','conflict','revoked')),
                    issued_at TIMESTAMPTZ NOT NULL,
                    expires_at TIMESTAMPTZ NOT NULL,
                    witness_hash TEXT CHECK (witness_hash IS NULL OR char_length(witness_hash)=64),
                    transaction_key_hmac TEXT CHECK (transaction_key_hmac IS NULL OR char_length(transaction_key_hmac)=64),
                    purchase_observed_at TIMESTAMPTZ,
                    witnessed_at TIMESTAMPTZ,
                    pending_expires_at TIMESTAMPTZ,
                    matched_charge_id UUID REFERENCES measurement_revenuecat_events(id),
                    conflict_hash TEXT CHECK (conflict_hash IS NULL OR char_length(conflict_hash)=64),
                    CHECK (state NOT IN ('witnessed','matched') OR witness_hash IS NOT NULL),
                    CHECK (witness_hash IS NULL OR
                      (transaction_key_hmac IS NOT NULL AND purchase_observed_at IS NOT NULL AND witnessed_at IS NOT NULL AND pending_expires_at IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX measurement_purchase_intent_transaction ON measurement_purchase_intents(transaction_key_hmac) WHERE transaction_key_hmac IS NOT NULL").run()
            try await sql.raw("CREATE INDEX measurement_purchase_intent_account ON measurement_purchase_intents(account_id,state,expires_at)").run()
            try await sql.raw("""
                CREATE TABLE measurement_purchase_acquisitions (
                    id UUID PRIMARY KEY,
                    chain_key_hmac TEXT NOT NULL UNIQUE CHECK (char_length(chain_key_hmac)=64),
                    account_id UUID REFERENCES users(id),
                    installation_id UUID,
                    consent_revision UUID,
                    subject_id UUID REFERENCES measurement_subjects(id),
                    product_id TEXT CHECK (product_id IS NULL OR product_id IN ('com.snaglist.pro.monthly','com.snaglist.pro.annual')),
                    environment TEXT NOT NULL CHECK (environment IN ('sandbox','production')),
                    initial_charge_id UUID NOT NULL UNIQUE REFERENCES measurement_revenuecat_events(id),
                    state TEXT NOT NULL CHECK (state IN ('active','conflict','revoked')),
                    bound_at TIMESTAMPTZ NOT NULL,
                    conflicted_at TIMESTAMPTZ,
                    revoked_at TIMESTAMPTZ,
                    CHECK (state='revoked' OR
                      (account_id IS NOT NULL AND installation_id IS NOT NULL AND consent_revision IS NOT NULL AND subject_id IS NOT NULL AND product_id IS NOT NULL))
                )
                """).run()
            try await sql.raw("ALTER TABLE measurement_revenuecat_events ADD COLUMN origin_acquisition_id UUID REFERENCES measurement_purchase_acquisitions(id)").run()
            try await sql.raw("CREATE INDEX measurement_purchase_acquisition_account ON measurement_purchase_acquisitions(account_id,state)").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Purchase-origin tombstones must survive rollback; use a compatible image")
    }
}
