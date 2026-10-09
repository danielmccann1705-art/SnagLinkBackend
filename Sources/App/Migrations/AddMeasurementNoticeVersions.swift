import Fluent
import FluentSQL
import Vapor

/// One final optional-measurement notice (FINAL-PRIVACY-NOTICE-2.0.1.md, 9 October 2026).
///
/// - `measurement_consent_events.notice_version`: the exact notice a revision was recorded under
///   (`MeasurementNotice`). NULL is a revision from a client that sent none: app-only coverage,
///   never broadened.
/// - `measurement_product_events.surface`: `web` for a server event caused by a portal cookie
///   session, `app` for one caused by the native app; NULL for client uploads and rows written
///   before this migration (all native). Dispatch re-checks the portal rule for `web` rows.
/// - Signup facts no longer reference their intent row, so an intent tombstone can be pruned on a
///   finite schedule while the per-account fact (the deduplication record) lives until the account
///   is deleted. `intent_id` stays unique; an intent can be adopted only while its own row exists.
///
/// Additive and forward-only. The previous image writes NULL into both new columns, never deletes
/// a tombstone and still inserts facts for existing intents, so every row it writes satisfies these
/// constraints.
struct AddMeasurementNoticeVersions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                ALTER TABLE measurement_consent_events ADD COLUMN notice_version TEXT
                    CONSTRAINT measurement_consent_notice_version CHECK (notice_version IS NULL OR notice_version ~ '^[a-z0-9][a-z0-9-]{0,63}$')
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_product_events ADD COLUMN surface TEXT
                    CONSTRAINT measurement_product_event_surface CHECK (surface IS NULL OR surface IN ('app','web'))
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_signup_facts DROP CONSTRAINT IF EXISTS measurement_signup_facts_intent_id_fkey
                """).run()
            try await sql.raw("""
                CREATE INDEX measurement_signup_intent_tombstone ON measurement_signup_intents(scrubbed_at)
                WHERE scrubbed_at IS NOT NULL
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        // Never discard the notice a grant was recorded under.
        throw Abort(.conflict, reason: "Measurement notice versions must survive rollback; use a compatible image")
    }
}
