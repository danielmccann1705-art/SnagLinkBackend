import Vapor
import Fluent
import FluentSQL

/// Register after CreateStagedLegacyImports when the internal storage slice is enabled.
struct CreateStagedImportOriginalReceipts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE staged_import_file_operations (
                actor_id UUID NOT NULL REFERENCES users(id), operation_id UUID NOT NULL,
                session_id UUID NOT NULL, declaration_id UUID NOT NULL,
                device_id UUID NOT NULL, session_revision BIGINT NOT NULL CHECK(session_revision > 0),
                request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'), created_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(actor_id,operation_id),
                UNIQUE(session_id,declaration_id),
                UNIQUE(actor_id,operation_id,session_id,declaration_id),
                FOREIGN KEY(session_id,declaration_id) REFERENCES staged_legacy_import_files(session_id,declaration_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_import_original_receipts (
                session_id UUID NOT NULL, declaration_id UUID NOT NULL, receipt_id UUID NOT NULL UNIQUE,
                actor_id UUID NOT NULL, first_operation_id UUID NOT NULL, device_id UUID NOT NULL,
                session_revision BIGINT NOT NULL CHECK(session_revision > 0),
                measured_sha256 TEXT NOT NULL CHECK(measured_sha256 ~ '^[a-f0-9]{64}$'),
                measured_bytes BIGINT NOT NULL CHECK(measured_bytes BETWEEN 0 AND 2147483648),
                measured_at TIMESTAMPTZ NOT NULL,
                verification TEXT NOT NULL CHECK(verification = 'persisted_original_bytes_v1'),
                content_validation TEXT NOT NULL CHECK(content_validation = 'opaque_not_decoded'),
                PRIMARY KEY(session_id,declaration_id),
                FOREIGN KEY(session_id,declaration_id) REFERENCES staged_legacy_import_files(session_id,declaration_id),
                FOREIGN KEY(actor_id,first_operation_id,session_id,declaration_id)
                    REFERENCES staged_import_file_operations(actor_id,operation_id,session_id,declaration_id)
            )
            """).run()
        for table in ["staged_import_file_operations", "staged_import_original_receipts"] {
            try await sql.raw("CREATE TRIGGER retained_import_original_immutable BEFORE UPDATE OR DELETE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_immutable()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain private import originals and receipts; use a compatible rollback image")
    }
}
