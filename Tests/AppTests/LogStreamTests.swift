import XCTVapor
@testable import App
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the log goes, and the one-run diagnostic that decides where it should.
///
/// The claim these tests exist to hold is narrow and it is the whole constraint:
/// selecting a stream changes the destination and nothing else. Not a line's
/// text, not its level, not its metadata. `testTheStandardErrorConsoleWrites...`
/// is the one that actually settles it — it captures both file descriptors around
/// the same logger call and requires the bytes to be equal.
///
/// Nothing here sets a process environment variable or starts a server. Every
/// value is synthetic and every lookup is handed in.
final class LogStreamTests: XCTestCase {

    // MARK: - Which stream

    /// Unset is today's behaviour, and today's behaviour is ConsoleKit's own
    /// `Terminal` — the very object `LoggingSystem.bootstrap(from:)` installs.
    func testAnUnsetLogStreamIsTodaysBehaviourAndTodaysObject() throws {
        XCTAssertEqual(try LogStreamBoot.resolve(nil), .standardOutput)
        XCTAssertTrue(LogStreamBoot.console(for: .standardOutput) is Terminal,
                      "unset must not be a reimplementation of stdout; it must be the same console")
        XCTAssertTrue(LogStreamBoot.console(for: .standardError) is StandardErrorConsole)
    }

    func testTheTwoStreamsAreTheOnlyTwoWordsAccepted() throws {
        XCTAssertEqual(try LogStreamBoot.resolve("stdout"), .standardOutput)
        XCTAssertEqual(try LogStreamBoot.resolve("stderr"), .standardError)
        for value in ["STDOUT", "stderr ", " stdout", "2", "both", "", "/dev/stderr", "on"] {
            XCTAssertThrowsError(try LogStreamBoot.resolve(value), "\(value) is not a stream") { error in
                XCTAssertEqual(error as? LogStreamBoot.Refusal, .streamUnknown)
            }
        }
    }

    /// The refusal is written to standard error before any logger exists, so what
    /// it says is what an operator gets. It has to name the variable and the two
    /// words, and it must not repeat what it was handed.
    func testTheStreamRefusalNamesTheVariableAndNotItsValue() {
        let refusal = LogStreamBoot.Refusal.streamUnknown
        XCTAssertEqual(refusal.code, "log_stream_unknown")
        XCTAssertTrue(refusal.description.contains("LOG_STREAM"))
        XCTAssertTrue(refusal.description.contains("stdout"))
        XCTAssertTrue(refusal.description.contains("stderr"))
    }

    // MARK: - The claim: a destination, not a format

    /// The same `ConsoleLogger`, the same default renderer, the same level and the
    /// same metadata, rendered through `Terminal` onto standard output and through
    /// `StandardErrorConsole` onto standard error — and the bytes are equal.
    ///
    /// The line is shaped like B2.1's, because B2.1's is the line the B5 gate
    /// reads and several tests assert its words.
    func testTheStandardErrorConsoleWritesTheBytesTerminalWritesOnStandardOutput() throws {
        let metadata: Logger.Metadata = ["kind": .string("created"), "role": .string("original")]

        let onStandardOutput = try Self.capturing(STDOUT_FILENO) {
            let logger = Logger(label: "synthetic") { label in
                ConsoleLogger(label: label, console: Terminal(), level: .info)
            }
            logger.info("Private media write", metadata: metadata)
        }
        let onStandardError = try Self.capturing(STDERR_FILENO) {
            let logger = Logger(label: "synthetic") { label in
                ConsoleLogger(label: label, console: StandardErrorConsole(), level: .info)
            }
            logger.info("Private media write", metadata: metadata)
        }

        XCTAssertEqual(onStandardError, onStandardOutput,
                       "selecting a stream may change where a line goes and nothing about what it says")
        XCTAssertTrue(onStandardError.contains("[ INFO ]"), "the level survives the swap")
        XCTAssertTrue(onStandardError.contains("Private media write"), "the message survives the swap")
        XCTAssertTrue(onStandardError.contains("kind: created"), "B2.1's fixed word survives the swap")
        XCTAssertTrue(onStandardError.contains("role: original"), "the metadata survives the swap")
    }

    /// And the threshold moves with the handler rather than being flattened: a
    /// `notice` handler still drops `info`, on either console, exactly as before.
    func testTheSwapDoesNotFlattenLevels() throws {
        let quiet = try Self.capturing(STDERR_FILENO) {
            let logger = Logger(label: "synthetic") { label in
                ConsoleLogger(label: label, console: StandardErrorConsole(), level: .notice)
            }
            logger.info("Private media write", metadata: ["kind": .string("created")])
            logger.notice("Private media write", metadata: ["kind": .string("created")])
        }
        XCTAssertEqual(quiet.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 1,
                       "a notice handler emits the notice and drops the info, on stderr as on stdout")
        XCTAssertTrue(quiet.contains("[ NOTICE ]"))
    }

    // MARK: - The probe

    func testTheProbeIsAbsentUnlessARunNamesAMarker() throws {
        XCTAssertNil(try LogStreamProbe.resolve(nil))
    }

    /// The alphabet is the point: it is what stops a key, a bearer, a cookie or a
    /// Contractor link token being routed into a log line through this variable.
    func testAProbeMarkerCannotCarryASecret() throws {
        for marker in ["SNAG0921A", "A1B2C3D4", "STREAM-0921-A", String(repeating: "X", count: 48)] {
            XCTAssertEqual(try LogStreamProbe.resolve(marker), marker)
        }
        for marker in ["SHORT7", String(repeating: "Y", count: 49), "-SNAG0921", "SNAG0921-",
                       "SNAG 0921", "c25hZ2xpc3Qtc3ludGhldGlj", "Bearer-abc123",
                       "sid=0123456789abcdef", String(repeating: "A", count: 42) + "="] {
            XCTAssertThrowsError(try LogStreamProbe.resolve(marker), "\(marker) is not a marker") { error in
                XCTAssertEqual(error as? LogStreamProbe.Refusal, .markerMalformed)
            }
        }
        XCTAssertEqual(LogStreamProbe.Refusal.markerMalformed.code, "log_stream_probe_marker_malformed")
        XCTAssertTrue(LogStreamProbe.Refusal.markerMalformed.description.contains("LOG_STREAM_PROBE"))
    }

    /// Three witnesses, one variable between them. If any other part of the marker
    /// moved, a search for one stream's line would not be a search for that stream.
    func testTheThreeWitnessesDifferOnlyInTheStream() {
        let marker = "STREAM-0921-A"
        let witnesses = ["APPLOG", "STDOUT", "STDERR"].map {
            LogStreamProbe.witness(marker, $0, .boot)
        }
        XCTAssertEqual(witnesses, ["SNAGLOGPROBE-STREAM-0921-A-APPLOG-BOOT",
                                   "SNAGLOGPROBE-STREAM-0921-A-STDOUT-BOOT",
                                   "SNAGLOGPROBE-STREAM-0921-A-STDERR-BOOT"])
        XCTAssertEqual(LogStreamProbe.witness(marker, "STDOUT", .request),
                       "SNAGLOGPROBE-STREAM-0921-A-STDOUT-REQUEST")
        for witness in witnesses {
            XCTAssertFalse(witness.contains(" "), "a marker must survive a dashboard as one token")
            XCTAssertTrue(witness.hasPrefix(LogStreamProbe.prefix), "one search has to find the lot")
        }
    }

    /// The emission itself: one line on each stream, each naming its own stream,
    /// with the application's own line kept off both so the capture is unambiguous.
    func testEachStreamCarriesItsOwnWitness() throws {
        let recorder = RecordingConsole()
        let application = Logger(label: "synthetic") { label in
            ConsoleLogger(label: label, console: recorder, level: .info)
        }
        var onStandardError = ""
        let onStandardOutput = try Self.capturing(STDOUT_FILENO) {
            onStandardError = (try? Self.capturing(STDERR_FILENO) {
                LogStreamProbe.emit(.boot, marker: "STREAM-0921-A", through: application)
            }) ?? ""
        }

        XCTAssertTrue(onStandardOutput.contains("SNAGLOGPROBE-STREAM-0921-A-STDOUT-BOOT"))
        XCTAssertFalse(onStandardOutput.contains("-STDERR-"), "the stdout witness must not be on stdout twice")
        XCTAssertTrue(onStandardError.contains("SNAGLOGPROBE-STREAM-0921-A-STDERR-BOOT"))
        XCTAssertFalse(onStandardError.contains("-STDOUT-"))
        XCTAssertEqual(recorder.lines.count, 1)
        XCTAssertTrue(recorder.lines[0].contains("SNAGLOGPROBE-STREAM-0921-A-APPLOG-BOOT"))
        // Same message, same level, same metadata key on all three.
        for line in [onStandardOutput, onStandardError, recorder.lines[0]] {
            XCTAssertTrue(line.contains("[ INFO ]"))
            XCTAssertTrue(line.contains("Log stream probe"))
            XCTAssertTrue(line.contains("marker: SNAGLOGPROBE-"))
        }
    }

    /// Installed or not installed, and the request path reads the same answer the
    /// boot wrote. A deployment that named no marker emits nothing at all.
    func testAnApplicationWithNoMarkerInstallsNothing() async throws {
        let app = try await Application.make(.testing)
        try LogStreamProbe.install(app: app, lookup: { _ in nil })
        XCTAssertNil(app.storage[LogStreamProbe.MarkerKey.self])
        try LogStreamProbe.install(app: app, lookup: { $0 == LogStreamProbe.variable ? "STREAM-0921-A" : nil })
        XCTAssertEqual(app.storage[LogStreamProbe.MarkerKey.self], "STREAM-0921-A")
        try await app.asyncShutdown()
    }

    func testAMalformedMarkerRefusesTheBootRatherThanRunningWithoutTheProbe() async throws {
        let app = try await Application.make(.testing)
        XCTAssertThrowsError(try LogStreamProbe.install(app: app, lookup: { _ in "not a marker" })) { error in
            XCTAssertEqual(error as? LogStreamProbe.Refusal, .markerMalformed)
        }
        XCTAssertNil(app.storage[LogStreamProbe.MarkerKey.self])
        try await app.asyncShutdown()
    }

    // MARK: - Capture

    /// Runs `body` with `descriptor` redirected onto a pipe and returns what was
    /// written to it. Both write ends are closed before the read, so the read ends
    /// at end of file rather than blocking.
    private static func capturing(_ descriptor: Int32, _ body: () -> Void) throws -> String {
        // Flush first: standard output is fully buffered when it is not a
        // terminal, and anything already sitting in that buffer would otherwise be
        // written down the capture pipe and read back as if this call had produced it.
        fflush(stdout)
        fflush(stderr)
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw CaptureFailure.pipeUnavailable }
        let saved = dup(descriptor)
        guard saved >= 0 else { close(ends[0]); close(ends[1]); throw CaptureFailure.pipeUnavailable }
        dup2(ends[1], descriptor)
        body()
        fflush(descriptor == STDOUT_FILENO ? stdout : stderr)
        dup2(saved, descriptor)
        close(saved)
        close(ends[1])
        var captured = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(ends[0], &buffer, buffer.count)
            if count <= 0 { break }
            captured.append(contentsOf: buffer[0..<count])
        }
        close(ends[0])
        return String(decoding: captured, as: UTF8.self)
    }

    private enum CaptureFailure: Error { case pipeUnavailable }
}

/// A `Console` that keeps what it was given instead of writing it anywhere, so a
/// test can read the application's own line without it landing on either stream.
final class RecordingConsole: Console, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var storedUserInfo: [AnySendableHashable: any Sendable] = [:]

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    var userInfo: [AnySendableHashable: any Sendable] {
        get { lock.lock(); defer { lock.unlock() }; return storedUserInfo }
        set { lock.lock(); defer { lock.unlock() }; storedUserInfo = newValue }
    }

    func output(_ text: ConsoleText, newLine: Bool) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(text.description)
    }

    func report(error: String, newLine: Bool) { output(ConsoleText(stringLiteral: error), newLine: newLine) }
    func clear(_ type: ConsoleClear) {}
    func input(isSecure: Bool) -> String { "" }
    var size: (width: Int, height: Int) { (width: 80, height: 25) }
    var supportsANSICommands: Bool { false }
}
