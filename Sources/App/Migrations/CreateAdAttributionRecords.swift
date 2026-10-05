import Fluent
import FluentSQL
import Vapor

/// 2.0.2 Apple ads measurement (IOS-2.0.2-SLICE1.md item 12, MEASUREMENT-DECISION.md §3.4), staging first.
///
/// **Additive.** One new table that no other table references and that references nothing; an older image
/// ignores it. **Reversible.** `revert` drops the table, and with it every record: erasing is the safe
/// direction for this data, and nothing else depends on it.
///
/// One row per reference, made by `POST /api/v1/ad-measurement/apple`. The columns are the whole of what is
/// kept, by construction:
/// - `reference`: 128 random bits as 26 RFC 4648 base32 characters, the only handle the app holds (withdrawal,
///   support requests);
/// - `rc_app_user_id`: the RevenueCat app user ID current at send time (the join key for reporting and the key
///   account deletion erases by), `app_version`;
/// - `token`: Apple's AdServices token, held only while the exchange is still due (`pending`/`failing`) and
///   NULL in every other state — the CHECK below makes keeping it past the exchange impossible to write;
/// - `exchange_state`, `exchange_attempts`, `created_at`, `exchanged_at`;
/// - Apple's Standard fields: `attribution`, `campaign_id`, `adgroup_id`, `keyword_id`, `ad_id`, `claim_type`,
///   `conversion_type`, `country_or_region`.
/// Never: `orgId`, `clickDate`, `impressionDate`, `supplyPlacement`, an IP address, a user agent or a device
/// field.
struct CreateAdAttributionRecords: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { transaction in
            let sql = try VerifiedIdentityService.sql(transaction)
            try await sql.raw("""
                CREATE TABLE ad_attribution_records (
                    id UUID PRIMARY KEY,
                    reference TEXT NOT NULL CHECK (reference ~ '^[A-Z2-7]{26}$'),
                    rc_app_user_id TEXT NOT NULL CHECK (char_length(rc_app_user_id) BETWEEN 1 AND 64),
                    app_version TEXT NOT NULL CHECK (char_length(app_version) BETWEEN 1 AND 32),
                    token TEXT,
                    exchange_state TEXT NOT NULL DEFAULT 'pending'
                        CHECK (exchange_state IN ('pending', 'done', 'expired', 'invalid', 'failing')),
                    exchange_attempts INTEGER NOT NULL DEFAULT 0 CHECK (exchange_attempts >= 0),
                    attribution BOOLEAN,
                    campaign_id BIGINT,
                    adgroup_id BIGINT,
                    keyword_id BIGINT,
                    ad_id BIGINT,
                    claim_type TEXT,
                    conversion_type TEXT,
                    country_or_region TEXT,
                    created_at TIMESTAMPTZ NOT NULL,
                    exchanged_at TIMESTAMPTZ,
                    CONSTRAINT ad_attribution_records_token_only_while_due
                        CHECK ((exchange_state IN ('pending', 'failing')) = (token IS NOT NULL)),
                    CONSTRAINT ad_attribution_records_exchanged_when_done
                        CHECK ((exchange_state = 'done') = (exchanged_at IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX ad_attribution_records_reference ON ad_attribution_records(reference)").run()
            try await sql.raw("CREATE INDEX ad_attribution_records_rc_app_user_id ON ad_attribution_records(rc_app_user_id)").run()
            try await sql.raw("CREATE INDEX ad_attribution_records_created_at ON ad_attribution_records(created_at)").run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.transaction { transaction in
            try await VerifiedIdentityService.sql(transaction).raw("DROP TABLE IF EXISTS ad_attribution_records").run()
        }
    }
}
