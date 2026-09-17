import Fluent
import FluentSQL
import Vapor

/// The cron-driven route and the in-process fallback loop both recorded themselves as
/// `schedule`, so the record could not say which had run. Telling them apart matters:
/// the whole defect this table exists to answer was "is the scheduler reaching us?",
/// and a record that cannot distinguish the scheduler from the fallback cannot answer it.
struct AllowFallbackCleanupTrigger: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("ALTER TABLE cleanup_runs DROP CONSTRAINT IF EXISTS cleanup_runs_trigger_check").run()
        try await sql.raw("""
            ALTER TABLE cleanup_runs ADD CONSTRAINT cleanup_runs_trigger_check
            CHECK(trigger IN ('schedule', 'fallback', 'manual', 'test'))
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("ALTER TABLE cleanup_runs DROP CONSTRAINT IF EXISTS cleanup_runs_trigger_check").run()
        try await sql.raw("""
            ALTER TABLE cleanup_runs ADD CONSTRAINT cleanup_runs_trigger_check
            CHECK(trigger IN ('schedule', 'manual', 'test'))
            """).run()
    }
}
