import Vapor
import Fluent
import Foundation

/// Staging-only phase timing for the Contractor link upload routes (Lane A, P0, 1 Oct 2026).
///
/// A recorder is installed for one request with `ServerTiming.respond`; code below it calls
/// `ServerTiming.measure(name)`, which is a plain call when no recorder is installed. The
/// response then carries `Server-Timing: name;dur=ms, …` with fixed phase names and durations
/// only — never keys, buckets, tokens, grant or asset ids, or anything about the image.
///
/// It is switched on only where `RUNTIME_DIAGNOSTICS` is `enabled`, which the staging adapter
/// maps and the production adapter refuses, so production never installs a recorder.
final class ServerTiming: @unchecked Sendable {
    @TaskLocal static var current: ServerTiming?

    private let lock = NSLock()
    private var phases: [(name: String, ms: Double)] = []
    /// SQL statements this request issued (WP2 profiling): a count, nothing about any statement.
    private var statements = 0
    func countStatement() { lock.lock(); statements += 1; lock.unlock() }

    static var enabled: Bool { Environment.get(RuntimeDiagnostics.variable) == "enabled" }

    /// Runs `body`, recording its duration under `name` when a recorder is installed.
    static func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        guard let recorder = current else { return try await body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { recorder.add(name, Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) }
        return try await body()
    }

    /// The same recorder, reachable through the request: work inside a database transaction closure runs in a new task
    /// (the task-local recorder is not inherited there), so code that holds the request measures through it.
    struct RecorderKey: StorageKey { typealias Value = ServerTiming }
    static func measure<T>(_ req: Request, _ name: String, _ body: () async throws -> T) async rethrows -> T {
        guard let recorder = current ?? req.storage[RecorderKey.self] else { return try await body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { recorder.add(name, Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) }
        return try await body()
    }

    /// Staging only: `db` with every statement issued through it counted into this request's recorder (WP2
    /// profiling: `sql;desc="N"`, the statements of the transaction body, BEGIN/COMMIT not included); `db` itself when
    /// no recorder is installed, which is always the case in production.
    static func counting(_ db: any Database, _ req: Request) -> any Database {
        guard let recorder = current ?? req.storage[RecorderKey.self] else { return db }
        return StatementCountingDatabase.wrap(db) { _ in recorder.countStatement() }
    }

    func add(_ name: String, _ ms: Double) { lock.lock(); phases.append((name, ms)); lock.unlock() }

    /// Phase list in order. A name seen again is numbered (`intent`, `intent_2`) unless
    /// `rename` gives it a fixed name.
    func header(rename: [String: String], total: Double, cold: Bool) -> String {
        lock.lock(); let recorded = phases, statements = self.statements; lock.unlock()
        var seen: [String: Int] = [:]
        var parts: [String] = []
        for phase in recorded {
            let count = (seen[phase.name] ?? 0) + 1; seen[phase.name] = count
            let numbered = count == 1 ? phase.name : "\(phase.name)_\(count)"
            parts.append("\(rename[numbered] ?? numbered);dur=\(String(format: "%.1f", phase.ms))")
        }
        parts.append("total;dur=\(String(format: "%.1f", total))")
        if statements > 0 { parts.append("sql;desc=\"\(statements)\"") }
        if cold { parts.append("cold") }
        return parts.joined(separator: ", ")
    }

    /// Encodes `body`'s result exactly as the route did before and, on staging only, adds the
    /// `Server-Timing` header. Errors propagate unchanged (no header on an error answer).
    static func respond<T: AsyncResponseEncodable>(_ req: Request, rename: [String: String] = [:],
                                                   _ body: @escaping () async throws -> T) async throws -> Response {
        guard enabled else { return try await body().encodeResponse(for: req) }
        let recorder = ServerTiming()
        req.storage[RecorderKey.self] = recorder
        let start = DispatchTime.now().uptimeNanoseconds
        let response = try await $current.withValue(recorder) { try await body().encodeResponse(for: req) }
        let total = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        let booted = req.application.storage[RuntimeDiagnostics.BootKey.self]
        let cold = booted.map { Date().timeIntervalSince($0) < 60 } ?? false
        response.headers.replaceOrAdd(name: "Server-Timing", value: recorder.header(rename: rename, total: total, cold: cold))
        return response
    }
}

