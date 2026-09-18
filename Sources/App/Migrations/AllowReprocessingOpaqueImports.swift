import Fluent
import FluentSQL
import Vapor

/// Lets a file that failed *our* image processor be processed again.
///
/// `legacy_import_file_processing` is append-only, and `pendingDeclarations` skips any
/// declaration that has a row. Together those made a processor failure permanent: the
/// file was recorded `opaque`, excluded from every later pass, and — before
/// `legacy_import_processing_attempts` learned to tell the difference — indistinguishable
/// from a file that genuinely is not an image.
///
/// One transition is permitted, and only one: `opaque` → `decoded_image` on a
/// preparation that has not been published. It is monotone — information is only ever
/// gained, never lost — so it cannot be used to walk a published record backwards, and
/// it cannot touch a row that already decoded.
struct AllowReprocessingOpaqueImports: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION legacy_import_processing_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_OP = 'DELETE' THEN
                    RAISE EXCEPTION 'Retained import processing is immutable' USING ERRCODE = '23514';
                END IF;
                IF OLD.state <> 'opaque' OR NEW.state <> 'decoded_image'
                   OR OLD.projection_id <> NEW.projection_id
                   OR OLD.declaration_id <> NEW.declaration_id
                   OR OLD.session_id <> NEW.session_id
                   OR OLD.receipt_id <> NEW.receipt_id THEN
                    RAISE EXCEPTION 'Retained import processing is immutable' USING ERRCODE = '23514';
                END IF;
                IF EXISTS (SELECT 1 FROM legacy_import_commits WHERE session_id = OLD.session_id) THEN
                    RAISE EXCEPTION 'This preparation was already published' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await sql.raw("DROP TRIGGER IF EXISTS legacy_import_publication_immutable ON legacy_import_file_processing").run()
        try await sql.raw("""
            CREATE TRIGGER legacy_import_publication_immutable
            BEFORE UPDATE OR DELETE ON legacy_import_file_processing
            FOR EACH ROW EXECUTE FUNCTION legacy_import_processing_guard()
            """).run()
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain import processing evidence; roll back to a compatible image")
    }
}
