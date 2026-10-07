import Fluent
import FluentSQL
import Vapor

/// Separates RevenueCat delivery identity from economic charge identity and
/// retains bounded refund reconciliation without becoming an entitlement store.
struct CreateRevenueCatLifecycleLedger: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE measurement_revenuecat_events ALTER COLUMN account_id DROP NOT NULL").run()
            try await sql.raw("""
                ALTER TABLE measurement_revenuecat_events
                  ADD COLUMN charge_kind TEXT NOT NULL DEFAULT 'initial_purchase'
                    CHECK (charge_kind IN ('initial_purchase','renewal')),
                  ADD COLUMN subscription_chain_key_hash TEXT CHECK
                    (subscription_chain_key_hash IS NULL OR char_length(subscription_chain_key_hash)=64)
                """).run()
            try await sql.raw("""
                CREATE TABLE measurement_revenuecat_lifecycle_events (
                    id UUID PRIMARY KEY,
                    provider_event_key_hash TEXT NOT NULL UNIQUE CHECK (char_length(provider_event_key_hash)=64),
                    normalized_hash TEXT NOT NULL CHECK (char_length(normalized_hash)=64),
                    account_id UUID REFERENCES users(id),
                    environment TEXT NOT NULL CHECK (environment IN ('production','sandbox')),
                    event_kind TEXT NOT NULL CHECK (event_kind IN
                        ('initial_purchase','renewal','cancellation','expiration','refund_reversed')),
                    effect TEXT NOT NULL CHECK (effect IN
                        ('charge','zero_value','cancellation_notice','expiration_notice','refund','refund_reversal','unresolved')),
                    resolution TEXT NOT NULL CHECK (resolution IN ('resolved','pending_charge','unresolved')),
                    charge_key_hash TEXT NOT NULL CHECK (char_length(charge_key_hash)=64),
                    subscription_chain_key_hash TEXT NOT NULL CHECK (char_length(subscription_chain_key_hash)=64),
                    event_generated_at TIMESTAMPTZ NOT NULL,
                    purchased_at TIMESTAMPTZ NOT NULL,
                    expiration_at TIMESTAMPTZ,
                    reason TEXT,
                    currency_code TEXT CHECK (currency_code IS NULL OR char_length(currency_code)=3),
                    monetary_delta TEXT CHECK (monetary_delta IS NULL OR char_length(monetary_delta) BETWEEN 1 AND 32),
                    received_at TIMESTAMPTZ NOT NULL
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_rc_lifecycle_account_time ON measurement_revenuecat_lifecycle_events(account_id,event_generated_at DESC)").run()
            try await sql.raw("CREATE INDEX measurement_rc_lifecycle_charge ON measurement_revenuecat_lifecycle_events(charge_key_hash,event_generated_at)").run()
            try await sql.raw("""
                CREATE TABLE measurement_revenuecat_adjustments (
                    charge_key_hash TEXT PRIMARY KEY CHECK (char_length(charge_key_hash)=64),
                    account_id UUID REFERENCES users(id),
                    currency_code TEXT CHECK (currency_code IS NULL OR char_length(currency_code)=3),
                    refund_amount TEXT CHECK (refund_amount IS NULL OR char_length(refund_amount) BETWEEN 1 AND 32),
                    refund_event_id UUID REFERENCES measurement_revenuecat_lifecycle_events(id),
                    refund_at TIMESTAMPTZ,
                    reversal_amount TEXT CHECK (reversal_amount IS NULL OR char_length(reversal_amount) BETWEEN 1 AND 32),
                    reversal_event_id UUID REFERENCES measurement_revenuecat_lifecycle_events(id),
                    reversal_at TIMESTAMPTZ,
                    state TEXT NOT NULL CHECK (state IN ('pending_charge','refunded','reversed','unresolved')),
                    updated_at TIMESTAMPTZ NOT NULL
                )
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "RevenueCat lifecycle tombstones must survive rollback; use a compatible image")
    }
}
