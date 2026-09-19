@testable import App
import Foundation
import Fluent
import FluentSQL

/// Inserts synthetic evidence representing a completion-photo row which existed
/// before trusted upload ownership was introduced. Production writes must always
/// use CompletionUploadObjectService.
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
