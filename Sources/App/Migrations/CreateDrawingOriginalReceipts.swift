import Vapor
import Fluent

/// Measured private original bytes only; no drawing upload/ready state or route.
struct CreateDrawingOriginalReceipts: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_original_receipts (
                    asset_id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                    uploader_id UUID NOT NULL REFERENCES users(id),
                    measured_sha256 TEXT NOT NULL CHECK(measured_sha256 ~ '^[a-f0-9]{64}$'),
                    measured_size INTEGER NOT NULL CHECK(measured_size > 0 AND measured_size <= 52428800),
                    measured_mime TEXT NOT NULL CHECK(measured_mime IN ('application/pdf','image/jpeg','image/png')),
                    processor_profile TEXT NOT NULL CHECK(processor_profile ~ '^drawing-linux-byte-v1:[a-f0-9]{64}$'),
                    verification_method TEXT NOT NULL CHECK(verification_method = 'drawing-original-readback-v1'),
                    verified_at TIMESTAMPTZ NOT NULL, asset_revision BIGINT NOT NULL CHECK(asset_revision > 1),
                    FOREIGN KEY(asset_id,project_id) REFERENCES drawing_assets(id,project_id),
                    FOREIGN KEY(project_id,workspace_id) REFERENCES projects(id,workspace_id),
                    CHECK(measured_mime = 'application/pdf' OR measured_size <= 10485760)
                )
                """).run()
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION preserve_drawing_original_receipt() RETURNS trigger AS $$
                BEGIN
                    IF TG_OP != 'INSERT' THEN RAISE EXCEPTION 'Drawing original receipt is immutable'; END IF;
                    IF NOT EXISTS (
                        SELECT 1 FROM drawing_assets a WHERE a.id = NEW.asset_id AND a.project_id = NEW.project_id
                        AND a.workspace_id = NEW.workspace_id AND a.uploader_id = NEW.uploader_id
                        AND a.purpose = 'drawing_source' AND a.state = 'allocated'
                        AND a.original_sha256 = NEW.measured_sha256 AND a.original_size = NEW.measured_size
                        AND a.original_mime = NEW.measured_mime AND a.processor_profile = NEW.processor_profile
                        AND a.revision + 1 = NEW.asset_revision
                    ) THEN RAISE EXCEPTION 'Drawing original receipt does not match source'; END IF;
                    RETURN NEW;
                END; $$ LANGUAGE plpgsql
                """).run()
            if try await sql.raw("SELECT 1 FROM pg_trigger WHERE tgname = 'drawing_original_receipt_immutable' AND tgrelid = 'drawing_original_receipts'::regclass").first() == nil {
                try await sql.raw("CREATE TRIGGER drawing_original_receipt_immutable BEFORE INSERT OR UPDATE OR DELETE ON drawing_original_receipts FOR EACH ROW EXECUTE FUNCTION preserve_drawing_original_receipt()").run()
            }
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain measured drawing original receipts; use a compatible rollback image")
    }
}
