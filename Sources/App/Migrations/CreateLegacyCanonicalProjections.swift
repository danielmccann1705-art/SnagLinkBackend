import Fluent
import Vapor

/// Private projection decisions only. No canonical project exists before a future
/// separately acknowledged atomic commit. Source/session receipt remains unchanged.
struct CreateLegacyCanonicalProjections: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE legacy_canonical_projections (
                id UUID PRIMARY KEY, session_id UUID NOT NULL REFERENCES staged_legacy_imports(id),
                actor_id UUID NOT NULL REFERENCES users(id), workspace_id UUID NOT NULL REFERENCES teams(id),
                device_id UUID NOT NULL, operation_id UUID NOT NULL,
                policy TEXT NOT NULL CHECK(policy = 'selected-project-canonical-projection-v1'),
                expected_source_revision BIGINT NOT NULL CHECK(expected_source_revision = 1),
                request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
                graph_sha256 TEXT NOT NULL CHECK(graph_sha256 ~ '^[a-f0-9]{64}$'),
                receipt_json TEXT NOT NULL CHECK(octet_length(receipt_json) <= 8192),
                state TEXT NOT NULL CHECK(state = 'prepared_non_executable'),
                created_at TIMESTAMPTZ NOT NULL,
                UNIQUE(session_id,policy), UNIQUE(actor_id,operation_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_canonical_allocations (
                projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id),
                allocation_key TEXT NOT NULL CHECK(octet_length(allocation_key) BETWEEN 1 AND 120), target_id UUID NOT NULL,
                PRIMARY KEY(projection_id,allocation_key),
                CHECK(allocation_key ~ '^(projects|snags|photos|drawings|contractors|trades|folders|tags|comments|statusHistory|deletionReceipts|fileObject|photoRendition|drawingAsset|drawingAssetPage|drawingVersion|drawingVersionPage|pinProjectionEvent)/[a-f0-9-]{36}$')
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_canonical_directory_identities (
                id UUID PRIMARY KEY, first_projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id),
                actor_id UUID NOT NULL REFERENCES users(id), workspace_id UUID NOT NULL REFERENCES teams(id),
                environment TEXT NOT NULL, api_origin TEXT NOT NULL CHECK(octet_length(api_origin) <= 512),
                archive_id UUID NOT NULL, source_fingerprint TEXT NOT NULL CHECK(source_fingerprint ~ '^[a-f0-9]{64}$'),
                kind TEXT NOT NULL CHECK(kind IN ('contractors','trades','folders','tags')), source_id UUID NOT NULL, target_id UUID NOT NULL,
                intrinsic_policy TEXT NOT NULL CHECK(intrinsic_policy = 'directory-intrinsic-v1'),
                intrinsic_sha256 TEXT NOT NULL CHECK(intrinsic_sha256 ~ '^[a-f0-9]{64}$'),
                canonical_reservation TEXT NOT NULL CHECK(canonical_reservation = 'none'),
                UNIQUE(actor_id,workspace_id,environment,api_origin,archive_id,source_fingerprint,kind,source_id)
            )
            """).run()
        try await sql.raw("""
            CREATE TABLE legacy_canonical_projection_directories (
                projection_id UUID NOT NULL REFERENCES legacy_canonical_projections(id),
                identity_id UUID NOT NULL REFERENCES legacy_canonical_directory_identities(id),
                PRIMARY KEY(projection_id,identity_id)
            )
            """).run()
        for table in ["legacy_canonical_projections","legacy_canonical_allocations","legacy_canonical_directory_identities","legacy_canonical_projection_directories"] {
            try await sql.raw("CREATE TRIGGER canonical_projection_immutable BEFORE UPDATE OR DELETE ON \(unsafeRaw: table) FOR EACH ROW EXECUTE FUNCTION staged_legacy_import_immutable()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain immutable projection mappings; use a compatible rollback image")
    }
}
