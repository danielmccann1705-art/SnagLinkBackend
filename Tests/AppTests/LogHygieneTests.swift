@testable import App
import XCTVapor

/// U2 log hygiene (FABLE-U1-U2-DESIGN §4), held before production container logs go on with U1's successor. The source scans
/// read this package's own `Sources/App` (next to this file); the middleware and level checks read a configured application.
final class LogHygieneTests: XCTestCase {
    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "the scan has to see the application's sources")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
    private func lines(_ predicate: (String) -> Bool) throws -> [String] {
        try sources().flatMap { file in file.text.split(separator: "\n").enumerated().compactMap { index, line in
            predicate(String(line)) ? "\(file.name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))" : nil } }
    }

    /// A caught error is logged by kind (`LogSafe.kind`: type, status or SQLSTATE), never by its description, which a library
    /// writes and can carry an address, a path or a value. Twelve sites interpolated `\(error)` before U2.
    func testNoLogLineCarriesACaughtErrorsDescription() throws {
        let found = try lines { line in
            (line.contains("logger.") || line.contains(".log(level:")) && (line.contains("\\(error)") || line.contains("localizedDescription"))
        }
        XCTAssertEqual(found, [], "log LogSafe.kind(error) instead")
        let prints = try lines { $0.range(of: #"(^|[^A-Za-z0-9_.])print\("#, options: .regularExpression) != nil }
        XCTAssertEqual(prints, [], "no print() in the application: it bypasses the logger and its level")
    }

    /// A push device token is a partial credential; not even its first characters are logged (four sites before U2).
    func testNoLogLineCarriesAPushDeviceToken() throws {
        // An interpolated token value - `\(deviceToken)`, `\(deviceToken.prefix(8))`, `\(token.deviceToken…)` - not a count of tokens.
        let found = try lines { ($0.contains("logger.") || $0.contains(".log(level:")) &&
            $0.range(of: #"\\\((token\.)?deviceToken(?!s)"#, options: .regularExpression) != nil }
        XCTAssertEqual(found, [])
        XCTAssertNotNil("logger.info(\"x \\(deviceToken.prefix(8))\")".range(of: #"\\\((token\.)?deviceToken(?!s)"#, options: .regularExpression), "the pattern sees a prefix")
        XCTAssertNil("logger.info(\"Found \\(deviceTokens.count) device token(s)\")".range(of: #"\\\((token\.)?deviceToken(?!s)"#, options: .regularExpression), "and not a count")
    }

    /// The dormant audit middleware logged the full request path — a Contractor link token on this product — and the error's
    /// description into the audit table. It was never registered; it is deleted so it cannot be one `use()` away from a leak.
    func testTheDormantAuditLogMiddlewareIsGone() throws {
        let all = try sources()
        XCTAssertFalse(all.contains { $0.name == "AuditLogMiddleware.swift" })
        XCTAssertEqual(all.filter { $0.text.contains("AuditLogMiddleware") }.map(\.name), [])
    }

    /// The middleware stack is exactly CORS and the private request logger (plus the local-storage file server outside the
    /// cloud): Vapor's ErrorMiddleware and RouteLoggingMiddleware, which log URLs and error descriptions, are not installed.
    /// The logger is capped at .info, so query text and bound values (debug/trace in PostgresNIO, Fluent, SQLKit) never log.
    func testTheMiddlewareStackAndTheLogLevelStayPrivate() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            let names = app.middleware.resolve().map { String(describing: type(of: $0)) }
            var expected = ["CORSMiddleware", "PrivateRequestLoggingMiddleware"]
            if StorageService.backend == .local { expected.append("FileMiddleware") }
            XCTAssertEqual(names, expected)
            XCTAssertFalse(names.contains("ErrorMiddleware")); XCTAssertFalse(names.contains("RouteLoggingMiddleware"))
            XCTAssertEqual(app.logger.logLevel, .info)
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    /// The vocabulary itself: a kind, never a message.
    func testLogSafeNamesAKindAndNeverAMessage() {
        struct Leaky: Error, CustomStringConvertible { var description: String { "contractor link c2_SECRET for someone@example.test" } }
        let kind = LogSafe.kind(Leaky())
        XCTAssertFalse(kind.contains("c2_SECRET")); XCTAssertFalse(kind.contains("@")); XCTAssertTrue(kind.hasSuffix("Leaky"))
        XCTAssertEqual(LogSafe.kind(Abort(.notFound, reason: "Contractor link c2_SECRET unavailable")), "Abort(404)")
        XCTAssertEqual(LogSafe.kind(CancellationError()), "CancellationError")
        XCTAssertEqual(DiagnosticFailureRecord.cause(of: nil), "response")
        XCTAssertEqual(DiagnosticFailureRecord.cause(of: Abort(.serviceUnavailable)), "Abort(503)")
    }
}
