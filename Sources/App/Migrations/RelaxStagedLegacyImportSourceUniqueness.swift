import Fluent
import FluentSQL
import Vapor

/// A stopped (aborted) preparation stays retained and immutable, but it must not claim
/// the source forever: the same actor may prepare the same source project again. Only
/// one non-aborted preparation per actor/environment/origin/source/project remains.
struct RelaxStagedLegacyImportSourceUniqueness: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        let rows = try await sql.raw("""
            SELECT c.conname AS name FROM pg_constraint c
            WHERE c.conrelid = 'staged_legacy_imports'::regclass AND c.contype = 'u'
              AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM unnest(c.conkey) k JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k)
                  = ARRAY['actor_id','api_origin','environment','source_fingerprint','source_project_id']
            """).all()
        for row in rows {
            let name = try row.decode(column: "name", as: String.self)
            guard name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { throw Abort(.internalServerError, reason: "Unexpected constraint name") }
            try await sql.raw("ALTER TABLE staged_legacy_imports DROP CONSTRAINT \(unsafeRaw: name)").run()
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS staged_legacy_import_active_source
            ON staged_legacy_imports(actor_id, environment, api_origin, source_fingerprint, source_project_id)
            WHERE state <> 'aborted'
            """).run()
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Retain preparations; roll back to a compatible image")
    }
}
