import Fluent
import FluentSQL
import Vapor

/// Manual PostHog erasure evidence (POSTHOG-MANUAL-REMEDIATION.md, 9 October 2026).
///
/// - Receipts record why a job needs a person (`manual_reason`, the worker's
///   `PostHogErasureService.ManualReason` spellings) and when (`manual_at`).
/// - Verification passes record the deletion-status row's own `created_at`, so a
///   re-issued deletion answered with the original row is visible as `stale`
///   evidence (same `created_at` as the earlier round), and the profile lookup
///   that decides whether another round can start is kept as a `reresolve` pass.
/// - `measurement_posthog_manual_resolutions` holds one closing record per job:
///   the supported mechanism used, who acted, and the post-escalation proof
///   (an uncached zero event count and an absent profile, or, for a sandbox
///   project deletion approved separately, lost project access). It is written
///   only by `PostHogManualResolution` and removed only with its erasure job.
///
/// Additive and forward-only. Every value an earlier image writes still satisfies
/// these checks: it never writes `manual_reason`, `stale`, `reresolve` or
/// `provider_created_at`.
struct AddPostHogErasureManualResolution: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            // Spelled out rather than derived, like the reason test: a renamed reason
            // must fail this migration's own test, not silently widen the check.
            let reasons = """
                'posthog_stale_receipt','posthog_profileless_late_events','posthog_unverifiable',
                'posthog_rounds_exhausted','posthog_profile_unresolved','posthog_response_invalid',
                'posthog_request_refused','posthog_observation_window_expired','posthog_receipt_inconsistent',
                'posthog_subject_ineligible','provider_configuration_required'
                """
            try await sql.raw("""
                ALTER TABLE measurement_posthog_erasure_receipts
                    ADD COLUMN manual_reason TEXT,
                    ADD COLUMN manual_at TIMESTAMPTZ,
                    ADD CONSTRAINT posthog_erasure_receipt_manual CHECK (
                        (manual_reason IS NULL) = (manual_at IS NULL)
                        AND (manual_reason IS NULL OR manual_reason IN (\(unsafeRaw: reasons))))
                """).run()

            // The stage and outcome checks were inline and unnamed; replace them with
            // named supersets.
            try await sql.raw("""
                DO $$
                DECLARE c record;
                BEGIN
                    FOR c IN SELECT con.conname FROM pg_constraint con
                             JOIN pg_attribute a ON a.attrelid=con.conrelid AND a.attnum=ANY(con.conkey)
                             WHERE con.conrelid='measurement_posthog_erasure_passes'::regclass AND con.contype='c'
                               AND array_length(con.conkey,1)=1 AND a.attname IN ('stage','outcome') LOOP
                        EXECUTE format('ALTER TABLE measurement_posthog_erasure_passes DROP CONSTRAINT %I', c.conname);
                    END LOOP;
                END $$
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_posthog_erasure_passes
                    ADD COLUMN provider_created_at TIMESTAMPTZ,
                    DROP CONSTRAINT posthog_erasure_pass_status_evidence,
                    ADD CONSTRAINT posthog_erasure_pass_stage CHECK (stage IN ('deletion','quiet','reresolve')),
                    ADD CONSTRAINT posthog_erasure_pass_outcome CHECK (outcome IN ('absent','present','unverifiable','stale')),
                    ADD CONSTRAINT posthog_erasure_pass_status_evidence CHECK (check_kind <> 'deletion_status' OR (
                        person_uuid IS NOT NULL AND requested_at IS NOT NULL
                        AND (outcome <> 'absent' OR provider_verified_at IS NOT NULL)
                        AND (outcome <> 'stale' OR (provider_created_at IS NOT NULL AND provider_created_at < requested_at)))),
                    ADD CONSTRAINT posthog_erasure_pass_stale_is_status CHECK (outcome <> 'stale' OR check_kind = 'deletion_status'),
                    ADD CONSTRAINT posthog_erasure_pass_reresolve_is_profile CHECK (stage <> 'reresolve' OR check_kind = 'profile')
                """).run()

            try await sql.raw("""
                CREATE TABLE measurement_posthog_manual_resolutions (
                    job_id UUID PRIMARY KEY REFERENCES measurement_erasure_jobs(id) ON DELETE CASCADE,
                    posthog_project_id TEXT NOT NULL CHECK (posthog_project_id ~ '^[1-9][0-9]{0,19}$'),
                    manual_reason TEXT NOT NULL CHECK (manual_reason IN (\(unsafeRaw: reasons),'expired_lease_ambiguous')),
                    method TEXT NOT NULL CHECK (method IN
                        ('posthog_support_deletion','posthog_person_deletion','sandbox_project_deletion')),
                    operator TEXT NOT NULL CHECK (operator ~ '^[a-z][a-z0-9._-]{1,63}$'),
                    support_reference TEXT CHECK (support_reference ~ '^[A-Za-z0-9][A-Za-z0-9 #._:/-]{0,119}$'),
                    approval_reference TEXT CHECK (approval_reference ~ '^[A-Za-z0-9][A-Za-z0-9 #._:/-]{0,159}$'),
                    verification_query_at TIMESTAMPTZ,
                    verified_event_count INTEGER CHECK (verified_event_count = 0),
                    profile_absent_verified_at TIMESTAMPTZ,
                    project_access_lost_at TIMESTAMPTZ,
                    project_lookup_status INTEGER CHECK (project_lookup_status IN (403,404)),
                    escalated_at TIMESTAMPTZ NOT NULL,
                    evidence_sha256 TEXT NOT NULL CHECK (evidence_sha256 ~ '^[0-9a-f]{64}$'),
                    evidence_reference TEXT NOT NULL CHECK (evidence_reference ~ '^[A-Za-z0-9._/-]{1,200}$'),
                    recorded_at TIMESTAMPTZ NOT NULL,
                    CONSTRAINT posthog_manual_resolution_support CHECK (
                        method <> 'posthog_support_deletion' OR support_reference IS NOT NULL),
                    CONSTRAINT posthog_manual_resolution_proof CHECK (CASE WHEN method = 'sandbox_project_deletion'
                        THEN approval_reference IS NOT NULL AND project_access_lost_at IS NOT NULL
                             AND project_lookup_status IS NOT NULL AND project_access_lost_at > escalated_at
                             AND project_access_lost_at <= recorded_at
                        ELSE COALESCE(verified_event_count, -1) = 0 AND verification_query_at IS NOT NULL
                             AND profile_absent_verified_at IS NOT NULL
                             AND verification_query_at > escalated_at AND profile_absent_verified_at > escalated_at
                             AND verification_query_at <= recorded_at AND profile_absent_verified_at <= recorded_at END)
                )
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        // Never discard manual escalation reasons, stale-receipt evidence or closing records.
        throw Abort(.conflict, reason: "PostHog manual erasure evidence must survive rollback; use a compatible image")
    }
}
