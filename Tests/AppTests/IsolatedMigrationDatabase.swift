@testable import App
import XCTVapor
import Fluent
import FluentPostgresDriver
import FluentSQL

/// Use a real pool with a per-connection schema configuration. Fluent's pinned
/// withConnection handle reports inTransaction=true without issuing BEGIN, so
/// passing that handle to a migration would bypass its transaction entirely.
enum IsolatedMigrationDatabase {
    static func withSchema(app: Application, schema: String,
                           body: @escaping @Sendable (Database) async throws -> Void) async throws {
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("CREATE SCHEMA \(ident: schema)").run()
        let database = try pool(app: app, schema: schema)
        do {
            // No outer transaction: the migration itself must establish atomicity.
            XCTAssertFalse(database.inTransaction)
            try await body(database)
            try await sql.raw("DROP SCHEMA \(ident: schema) CASCADE").run()
        } catch {
            try? await sql.raw("DROP SCHEMA \(ident: schema) CASCADE").run()
            throw error
        }
    }
    static func pool(app: Application, schema: String) throws -> Database {
        let url = try XCTUnwrap(Environment.get("DATABASE_URL"))
        var configuration = try SQLPostgresConfiguration(url: url)
        if Environment.get("DATABASE_TLS_DISABLE") == "true" {
            configuration.coreConfiguration.tls = .disable
        }
        configuration.searchPath = [schema]
        let id = DatabaseID(string: "isolated-" + UUID().uuidString)
        app.databases.use(.postgres(configuration: configuration), as: id)
        return app.db(id)
    }

}
