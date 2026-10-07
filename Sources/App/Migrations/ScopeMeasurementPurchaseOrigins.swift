import Fluent
import FluentSQL
import Vapor

/// Adds a second, fixed Apple Ads authority to the purchase-origin ledger.
/// Existing rows remain cross-company rows, and existing Apple records remain
/// unclassified. No historical record is promoted by this migration.
struct ScopeMeasurementPurchaseOrigins: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await sql.raw("""
                ALTER TABLE ad_attribution_records
                  ADD COLUMN evidence_class TEXT NOT NULL DEFAULT 'unknown'
                    CHECK (evidence_class IN ('unknown','test','verified','organic')),
                  ADD COLUMN evidence_config_hash TEXT
                    CHECK (evidence_config_hash IS NULL OR char_length(evidence_config_hash)=64),
                  ADD COLUMN evidence_classified_at TIMESTAMPTZ
                """).run()

            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents
                  ADD COLUMN purpose TEXT NOT NULL DEFAULT 'crossCompanyAds'
                    CHECK (purpose IN ('crossCompanyAds','appleAds')),
                  ADD COLUMN attribution_record_id UUID REFERENCES ad_attribution_records(id) ON DELETE CASCADE,
                  ALTER COLUMN subject_id DROP NOT NULL
                """).run()
            try await sql.raw("DROP INDEX measurement_purchase_intent_transaction").run()
            try await sql.raw("""
                CREATE UNIQUE INDEX measurement_purchase_intent_purpose_transaction
                ON measurement_purchase_intents(purpose,transaction_key_hmac)
                WHERE transaction_key_hmac IS NOT NULL
                """).run()
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents ADD CONSTRAINT measurement_purchase_intent_authority
                CHECK ((purpose='crossCompanyAds' AND subject_id IS NOT NULL AND attribution_record_id IS NULL) OR
                       (purpose='appleAds' AND subject_id IS NULL AND attribution_record_id IS NOT NULL))
                """).run()

            try await sql.raw("""
                ALTER TABLE measurement_purchase_acquisitions
                  ADD COLUMN purpose TEXT NOT NULL DEFAULT 'crossCompanyAds'
                    CHECK (purpose IN ('crossCompanyAds','appleAds')),
                  ADD COLUMN attribution_record_id UUID REFERENCES ad_attribution_records(id) ON DELETE SET NULL
                """).run()
            try await sql.raw("ALTER TABLE measurement_purchase_acquisitions DROP CONSTRAINT measurement_purchase_acquisitions_chain_key_hmac_key").run()
            try await sql.raw("ALTER TABLE measurement_purchase_acquisitions DROP CONSTRAINT measurement_purchase_acquisitions_initial_charge_id_key").run()
            try await sql.raw("""
                DO $$ DECLARE c TEXT; BEGIN
                  SELECT conname INTO c FROM pg_constraint
                  WHERE conrelid='measurement_purchase_acquisitions'::regclass AND contype='c'
                    AND pg_get_constraintdef(oid) LIKE '%state%revoked%subject_id%';
                  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE measurement_purchase_acquisitions DROP CONSTRAINT %I', c); END IF;
                END $$
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX measurement_purchase_acquisition_purpose_chain ON measurement_purchase_acquisitions(purpose,chain_key_hmac)").run()
            try await sql.raw("CREATE UNIQUE INDEX measurement_purchase_acquisition_purpose_initial ON measurement_purchase_acquisitions(purpose,initial_charge_id)").run()
            try await sql.raw("""
                ALTER TABLE measurement_purchase_acquisitions ADD CONSTRAINT measurement_purchase_acquisition_authority
                CHECK (state='revoked' OR
                  (account_id IS NOT NULL AND installation_id IS NOT NULL AND consent_revision IS NOT NULL AND
                   product_id IS NOT NULL AND
                   ((purpose='crossCompanyAds' AND subject_id IS NOT NULL AND attribution_record_id IS NULL) OR
                    (purpose='appleAds' AND subject_id IS NULL AND attribution_record_id IS NOT NULL))))
                """).run()

            try await sql.raw("""
                CREATE TABLE measurement_purchase_charge_links (
                    charge_id UUID NOT NULL REFERENCES measurement_revenuecat_events(id) ON DELETE CASCADE,
                    purpose TEXT NOT NULL CHECK (purpose IN ('crossCompanyAds','appleAds')),
                    acquisition_id UUID REFERENCES measurement_purchase_acquisitions(id),
                    attribution_record_id UUID REFERENCES ad_attribution_records(id) ON DELETE CASCADE,
                    outcome TEXT NOT NULL CHECK (outcome IN ('origin','paid_campaign','organic')),
                    linked_at TIMESTAMPTZ NOT NULL,
                    PRIMARY KEY (charge_id,purpose),
                    CHECK ((purpose='crossCompanyAds' AND outcome='origin' AND acquisition_id IS NOT NULL AND attribution_record_id IS NULL) OR
                           (purpose='appleAds' AND outcome='paid_campaign' AND acquisition_id IS NOT NULL AND attribution_record_id IS NOT NULL) OR
                           (purpose='appleAds' AND outcome='organic' AND acquisition_id IS NULL AND attribution_record_id IS NOT NULL))
                )
                """).run()
            try await sql.raw("CREATE INDEX measurement_purchase_charge_link_acquisition ON measurement_purchase_charge_links(acquisition_id)").run()
            try await sql.raw("CREATE INDEX measurement_purchase_intent_attribution ON measurement_purchase_intents(attribution_record_id,state)").run()
        }
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Purpose-scoped purchase origin tombstones must survive rollback; use a compatible image")
    }
}
