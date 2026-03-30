import Fluent
import FluentSQL

struct AddThumbnailToSyncedPhoto: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("synced_photos")
            .field("thumbnail_file_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("synced_photos")
            .deleteField("thumbnail_file_path")
            .update()
    }
}
