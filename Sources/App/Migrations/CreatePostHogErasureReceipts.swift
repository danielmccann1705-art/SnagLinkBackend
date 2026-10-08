import Fluent
import FluentSQL
import Vapor

/// A receipt is retained before the destructive provider request, so a restart
/// can poll the same person's deletion instead of guessing from HTTP acceptance.
struct CreatePostHogErasureReceipts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE measurement_posthog_erasure_receipts (
                job_id UUID PRIMARY KEY REFERENCES measurement_erasure_jobs(id) ON DELETE CASCADE,
                project_id TEXT NOT NULL CHECK (project_id ~ '^[1-9][0-9]{0,19}$'),
                person_uuid UUID NOT NULL,
                phase TEXT NOT NULL CHECK (phase IN ('resolved','submitting','polling','events_verified','completed')),
                resolved_at TIMESTAMPTZ NOT NULL,
                requested_at TIMESTAMPTZ,
                queue_acknowledged_at TIMESTAMPTZ,
                provider_created_at TIMESTAMPTZ,
                events_verified_at TIMESTAMPTZ,
                profile_absent_at TIMESTAMPTZ,
                CHECK ((phase='resolved') = (requested_at IS NULL)),
                CHECK (phase NOT IN ('events_verified','completed') OR
                    (provider_created_at IS NOT NULL AND events_verified_at IS NOT NULL)),
                CHECK ((phase='completed') = (profile_absent_at IS NOT NULL))
            )
            """).run()
    }

    func revert(on database: Database) async throws {
        // Never discard an in-flight or completed provider deletion receipt.
        throw Abort(.conflict, reason: "PostHog deletion receipts must survive rollback; use a compatible image")
    }
}
