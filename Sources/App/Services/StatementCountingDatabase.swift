import Vapor
import Fluent
import FluentSQL

/// Staging diagnostics and tests only (Lane A WP2 profiling): a database handle that forwards every call to `base`
/// unchanged and reports each statement issued through it — raw SQL by its text, a Fluent query by its action and
/// schema. Nothing is changed, retried or reordered; a transaction or connection opened through it yields another
/// counting handle over the same connection.
///
/// Why not count the "Executing query" log lines: inside a transaction PostgresKit logs through the pooled
/// connection's own logger, fixed when the connection was made, so a request's logger never sees those statements.
struct StatementCountingDatabase: Database, SQLDatabase {
    let base: any Database
    let sql: any SQLDatabase
    let report: @Sendable (String) -> Void

    /// `db` itself when it is not an SQL database (never the case for this app's PostgreSQL handles).
    static func wrap(_ db: any Database, report: @escaping @Sendable (String) -> Void) -> any Database {
        guard let sql = db as? any SQLDatabase else { return db }
        return StatementCountingDatabase(base: db, sql: sql, report: report)
    }

    // MARK: Database
    var context: DatabaseContext { base.context }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        report("fluent \(query.action) \(query.schema)")
        return base.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { report("schema"); return base.execute(schema: schema) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { report("enum"); return base.execute(enum: `enum`) }
    var inTransaction: Bool { base.inTransaction }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let report = self.report
        return base.transaction { closure(StatementCountingDatabase.wrap($0, report: report)) }
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let report = self.report
        return base.withConnection { closure(StatementCountingDatabase.wrap($0, report: report)) }
    }

    // MARK: SQLDatabase
    var logger: Logger { sql.logger }
    var eventLoop: any EventLoop { sql.eventLoop }
    var version: (any SQLDatabaseReportedVersion)? { sql.version }
    var dialect: any SQLDialect { sql.dialect }
    var queryLogLevel: Logger.Level? { sql.queryLogLevel }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> ()) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(database: sql)
        query.serialize(to: &serializer)
        report(serializer.sql)
        return sql.execute(sql: query, onRow)
    }
}
