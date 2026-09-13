import Fluent
import Vapor

/// Additive canonical storage for one atomically published legacy project: qualified
/// workflow columns, typed imported files/photos/history/organisation, private
/// processing facts and the append-only commit receipt. The frozen source receipt
/// (`staged_legacy_imports.state`) is untouched; publication is a separate record.
struct CreateLegacyImportPublication: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            ALTER TABLE snags ADD COLUMN workflow_qualification TEXT CHECK(workflow_qualification IN ('legacy_unverified')),
                ADD COLUMN source_status TEXT, ADD COLUMN source_closed_at TIMESTAMPTZ, ADD COLUMN imported_at TIMESTAMPTZ,
                ADD COLUMN source_created_at TIMESTAMPTZ, ADD COLUMN source_updated_at TIMESTAMPTZ
            """).run()
        try await sql.raw("""
            ALTER TABLE projects ADD COLUMN imported_at TIMESTAMPTZ, ADD COLUMN import_session_id UUID, ADD COLUMN source_status TEXT,
                ADD COLUMN source_created_at TIMESTAMPTZ, ADD COLUMN source_updated_at TIMESTAMPTZ, ADD COLUMN cover_file_id UUID
            """).run()
        try await sql.raw("""
            CREATE TABLE workspace_folders (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL REFERENCES teams(id),
                name TEXT NOT NULL CHECK(octet_length(name) BETWEEN 1 AND 800), color_hex TEXT NOT NULL CHECK(octet_length(color_hex) <= 16),
                sort_order INTEGER NOT NULL, parent_id UUID, revision BIGINT NOT NULL CHECK(revision > 0),
                source_created_at TIMESTAMPTZ, source_updated_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
                UNIQUE(id, workspace_id), FOREIGN KEY(parent_id, workspace_id) REFERENCES workspace_folders(id, workspace_id) DEFERRABLE INITIALLY DEFERRED
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE workspace_tags (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL REFERENCES teams(id),
                name TEXT NOT NULL CHECK(octet_length(name) BETWEEN 1 AND 800), color_hex TEXT NOT NULL CHECK(octet_length(color_hex) <= 16),
                revision BIGINT NOT NULL CHECK(revision > 0), source_created_at TIMESTAMPTZ, source_updated_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL, UNIQUE(id, workspace_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE project_folder_links (
                project_id UUID PRIMARY KEY, workspace_id UUID NOT NULL, folder_id UUID NOT NULL,
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(folder_id, workspace_id) REFERENCES workspace_folders(id, workspace_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE project_tag_links (
                project_id UUID NOT NULL, workspace_id UUID NOT NULL, tag_id UUID NOT NULL, PRIMARY KEY(project_id, tag_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(tag_id, workspace_id) REFERENCES workspace_tags(id, workspace_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_file_objects (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL, session_id UUID NOT NULL, declaration_id UUID NOT NULL,
                receipt_id UUID NOT NULL, sha256 TEXT NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'), bytes BIGINT NOT NULL CHECK(bytes BETWEEN 0 AND 2147483648),
                storage TEXT NOT NULL CHECK(storage = 'staged_original_v1'),
                decoded_mime TEXT CHECK(decoded_mime IN ('image/jpeg','image/png')), width INTEGER, height INTEGER,
                rendition_key TEXT UNIQUE, rendition_sha256 TEXT CHECK(rendition_sha256 ~ '^[a-f0-9]{64}$'), rendition_size INTEGER,
                revision BIGINT NOT NULL CHECK(revision > 0), created_at TIMESTAMPTZ NOT NULL,
                UNIQUE(session_id, declaration_id), UNIQUE(id, project_id),
                CHECK(decoded_mime IS NULL OR (width > 0 AND height > 0 AND rendition_key IS NOT NULL AND rendition_sha256 IS NOT NULL AND rendition_size > 0)),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(session_id, declaration_id) REFERENCES staged_legacy_import_files(session_id, declaration_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_file_uses (
                id UUID PRIMARY KEY, project_id UUID NOT NULL REFERENCES projects(id), kind TEXT NOT NULL, source_id UUID NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('projectCover','photoOriginal','photoThumbnail','photoAnnotation','drawingFile','drawingThumbnail','commentAttachment','deletedPhoto')),
                position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 49999), required BOOLEAN NOT NULL,
                availability TEXT NOT NULL CHECK(availability IN ('verifiedBytes','missing','unsafePath','notRecorded')),
                file_object_id UUID, source_path_sha256 TEXT, used_legacy_drawing_location BOOLEAN NOT NULL,
                UNIQUE(project_id, kind, source_id, role, position), UNIQUE(id, project_id),
                FOREIGN KEY(file_object_id, project_id) REFERENCES imported_file_objects(id, project_id),
                CHECK(kind IN ('projects','snags','photos','drawings','contractors','trades','folders','tags','comments','statusHistory','deletionReceipts'))
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_photos (
                id UUID PRIMARY KEY, project_id UUID NOT NULL, snag_id UUID NOT NULL,
                original_use_id UUID NOT NULL, thumbnail_use_id UUID NOT NULL, annotation_use_id UUID NOT NULL,
                source_label_json TEXT, source_legacy_label_json TEXT, label_resolution TEXT NOT NULL,
                captured_at TIMESTAMPTZ NOT NULL, latitude DOUBLE PRECISION, longitude DOUBLE PRECISION, sort_order INTEGER NOT NULL,
                source_created_at TIMESTAMPTZ NOT NULL, revision BIGINT NOT NULL CHECK(revision > 0), imported_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id),
                FOREIGN KEY(original_use_id, project_id) REFERENCES imported_file_uses(id, project_id),
                FOREIGN KEY(thumbnail_use_id, project_id) REFERENCES imported_file_uses(id, project_id),
                FOREIGN KEY(annotation_use_id, project_id) REFERENCES imported_file_uses(id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_snag_comments (
                id UUID PRIMARY KEY, project_id UUID NOT NULL, snag_id UUID NOT NULL, content TEXT NOT NULL,
                unverified_author_id UUID, unverified_author_name TEXT NOT NULL, unverified_author_type TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ, parent_comment_id UUID, mentions_json TEXT NOT NULL,
                is_from_contractor_link BOOLEAN NOT NULL, attachment_list_state TEXT NOT NULL, attachment_list_source_bytes INTEGER NOT NULL,
                attachment_list_source_sha256 TEXT, provenance TEXT NOT NULL, revision BIGINT NOT NULL CHECK(revision > 0), imported_at TIMESTAMPTZ NOT NULL,
                redacted_at TIMESTAMPTZ, FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_status_changes (
                id UUID PRIMARY KEY, project_id UUID NOT NULL, snag_id UUID NOT NULL, from_status TEXT NOT NULL, to_status TEXT NOT NULL,
                unverified_changed_by_id UUID, unverified_changed_by_name TEXT NOT NULL, unverified_changed_by_type TEXT NOT NULL, reason TEXT,
                created_at TIMESTAMPTZ NOT NULL, provenance TEXT NOT NULL, imported_at TIMESTAMPTZ NOT NULL,
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_snag_deletions (
                deleted_snag_id UUID NOT NULL, project_id UUID NOT NULL REFERENCES projects(id), reference TEXT NOT NULL,
                unverified_source_owner_id UUID, created_at TIMESTAMPTZ NOT NULL, historical_needs_remote_deletion BOOLEAN NOT NULL,
                execution TEXT NOT NULL, imported_at TIMESTAMPTZ NOT NULL, PRIMARY KEY(deleted_snag_id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE imported_drawing_provenance (
                drawing_id UUID NOT NULL, project_id UUID NOT NULL REFERENCES projects(id), name TEXT NOT NULL, sort_order INTEGER NOT NULL,
                file_use_id UUID NOT NULL, thumbnail_use_id UUID NOT NULL, source_page_number INTEGER,
                source_created_at TIMESTAMPTZ NOT NULL, source_updated_at TIMESTAMPTZ NOT NULL, provenance TEXT NOT NULL,
                rendering TEXT NOT NULL CHECK(rendering IN ('rendered_single_raster_v1','opaque_unrendered')), asset_id UUID, imported_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(drawing_id, project_id),
                FOREIGN KEY(file_use_id, project_id) REFERENCES imported_file_uses(id, project_id),
                FOREIGN KEY(thumbnail_use_id, project_id) REFERENCES imported_file_uses(id, project_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_import_file_processing (
                projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id), session_id UUID NOT NULL, declaration_id UUID NOT NULL,
                receipt_id UUID NOT NULL, state TEXT NOT NULL CHECK(state IN ('decoded_image','opaque')),
                decoded_mime TEXT CHECK(decoded_mime IN ('image/jpeg','image/png')), width INTEGER, height INTEGER,
                rendition_key TEXT UNIQUE, rendition_sha256 TEXT CHECK(rendition_sha256 ~ '^[a-f0-9]{64}$'), rendition_size INTEGER,
                processed_at TIMESTAMPTZ NOT NULL, PRIMARY KEY(projection_id, declaration_id),
                CHECK((state = 'opaque' AND decoded_mime IS NULL AND rendition_key IS NULL) OR (state = 'decoded_image' AND decoded_mime IS NOT NULL AND width > 0 AND height > 0 AND rendition_key IS NOT NULL AND rendition_sha256 IS NOT NULL AND rendition_size > 0)),
                FOREIGN KEY(session_id, declaration_id) REFERENCES staged_legacy_import_files(session_id, declaration_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_import_drawing_processing (
                projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id), drawing_source_id UUID NOT NULL, asset_id UUID NOT NULL,
                declaration_id UUID NOT NULL, state TEXT NOT NULL CHECK(state IN ('rendered','unsupported')),
                source_mime TEXT, source_sha256 TEXT NOT NULL CHECK(source_sha256 ~ '^[a-f0-9]{64}$'), source_bytes BIGINT NOT NULL,
                geometry_json TEXT, rendition_key TEXT UNIQUE, rendition_sha256 TEXT, rendition_size INTEGER,
                thumbnail_key TEXT UNIQUE, thumbnail_sha256 TEXT, thumbnail_size INTEGER, result_hash TEXT, processed_at TIMESTAMPTZ NOT NULL,
                PRIMARY KEY(projection_id, drawing_source_id), UNIQUE(asset_id),
                CHECK(state = 'unsupported' OR (source_mime IN ('image/jpeg','image/png') AND geometry_json IS NOT NULL AND rendition_key IS NOT NULL AND rendition_sha256 IS NOT NULL AND rendition_size > 0 AND thumbnail_key IS NOT NULL AND thumbnail_sha256 IS NOT NULL AND thumbnail_size > 0 AND result_hash IS NOT NULL))
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_import_commits (
                id UUID PRIMARY KEY, session_id UUID NOT NULL UNIQUE REFERENCES staged_legacy_imports(id),
                projection_id UUID NOT NULL UNIQUE REFERENCES legacy_canonical_projections(id),
                actor_id UUID NOT NULL REFERENCES users(id), workspace_id UUID NOT NULL REFERENCES teams(id), device_id UUID NOT NULL, operation_id UUID NOT NULL,
                request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'), graph_sha256 TEXT NOT NULL CHECK(graph_sha256 ~ '^[a-f0-9]{64}$'),
                acknowledgement_version TEXT NOT NULL CHECK(octet_length(acknowledgement_version) <= 100),
                acknowledgement_wording TEXT NOT NULL CHECK(octet_length(acknowledgement_wording) <= 2048),
                project_id UUID NOT NULL REFERENCES projects(id), transaction_group UUID NOT NULL,
                first_sequence BIGINT NOT NULL, last_sequence BIGINT NOT NULL, journal_event_count INTEGER NOT NULL CHECK(journal_event_count > 0),
                state TEXT NOT NULL CHECK(state = 'published'), receipt_json TEXT NOT NULL CHECK(octet_length(receipt_json) <= 65536),
                created_at TIMESTAMPTZ NOT NULL, UNIQUE(actor_id, operation_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_import_published_records (
                commit_id UUID NOT NULL REFERENCES legacy_import_commits(id), kind TEXT NOT NULL, source_id UUID NOT NULL, target_id UUID NOT NULL,
                target_kind TEXT NOT NULL, PRIMARY KEY(commit_id, kind, source_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_import_directory_publications (
                identity_id UUID PRIMARY KEY REFERENCES legacy_canonical_directory_identities(id), commit_id UUID NOT NULL REFERENCES legacy_import_commits(id),
                kind TEXT NOT NULL, target_id UUID NOT NULL, canonical_revision BIGINT NOT NULL, content_sha256 TEXT NOT NULL CHECK(content_sha256 ~ '^[a-f0-9]{64}$')
            )
            """).run()
        for table in ["legacy_import_file_processing", "legacy_import_drawing_processing", "legacy_import_commits", "legacy_import_published_records", "legacy_import_directory_publications", "imported_snag_deletions", "imported_status_changes"] {
            try await sql.raw("CREATE TRIGGER legacy_import_publication_immutable BEFORE UPDATE OR DELETE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_immutable()").run()
        }
        try await sql.raw("CREATE INDEX imported_file_uses_scope ON imported_file_uses(project_id, kind, source_id)").run()
        try await sql.raw("CREATE INDEX imported_photos_snag ON imported_photos(project_id, snag_id, sort_order, id)").run()
        try await sql.raw("CREATE INDEX imported_comments_snag ON imported_snag_comments(project_id, snag_id, created_at, id)").run()
        try await sql.raw("CREATE INDEX imported_status_snag ON imported_status_changes(project_id, snag_id, created_at, id)").run()
        try await sql.raw("CREATE INDEX workspace_folders_scope ON workspace_folders(workspace_id, sort_order, id)").run()
        try await sql.raw("CREATE INDEX workspace_tags_scope ON workspace_tags(workspace_id, name, id)").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain published legacy imports and their receipts; use a compatible rollback image")
    }
}
