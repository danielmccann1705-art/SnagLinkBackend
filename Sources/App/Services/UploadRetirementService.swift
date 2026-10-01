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
    /// The keys a retired row can hold bytes at. Both columns stay NULL until the upload that records the intent for
    /// exactly that address (`BindMediaAssetKeysAtUpload`), so an allocated-never-uploaded row has none and queues
    /// nothing. A historical `…/view.jpg` placeholder is never written by anything, so it is not queued either.
    static func keys(of row: SQLRow) throws -> [(role: String, key: String)] {
        var found: [(role: String, key: String)] = []
        if let original = try row.decode(column: "original_key", as: String?.self) { found.append(("original", original)) }
        if let rendition = try row.decode(column: "rendition_key", as: String?.self), !rendition.hasSuffix("/view.jpg") {
            found.append(("rendition", rendition))
        }
        return found
    }

    /// Retires one unattached, not yet retired row the caller has locked and checked. One or two statements.
    static func retire(_ row: SQLRow, now: Date = Date(), on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db), id = try row.decode(column: "id", as: UUID.self)
        try await sql.raw("UPDATE media_assets SET state = 'retired', revision = revision + 1, retired_at = \(bind: now) WHERE id = \(bind: id) AND attached_at IS NULL AND state <> 'retired'").run()
        let queued = try keys(of: row)
        guard !queued.isEmpty else { return }
        let values = queued.map { entry -> SQLQueryString in
            "(\(bind: id), \(bind: entry.role), \(bind: entry.key), 'pending', 0, \(bind: now))"
        }
        try await sql.raw(SQLQueryString("INSERT INTO upload_retirements (asset_id, role, object_key, state, attempts, created_at) VALUES ")
                          + values.joined(separator: ", ") + SQLQueryString(" ON CONFLICT (asset_id, role) DO NOTHING")).run()
    }
}
