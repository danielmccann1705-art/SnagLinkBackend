import Vapor
import Fluent

/// A media asset's storage addresses are born with the write intent that records
/// them, not with the allocation that precedes it.
///
/// Until now `PrivateMediaService.allocate` wrote `original_key` and a
/// `view.jpg` rendition placeholder into the row before any intent existed, and
/// both columns were `NOT NULL` so it had no choice. Under the private namespace
/// that ordering is not survivable. A namespaced key is never physically deleted:
/// an account erasure replaces its bytes with a fence, and a fence can only be
/// placed for a key whose captured `create_only_v1` intents agree on one physical
/// target. A key that reached `media_assets` with no intent behind it therefore
/// enters the erasure manifest through the row, finds no intent to make it
/// fenceable, and is handed to the physical-delete branch, which refuses a
/// namespaced address by shape — for good. Every allocated-never-uploaded asset
/// would be one of those, and that is the common case, not the rare one.
///
/// So both columns become nullable and stay NULL until the moment an upload
/// records the intent for that exact string, inside the same transaction. Three
/// rules keep that meaningful:
///
/// * `media_ready_has_keys` — a `ready` row still has both addresses. Readiness
///   is the state in which the object is disclosed, and it is only ever committed
///   after both writes were verified, so there is no readiness without addresses.
/// * `preserve_media_asset_keys` — once an address is set it is final. NULL to a
///   value is the only transition either column may make. Under create-only an
///   address is spent the moment it is used and spent for good once a fence has
///   taken it, so re-pointing a row at a second address would abandon the first
///   object with nothing left in the database that names it.
/// * The manifest's own SQL already skips a NULL key (`AccountDeletionGraphService`
///   selects `rendition_key` only `WHERE rendition_key IS NOT NULL`, and
///   `original_key` becomes NULL-able the same way), so an allocated-never-
///   uploaded asset simply contributes nothing to erase.
///
/// Nothing here is namespace-specific. A historical `platform/` row keeps its two
/// addresses and its physical deletion exactly as before; what changes is only
/// *when* an address appears, which is the one thing the fence needs.
struct BindMediaAssetKeysAtUpload: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            ALTER TABLE media_assets
                ALTER COLUMN original_key DROP NOT NULL,
                ALTER COLUMN rendition_key DROP NOT NULL,
                ADD CONSTRAINT media_ready_has_keys
                    CHECK (state <> 'ready' OR (original_key IS NOT NULL AND rendition_key IS NOT NULL))
            """).run()
        // Refuses the change rather than the row: a caller that meets this has
        // tried to move an object that is already addressed, and the SQLSTATE is
        // the same 23514 every other authority check in this schema raises.
        try await sql.raw("""
            CREATE FUNCTION preserve_media_asset_keys() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF OLD.original_key IS NOT NULL AND NEW.original_key IS DISTINCT FROM OLD.original_key THEN
                    RAISE EXCEPTION 'Media asset original_key is bound for good' USING ERRCODE='23514';
                END IF;
                IF OLD.rendition_key IS NOT NULL AND NEW.rendition_key IS DISTINCT FROM OLD.rendition_key THEN
                    RAISE EXCEPTION 'Media asset rendition_key is bound for good' USING ERRCODE='23514';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await sql.raw("""
            CREATE TRIGGER preserve_media_asset_keys BEFORE UPDATE ON media_assets
            FOR EACH ROW EXECUTE FUNCTION preserve_media_asset_keys()
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain media ownership and evidence records; use a compatible rollback image")
    }
}
