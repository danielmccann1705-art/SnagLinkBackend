import Vapor
import Fluent

enum CanonicalValueService {
    static let decimalLocale = Locale(identifier: "en_US_POSIX")
    static func decimal(_ value: PlatformJSON) throws -> Decimal? {
        if value == .null { return nil }
        guard case .string(let raw) = value,
              raw.range(of: "^(0|[1-9][0-9]{0,9})(\\.[0-9]{1,6})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: raw, locale: decimalLocale), decimal <= Decimal(1_000_000_000) else {
            throw Abort(.badRequest, reason: "Enter an exact non-negative cost, with up to six decimal places", identifier: "invalid_decimal")
        }
        return decimal
    }
    static func calendarDate(_ value: PlatformJSON) throws -> String? {
        if value == .null { return nil }
        guard case .string(let raw) = value, raw.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Use a calendar date in YYYY-MM-DD format", identifier: "invalid_calendar_date")
        }
        let formatter = dateFormatter(timezone: TimeZone(secondsFromGMT: 0)!)
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            throw Abort(.badRequest, reason: "Choose a valid calendar date", identifier: "invalid_calendar_date")
        }
        return raw
    }
    static func dateFormatter(timezone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = decimalLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
    static func timezone(_ project: Project, on db: Database) async throws -> TimeZone {
        guard let id = project.workspaceId, let workspace = try await Team.find(id, on: db),
              let timezone = TimeZone(identifier: workspace.timezone) else {
            throw Abort(.conflict, reason: "Confirm the workspace timezone before setting deadlines", identifier: "timezone_required")
        }
        return timezone
    }
}
