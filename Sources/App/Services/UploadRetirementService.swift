import Vapor
import Fluent
import FluentSQL

/// Lane A WP4 (FABLE-DESIGN-A-AMENDMENT §4.4–4.5): retiring an upload that was never attached.
///
/// Retirement is a database fact first: the row becomes `retired` (with `retired_at`) in the caller's transaction,
/// under the caller's locks, and from then on every allocate, PUT and attachment refuses it inside its own
/// authorisation. Its object keys are queued in `upload_retirements` for the hourly pass, which replaces each with
/// the same zero-byte erasure fence account deletion writes. No change row is written: a draft never had one
/// (allocation and readiness write none), so retiring it leaves every other reader exactly as it was.
enum UploadRetirementService {
    /// Role by address shape: the original's key ends in `/original`, a rendition's in `view-<sha>.jpg`.
    static func role(of key: String) -> String { key.hasSuffix("/original") ? "original" : "rendition" }

    /// Every address this upload's bytes can be at: the row's `original_key` and `rendition_key` (both NULL until the
    /// upload that records the intent for exactly that address, `BindMediaAssetKeysAtUpload`; the historical
    /// `…/view.jpg` placeholder is never written and is skipped), **and** every key an object-write intent was recorded
    /// for this asset (Fable §8.3: a rendition can settle and its readiness transaction then fail, leaving its key only
    /// in `object_write_intents`). An intent in any state counts — an `active` one may still land, and a fence over an
    /// address a create-only PUT has not reached yet only makes that PUT refuse. A never-uploaded allocation has none.
    static func keys(of row: SQLRow, on db: Database) async throws -> [String] {
        var found: [String] = []
        func add(_ key: String?) { if let key, !key.hasSuffix("/view.jpg"), !found.contains(key) { found.append(key) } }
        add(try row.decode(column: "original_key", as: String?.self))
        add(try row.decode(column: "rendition_key", as: String?.self))
        let id = try row.decode(column: "id", as: UUID.self)
        for intent in try await VerifiedIdentityService.sql(db).raw("""
            SELECT object_key FROM object_write_intents
            WHERE source_kind = 'media_asset' AND source_id = \(bind: id) AND storage_kind = 'private_media' ORDER BY created_at
            """).all() {
            add(try intent.decode(column: "object_key", as: String.self))
        }
        return found
    }

    /// Retires one unattached, not yet retired row the caller has locked and checked, and queues its keys. The queue is
    /// written only when this call's guarded UPDATE changed the row (Fable §8.2), so a row attached or retired between
    /// a caller's read and its lock is never queued. Two or three statements.
    static func retire(_ row: SQLRow, now: Date = Date(), on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db), id = try row.decode(column: "id", as: UUID.self)
        guard try await sql.raw("""
            UPDATE media_assets SET state = 'retired', revision = revision + 1, retired_at = \(bind: now)
            WHERE id = \(bind: id) AND attached_at IS NULL AND state <> 'retired' RETURNING id
            """).first() != nil else { return }
        let queued = try await keys(of: row, on: db)
        guard !queued.isEmpty else { return }
        let values = queued.map { key -> SQLQueryString in
            "(\(bind: id), \(bind: role(of: key)), \(bind: key), 'pending', 0, \(bind: now))"
        }
        try await sql.raw(SQLQueryString("INSERT INTO upload_retirements (asset_id, role, object_key, state, attempts, created_at) VALUES ")
                          + values.joined(separator: ", ") + SQLQueryString(" ON CONFLICT (asset_id, object_key) DO NOTHING")).run()
    }
}
