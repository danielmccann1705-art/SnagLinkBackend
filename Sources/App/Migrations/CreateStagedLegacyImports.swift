import Fluent
import Vapor

/// Private preparation storage only. No canonical project, user, membership,
/// media asset, publication cursor or Contractor grant is created by this schema.
struct CreateStagedLegacyImports: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE staged_legacy_imports (
                id UUID PRIMARY KEY, actor_id UUID NOT NULL REFERENCES users(id),
                workspace_id UUID NOT NULL REFERENCES teams(id), workspace_kind TEXT NOT NULL CHECK(workspace_kind IN ('personal','company')),
                environment TEXT NOT NULL CHECK(environment IN ('development','staging','production')), api_origin TEXT NOT NULL CHECK(octet_length(api_origin) <= 512),
                device_id UUID NOT NULL, operation_id UUID NOT NULL, auth_version INTEGER NOT NULL CHECK(auth_version >= 0),
                authority_fingerprint TEXT NOT NULL CHECK(authority_fingerprint ~ '^[a-f0-9]{64}$'),
                source_project_id UUID NOT NULL, source_fingerprint TEXT NOT NULL CHECK(source_fingerprint ~ '^[a-f0-9]{64}$'),
                export_sha256 TEXT NOT NULL CHECK(export_sha256 ~ '^[a-f0-9]{64}$'), export_byte_count INTEGER NOT NULL CHECK(export_byte_count BETWEEN 1 AND 8388608),
                request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
                state TEXT NOT NULL CHECK(state IN ('staged_incomplete','aborted')), revision BIGINT NOT NULL CHECK(revision > 0),
                acknowledgement_version TEXT NOT NULL CHECK(octet_length(acknowledgement_version) <= 100),
                acknowledgement_wording TEXT NOT NULL CHECK(octet_length(acknowledgement_wording) <= 2048),
                acknowledged_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
                summary_json TEXT NOT NULL CHECK(octet_length(summary_json) <= 32768),
                UNIQUE(actor_id, operation_id),
                UNIQUE(actor_id, environment, api_origin, source_fingerprint, source_project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_sources (
                session_id UUID PRIMARY KEY REFERENCES staged_legacy_imports(id),
                descriptor BYTEA NOT NULL CHECK(octet_length(descriptor) BETWEEN 1 AND 8388608)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_records (
                session_id UUID NOT NULL REFERENCES staged_legacy_imports(id), kind TEXT NOT NULL,
                source_id UUID NOT NULL, mapping_id UUID NOT NULL UNIQUE,
                proposed_target_id UUID NOT NULL, mapping_state TEXT NOT NULL CHECK(mapping_state = 'unreserved_source_id'),
                source_json TEXT NOT NULL CHECK(octet_length(source_json) <= 8388608), source_sha256 TEXT NOT NULL CHECK(source_sha256 ~ '^[a-f0-9]{64}$'),
                PRIMARY KEY(session_id, kind, source_id),
                CHECK(kind IN ('projects','snags','photos','drawings','contractors','trades','folders','tags','comments','statusHistory','deletionReceipts'))
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_edges (
                session_id UUID NOT NULL, position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 49999),
                kind TEXT NOT NULL, source_id UUID NOT NULL, field TEXT NOT NULL CHECK(octet_length(field) <= 100),
                target_kind TEXT NOT NULL, target_source_id UUID NOT NULL, target_present BOOLEAN NOT NULL,
                PRIMARY KEY(session_id, position), FOREIGN KEY(session_id,kind,source_id) REFERENCES staged_legacy_import_records(session_id,kind,source_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_files (
                session_id UUID NOT NULL REFERENCES staged_legacy_imports(id), declaration_id UUID NOT NULL UNIQUE,
                archive_path TEXT NOT NULL CHECK(octet_length(archive_path) BETWEEN 1 AND 4096),
                declared_sha256 TEXT NOT NULL CHECK(declared_sha256 ~ '^[a-f0-9]{64}$'), declared_bytes BIGINT NOT NULL CHECK(declared_bytes BETWEEN 0 AND 2147483648),
                verification_state TEXT NOT NULL CHECK(verification_state = 'unverified_declaration'),
                PRIMARY KEY(session_id, archive_path), UNIQUE(session_id,declaration_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_file_uses (
                session_id UUID NOT NULL, use_id UUID NOT NULL UNIQUE, kind TEXT NOT NULL, source_id UUID NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('projectCover','photoOriginal','photoThumbnail','photoAnnotation','drawingFile','drawingThumbnail','commentAttachment','deletedPhoto')),
                position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 49999), required BOOLEAN NOT NULL,
                source_json TEXT NOT NULL CHECK(octet_length(source_json) <= 32768),
                PRIMARY KEY(session_id, kind, source_id, role, position),
                FOREIGN KEY(session_id,kind,source_id) REFERENCES staged_legacy_import_records(session_id,kind,source_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE staged_legacy_import_actions (
                session_id UUID NOT NULL REFERENCES staged_legacy_imports(id), revision BIGINT NOT NULL CHECK(revision > 0),
                actor_id UUID NOT NULL REFERENCES users(id), operation_id UUID NOT NULL, device_id UUID NOT NULL,
                action TEXT NOT NULL CHECK(action IN ('source_staged','preparation_aborted')),
                happened_at TIMESTAMPTZ NOT NULL, PRIMARY KEY(session_id,revision)
            )
            """).run()
        try await sql.raw("""
            CREATE FUNCTION staged_legacy_import_state_transition() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Retained import binding is immutable' USING ERRCODE = '23514'; END IF;
                IF (to_jsonb(NEW) - ARRAY['state','revision','updated_at','summary_json']) <> (to_jsonb(OLD) - ARRAY['state','revision','updated_at','summary_json'])
                    OR OLD.state <> 'staged_incomplete' OR NEW.state <> 'aborted' OR NEW.revision <> OLD.revision + 1 THEN
                    RAISE EXCEPTION 'Import permits only its explicit abort transition' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await sql.raw("CREATE TRIGGER staged_import_state_guard BEFORE UPDATE OR DELETE ON staged_legacy_imports FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_state_transition()").run()
        try await sql.raw("CREATE INDEX staged_legacy_import_actor_state ON staged_legacy_imports(actor_id, state, created_at)").run()
        // These guards prevent accidental mutation through future services. Deliberate
        // redaction/erasure needs its own reviewed migration/lifecycle implementation.
        try await sql.raw("""
            CREATE FUNCTION staged_legacy_import_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'Retained import source is immutable' USING ERRCODE = '23514'; END $$
            """).run()
        for table in ["staged_legacy_import_sources", "staged_legacy_import_records", "staged_legacy_import_edges", "staged_legacy_import_files", "staged_legacy_import_file_uses", "staged_legacy_import_actions"] {
            try await sql.raw("CREATE TRIGGER retained_import_immutable BEFORE UPDATE OR DELETE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_immutable()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain private import recovery evidence; roll back to a compatible image")
    }
}
