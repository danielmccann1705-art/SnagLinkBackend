import Vapor
import Fluent
import FluentSQL
import NIOCore

/// The database connection pool (wave 3, 28 Sep 2026: staging served about one register
/// read a second whatever the concurrency, with exactly one busy connection observed in
/// `pg_stat_activity`). Vapor's default is one connection per event loop, and a `basic`
/// container has one event loop, so every request queued behind one connection.
///
/// `DATABASE_MAX_CONNECTIONS` is the total wanted across the event loops (1...16). Absent or
/// invalid, the pool stays exactly as before: one connection per event loop. Migrations are
/// unaffected — `autoMigrate` runs once, at boot, before the server accepts a request, in the
/// one container the Worker addresses by a single Durable Object name.
struct DatabasePool: Sendable, Equatable {
    static let variable = "DATABASE_MAX_CONNECTIONS"
    static let ceiling = 16
    let requested: Int?
    let invalid: Bool
    let eventLoops: Int
    let perEventLoop: Int
    var total: Int { perEventLoop * eventLoops }

    static func settings(requested raw: String?, eventLoops: Int) -> DatabasePool {
        let loops = max(1, eventLoops)
        guard let raw else { return .init(requested: nil, invalid: false, eventLoops: loops, perEventLoop: 1) }
        guard let value = Int(raw), (1...ceiling).contains(value) else {
            return .init(requested: nil, invalid: true, eventLoops: loops, perEventLoop: 1)
        }
        return .init(requested: value, invalid: false, eventLoops: loops, perEventLoop: max(1, value / loops))
    }

    static func eventLoopCount(_ group: any EventLoopGroup) -> Int {
        var iterator = group.makeIterator(), count = 0
        while iterator.next() != nil { count += 1 }
        return count
    }

    struct Key: StorageKey { typealias Value = DatabasePool }
}

/// Numbers about the running container, for confirming a capacity limit at runtime rather
/// than from source: CPU and memory as the container's cgroup reports them, the pool, and
/// database round trips. Numbers only — no host name, address, path, variable value or id.
struct RuntimeFacts: Content, Equatable {
    let cpuCount: Int
    let eventLoops: Int
    let databasePoolPerEventLoop: Int
    let databasePoolTotal: Int
    let databasePoolRequested: Int?
    let databasePoolRequestInvalid: Bool
    /// cgroup `cpu.max` quota / period (0.25 for a quarter of a CPU); nil when unlimited or unreadable.
    let cpuLimit: Double?
    /// cgroup `cpu.stat` usage, else this process's user + system time.
    let cpuUsageSeconds: Double?
    let cpuThrottledSeconds: Double?
    let cpuThrottledPeriods: Int?
    let cpuPeriods: Int?
    let memoryLimitBytes: Int?
    let memoryCurrentBytes: Int?
    let residentBytes: Int?
    let uptimeSeconds: Double
    /// Time to obtain a pooled connection (includes waiting behind busy ones); nil when the
    /// caller already held one.
    let databaseAcquireMs: Double?
    /// `SELECT 1` five times on one held connection: the network round trip to the database.
    let databaseRoundTripMs: [Double]
}

enum RuntimeDiagnostics {
    /// `enabled` registers `GET /api/v2/runtime/diagnostics` for signed-in users. The staging
    /// adapter maps it; the production adapter refuses it, so production never serves it.
    static let variable = "RUNTIME_DIAGNOSTICS"
    struct BootKey: StorageKey { typealias Value = Date }

    static func facts(app: Application, pinned: (any Database)? = nil) async throws -> RuntimeFacts {
        let measured: (Double?, [Double])
        if let pinned {
            measured = (nil, try await roundTrips(on: pinned))
        } else {
            let asked = Date()
            measured = try await app.db.withConnection { connection -> (Double?, [Double]) in
                let waited = Date().timeIntervalSince(asked) * 1000
                return (waited, try await roundTrips(on: connection))
            }
        }
        let acquire = measured.0, trips = measured.1
        let pool = app.storage[DatabasePool.Key.self] ?? .settings(requested: nil, eventLoops: DatabasePool.eventLoopCount(app.eventLoopGroup))
        let stat = keyed(read("/sys/fs/cgroup/cpu.stat"))
        let usage = stat["usage_usec"].map { Double($0) / 1_000_000 } ?? processCPUSeconds()
        return RuntimeFacts(
            cpuCount: NIOCore.System.coreCount, eventLoops: pool.eventLoops,
            databasePoolPerEventLoop: pool.perEventLoop, databasePoolTotal: pool.total,
            databasePoolRequested: pool.requested, databasePoolRequestInvalid: pool.invalid,
            cpuLimit: cpuLimit(read("/sys/fs/cgroup/cpu.max")),
            cpuUsageSeconds: usage.map(round3),
            cpuThrottledSeconds: stat["throttled_usec"].map { round3(Double($0) / 1_000_000) },
            cpuThrottledPeriods: stat["nr_throttled"], cpuPeriods: stat["nr_periods"],
            memoryLimitBytes: read("/sys/fs/cgroup/memory.max").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            memoryCurrentBytes: read("/sys/fs/cgroup/memory.current").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            residentBytes: residentBytes(),
            uptimeSeconds: round3(Date().timeIntervalSince(app.storage[BootKey.self] ?? Date())),
            databaseAcquireMs: acquire.map(round3), databaseRoundTripMs: trips.map(round3))
    }

    static func roundTrips(on db: any Database, count: Int = 5) async throws -> [Double] {
        let sql = try VerifiedIdentityService.sql(db)
        var trips: [Double] = []
        for _ in 0..<count {
            let started = Date()
            try await sql.raw("SELECT 1").run()
            trips.append(Date().timeIntervalSince(started) * 1000)
        }
        return trips
    }

    // MARK: - Reading the container's own numbers (Linux; nil elsewhere)

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    static func keyed(_ text: String?) -> [String: Int] {
        var values: [String: Int] = [:]
        for line in (text ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let value = Int(parts[1]) { values[String(parts[0])] = value }
        }
        return values
    }

    /// `"25000 100000"` → 0.25; `"max 100000"` → nil (unlimited).
    static func cpuLimit(_ text: String?) -> Double? {
        let parts = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, let quota = Double(parts[0]), let period = Double(parts[1]), period > 0 else { return nil }
        return round3(quota / period)
    }

    /// `/proc/self/stat` user + system time, in clock ticks of 1/100 s (Linux's fixed USER_HZ).
    static func processCPUSeconds() -> Double? {
        guard let text = read("/proc/self/stat"), let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let user = Double(fields[11]), let system = Double(fields[12]) else { return nil }
        return (user + system) / 100
    }

    static func residentBytes() -> Int? {
        guard let text = read("/proc/self/status") else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let kilobytes = Int(parts[1]) { return kilobytes * 1024 }
        }
        return nil
    }

    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// Staging-only: the numbers above for a signed-in user, so a load test can read CPU,
/// memory, the pool and database round trips before and after it runs.
struct RuntimeDiagnosticsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "v2", "runtime").grouped(PlatformAuthMiddleware()).get("diagnostics") { req async throws -> Response in
            _ = try req.requireAuthenticatedUserId()
            let response = try await RuntimeDiagnostics.facts(app: req.application).encodeResponse(for: req)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}
