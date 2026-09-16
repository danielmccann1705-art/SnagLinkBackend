import Fluent
import FluentSQL
import Vapor

/// A record that cleanup ran.
///
/// Its absence is why "has the 90-day audit retention ever been enforced?" could not be
/// answered: the service existed, was never reachable, and left no trace either way.
/// Counts and classifications only — never an identifier, an address or an error message.
struct CreateCleanupRuns: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS cleanup_runs (
                id UUID PRIMARY KEY,
                trigger TEXT NOT NULL CHECK(trigger IN ('schedule', 'manual', 'test')),
                started_at TIMESTAMPTZ NOT NULL,
                finished_at TIMESTAMPTZ,
                state TEXT NOT NULL CHECK(state IN ('running', 'succeeded', 'failed', 'skipped')),
                duration_ms INTEGER,
                removed_json TEXT,
                error_kind TEXT
            )
            """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS cleanup_runs_recent ON cleanup_runs(started_at DESC)").run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("DROP TABLE IF EXISTS cleanup_runs").run()
    }
}
