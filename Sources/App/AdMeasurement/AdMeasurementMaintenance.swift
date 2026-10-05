import Vapor
import Fluent

/// The advert-measurement step of the hourly maintenance pass (`CleanupService.perform`; IOS-2.0.2-SLICE1.md items
/// 14–15): the retention sweep, token expiry, then the Apple exchange.
///
/// - **Retention sweep** (D6, PROPOSED 180 days): runs whatever the switch says.
/// - **Expiry**: rows whose token is older than Apple's 24-hour validity become `expired` and lose the token. Runs
///   whatever the switch says, so a token is never held past its validity even while measurement is switched off.
/// - **Exchange**: only while `adMeasurementEnabled` resolves to `true`, re-checked before every row; at most
///   `exchangeBatch` rows and no new row after `exchangeBudgetSeconds`.
///
/// Isolated like the M1 retention sweeps: it never throws. A step that fails is named in `failed` (by step, never
/// by message) and the rest of the pass carries on. Counts only, never a row, a reference or an identifier.
enum AdMeasurementMaintenance {
    struct Counts: Codable, Sendable, Equatable {
        /// Rows deleted at the end of retention.
        var swept = 0
        /// Rows whose token ran out of validity unexchanged (token dropped).
        var expired = 0
        /// Exchanges by outcome in this pass.
        var exchanged = 0
        var invalid = 0
        var notYet = 0
        var failing = 0
        /// Exchanges whose row was withdrawn while Apple was answering: the result was discarded.
        var discarded = 0
        /// Due rows left for the next pass (batch or budget).
        var deferred = 0
        /// The switch did not resolve to `true`: no request was made to Apple in this pass.
        var exchangePaused = false
        /// Under `.testing` with no transport installed: nothing was sent anywhere.
        var noTransport: Bool? = nil
        /// Steps that failed, by name.
        var failed: [String]? = nil
    }

    static func run(app: Application, on db: Database, now: Date = Date()) async -> Counts {
        var counts = Counts()
        var failed: [String] = []
        do { counts.swept = try await AdAttributionStore.sweep(now: now, on: db) } catch { failed.append("sweep") }
        do { counts.expired = try await AdAttributionStore.expire(now: now, on: db) } catch { failed.append("expire") }
        do { try await exchange(app: app, on: db, now: now, counts: &counts) } catch { failed.append("exchange") }
        if !failed.isEmpty { counts.failed = failed }
        if counts != Counts() {
            app.logger.info("Ad measurement maintenance", metadata: [
                "swept": "\(counts.swept)", "expired": "\(counts.expired)", "exchanged": "\(counts.exchanged)",
                "invalid": "\(counts.invalid)", "notYet": "\(counts.notYet)", "failing": "\(counts.failing)",
                "discarded": "\(counts.discarded)", "deferred": "\(counts.deferred)",
                "paused": "\(counts.exchangePaused)", "failed": .string(failed.joined(separator: ","))])
        }
        return counts
    }

    private static func exchange(app: Application, on db: Database, now: Date, counts: inout Counts) async throws {
        let due = try await AdAttributionStore.due(now: now, limit: AdMeasurementPolicy.exchangeBatch, on: db)
        guard due.total > 0 else { return }
        guard await AdMeasurementPolicy.isEnabled(on: db) else {
            counts.exchangePaused = true
            counts.deferred = due.total
            return
        }
        guard let transport = AppleAttributionExchangeService.transport(app) else {
            counts.noTransport = true
            counts.deferred = due.total
            return
        }
        let sleep = AppleAttributionExchangeService.sleep(app)
        let started = DispatchTime.now().uptimeNanoseconds
        var processed = 0
        for row in due.rows {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
            guard elapsed < AdMeasurementPolicy.exchangeBudgetSeconds else { break }
            // Re-read the switch before every request: a kill reaches the next row, not the next pass.
            guard await AdMeasurementPolicy.isEnabled(on: db) else { counts.exchangePaused = true; break }
            let result = await AppleAttributionExchangeService.exchange(token: row.token, transport: transport, sleep: sleep)
            processed += 1
            let written = try await AdAttributionStore.record(result.outcome, attempts: result.attempts, id: row.id, now: Date(), on: db)
            let state: String
            if !written {
                counts.discarded += 1
                state = "discarded"
            } else {
                switch result.outcome {
                case .attributed: counts.exchanged += 1; state = "done"
                case .invalid: counts.invalid += 1; state = "invalid"
                case .notYetAvailable: counts.notYet += 1; state = "pending"
                case .failing: counts.failing += 1; state = "failing"
                }
            }
            app.logger.info("Ad attribution exchange", metadata: ["state": .string(state), "status": .string(result.status)])
        }
        counts.deferred = due.total - processed
    }
}
