import Fluent
import FluentSQL
import Vapor

/// Optional pre-auth signup measurement: one short-lived capability-bound intent per
/// new-account authentication attempt, and one canonical signup fact per account that
/// the identity resolver actually inserted. Only a versioned capability hash and a
/// server nonce hash are stored; no email, provider token, IP or advertising identifier.
/// Unclaimed, expired and settled rows are reduced to a minimal tombstone by retention
/// (`SignupIntentService.cleanup`) and by account deletion. Follows `CreatePostHogErasureReceipts`.
struct CreateMeasurementSignupIntents: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE measurement_signup_intents (
                    id UUID PRIMARY KEY,
                    capability_hash TEXT UNIQUE
                        CHECK (capability_hash IS NULL OR capability_hash ~ '^sha256v1:[0-9a-f]{64}$'),
                    provider TEXT NOT NULL CHECK (provider IN ('apple','google','email')),
                    surface TEXT NOT NULL CHECK (surface='native'),
                    environment TEXT NOT NULL CHECK (environment IN ('local','staging','production')),
                    installation_id UUID,
                    notice_version TEXT NOT NULL CHECK (char_length(notice_version) BETWEEN 1 AND 64),
                    product_analytics BOOLEAN,
                    apple_ads BOOLEAN,
                    cross_company_ads BOOLEAN,
                    att_status TEXT CHECK (att_status IN ('authorized','denied','restricted','notDetermined')),
                    att_observed_at TIMESTAMPTZ,
                    apple_nonce_hash TEXT UNIQUE CHECK (apple_nonce_hash IS NULL OR apple_nonce_hash ~ '^[0-9a-f]{64}$'),
                    binding_kind TEXT CHECK (binding_kind IN ('apple_nonce','google_challenge','email_token')),
                    binding_id UUID,
                    state TEXT NOT NULL CHECK (state IN
                        ('issued','bound','consumed_new','consumed_existing','cancelled','expired')),
                    consumed_reason TEXT CHECK (consumed_reason IN
                        ('new_account','existing_account','context_absent','nothing_eligible')),
                    received_at TIMESTAMPTZ NOT NULL,
                    expires_at TIMESTAMPTZ NOT NULL,
                    bound_at TIMESTAMPTZ,
                    consumed_at TIMESTAMPTZ,
                    cancelled_at TIMESTAMPTZ,
                    scrubbed_at TIMESTAMPTZ,
                    account_id UUID REFERENCES users(id),
                    product_revision UUID,
                    apple_revision UUID,
                    cross_revision UUID,
                    signup_fact_id UUID,
                    CHECK (expires_at > received_at),
                    CHECK ((binding_kind='apple_nonce') = (provider='apple' AND binding_kind IS NOT NULL)),
                    CHECK (binding_kind IS NULL OR binding_kind='apple_nonce' OR
                           (binding_kind='google_challenge') = (provider='google')),
                    CHECK (binding_kind IS NULL OR binding_kind='apple_nonce' OR
                           (binding_kind='email_token') = (provider='email')),
                    CHECK (binding_id IS NULL OR binding_kind IN ('google_challenge','email_token')),
                    CHECK (state<>'issued' OR binding_kind IS NULL),
                    CHECK (state<>'bound' OR binding_kind IS NOT NULL),
                    CHECK ((consumed_reason IS NOT NULL) = (consumed_at IS NOT NULL)),
                    CHECK (state NOT IN ('consumed_new','consumed_existing') OR consumed_reason IS NOT NULL),
                    CHECK ((consumed_reason='new_account') =
                           (consumed_reason IS NOT NULL AND (state='consumed_new' OR (state='cancelled' AND signup_fact_id IS NOT NULL)))),
                    CHECK (state<>'consumed_existing' OR consumed_reason IN ('existing_account','context_absent','nothing_eligible')),
                    CHECK (state<>'cancelled' OR cancelled_at IS NOT NULL),
                    CHECK (account_id IS NULL OR consumed_reason='new_account'),
                    CHECK (scrubbed_at IS NOT NULL OR (capability_hash IS NOT NULL AND installation_id IS NOT NULL AND
                           product_analytics IS NOT NULL AND apple_ads IS NOT NULL AND cross_company_ads IS NOT NULL)),
                    CHECK (scrubbed_at IS NOT NULL OR
                           (cross_company_ads = (att_status IS NOT NULL AND att_observed_at IS NOT NULL))),
                    CHECK (scrubbed_at IS NOT NULL OR (provider='apple') = (apple_nonce_hash IS NOT NULL)),
                    CHECK (state<>'consumed_new' OR (account_id IS NOT NULL AND signup_fact_id IS NOT NULL) OR scrubbed_at IS NOT NULL)
                )
                """).run()
            // One provider challenge or issued email token can carry at most one intent.
            try await sql.raw("""
                CREATE UNIQUE INDEX measurement_signup_intent_binding
                ON measurement_signup_intents(binding_kind,binding_id) WHERE binding_id IS NOT NULL
                """).run()
            try await sql.raw("CREATE INDEX measurement_signup_intent_due ON measurement_signup_intents(state,expires_at)").run()
            try await sql.raw("""
                CREATE INDEX measurement_signup_intent_account ON measurement_signup_intents(account_id)
                WHERE account_id IS NOT NULL
                """).run()

            try await sql.raw("""
                CREATE TABLE measurement_signup_facts (
                    id UUID PRIMARY KEY,
                    account_id UUID UNIQUE REFERENCES users(id),
                    intent_id UUID NOT NULL UNIQUE REFERENCES measurement_signup_intents(id),
                    provider TEXT NOT NULL CHECK (provider IN ('apple','google','email')),
                    environment TEXT NOT NULL CHECK (environment IN ('local','staging','production')),
                    occurred_at TIMESTAMPTZ NOT NULL,
                    product_eligible BOOLEAN NOT NULL,
                    linkedin_eligible BOOLEAN NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL,
                    withdrawn_at TIMESTAMPTZ,
                    scrubbed_at TIMESTAMPTZ,
                    CHECK (account_id IS NOT NULL OR scrubbed_at IS NOT NULL)
                )
                """).run()

            // Dedicated server signup source. Product analytics stays installation-free;
            // LinkedIn signup jobs carry the originating installation like purchases.
            try await sql.raw("ALTER TABLE measurement_dispatch_jobs DROP CONSTRAINT measurement_dispatch_jobs_source_kind_check").run()
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_jobs_source_kind_check
                CHECK (source_kind IN ('productEvent','revenueCatLifecycle','revenueCatEvent','signupFact'))
                """).run()
            try await sql.raw("ALTER TABLE measurement_dispatch_jobs DROP CONSTRAINT measurement_dispatch_ad_installation").run()
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_ad_installation CHECK (
                    ((destination IN ('singular','linkedin') AND source_kind IN ('revenueCatLifecycle','signupFact')) =
                     (installation_id IS NOT NULL)))
                """).run()
            // Singular is held for signup facts until SDK-ACTIVATION-DECISION.md is resolved.
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs ADD CONSTRAINT measurement_dispatch_signup_destinations CHECK (
                    source_kind<>'signupFact' OR destination IN ('posthog','linkedin'))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Signup measurement intents and facts must survive rollback; use a compatible image")
    }
}
