import Fluent
import FluentSQL
import Vapor

/// Durable, account-bound inputs for the measurement relays. Provider credentials and
/// raw Apple tokens never enter these tables. This follows `CreateMeasurementPrivacyState`.
struct CreateMeasurementRelayState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE measurement_device_bindings (
                    account_id UUID NOT NULL REFERENCES users(id),
                    installation_id UUID NOT NULL,
                    purpose TEXT NOT NULL DEFAULT 'crossCompanyAds' CHECK (purpose='crossCompanyAds'),
                    consent_revision UUID NOT NULL,
                    subject_id UUID NOT NULL REFERENCES measurement_subjects(id),
                    singular_device_id_ciphertext TEXT NOT NULL,
                    singular_device_id_hash TEXT NOT NULL CHECK (char_length(singular_device_id_hash)=64),
                    received_at TIMESTAMPTZ NOT NULL,
                    revoked_at TIMESTAMPTZ,
                    PRIMARY KEY(subject_id,installation_id),
                    FOREIGN KEY(account_id,purpose,subject_id)
                        REFERENCES measurement_subjects(account_id,purpose,id),
                    FOREIGN KEY(account_id,consent_revision,purpose)
                        REFERENCES measurement_consent_events(account_id,id,purpose)
                )
                """).run()

            try await sql.raw("""
                CREATE TABLE measurement_product_events (
                    account_id UUID NOT NULL REFERENCES users(id),
                    event_id UUID NOT NULL,
                    installation_id UUID NOT NULL,
                    purpose TEXT NOT NULL DEFAULT 'productAnalytics' CHECK (purpose='productAnalytics'),
                    consent_revision UUID NOT NULL,
                    subject_id UUID NOT NULL REFERENCES measurement_subjects(id),
                    occurred_at TIMESTAMPTZ NOT NULL,
                    received_at TIMESTAMPTZ NOT NULL,
                    schema_version INTEGER NOT NULL CHECK (schema_version=1),
                    event_name TEXT,
                    properties JSONB,
                    body_hash TEXT NOT NULL CHECK (char_length(body_hash)=64),
                    revoked_at TIMESTAMPTZ,
                    PRIMARY KEY(account_id,event_id),
                    FOREIGN KEY(account_id,purpose,subject_id)
                        REFERENCES measurement_subjects(account_id,purpose,id),
                    FOREIGN KEY(account_id,consent_revision,purpose)
                        REFERENCES measurement_consent_events(account_id,id,purpose),
                    CHECK ((revoked_at IS NULL) = (event_name IS NOT NULL AND properties IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_product_events_subject ON measurement_product_events(subject_id,received_at)").run()

            try await sql.raw("""
                CREATE TABLE measurement_dispatch_jobs (
                    id UUID PRIMARY KEY,
                    destination TEXT NOT NULL CHECK (destination IN ('posthog','singular','linkedin')),
                    source_kind TEXT NOT NULL CHECK (source_kind IN ('productEvent','revenueCatLifecycle')),
                    source_id UUID NOT NULL,
                    account_id UUID NOT NULL REFERENCES users(id),
                    subject_id UUID NOT NULL REFERENCES measurement_subjects(id),
                    consent_revision UUID NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending','leased','delivered','failing','uncertain','suppressed','manual_required')),
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts>=0),
                    available_at TIMESTAMPTZ NOT NULL,
                    lease_token UUID,
                    lease_expires_at TIMESTAMPTZ,
                    payload JSONB,
                    created_at TIMESTAMPTZ NOT NULL,
                    delivered_at TIMESTAMPTZ,
                    last_error_kind TEXT,
                    UNIQUE(account_id,destination,source_kind,source_id),
                    CHECK ((state='leased') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
                    CHECK ((state='delivered') = (delivered_at IS NOT NULL)),
                    CHECK (state NOT IN ('pending','leased','failing') OR payload IS NOT NULL)
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_dispatch_due ON measurement_dispatch_jobs(destination,state,available_at)").run()
            try await sql.raw("CREATE INDEX measurement_dispatch_account ON measurement_dispatch_jobs(account_id)").run()

            try await sql.raw("ALTER TABLE ad_attribution_records DROP CONSTRAINT ad_attribution_records_exchange_state_check").run()
            try await sql.raw("""
                ALTER TABLE ad_attribution_records
                    ADD COLUMN canonical_account_id UUID REFERENCES users(id),
                    ADD COLUMN canonical_consent_revision UUID REFERENCES measurement_consent_events(id),
                    ADD COLUMN canonical_installation_id UUID,
                    ADD CONSTRAINT ad_attribution_records_exchange_state_check
                        CHECK (exchange_state IN ('processing','pending','done','expired','invalid','failing')),
                    ADD CONSTRAINT ad_attribution_canonical_all_or_none CHECK (
                        (canonical_account_id IS NULL AND canonical_consent_revision IS NULL AND canonical_installation_id IS NULL) OR
                        (canonical_account_id IS NOT NULL AND canonical_consent_revision IS NOT NULL AND canonical_installation_id IS NOT NULL))
                """).run()
            try await sql.raw("""
                CREATE UNIQUE INDEX ad_attribution_canonical_request
                ON ad_attribution_records(canonical_account_id,canonical_installation_id,canonical_consent_revision)
                WHERE canonical_account_id IS NOT NULL
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Measurement relay and canonical attribution records must survive rollback; use a compatible image")
    }
}
