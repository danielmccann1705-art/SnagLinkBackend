import Vapor
import Logging
import Foundation

/// Where this process's log output goes — and nothing else about it.
///
/// **What this is for.** The staging container emits nothing into Cloudflare's
/// log store. Every line the store does hold, from the one other container on the
/// account that is collected, looks like standard error: a package manager's exit
/// status, a runtime security warning, a driver deprecation notice. This process
/// writes its log on standard output, because that is where ConsoleKit's
/// `Terminal` writes and `LoggingSystem.bootstrap(from:)` installs a `Terminal`.
/// That correlation is a hypothesis, not a finding, and `LogStreamProbe` is what
/// tests it. This type is what makes the answer actionable without a second
/// image: the stream is chosen at boot from `LOG_STREAM`, so moving the log from
/// one stream to the other is a configuration change and a redeploy, not a build.
///
/// **What it deliberately does not change.** Not one line's text, level or
/// metadata. The handler stays `ConsoleLogger`, the renderer stays
/// `defaultLoggerFragment()`, the level still comes from
/// `Logger.Level.detect(from:)` exactly as Vapor computes it. The only
/// substitution is the `Console` the handler holds, and a `Console` is a
/// destination. B2.1's `kind:` words are fixed strings from closed enums and
/// several tests assert them; nothing here can reach them.
///
/// **Why not redirect the file descriptor.** `dup2(STDERR_FILENO, STDOUT_FILENO)`
/// would also preserve every byte, in one line, and was the first design. It is
/// rejected for one decisive reason: it would destroy the very distinction the
/// probe exists to measure. With standard output dup'd onto standard error there
/// is no longer a standard output to emit a marker on, so the diagnostic and the
/// fix could not live in one image — which is the whole point of building once.
enum LogStreamBoot {

    /// The variable, named once so the refusal, the probe and the tests all spell
    /// it the same way.
    static let variable = "LOG_STREAM"

    /// The two streams a container writes on.
    ///
    /// `stdout` is what this process has always used and is the default, so an
    /// unset `LOG_STREAM` is today's behaviour exactly — byte for byte, because
    /// unset resolves to the same `Terminal` Vapor installs itself.
    enum Stream: String, CaseIterable {
        case standardOutput = "stdout"
        case standardError = "stderr"
    }

    /// The one refusal. Shaped like `SigningSecretBoot.Refusal`: a stable `code`
    /// a runbook keys on and a sentence for whoever is reading the log.
    enum Refusal: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// `LOG_STREAM` is set to something that is not one of the two streams.
        case streamUnknown

        /// The stable identifier. Not a sentence, and not rewritten when the
        /// sentence is.
        var code: String {
            switch self {
            case .streamUnknown: return "log_stream_unknown"
            }
        }

        /// Names the variable and the two words it accepts. Never repeats what it
        /// was given: every boot refusal in this codebase names the variable to
        /// fix and never its contents, and this one is read before
        /// `LoggingSystem.bootstrap` exists, so it is written to standard error
        /// by `Entrypoint.refuseBeforeLogging` where nothing can redact it later.
        var description: String {
            switch self {
            case .streamUnknown:
                return """
                    LOG_STREAM is set to something that is not a stream this process can write on. The \
                    two it accepts are the literal words stdout and stderr. It refuses rather than \
                    falling back, because a deployment that set this variable set it in order to move \
                    the log output, and a silent fallback would leave the output exactly where it was \
                    and say nothing about it.
                    """
            }
        }
        var errorDescription: String? { description }
    }

    /// Reads the selection. Pure and total, so a test can drive every case
    /// without setting a variable this process or any other test shares.
    static func resolve(_ raw: String?) throws -> Stream {
        guard let raw else { return .standardOutput }
        guard let stream = Stream(rawValue: raw) else { throw Refusal.streamUnknown }
        return stream
    }

    /// The console a stream writes on.
    ///
    /// `Terminal` is ConsoleKit's own and is the one
    /// `LoggingSystem.bootstrap(from:)` installs, so the `stdout` case is not a
    /// reimplementation of today's behaviour — it is today's behaviour.
    static func console(for stream: Stream) -> any Console {
        switch stream {
        case .standardOutput: return Terminal()
        case .standardError: return StandardErrorConsole()
        }
    }

    /// Vapor's `LoggingSystem.bootstrap(from:)` with the console substituted and
    /// nothing else touched.
    ///
    /// The level still comes from Vapor's own `Logger.Level.detect(from:)`, via
    /// the public factory overload, rather than being recomputed here — so a
    /// `--log` option, `LOG_LEVEL`, and the production default all keep behaving
    /// as they do today. `configure` then sets `app.logger.logLevel = .info`, and
    /// `Request.logger` is derived from `application.logger`, which is why an
    /// `info` line on a request path is emitted under `--env production`.
    static func bootstrap(from environment: inout Vapor.Environment, stream: Stream) throws {
        let console = console(for: stream)
        try LoggingSystem.bootstrap(from: &environment) { level in
            { label in ConsoleLogger(label: label, console: console, level: level) }
        }
    }
}

/// A `Console` that writes its output where `Terminal` writes its errors.
///
/// `Terminal` is `final`, so this is a sibling rather than a subclass. It is a
/// destination and not a format: the text handed to `output` has already been
/// rendered by the same `defaultLoggerFragment()` pipeline, so the bytes that
/// reach standard error here are the bytes that reach standard output there.
///
/// Plain text, never ANSI. `Terminal` stylizes only when standard output is an
/// interactive terminal, and a container's is not, so in the one place this runs
/// the two produce identical bytes. Run locally in a terminal the log loses
/// colour, which is the entire difference.
final class StandardErrorConsole: Console, @unchecked Sendable {

    private let lock = NSLock()
    private var storedUserInfo: [AnySendableHashable: any Sendable] = [:]

    /// See `Console`.
    var userInfo: [AnySendableHashable: any Sendable] {
        get { lock.lock(); defer { lock.unlock() }; return storedUserInfo }
        set { lock.lock(); defer { lock.unlock() }; storedUserInfo = newValue }
    }

    /// See `Console`. One write per line, under a lock, so that two threads
    /// logging at once cannot interleave halves of a line — `stderr` is unbuffered
    /// and a per-fragment write would be free to do exactly that.
    func output(_ text: ConsoleText, newLine: Bool) {
        let line = newLine ? text.description + "\n" : text.description
        lock.lock()
        defer { lock.unlock() }
        fputs(line, stderr)
        fflush(stderr)
    }

    /// See `Console`. Errors already went to standard error; now so does
    /// everything else, which is the point.
    func report(error: String, newLine: Bool) {
        output(ConsoleText(stringLiteral: error), newLine: newLine)
    }

    /// See `Console`. A log stream has no cursor to move and no screen to erase.
    func clear(_ type: ConsoleClear) {}

    /// See `Console`. A server reads no console input; the protocol documents an
    /// empty string as the answer at end of file, and this is always that.
    func input(isSecure: Bool) -> String { "" }

    /// See `Console`. Only consulted when ANSI commands are enabled, and they
    /// never are here.
    var size: (width: Int, height: Int) { (width: 80, height: 25) }

    /// See `Console`. The default implementation asks whether standard *output*
    /// is a terminal, which is the wrong question for this console.
    var supportsANSICommands: Bool { false }
}
