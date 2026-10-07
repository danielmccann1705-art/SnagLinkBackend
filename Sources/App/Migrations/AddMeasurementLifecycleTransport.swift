import Fluent
import FluentSQL
import Vapor

/// Authoritative purchase lifecycle facts and the installation pointer needed by
/// Singular's server relay. This follows `CreateMeasurementRelayState`.
struct AddMeasurementLifecycleTransport: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE measurement_revenuecat_events (
                    id UUID PRIMARY KEY,
                    account_id UUID NOT NULL REFERENCES users(id),
                    durable_key_hash TEXT NOT NULL UNIQUE CHECK (char_length(durable_key_hash)=64),
                    fact_hash TEXT NOT NULL CHECK (char_length(fact_hash)=64),
                    event_kind TEXT NOT NULL CHECK (event_kind='subscription_payment'),
                    environment TEXT NOT NULL CHECK (environment IN ('production','sandbox')),
                    occurred_at TIMESTAMPTZ NOT NULL,
                    received_at TIMESTAMPTZ NOT NULL,
                    currency_code TEXT NOT NULL CHECK (char_length(currency_code)=3),
                    amount TEXT NOT NULL CHECK (char_length(amount) BETWEEN 1 AND 32)
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_revenuecat_account_time ON measurement_revenuecat_events(account_id,received_at DESC)").run()
            try await sql.raw("ALTER TABLE measurement_dispatch_jobs ADD COLUMN installation_id UUID").run()
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_singular_installation CHECK
                    ((destination='singular' AND source_kind='revenueCatLifecycle') = (installation_id IS NOT NULL))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Measurement lifecycle facts and outbox state must survive rollback; use a compatible image")
    }
}
