import Fluent
import FluentSQL
import Vapor

/// Account-scoped consent, per-purpose opaque identities and the durable beginning
/// of provider erasure. No table stores an email, provider token, SDID, project ID
/// or event body. Provider delivery is added by later migrations.
struct CreateMeasurementPrivacyState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE measurement_subjects (
                    id UUID PRIMARY KEY,
                    account_id UUID NOT NULL REFERENCES users(id),
                    purpose TEXT NOT NULL CHECK (purpose IN ('productAnalytics','crossCompanyAds')),
                    opaque_subject UUID NOT NULL UNIQUE,
                    state TEXT NOT NULL CHECK (state IN ('active','revoked')),
                    created_at TIMESTAMPTZ NOT NULL,
                    revoked_at TIMESTAMPTZ,
                    UNIQUE(account_id,purpose,id),
                    CHECK ((state='active') = (revoked_at IS NULL))
                )
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX measurement_subject_one_active ON measurement_subjects(account_id,purpose) WHERE state='active'").run()

            try await sql.raw("""
                CREATE TABLE measurement_consent_events (
                    id UUID PRIMARY KEY,
                    request_id UUID NOT NULL,
                    account_id UUID NOT NULL REFERENCES users(id),
                    purpose TEXT NOT NULL CHECK (purpose IN ('productAnalytics','appleAds','crossCompanyAds')),
                    expected_revision UUID,
                    decision TEXT NOT NULL CHECK (decision IN ('granted','denied','withdrawn')),
                    occurred_at TIMESTAMPTZ NOT NULL,
                    received_at TIMESTAMPTZ NOT NULL,
                    installation_id UUID,
                    att_status TEXT CHECK (att_status IN ('authorized','denied','restricted','notDetermined')),
                    att_asserted_at TIMESTAMPTZ,
                    att_expires_at TIMESTAMPTZ,
                    UNIQUE(account_id,request_id),
                    UNIQUE(account_id,id,purpose),
                    CHECK ((purpose='crossCompanyAds' AND decision='granted') =
                           (installation_id IS NOT NULL AND att_status IS NOT NULL AND att_asserted_at IS NOT NULL AND att_expires_at IS NOT NULL)),
                    CHECK (att_expires_at IS NULL OR att_expires_at > received_at)
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_consent_account_time ON measurement_consent_events(account_id,received_at DESC)").run()

            try await sql.raw("""
                CREATE TABLE measurement_permission_current (
                    account_id UUID NOT NULL REFERENCES users(id),
                    purpose TEXT NOT NULL CHECK (purpose IN ('productAnalytics','appleAds','crossCompanyAds')),
                    revision UUID NOT NULL,
                    decision TEXT NOT NULL CHECK (decision IN ('granted','denied','withdrawn')),
                    subject_id UUID,
                    updated_at TIMESTAMPTZ NOT NULL,
                    PRIMARY KEY(account_id,purpose),
                    FOREIGN KEY(account_id,revision,purpose) REFERENCES measurement_consent_events(account_id,id,purpose),
                    FOREIGN KEY(account_id,purpose,subject_id) REFERENCES measurement_subjects(account_id,purpose,id),
                    CHECK ((purpose IN ('productAnalytics','crossCompanyAds') AND decision='granted') OR subject_id IS NULL)
                )
                """).run()

            try await sql.raw("""
                CREATE TABLE measurement_att_assertions (
                    account_id UUID NOT NULL REFERENCES users(id),
                    installation_id UUID NOT NULL,
                    purpose TEXT NOT NULL DEFAULT 'crossCompanyAds' CHECK (purpose='crossCompanyAds'),
                    consent_revision UUID NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('authorized','denied','restricted','notDetermined')),
                    asserted_at TIMESTAMPTZ NOT NULL,
                    received_at TIMESTAMPTZ NOT NULL,
                    expires_at TIMESTAMPTZ NOT NULL,
                    PRIMARY KEY(account_id,installation_id),
                    FOREIGN KEY(account_id,consent_revision,purpose) REFERENCES measurement_consent_events(account_id,id,purpose),
                    CHECK (expires_at > received_at)
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_att_expiry ON measurement_att_assertions(expires_at)").run()

            try await sql.raw("""
                CREATE TABLE measurement_erasure_jobs (
                    id UUID PRIMARY KEY,
                    account_id UUID NOT NULL REFERENCES users(id),
                    subject_id UUID NOT NULL REFERENCES measurement_subjects(id),
                    destination TEXT NOT NULL CHECK (destination IN ('posthog','singular','linkedin')),
                    account_deletion_job_id UUID REFERENCES account_deletion_jobs(id),
                    state TEXT NOT NULL CHECK (state IN ('pending','leased','completed','failing','manual_required')),
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
                    available_at TIMESTAMPTZ NOT NULL,
                    lease_token UUID,
                    lease_expires_at TIMESTAMPTZ,
                    created_at TIMESTAMPTZ NOT NULL,
                    completed_at TIMESTAMPTZ,
                    last_error_kind TEXT,
                    UNIQUE(subject_id,destination),
                    CHECK ((state='leased') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
                    CHECK ((state='completed') = (completed_at IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_erasure_due ON measurement_erasure_jobs(state,available_at)").run()
            try await sql.raw("CREATE INDEX measurement_erasure_account ON measurement_erasure_jobs(account_id)").run()

            try await sql.raw("""
                ALTER TABLE account_deletion_jobs
                    ADD COLUMN measurement_erasure_state TEXT NOT NULL DEFAULT 'not_requested'
                        CONSTRAINT account_deletion_measurement_erasure_state CHECK (measurement_erasure_state IN
                            ('not_requested','pending','completed','failing','manual_required')),
                    ADD CONSTRAINT account_deletion_completion_settles_measurement_erasure
                        CHECK (state <> 'completed' OR measurement_erasure_state IN ('not_requested','completed'))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Measurement consent and erasure records must survive rollback; use a compatible image")
    }
}
