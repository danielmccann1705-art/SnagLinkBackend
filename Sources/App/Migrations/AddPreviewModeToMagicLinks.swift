import Fluent
import FluentSQL

/// B2: adds preview-link support to magic_links. A preview link is an unsent link the PM can
/// view (via `/preview/{token}`) to see exactly what the contractor will receive. Preview links
/// carry their own 1h TTL and never count against the monthly allowance.
struct AddPreviewModeToMagicLinks: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase

        try await sql.raw("""
            ALTER TABLE magic_links
            ADD COLUMN IF NOT EXISTS preview_mode BOOLEAN NOT NULL DEFAULT FALSE
            """).run()

        try await sql.raw("""
            ALTER TABLE magic_links
            ADD COLUMN IF NOT EXISTS preview_expires_at TIMESTAMPTZ
            """).run()

        // Supports the nightly cleanup scan for expired preview links.
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_magic_links_preview
            ON magic_links(preview_mode, preview_expires_at)
            WHERE preview_mode = TRUE
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("DROP INDEX IF EXISTS idx_magic_links_preview").run()
        try await sql.raw("ALTER TABLE magic_links DROP COLUMN IF EXISTS preview_expires_at").run()
        try await sql.raw("ALTER TABLE magic_links DROP COLUMN IF EXISTS preview_mode").run()
    }
}
