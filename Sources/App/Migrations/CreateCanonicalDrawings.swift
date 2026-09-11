import Vapor
import Fluent

/// Additive internal foundation. Old public sync/media and register coverage are unchanged.
struct CreateCanonicalDrawings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_assets (
                    id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                    uploader_id UUID NOT NULL REFERENCES users(id),
                    purpose TEXT NOT NULL CHECK(purpose = 'drawing_source'),
                    original_sha256 TEXT NOT NULL CHECK(original_sha256 ~ '^[a-f0-9]{64}$'),
                    original_size INTEGER NOT NULL CHECK(original_size > 0 AND original_size <= 52428800),
                    original_mime TEXT NOT NULL CHECK(original_mime IN ('application/pdf','image/jpeg','image/png')),
                    original_filename TEXT NOT NULL, original_key TEXT NOT NULL UNIQUE,
                    processor_profile TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('allocated','processing','ready','failed','retired')),
                    revision BIGINT NOT NULL CHECK(revision > 0),
                    created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                    ready_at TIMESTAMPTZ, published_at TIMESTAMPTZ,
                    result_hash TEXT CHECK(result_hash ~ '^[a-f0-9]{64}$'),
                    CHECK(state != 'ready' OR (ready_at IS NOT NULL AND result_hash IS NOT NULL)),
                    CHECK(published_at IS NULL OR state IN ('ready','retired')),
                    CHECK(original_mime = 'application/pdf' OR original_size <= 10485760),
                    UNIQUE(id,project_id),
                    FOREIGN KEY(project_id,workspace_id) REFERENCES projects(id,workspace_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_processing_jobs (
                    asset_id UUID PRIMARY KEY, project_id UUID NOT NULL,
                    lease_token UUID NOT NULL, lease_expires_at TIMESTAMPTZ NOT NULL,
                    attempt INTEGER NOT NULL CHECK(attempt > 0),
                    state TEXT NOT NULL CHECK(state IN ('processing','complete')),
                    FOREIGN KEY(asset_id,project_id) REFERENCES drawing_assets(id,project_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_asset_pages (
                    id UUID PRIMARY KEY, asset_id UUID NOT NULL, project_id UUID NOT NULL,
                    source_page_index INTEGER NOT NULL CHECK(source_page_index BETWEEN 0 AND 99),
                    source_page_label TEXT NOT NULL, geometry_json TEXT NOT NULL,
                    rendition_key TEXT NOT NULL UNIQUE, rendition_sha256 TEXT NOT NULL CHECK(rendition_sha256 ~ '^[a-f0-9]{64}$'),
                    rendition_size INTEGER NOT NULL CHECK(rendition_size BETWEEN 1 AND 10485760),
                    thumbnail_key TEXT NOT NULL UNIQUE, thumbnail_sha256 TEXT NOT NULL CHECK(thumbnail_sha256 ~ '^[a-f0-9]{64}$'),
                    thumbnail_size INTEGER NOT NULL CHECK(thumbnail_size BETWEEN 1 AND 10485760),
                    UNIQUE(asset_id,source_page_index), UNIQUE(id,asset_id,project_id), UNIQUE(id,project_id),
                    FOREIGN KEY(asset_id,project_id) REFERENCES drawing_assets(id,project_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawings (
                    id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                    name TEXT NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 200), sort_order INTEGER NOT NULL,
                    revision BIGINT NOT NULL CHECK(revision > 0), current_version_id UUID NOT NULL,
                    created_by UUID NOT NULL REFERENCES users(id), created_at TIMESTAMPTZ NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL, archived_at TIMESTAMPTZ, archive_reason TEXT,
                    UNIQUE(id,project_id), FOREIGN KEY(project_id,workspace_id) REFERENCES projects(id,workspace_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_versions (
                    id UUID PRIMARY KEY, drawing_id UUID NOT NULL, project_id UUID NOT NULL,
                    asset_id UUID NOT NULL, version_number INTEGER NOT NULL CHECK(version_number = 1),
                    published_by UUID NOT NULL REFERENCES users(id), published_at TIMESTAMPTZ NOT NULL,
                    UNIQUE(drawing_id,version_number), UNIQUE(id,drawing_id,project_id), UNIQUE(id,drawing_id,asset_id,project_id),
                    FOREIGN KEY(drawing_id,project_id) REFERENCES drawings(id,project_id),
                    FOREIGN KEY(asset_id,project_id) REFERENCES drawing_assets(id,project_id)
                )
                """).run()
            let currentFK = try await sql.raw("SELECT 1 FROM pg_constraint WHERE conrelid = 'drawings'::regclass AND conname = 'drawing_current_version_scope'").first()
            if currentFK == nil {
                try await sql.raw("ALTER TABLE drawings ADD CONSTRAINT drawing_current_version_scope FOREIGN KEY(current_version_id,id,project_id) REFERENCES drawing_versions(id,drawing_id,project_id) DEFERRABLE INITIALLY DEFERRED").run()
            }
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_version_pages (
                    id UUID PRIMARY KEY, version_id UUID NOT NULL, drawing_id UUID NOT NULL,
                    asset_id UUID NOT NULL, asset_page_id UUID NOT NULL, project_id UUID NOT NULL,
                    page_index INTEGER NOT NULL CHECK(page_index = 0),
                    UNIQUE(version_id,page_index), UNIQUE(id,version_id,drawing_id,project_id), UNIQUE(id,project_id),
                    FOREIGN KEY(version_id,drawing_id,asset_id,project_id) REFERENCES drawing_versions(id,drawing_id,asset_id,project_id),
                    FOREIGN KEY(asset_page_id,asset_id,project_id) REFERENCES drawing_asset_pages(id,asset_id,project_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS snag_drawing_pins (
                    snag_id UUID PRIMARY KEY, project_id UUID NOT NULL,
                    drawing_id UUID, version_id UUID, version_page_id UUID,
                    x DOUBLE PRECISION, y DOUBLE PRECISION,
                    revision BIGINT NOT NULL CHECK(revision > 0), snag_revision BIGINT NOT NULL CHECK(snag_revision > 0),
                    recorded_by UUID NOT NULL REFERENCES users(id), recorded_at TIMESTAMPTZ NOT NULL, deleted_at TIMESTAMPTZ,
                    CHECK((deleted_at IS NULL AND drawing_id IS NOT NULL AND version_id IS NOT NULL AND version_page_id IS NOT NULL AND x IS NOT NULL AND y IS NOT NULL AND x >= 0 AND x <= 1 AND y >= 0 AND y <= 1)
                       OR (deleted_at IS NOT NULL AND drawing_id IS NULL AND version_id IS NULL AND version_page_id IS NULL AND x IS NULL AND y IS NULL)),
                    FOREIGN KEY(snag_id,project_id) REFERENCES snags(id,project_id),
                    FOREIGN KEY(version_page_id,version_id,drawing_id,project_id) REFERENCES drawing_version_pages(id,version_id,drawing_id,project_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS drawing_pin_events (
                    id UUID PRIMARY KEY, snag_id UUID NOT NULL, project_id UUID NOT NULL,
                    pin_revision BIGINT NOT NULL CHECK(pin_revision > 0), snag_revision BIGINT NOT NULL CHECK(snag_revision > 0),
                    previous_page_id UUID, previous_x DOUBLE PRECISION, previous_y DOUBLE PRECISION,
                    next_page_id UUID, next_x DOUBLE PRECISION, next_y DOUBLE PRECISION,
                    action TEXT NOT NULL CHECK(action IN ('placed','moved','removed')),
                    actor_id UUID NOT NULL REFERENCES users(id), recorded_at TIMESTAMPTZ NOT NULL,
                    UNIQUE(snag_id,pin_revision),
                    CHECK((previous_page_id IS NULL AND previous_x IS NULL AND previous_y IS NULL) OR
                          (previous_page_id IS NOT NULL AND previous_x IS NOT NULL AND previous_y IS NOT NULL AND previous_x >= 0 AND previous_x <= 1 AND previous_y >= 0 AND previous_y <= 1)),
                    CHECK((next_page_id IS NULL AND next_x IS NULL AND next_y IS NULL) OR
                          (next_page_id IS NOT NULL AND next_x IS NOT NULL AND next_y IS NOT NULL AND next_x >= 0 AND next_x <= 1 AND next_y >= 0 AND next_y <= 1)),
                    CHECK((action = 'placed' AND previous_page_id IS NULL AND next_page_id IS NOT NULL) OR
                          (action = 'moved' AND previous_page_id IS NOT NULL AND next_page_id IS NOT NULL) OR
                          (action = 'removed' AND previous_page_id IS NOT NULL AND next_page_id IS NULL)),
                    FOREIGN KEY(snag_id,project_id) REFERENCES snags(id,project_id),
                    FOREIGN KEY(previous_page_id,project_id) REFERENCES drawing_version_pages(id,project_id),
                    FOREIGN KEY(next_page_id,project_id) REFERENCES drawing_version_pages(id,project_id)
                )
                """).run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS drawings_project_order ON drawings(project_id,sort_order,id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS drawing_pin_history ON drawing_pin_events(project_id,snag_id,pin_revision)").run()
            // Immutable source identity is enforced even against an accidental future SQL updater.
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION preserve_drawing_source() RETURNS trigger AS $$
                BEGIN
                    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Drawing source identity must be retained'; END IF;
                    IF (OLD.id,OLD.workspace_id,OLD.project_id,OLD.uploader_id,OLD.purpose,OLD.original_sha256,OLD.original_size,OLD.original_mime,OLD.original_filename,OLD.original_key,OLD.processor_profile,OLD.created_at,OLD.expires_at)
                       IS DISTINCT FROM
                       (NEW.id,NEW.workspace_id,NEW.project_id,NEW.uploader_id,NEW.purpose,NEW.original_sha256,NEW.original_size,NEW.original_mime,NEW.original_filename,NEW.original_key,NEW.processor_profile,NEW.created_at,NEW.expires_at)
                    THEN RAISE EXCEPTION 'Drawing source identity is immutable'; END IF;
                    IF OLD.result_hash IS NOT NULL AND (OLD.result_hash,OLD.ready_at) IS DISTINCT FROM (NEW.result_hash,NEW.ready_at)
                    THEN RAISE EXCEPTION 'Processed drawing identity is immutable'; END IF;
                    IF OLD.published_at IS NOT NULL AND OLD.published_at IS DISTINCT FROM NEW.published_at
                    THEN RAISE EXCEPTION 'Drawing publication is immutable'; END IF;
                    RETURN NEW;
                END; $$ LANGUAGE plpgsql
                """).run()
            try await sql.raw("""
                CREATE OR REPLACE FUNCTION preserve_drawing_history() RETURNS trigger AS $$
                BEGIN RAISE EXCEPTION 'Drawing version, page and history records are immutable'; END; $$ LANGUAGE plpgsql
                """).run()
            for table in ["drawing_asset_pages", "drawing_versions", "drawing_version_pages", "drawing_pin_events"] {
                // Closed compile-time identifiers only, never request input.
                let trigger = table + "_immutable"
                let exists = try await sql.raw("SELECT 1 FROM pg_trigger WHERE tgname = \(bind: trigger) AND tgrelid = to_regclass(\(bind: table))").first()
                if exists == nil { try await sql.raw("CREATE TRIGGER \(unsafeRaw: trigger) BEFORE UPDATE OR DELETE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION preserve_drawing_history()").run() }
            }
            if try await sql.raw("SELECT 1 FROM pg_trigger WHERE tgname = 'drawing_source_immutable' AND tgrelid = 'drawing_assets'::regclass").first() == nil {
                try await sql.raw("CREATE TRIGGER drawing_source_immutable BEFORE UPDATE OR DELETE ON drawing_assets FOR EACH ROW EXECUTE FUNCTION preserve_drawing_source()").run()
            }
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain drawing sources, versions and pin history; use a compatible rollback image")
    }
}
