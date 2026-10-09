import Fluent
import FluentSQL
import Vapor

/// Adds the product-analytics purpose to the purchase-intent ledger so a verified initial
/// purchase can be classified as a confirmed purchase origin without any advertising
/// consent (ProductPurchaseOriginService). Constraint-only: no column, no table, no
/// default changes, and existing rows keep their purpose. Older images never write or
/// read this purpose, so they run unchanged on the widened constraints. The revert removes
/// product-purpose rows (short-lived optional evidence) and restores the old constraints.
struct AddProductPurchaseOriginPurpose: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await dropPurposeCheck(sql)
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents ADD CONSTRAINT measurement_purchase_intent_purpose
                CHECK (purpose IN ('crossCompanyAds','appleAds','productAnalytics'))
                """).run()
            try await sql.raw("ALTER TABLE measurement_purchase_intents DROP CONSTRAINT measurement_purchase_intent_authority").run()
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents ADD CONSTRAINT measurement_purchase_intent_authority
                CHECK ((purpose='crossCompanyAds' AND subject_id IS NOT NULL AND attribution_record_id IS NULL) OR
                       (purpose='appleAds' AND subject_id IS NULL AND attribution_record_id IS NOT NULL) OR
                       (purpose='productAnalytics' AND subject_id IS NOT NULL AND attribution_record_id IS NULL))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await sql.raw("DELETE FROM measurement_purchase_intents WHERE purpose='productAnalytics'").run()
            try await dropPurposeCheck(sql)
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents ADD CONSTRAINT measurement_purchase_intent_purpose
                CHECK (purpose IN ('crossCompanyAds','appleAds'))
                """).run()
            try await sql.raw("ALTER TABLE measurement_purchase_intents DROP CONSTRAINT measurement_purchase_intent_authority").run()
            try await sql.raw("""
                ALTER TABLE measurement_purchase_intents ADD CONSTRAINT measurement_purchase_intent_authority
                CHECK ((purpose='crossCompanyAds' AND subject_id IS NOT NULL AND attribution_record_id IS NULL) OR
                       (purpose='appleAds' AND subject_id IS NULL AND attribution_record_id IS NOT NULL))
                """).run()
        }
    }

    /// The original purpose check was declared inline (system-named); drop it by definition.
    private func dropPurposeCheck(_ sql: SQLDatabase) async throws {
        try await sql.raw("""
            DO $$
            DECLARE c text;
            BEGIN
              FOR c IN SELECT conname FROM pg_constraint
                       WHERE conrelid='measurement_purchase_intents'::regclass AND contype='c'
                         AND pg_get_constraintdef(oid) LIKE '%(purpose = ANY%'
              LOOP
                EXECUTE format('ALTER TABLE measurement_purchase_intents DROP CONSTRAINT %I', c);
              END LOOP;
            END $$
            """).run()
    }
}
