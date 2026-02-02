import Fluent
import FluentSQL

struct AddSlugToMagicLink: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Add slug column
        try await sql.raw("""
            ALTER TABLE magic_links
            ADD COLUMN IF NOT EXISTS slug TEXT
            """).run()

        // Add unique constraint on slug (allowing NULLs)
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_magic_links_slug
            ON magic_links(slug)
            WHERE slug IS NOT NULL
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase

        // Drop the unique index
        try await sql.raw("DROP INDEX IF EXISTS idx_magic_links_slug").run()

        // Drop the column
        try await sql.raw("ALTER TABLE magic_links DROP COLUMN IF EXISTS slug").run()
    }
}
