import Vapor
import Logging

/// The controlled diagnostic that decides which stream Cloudflare collects.
///
/// **The question.** Over six hours the account's `containers` dataset held 1,025
/// events and every one of them came from a different container application; none
/// came from ours, and a driven probe at a known minute produced five expected
/// lines that never appeared. Every line that *does* appear looks like standard
/// error. Our log goes to standard output. That is one correlation and it is not
/// a finding, so this emits a fixed marker on both streams at once and lets the
/// store say which of them it kept.
///
/// **Why it is decisive in one build.** Three witnesses go out at each moment,
/// and they differ in exactly one thing: the stream that carries them.
///
/// * `…-STDOUT-…` is written through a logger pinned to ConsoleKit's `Terminal`,
///   which writes on standard output whatever `LOG_STREAM` says.
/// * `…-STDERR-…` is written through a logger pinned to `StandardErrorConsole`,
///   the same `ConsoleLogger`, the same `defaultLoggerFragment()`, the same
///   `info` level and the same metadata shape — one different destination.
/// * `…-APPLOG-…` is written through the application's or the request's own
///   logger, the one every real line uses, so the run also says whether the real
///   path works end to end rather than only whether a stream is collected.
///
/// The three markers are spelled apart rather than being one identical string on
/// three paths. Identical text would be decisive only if the store recorded which
/// stream a line arrived on, and we cannot read the store to find out. Spelling
/// the stream into the marker makes a single line in a dashboard answer the
/// question by itself, and costs nothing: everything else about the three lines
/// is held equal.
///
/// **Why both a boot and a request.** They are different moments in a container's
/// life and either could be the one that is not collected — a boot line is
/// written by the process before it serves anything, a request line while it is
/// serving. B5's three assertions are all request lines.
///
/// **Why it is off unless asked for.** `LOG_STREAM_PROBE` carries the marker, so
/// the probe ships in the image inert and a run is switched on by a Worker
/// deploy. A second run with a fresh marker needs no second image, which is the
/// whole point.
enum LogStreamProbe {

    /// The variable, named once.
    static let variable = "LOG_STREAM_PROBE"

    /// The fixed prefix every marker starts with, so one search finds the lot.
    static let prefix = "SNAGLOGPROBE"

    /// The one refusal, shaped like its siblings.
    enum Refusal: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// `LOG_STREAM_PROBE` is set to something that is not a marker.
        case markerMalformed

        var code: String {
            switch self {
            case .markerMalformed: return "log_stream_probe_marker_malformed"
            }
        }

        /// Names the variable and the shape it accepts, never what it was given.
        /// The alphabet is part of the refusal on purpose: it is the reason a
        /// secret cannot be smuggled into a log line through this variable.
        var description: String {
            switch self {
            case .markerMalformed:
                return """
                    LOG_STREAM_PROBE is set to something that is not a probe marker. A marker is 8 to \
                    48 characters of A-Z, 0-9 and the hyphen, beginning and ending with a letter or a \
                    digit. It refuses rather than running without the probe, because a diagnostic that \
                    silently does not run costs a whole deploy cycle to discover.
                    """
            }
        }
        var errorDescription: String? { description }
    }

    /// The two moments. Spelled in the marker, so a search can separate them.
    enum Moment: String {
        case boot = "BOOT"
        case request = "REQUEST"
    }

    /// Where the resolved marker lives for the request path to read. Application
    /// storage rather than a global, so a test can install one into its own
    /// `Application` and nothing leaks between tests.
    struct MarkerKey: StorageKey {
        typealias Value = String
    }

    /// Reads the marker. Pure, so a test can drive every case.
    ///
    /// The alphabet is uppercase letters, digits and the hyphen. That is narrow
    /// enough that no base64 key, bearer, cookie or Contractor link token can
    /// pass through it — every one of those carries lowercase or one of `+/=` —
    /// which matters because this value is written into a log line verbatim.
    static func resolve(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.count >= 8, raw.count <= 48,
              raw.allSatisfy({ $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber || $0 == "-") }),
              raw.first != "-", raw.last != "-" else {
            throw Refusal.markerMalformed
        }
        return raw
    }

    /// Resolves the marker and, if there is one, emits the boot witnesses.
    ///
    /// Called by `configure` after the two boot gates, never before them: those
    /// two are the first things a boot decides and a test holds them there.
    static func install(app: Application, lookup: (String) -> String? = Environment.get) throws {
        guard let marker = try resolve(lookup(variable)) else { return }
        app.storage[MarkerKey.self] = marker
        emit(.boot, marker: marker, through: app.logger)
    }

    /// The request witnesses. A no-op when no marker is installed, which is every
    /// deployment that did not ask for a probe.
    ///
    /// It takes the request's own logger on purpose: `Request.logger` is derived
    /// from `application.logger`, and it is the logger every line B5 has to see —
    /// `Private media write`, `Private media read` — is written through.
    static func emitRequest(_ req: Request) {
        guard let marker = req.application.storage[MarkerKey.self] else { return }
        emit(.request, marker: marker, through: req.logger)
    }

    /// The three witnesses. One message, one level, one metadata key; the stream
    /// is the only thing that varies, and it is named in the value.
    static func emit(_ moment: Moment, marker: String, through logger: Logger) {
        logger.info(message, metadata: ["marker": .string(witness(marker, "APPLOG", moment))])
        standardOutputLogger.info(message, metadata: ["marker": .string(witness(marker, "STDOUT", moment))])
        standardErrorLogger.info(message, metadata: ["marker": .string(witness(marker, "STDERR", moment))])
    }

    /// `SNAGLOGPROBE-<marker>-<stream>-<moment>`. One token, no spaces, so it
    /// survives whatever a dashboard does to a line and a plain substring search
    /// finds it.
    static func witness(_ marker: String, _ stream: String, _ moment: Moment) -> String {
        "\(prefix)-\(marker)-\(stream)-\(moment.rawValue)"
    }

    /// The one message a probe line carries, fixed here.
    private static let message: Logger.Message = "Log stream probe"

    /// Pinned to standard output regardless of `LOG_STREAM`, and to `info`
    /// regardless of `LOG_LEVEL` or the production default, so that neither the
    /// stream selection nor the level can be what makes a witness go missing.
    private static let standardOutputLogger = Logger(label: "codes.snaglist.log-stream-probe.stdout") { label in
        ConsoleLogger(label: label, console: Terminal(), level: .info)
    }

    /// Pinned to standard error, and identical in every other particular.
    private static let standardErrorLogger = Logger(label: "codes.snaglist.log-stream-probe.stderr") { label in
        ConsoleLogger(label: label, console: StandardErrorConsole(), level: .info)
    }
}
