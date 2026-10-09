import Fluent
import FluentSQL
import Vapor

/// Delayed-ingestion controls for PostHog erasure (POSTHOG-DELAYED-INGESTION-OCT9.md).
///
/// - Dispatch rows keep the claim-time lease end (`send_window_until`) and the
///   start of their last provider attempt. A send starts only while the lease
///   covers its whole request deadline, so the lease end bounds any capture that
///   could still be in flight, even across a crash or a lost database session.
/// - Subjects receive that bound at the dispatch barrier (withdrawal or account
///   deletion), before account deletion removes the outbox rows.
/// - Receipts gain deletion rounds, the quiet-period end and a final completion
///   time; every provider verification pass is retained separately.
struct AddPostHogDelayedIngestionControls: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                ALTER TABLE measurement_dispatch_jobs
                    ADD COLUMN send_window_until TIMESTAMPTZ,
                    ADD COLUMN last_send_started_at TIMESTAMPTZ,
                    ADD CONSTRAINT measurement_dispatch_send_inside_window CHECK (
                        last_send_started_at IS NULL OR send_window_until IS NULL
                        OR last_send_started_at <= send_window_until)
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_subjects
                    ADD COLUMN last_send_started_at TIMESTAMPTZ,
                    ADD COLUMN send_in_flight_until TIMESTAMPTZ
                """).run()

            // The original receipt checks were unnamed; replace all of them with
            // named equivalents that admit the quiet-period phases.
            try await sql.raw("""
                DO $$
                DECLARE c record;
                BEGIN
                    FOR c IN SELECT conname FROM pg_constraint
                             WHERE conrelid='measurement_posthog_erasure_receipts'::regclass AND contype='c' LOOP
                        EXECUTE format('ALTER TABLE measurement_posthog_erasure_receipts DROP CONSTRAINT %I', c.conname);
                    END LOOP;
                END $$
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_posthog_erasure_receipts
                    ADD COLUMN round INTEGER NOT NULL DEFAULT 1,
                    ADD COLUMN in_flight_until TIMESTAMPTZ,
                    ADD COLUMN quiet_until TIMESTAMPTZ,
                    ADD COLUMN completed_at TIMESTAMPTZ
                """).run()
            // Provider calls outside tests are impossible while the live receiver
            // gate is closed, so a completed receipt can only be a disposable test
            // row from the single-pass rule. It keeps a zero-length quiet period.
            try await sql.raw("""
                UPDATE measurement_posthog_erasure_receipts
                SET quiet_until=profile_absent_at,completed_at=profile_absent_at WHERE phase='completed'
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_posthog_erasure_receipts
                    ADD CONSTRAINT posthog_erasure_receipt_project CHECK (project_id ~ '^[1-9][0-9]{0,19}$'),
                    ADD CONSTRAINT posthog_erasure_receipt_phase CHECK (phase IN ('resolved','submitting','polling',
                        'events_verified','quiet','quiet_events_absent','reresolving','completed')),
                    ADD CONSTRAINT posthog_erasure_receipt_round CHECK (round BETWEEN 1 AND 10),
                    ADD CONSTRAINT posthog_erasure_receipt_requested CHECK ((phase='resolved') = (requested_at IS NULL)),
                    ADD CONSTRAINT posthog_erasure_receipt_events_verified CHECK (
                        phase NOT IN ('events_verified','quiet','quiet_events_absent','reresolving','completed')
                        OR (provider_created_at IS NOT NULL AND events_verified_at IS NOT NULL)),
                    ADD CONSTRAINT posthog_erasure_receipt_quiet CHECK (
                        phase NOT IN ('quiet','quiet_events_absent','reresolving','completed')
                        OR (profile_absent_at IS NOT NULL AND quiet_until IS NOT NULL)),
                    ADD CONSTRAINT posthog_erasure_receipt_completed CHECK ((phase='completed') = (completed_at IS NOT NULL)),
                    ADD CONSTRAINT posthog_erasure_receipt_completed_after_quiet CHECK (
                        completed_at IS NULL OR completed_at >= quiet_until)
                """).run()
            try await sql.raw("""
                CREATE TABLE measurement_posthog_erasure_passes (
                    job_id UUID NOT NULL REFERENCES measurement_posthog_erasure_receipts(job_id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 1000),
                    round INTEGER NOT NULL CHECK (round BETWEEN 1 AND 10),
                    stage TEXT NOT NULL CHECK (stage IN ('deletion','quiet')),
                    check_kind TEXT NOT NULL CHECK (check_kind IN ('deletion_status','profile','events')),
                    checked_at TIMESTAMPTZ NOT NULL,
                    person_uuid UUID,
                    requested_at TIMESTAMPTZ,
                    provider_verified_at TIMESTAMPTZ,
                    event_count INTEGER CHECK (event_count >= 0),
                    outcome TEXT NOT NULL CHECK (outcome IN ('absent','present','unverifiable')),
                    PRIMARY KEY (job_id, sequence),
                    CONSTRAINT posthog_erasure_pass_status_evidence CHECK (check_kind <> 'deletion_status' OR
                        (person_uuid IS NOT NULL AND requested_at IS NOT NULL AND provider_verified_at IS NOT NULL)),
                    CONSTRAINT posthog_erasure_pass_event_evidence CHECK (check_kind <> 'events' OR
                        (outcome = 'unverifiable') = (event_count IS NULL))
                )
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        // Never discard deletion rounds, verification passes or in-flight bounds.
        throw Abort(.conflict, reason: "PostHog delayed-ingestion evidence must survive rollback; use a compatible image")
    }
}
