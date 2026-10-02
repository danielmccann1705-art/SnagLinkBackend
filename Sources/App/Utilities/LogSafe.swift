import Vapor
import FluentPostgresDriver

/// U2 log hygiene (FABLE-U1-U2-DESIGN §4). Once container logs reach the observability store, a line about a caught error
/// says what kind of error it was and nothing else: its type, an HTTP status or a SQLSTATE — a closed, value-free vocabulary.
/// Never the error's description: a library's text (an email provider's, a decoder's, a process launcher's) is not ours to
/// predict and can echo an address, a path or a value. The staging failure record uses the same words.
enum LogSafe {
    static func kind(_ error: any Error) -> String {
        if let psql = error as? PSQLError { return "PSQLError(" + (psql.serverInfo?[.sqlState] ?? "\(psql.code)") + ")" }
        if error is CancellationError { return "CancellationError" }
        if let abort = error as? AbortError { return "Abort(\(abort.status.code))" }
        return String(reflecting: type(of: error))
    }
}
