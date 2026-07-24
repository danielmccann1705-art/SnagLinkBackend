import Fluent
import FluentSQL

/// B6: remote feature-flag overrides. Absence of a row means "use the env-var default".
struct CreateFeatureFlags: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS feature_flags (
                id UUID PRIMARY KEY,
                key TEXT NOT NULL,
                enabled BOOLEAN NOT NULL,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:feature_flags.key" UNIQUE (key)
            )
            """).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("feature_flags").delete()
    }
}
