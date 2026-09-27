import Vapor
import Fluent

/// Retention maintenance packet M1 (A4 §5, accepted 25 Sep; F17). Schema only:
///
/// - `mutation_receipts.result_purged_at`, `link_mutation_receipts.result_purged_at`:
///   a purged cached response keeps its recognition columns (actor or grant,
///   operation id, request hash) so a late retry is still recognised and answered
///   409 `already_applied_refresh_required`, never re-applied (A4 §1.4). The purge
///   itself is off unless `MUTATION_RECEIPT_RETENTION_DAYS` is configured.
/// - `link_grants.secrets_purged_at`: 30 days after a Contractor link expired or was
///   revoked, its sealed token, PIN hash and issuance copy are removed (I-15). An
///   expired link keeps `state = 'active'` (expiry is by time), so the check that an
///   active link carries its sealed token is restated to admit a purged record. Every
///   read path already refuses an expired or revoked link before it reads any of the
///   three columns (`LinkGrantService.load`, the manager's re-show).
/// - Expiry indexes for the bounded sweeps.
///
/// Additive: an older image ignores the new columns. An older image would still
/// replay a purged receipt's sentinel body as a result, which is why the purge
/// ships switched off.
struct AddRetentionMaintenanceM1: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("ALTER TABLE mutation_receipts ADD COLUMN result_purged_at TIMESTAMPTZ").run()
            try await sql.raw("CREATE INDEX mutation_receipt_purge ON mutation_receipts(created_at) WHERE result_purged_at IS NULL AND account_deletion_redacted_at IS NULL").run()
            try await sql.raw("ALTER TABLE link_mutation_receipts ADD COLUMN result_purged_at TIMESTAMPTZ").run()
            try await sql.raw("CREATE INDEX link_mutation_receipt_purge ON link_mutation_receipts(created_at) WHERE result_purged_at IS NULL AND account_deletion_redacted_at IS NULL").run()
            try await sql.raw("ALTER TABLE link_grants ADD COLUMN secrets_purged_at TIMESTAMPTZ").run()
            try await sql.raw("""
                DO $$
                DECLARE found_name TEXT; found_count INTEGER;
                BEGIN
                    SELECT count(*), min(conname) INTO found_count, found_name FROM pg_constraint
                    WHERE conrelid = 'link_grants'::regclass AND contype = 'c'
                      AND pg_get_constraintdef(oid) LIKE '%token_ciphertext IS NOT NULL%';
                    IF found_count <> 1 THEN
                        RAISE EXCEPTION 'Expected exactly one active-material check on link_grants, found %', found_count;
                    END IF;
                    EXECUTE format('ALTER TABLE link_grants DROP CONSTRAINT %I', found_name);
                END $$
                """).run()
            try await sql.raw("""
                ALTER TABLE link_grants ADD CONSTRAINT link_grant_active_material CHECK (
                    state <> 'active' OR (token_hash IS NOT NULL AND activated_at IS NOT NULL
                        AND (secrets_purged_at IS NOT NULL OR (token_ciphertext IS NOT NULL AND issuance_json IS NOT NULL))))
                """).run()
            try await sql.raw("""
                ALTER TABLE link_grants ADD CONSTRAINT link_grant_purge_is_complete CHECK (
                    secrets_purged_at IS NULL OR (token_ciphertext IS NULL AND pin_hash IS NULL AND issuance_json IS NULL))
                """).run()
            try await sql.raw("CREATE INDEX link_grant_secret_purge ON link_grants(expires_at) WHERE secrets_purged_at IS NULL").run()
            try await sql.raw("CREATE INDEX browser_session_expiry ON browser_sessions(expires_at)").run()
            try await sql.raw("CREATE INDEX project_discovery_expiry ON project_discovery_snapshots(expires_at)").run()
            try await sql.raw("CREATE INDEX team_invite_retention ON team_invites(expires_at) WHERE accepted_user_id IS NULL").run()
            try await sql.raw("CREATE INDEX workflow_outbox_age ON workflow_outbox(created_at)").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retention columns record completed purges; use a compatible image instead of reverting")
    }
}
