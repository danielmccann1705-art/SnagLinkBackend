import Fluent
import FluentSQL
import Vapor

/// LinkedIn erasure resolution (outputs/measurement-2026-10-07/LINKEDIN-ERASURE-RESOLUTION.md).
///
/// LinkedIn documents no way to delete a conversion once it has been sent, so a LinkedIn erasure job can
/// never honestly be `completed`. It ends in `provider_retention_bound` instead (`LinkedInErasureResolution`):
/// future sends stopped, our own copies gone, and the job records the retention basis it relies on, the
/// latest time a send could have reached LinkedIn and the date LinkedIn's copy is due to age out. An account
/// deletion may finish in that state; its own measurement state says `provider_retention_bound`.
///
/// Additive for the previous image: it never reads the new columns, never claims a job in the new state and
/// treats the state as unfinished erasure. That is conservative: it blocks regrant and receipt cleanup, and
/// leaves such an account deletion unfinished until this image runs again.
struct AddLinkedInErasureResolution: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            // The original state check was an unnamed column constraint; replace it with a named one.
            try await sql.raw("""
                DO $$
                DECLARE c record;
                BEGIN
                    FOR c IN SELECT conname FROM pg_constraint
                             WHERE conrelid='measurement_erasure_jobs'::regclass AND contype='c'
                               AND pg_get_constraintdef(oid) LIKE '%manual_required%' LOOP
                        EXECUTE format('ALTER TABLE measurement_erasure_jobs DROP CONSTRAINT %I', c.conname);
                    END LOOP;
                END $$
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_erasure_jobs
                    ADD COLUMN provider_retention_basis TEXT,
                    ADD COLUMN provider_last_send_by TIMESTAMPTZ,
                    ADD COLUMN provider_copy_expires_at TIMESTAMPTZ,
                    ADD COLUMN retention_bound_at TIMESTAMPTZ,
                    ADD CONSTRAINT measurement_erasure_jobs_state CHECK (state IN
                        ('pending','leased','completed','failing','manual_required','provider_retention_bound')),
                    ADD CONSTRAINT measurement_erasure_retention_bound_evidence CHECK (
                        (state='provider_retention_bound') = (provider_retention_basis IS NOT NULL
                            AND provider_last_send_by IS NOT NULL AND provider_copy_expires_at IS NOT NULL
                            AND retention_bound_at IS NOT NULL)),
                    ADD CONSTRAINT measurement_erasure_retention_bound_linkedin_only CHECK (
                        state<>'provider_retention_bound' OR destination='linkedin'),
                    ADD CONSTRAINT measurement_erasure_retention_bound_after_last_send CHECK (
                        provider_copy_expires_at IS NULL OR provider_copy_expires_at > provider_last_send_by)
                """).run()
            try await sql.raw("""
                ALTER TABLE account_deletion_jobs
                    DROP CONSTRAINT account_deletion_measurement_erasure_state,
                    DROP CONSTRAINT account_deletion_completion_settles_measurement_erasure,
                    ADD CONSTRAINT account_deletion_measurement_erasure_state CHECK (measurement_erasure_state IN
                        ('not_requested','pending','completed','failing','manual_required','provider_retention_bound')),
                    ADD CONSTRAINT account_deletion_completion_settles_measurement_erasure CHECK (
                        state <> 'completed'
                        OR measurement_erasure_state IN ('not_requested','completed','provider_retention_bound'))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "LinkedIn erasure resolution records must survive rollback; use a compatible image")
    }
}
