import Vapor
import Fluent

/// The PLOT 10-state snag status model (B3). The `snags.status` column is free TEXT, so this is a
/// validation/normalization layer, not a stored enum type — no migration required.
enum SnagStatus: String, Codable, CaseIterable {
    case draft
    case open
    case sent
    case opened
    case cold
    case submitted
    case awaitingApproval
    case approved
    case sentBack
    case overdue

    /// Legacy (pre-redesign 5-state) iOS raw values, mapped to their new-model equivalents.
    private static let legacyMap: [String: SnagStatus] = [
        "inProgress": .sent,
        "readyForInspection": .submitted,
        "closed": .approved,
        "rejected": .sentBack,
    ]

    /// Normalizes an incoming status string to the canonical stored value.
    /// - Legacy 5-state values are remapped (inProgress→sent, readyForInspection→submitted,
    ///   closed→approved, rejected→sentBack).
    /// - New 10-state values pass through unchanged.
    /// - Any other string (e.g. the web/completion flow's own vocabulary) passes through
    ///   unchanged, preserving backwards compatibility — the column accepts any string.
    static func normalize(_ raw: String) -> String {
        if let mapped = legacyMap[raw] { return mapped.rawValue }
        return raw
    }

    static func isApproved(_ raw: String) -> Bool {
        ["approved", "resolved", "verified"].contains(normalize(raw))
    }

    static func needsWork(_ raw: String) -> Bool {
        ["draft", "open", "sentBack", "overdue"].contains(normalize(raw))
    }

    static func isInProgressOrReview(_ raw: String) -> Bool {
        !isApproved(raw) && !needsWork(raw)
    }

    static func contractorCanSubmit(_ raw: String) -> Bool {
        ["open", "sent", "opened", "cold", "overdue", "in_progress", "sentBack"].contains(normalize(raw))
    }

    static func reportTitle(_ raw: String) -> String {
        switch normalize(raw) {
        case "approved", "resolved", "verified": return "Approved"
        case "submitted", "complete", "completed": return "Submitted for review"
        case "awaitingApproval": return "Awaiting approval"
        case "sentBack": return "Sent back"
        case "in_progress": return "In progress"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `cold` and `overdue` are derived at read time, never written to the database.
    /// `overdue` is fully derivable server-side; `cold` requires a magic-link "sent" timestamp
    /// that the server `Snag` model does not track, so cold remains client-derived only (the
    /// client derives both at read time — see F2).
    static func isOverdue(dueDate: Date?, status: String, now: Date = Date()) -> Bool {
        guard let dueDate = dueDate else { return false }
        return dueDate < now && status != SnagStatus.approved.rawValue
    }
}

extension Snag {
    /// True when past due and not yet approved. Derived (not stored) — see `SnagStatus`.
    var isOverdue: Bool {
        SnagStatus.isOverdue(dueDate: dueDate, status: status)
    }
}
