import Fluent
import SQLKit
import Vapor

/// The one transaction strategy every part of a deletion job uses.
///
/// There are two kinds of handle in this flow and they need opposite treatment.
/// An ordinary pooled handle takes `Database.transaction`. `CleanupService` holds
/// one pinned `withConnection` handle for the whole maintenance pass, and Fluent
/// marks that handle `inTransaction == true` without ever having issued a BEGIN —
/// so `Database.transaction` on it would nest, and a `guard !db.inTransaction`
/// would refuse it outright. That refusal is exactly why the fence service could
/// not be reached from the maintenance path at all.
///
/// Neither branch may take a second connection. The pool is one connection wide in
/// the tested configuration, and a nested checkout is the starvation defect this
/// code already has a regression for.
enum AccountDeletionTransaction {

    /// Runs `body` in a transaction chosen by `mode`, and never opens a second one.
    ///
    /// This helper does not decide who may call it. A caller that must refuse an
    /// already-open transaction keeps its own `guard` and its own error, so no
    /// existing refusal changes shape; what this removes is the need for each of
    /// them to reimplement BEGIN, COMMIT and ROLLBACK for the pinned handle.
    static func run<T: Sendable>(_ mode: AccountDeletionWorker.TransactionMode, on db: Database,
                                 _ body: @escaping @Sendable (Database) async throws -> T) async throws -> T {
        switch mode {
        case .managed:
            return try await db.transaction(body)
        case .maintenanceConnection:
            // Exclusively owned by CleanupService and never entered from inside
            // another transaction. BEGIN and COMMIT are explicit because Fluent
            // will not issue them for this handle.
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("BEGIN").run()
            do {
                let result = try await body(db)
                try await sql.raw("COMMIT").run()
                return result
            } catch {
                try await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}
