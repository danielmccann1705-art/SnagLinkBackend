import Vapor
import Fluent

/// New assets have no public URL. Historical synced-photo tables remain intact.
struct CreatePrivateMedia: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE media_assets (
                id UUID PRIMARY KEY, workspace_id UUID NOT NULL, project_id UUID NOT NULL,
                snag_id UUID NOT NULL, creator_id UUID NOT NULL REFERENCES users(id),
                purpose TEXT NOT NULL CHECK(purpose IN ('capture', 'completion')),
                intent_id UUID, state TEXT NOT NULL CHECK(state IN ('allocated', 'ready', 'retired')),
                original_sha256 TEXT NOT NULL CHECK(original_sha256 ~ '^[a-f0-9]{64}$'),
                original_size INTEGER NOT NULL CHECK(original_size > 0 AND original_size <= 10485760),
                original_mime TEXT NOT NULL CHECK(original_mime IN ('image/jpeg', 'image/png')),
                original_key TEXT NOT NULL UNIQUE, rendition_key TEXT NOT NULL UNIQUE,
                rendition_sha256 TEXT, rendition_size INTEGER, width INTEGER, height INTEGER,
                revision BIGINT NOT NULL DEFAULT 1 CHECK(revision > 0),
                base_snag_revision BIGINT NOT NULL CHECK(base_snag_revision > 0),
                created_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
                ready_at TIMESTAMPTZ, attached_at TIMESTAMPTZ,
                CHECK((purpose = 'capture' AND intent_id IS NULL) OR (purpose = 'completion' AND intent_id IS NOT NULL)),
                CHECK(state != 'ready' OR (rendition_sha256 IS NOT NULL AND rendition_size > 0 AND width > 0 AND height > 0 AND ready_at IS NOT NULL)),
                UNIQUE(id, snag_id, project_id),
                FOREIGN KEY(project_id, workspace_id) REFERENCES projects(id, workspace_id),
                FOREIGN KEY(snag_id, project_id) REFERENCES snags(id, project_id)
            )
            """).run()
        try await sql.raw("CREATE INDEX media_snag_manifest ON media_assets(project_id, snag_id, created_at, id)").run()
        try await sql.raw("CREATE INDEX media_unattached_expiry ON media_assets(expires_at) WHERE attached_at IS NULL").run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain media ownership and evidence records; use a compatible rollback image")
    }
}
