import Fluent
import FluentSQL
import Vapor

/// Lane A P0e (Dan, 1 Oct: "identify the error path before treating any retry as the fix"). Staging diagnostics only:
/// one row per 5xx answer on a Contractor-link route (and per answer that succeeded only because the write path retried), written only where `RUNTIME_DIAGNOSTICS=enabled` (which the
/// production adapter refuses), so production never writes a row. Route pattern, status, the answer's identifier, the
/// error's type, the phases the request completed and the write path's notes — fixed vocabulary, never a URL, token,
/// key, message or value. Durable where Workers Logs are not (they keep 3–7 days); staging rows only, no retention sweep yet.
struct CreateDiagnosticRequestFailures: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = try VerifiedIdentityService.sql(database)
        try await sql.raw("""
            CREATE TABLE diagnostic_request_failures (
                id UUID PRIMARY KEY, occurred_at TIMESTAMPTZ NOT NULL, method TEXT NOT NULL, route TEXT NOT NULL,
                status INTEGER NOT NULL CHECK(status >= 200 AND status <= 599), identifier TEXT NOT NULL, cause TEXT NOT NULL,
                phases TEXT NOT NULL, notes TEXT NOT NULL, request_id TEXT, duration_ms INTEGER
            )
            """).run()
        try await sql.raw("CREATE INDEX diagnostic_request_failures_time ON diagnostic_request_failures(occurred_at)").run()
    }
    func revert(on database: Database) async throws {
        try await VerifiedIdentityService.sql(database).raw("DROP TABLE IF EXISTS diagnostic_request_failures").run()
    }
}
