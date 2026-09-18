import Fluent
import FluentSQL
import Vapor

/// Every attempt to process one retained original, including the ones that failed.
///
/// `legacy_import_file_processing` records only outcomes that succeeded, so a
/// preparation that took four passes to get through a flaky storage read looks
/// identical to one that succeeded first time. That matters twice over: an operator
/// cannot see which file keeps failing, and nobody can tell a preparation that is
/// progressing from one that is stuck on the same file forever.
///
/// Append-only, like the rest of the import record. `failure_kind` is a
/// classification, never a message — an error string from a storage client is exactly
/// where a signed URL or a path ends up in a table.
struct CreateImportProcessingAttempts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS legacy_import_processing_attempts (
                id UUID PRIMARY KEY,
                projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id),
                session_id UUID NOT NULL,
                declaration_id UUID NOT NULL,
                attempt_number INTEGER NOT NULL CHECK(attempt_number BETWEEN 1 AND 1000),
                outcome TEXT NOT NULL CHECK(outcome IN ('succeeded', 'failed')),
                failure_kind TEXT CHECK(failure_kind IS NULL OR failure_kind ~ '^[a-z_]{1,64}$'),
                attempted_at TIMESTAMPTZ NOT NULL,
                UNIQUE(projection_id, declaration_id, attempt_number),
                CHECK((outcome = 'succeeded' AND failure_kind IS NULL)
                   OR (outcome = 'failed' AND failure_kind IS NOT NULL)),
                FOREIGN KEY(session_id, declaration_id) REFERENCES staged_legacy_import_files(session_id, declaration_id)
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS import_processing_attempts_scope
            ON legacy_import_processing_attempts(projection_id, declaration_id, attempt_number)
            """).run()
        try await sql.raw("""
            CREATE TRIGGER legacy_import_publication_immutable
            BEFORE UPDATE OR DELETE ON legacy_import_processing_attempts
            FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_immutable()
            """).run()
    }

    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Processing attempts are retained evidence; roll back to a compatible image")
    }
}
