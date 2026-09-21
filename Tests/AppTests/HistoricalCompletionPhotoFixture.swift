@testable import App
import Foundation
import Fluent
import FluentSQL

/// Inserts synthetic evidence representing a completion-photo row which existed
/// before trusted upload ownership was introduced. Production writes must always
/// use CompletionUploadObjectService.
///
/// **This is the tree's one shared exception to the rule that a test never
/// disables a production trigger or constraint**, and it is deliberate.
///
/// *What the row is.* A completion photo with `upload_object_id` NULL — the shape
/// every completion photo had before `CreateCompletionUploadObjects` introduced
/// trusted upload ownership. That migration kept those rows and left the column
/// nullable on purpose ("Existing rows remain historical and nullable"), and three
/// product paths exist only for them: the unresolved-object candidates in
/// `AccountDeletionGraphService` and `AccountDeletionCompanyGraphService`, both of
/// which select on `cp.upload_object_id IS NULL`, and the `legacy_completion_photo`
/// branch of `account_deletion_erasure_allowed` in `CreateObjectErasureFences`. A
/// fixture that built a trusted row instead would stop covering all three, so the
/// alternative here is not a different fixture — it is losing the coverage.
///
/// *Why it cannot be written any other way.* The trigger's first insert rule is
/// `IF NEW.upload_object_id IS NULL THEN RAISE`, so no post-migration writer can
/// produce this row, which is exactly what the trigger is for: it fences old
/// application binaries during a rolling transition, rather than forbidding the
/// rows that predate it. `CompletionUploadObjectService.attach` is the only product
/// writer of `completion_photos` and always sets `upload_object_id`; the column is
/// immutable afterwards (the trigger's UPDATE branch) and the upload row it points
/// at cannot be removed (`completion_upload_object_immutable`). So there is no
/// sequence of permitted statements that ends in this row.
///
/// *Why suspending it here is safe.* The refusal is proved live by tests that do
/// not suspend anything — `CompletionUploadObjectTests`
/// `.testForgedHistoricalAndOtherLinkURLsCannotManufactureOwnership` and
/// `.testMigrationPreservesHistoricalRowsAndFencesOldWriters` — so this fixture
/// cannot hide a trigger that has quietly stopped working. The access-exclusive
/// lock and the toggle are transaction-local: a failure rolls the fixture row and
/// the DDL state back together.
enum HistoricalCompletionPhotoFixture {
    static func insert(completionID: UUID, url: String, on database: Database) async throws {
        try await database.transaction { db in
            let sql=try VerifiedIdentityService.sql(db)
            try await sql.raw("LOCK TABLE completion_photos IN ACCESS EXCLUSIVE MODE").run()
            try await sql.raw("ALTER TABLE completion_photos DISABLE TRIGGER completion_photo_trusted_insert").run()
            try await sql.raw("INSERT INTO completion_photos(id,completion_id,url,uploaded_at) VALUES(\(bind:UUID()),\(bind:completionID),\(bind:url),NOW())").run()
            try await sql.raw("ALTER TABLE completion_photos ENABLE TRIGGER completion_photo_trusted_insert").run()
        }
    }
}
