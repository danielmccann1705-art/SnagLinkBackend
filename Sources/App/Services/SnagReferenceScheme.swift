import Vapor
import Fluent

/// A register keeps one numbering scheme.
///
/// Snags imported from the old app arrive with the references they already carry on site
/// and in the client's correspondence, and those are never renumbered. A snag logged here
/// afterwards used to be given "SL<n>" from this project's own counter, so a register read
/// WC-015-001, WC-015-002, WC-015-003, SL4 — two schemes side by side, which reads as a
/// fault to anyone looking at it even though nothing underneath is wrong.
///
/// A new snag now continues the shape the register already uses, when the register has one.
struct SnagReferenceScheme: Sendable, Equatable {
    let prefix: String
    /// Zero padding the register uses, or 0 where its references disagree about width.
    let width: Int
    /// The highest number already used in this shape.
    let highest: Int64

    /// The shape a strict majority of the references share. A register with no clear
    /// majority — mixed prefixes, free-text references, an even split — has no shape, and
    /// its new snags keep the project counter's own "SL<n>".
    init?(references: [String]) {
        var groups: [String: (width: Set<Int>, highest: Int64, count: Int)] = [:]
        var considered = 0
        for value in references where !value.isEmpty {
            let digits = String(value.reversed().prefix(while: \.isNumber).reversed())
            guard !digits.isEmpty, digits.count <= 12, let parsed = Int64(digits) else { continue }
            considered += 1
            let prefix = String(value.dropLast(digits.count))
            var group = groups[prefix] ?? (width: [], highest: 0, count: 0)
            group.width.insert(digits.count)
            group.highest = max(group.highest, parsed)
            group.count += 1
            groups[prefix] = group
        }
        guard considered > 0, let winner = groups.max(by: { $0.value.count < $1.value.count }),
              winner.value.count * 2 > references.count,
              groups.filter({ $0.value.count == winner.value.count }).count == 1 else { return nil }
        prefix = winner.key
        width = winner.value.width.count == 1 ? (winner.value.width.first ?? 0) : 0
        highest = winner.value.highest
    }

    func reference(_ number: Int64) -> String {
        let digits = String(number)
        guard digits.count < width else { return prefix + digits }
        return prefix + String(repeating: "0", count: width - digits.count) + digits
    }

    /// The reference for a new snag in this project. `number` is the project counter's next
    /// value, which is what keeps a register created entirely here numbering as it always has.
    /// A reference already used — including one retained for an imported snag that was
    /// deleted, which must never be recycled — is skipped rather than reused.
    static func next(number: Int64, projectID: UUID, on db: Database) async throws -> String {
        let fallback = "SL\(number)"
        let sql = try VerifiedIdentityService.sql(db)
        let existing = try await sql.raw("SELECT reference FROM snags WHERE project_id = \(bind: projectID)")
            .all().map { try $0.decode(column: "reference", as: String.self) }
        guard let scheme = SnagReferenceScheme(references: existing) else { return fallback }
        var taken = Set(existing)
        for row in try await sql.raw("SELECT reference FROM imported_snag_deletions WHERE project_id = \(bind: projectID)").all() {
            taken.insert(try row.decode(column: "reference", as: String.self))
        }
        var candidate = max(number, scheme.highest + 1)
        for _ in 0..<1_000 {
            let value = scheme.reference(candidate)
            if !taken.contains(value) { return value }
            candidate += 1
        }
        return fallback
    }
}
