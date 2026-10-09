@testable import App
import XCTVapor
import Fluent
import FluentSQL
import CoreFoundation

// L7 real-transport harness for PostHog erasure (POSTHOG-DELAYED-INGESTION-OCT9.md, "L7 harness").
//
// Runs the real backend paths: the consent API, the relay (`POST /api/v2/measurement/events`),
// the outbox dispatcher, withdrawal with its dispatch barrier, and the PostHog erasure worker
// with both verification passes. They talk through the real HTTP clients
// (`MeasurementDirectHTTPClient`, `PostHogErasureHTTPClient`) behind a guarded router:
// - dry run (default): every request goes to the local fake PostHog
//   (scripts/posthog_l7_fake_server.py) on 127.0.0.1;
// - live (Dan's concrete approval, Codex operating): the same requests go unchanged to
//   EU sandbox project 298161 and nowhere else.
// Only the scripts/run-posthog-l7-harness.sh wrapper opts in. Nothing here is compiled into App.

/// Run-time guard. Every check runs before the first request of any kind.
struct PostHogL7Guard: Sendable {
    enum Mode: String, Sendable, Codable { case dryRun = "dry-run", live }
    enum LateCapture: String, Sendable, Codable { case afterPassOne = "after-pass-1", afterRequest = "after-request" }
    struct Refusal: Error, CustomStringConvertible, Sendable {
        let description: String
        init(_ description: String) { self.description = description }
    }
    struct Secrets: Sendable { let captureToken: String; let apiKey: String }

    static let sandboxProjectID = "298161"
    static let captureHost = "https://eu.i.posthog.com"
    static let captureURL = "https://eu.i.posthog.com/capture/"
    static let apiHost = "https://eu.posthog.com"
    static let apiPrefix = "https://eu.posthog.com/api/projects/298161/"

    let mode: Mode
    let subjectPrefix: String
    let erasureKeyFile: String
    let captureConfigFile: String
    let fakeBase: String?
    let liveApproval: String?
    let operatorName: String
    let outputDirectory: String
    let reportName: String
    let window: TimeInterval
    let realWait: TimeInterval
    let poll: TimeInterval
    let observationPoll: TimeInterval
    let ingestTimeout: TimeInterval
    let maxRun: TimeInterval
    let maxDeletionWait: TimeInterval
    let lateCapture: LateCapture
    let resume: Bool
    let gitHead: String

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func parse(_ env: [String: String]) throws -> PostHogL7Guard {
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        guard value("POSTHOG_L7_HARNESS") == "1" else {
            throw Refusal("POSTHOG_L7_HARNESS=1 is required (run through scripts/run-posthog-l7-harness.sh)")
        }
        guard let mode = Mode(rawValue: value("POSTHOG_L7_MODE") ?? Mode.dryRun.rawValue) else {
            throw Refusal("POSTHOG_L7_MODE must be dry-run or live")
        }
        guard value("POSTHOG_L7_PROJECT_ID") == sandboxProjectID else {
            throw Refusal("POSTHOG_L7_PROJECT_ID must name the sandbox project \(sandboxProjectID)")
        }
        for key in ["PLATFORM_ENVIRONMENT", "ENVIRONMENT", "APP_ENV", "VAPOR_ENV", "POSTHOG_MEASUREMENT_ENVIRONMENT"] {
            if let setting = value(key)?.lowercased(), setting.hasPrefix("prod") {
                throw Refusal("production configuration (\(key)) is refused")
            }
        }
        if let project = value("POSTHOG_ERASURE_PROJECT_ID"), project != sandboxProjectID {
            throw Refusal("POSTHOG_ERASURE_PROJECT_ID names a non-sandbox project")
        }
        for key in ["POSTHOG_ERASURE_API_KEY", "POSTHOG_PROJECT_API_KEY", "POSTHOG_API_KEY", "POSTHOG_PERSONAL_API_KEY"]
        where value(key) != nil {
            throw Refusal("\(key) is set; the harness reads keys only from the private files")
        }
        guard let databaseURL = value("DATABASE_URL"), let database = URLComponents(string: databaseURL),
              ["postgres", "postgresql"].contains(database.scheme ?? ""),
              ["127.0.0.1", "localhost", "::1"].contains(database.host ?? ""),
              matches(database.path, "^/snaglist_(test|opus_[a-z0-9_]+|l7_[a-z0-9_]+)$") else {
            throw Refusal("DATABASE_URL must be a disposable loopback snaglist_test, snaglist_opus_* or snaglist_l7_* database")
        }
        guard let prefix = value("POSTHOG_L7_SUBJECT_PREFIX"), matches(prefix, "^[0-9a-f]{8}$"), prefix != "00000000" else {
            throw Refusal("POSTHOG_L7_SUBJECT_PREFIX must be 8 lower-case hex digits, not all zero")
        }
        guard let keyFile = value("POSTHOG_L7_ERASURE_KEY_FILE"), keyFile.hasPrefix("/") else {
            throw Refusal("POSTHOG_L7_ERASURE_KEY_FILE (an absolute path) is required")
        }
        guard let captureFile = value("POSTHOG_L7_CAPTURE_CONFIG"), captureFile.hasPrefix("/") else {
            throw Refusal("POSTHOG_L7_CAPTURE_CONFIG (an absolute path) is required")
        }
        let fakeBase = value("POSTHOG_L7_FAKE_BASE")
        let approval = value("POSTHOG_L7_LIVE_APPROVAL")
        switch mode {
        case .dryRun:
            guard let fakeBase, matches(fakeBase, "^http://127\\.0\\.0\\.1:[0-9]{2,5}$") else {
                throw Refusal("a dry run needs POSTHOG_L7_FAKE_BASE=http://127.0.0.1:<port>, the local fake PostHog")
            }
            if [keyFile, captureFile].contains(where: { $0.contains("/.config/snaglist/") }) {
                throw Refusal("a dry run uses synthetic key files, never the real ones under ~/.config/snaglist")
            }
            guard approval == nil else { throw Refusal("POSTHOG_L7_LIVE_APPROVAL is set in a dry run") }
        case .live:
            guard fakeBase == nil else { throw Refusal("POSTHOG_L7_FAKE_BASE is set in live mode") }
            guard let approval, matches(approval, "^[A-Za-z0-9][A-Za-z0-9 ._:#/-]{7,159}$") else {
                throw Refusal("live mode needs POSTHOG_L7_LIVE_APPROVAL, the reference of Dan's concrete approval")
            }
        }
        let operatorName = value("POSTHOG_L7_OPERATOR") ?? (mode == .dryRun ? "opus-dry-run" : "")
        guard matches(operatorName, "^[a-z][a-z0-9._-]{1,63}$") else {
            throw Refusal("POSTHOG_L7_OPERATOR must be a lower-case handle")
        }
        guard let output = value("POSTHOG_L7_OUTPUT_DIR"), output.hasPrefix("/") else {
            throw Refusal("POSTHOG_L7_OUTPUT_DIR (an absolute path) is required")
        }
        guard let reportName = value("POSTHOG_L7_REPORT_NAME"), matches(reportName, "^[a-z0-9][a-z0-9-]{2,80}$") else {
            throw Refusal("POSTHOG_L7_REPORT_NAME must be a lower-case file stem")
        }
        func seconds(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            guard let text = value(key) else { return fallback }
            guard let number = Double(text), range.contains(number) else {
                throw Refusal("\(key) must be between \(range.lowerBound) and \(range.upperBound) seconds")
            }
            return number
        }
        let live = mode == .live
        let window = try seconds("POSTHOG_L7_WINDOW_SECONDS", 3_600, PostHogErasureService.ingestionLagWindowRange)
        let realWait = try seconds("POSTHOG_L7_REAL_WAIT_SECONDS", live ? 900 : 6, 1...86_400)
        let poll = try seconds("POSTHOG_L7_POLL_SECONDS", live ? 60 : 1, live ? 15...3_600 : 0.2...60)
        let observationPoll = live ? 30.0 : 0.5
        let ingestTimeout = try seconds("POSTHOG_L7_INGEST_TIMEOUT_SECONDS", live ? 1_800 : 30, 5...86_400)
        let maxRun = try seconds("POSTHOG_L7_MAX_RUN_SECONDS", live ? 6 * 3_600 : 300, 5...(14 * 86_400))
        let maxDeletionWait = try seconds("POSTHOG_L7_MAX_DELETION_WAIT_SECONDS", live ? 9 * 86_400 : 60, 5...(14 * 86_400))
        guard let late = LateCapture(rawValue: value("POSTHOG_L7_LATE_CAPTURE") ?? LateCapture.afterPassOne.rawValue) else {
            throw Refusal("POSTHOG_L7_LATE_CAPTURE must be after-pass-1 or after-request")
        }
        let head = value("POSTHOG_L7_GIT_HEAD").flatMap { matches($0, "^[0-9a-f]{7,40}(-dirty)?$") ? $0 : nil } ?? "unknown"
        return PostHogL7Guard(mode: mode, subjectPrefix: prefix, erasureKeyFile: keyFile, captureConfigFile: captureFile,
                              fakeBase: fakeBase, liveApproval: approval, operatorName: operatorName,
                              outputDirectory: output, reportName: reportName, window: window, realWait: realWait,
                              poll: poll, observationPoll: observationPoll, ingestTimeout: ingestTimeout,
                              maxRun: maxRun, maxDeletionWait: maxDeletionWait, lateCapture: late,
                              resume: value("POSTHOG_L7_RESUME") == "1", gitHead: head)
    }

    /// Reads the two private files. Values are never printed or written anywhere.
    func loadSecrets() throws -> Secrets {
        func privateJSON(_ path: String) throws -> [String: Any] {
            let name = (path as NSString).lastPathComponent
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
                throw Refusal("\(name) is missing")
            }
            guard permissions & 0o077 == 0 else { throw Refusal("\(name) is not private (mode 0600 required)") }
            guard let data = FileManager.default.contents(atPath: path), data.count <= 65_536,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Refusal("\(name) is not a JSON object")
            }
            let synthetic = object["synthetic"] as? Bool == true
            switch mode {
            case .dryRun where !synthetic: throw Refusal("\(name) is not marked synthetic; a dry run never loads a real key")
            case .live where synthetic: throw Refusal("\(name) is synthetic; live mode needs the real sandbox files")
            default: return object
            }
        }
        func text(_ any: Any?) -> String? {
            if let string = any as? String { return string }
            if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
            return nil
        }
        func printable(_ value: String) -> Bool {
            (20...4096).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
        }
        let erasure = try privateJSON(erasureKeyFile)
        guard erasure["host"] as? String == Self.apiHost else { throw Refusal("the erasure key file is not for \(Self.apiHost)") }
        guard text(erasure["projectID"] ?? erasure["projectId"]) == Self.sandboxProjectID else {
            throw Refusal("the erasure key file is not scoped to sandbox project \(Self.sandboxProjectID)")
        }
        guard let apiKey = erasure["apiKey"] as? String, printable(apiKey) else {
            throw Refusal("the erasure key file has no well-formed apiKey")
        }
        let capture = try privateJSON(captureConfigFile)
        guard capture["host"] as? String == Self.captureHost, capture["environment"] as? String == "sandbox",
              text(capture["projectId"] ?? capture["projectID"]) == Self.sandboxProjectID else {
            throw Refusal("the capture configuration is not the EU sandbox project \(Self.sandboxProjectID)")
        }
        guard let token = capture["publicWriteToken"] as? String, printable(token) else {
            throw Refusal("the capture configuration has no well-formed publicWriteToken")
        }
        switch mode {
        case .live:
            guard apiKey.hasPrefix("phx_"), token.hasPrefix("phc_") else {
                throw Refusal("live key material is not a PostHog personal key and project token")
            }
        case .dryRun:
            guard !apiKey.lowercased().hasPrefix("phx_"), !token.lowercased().hasPrefix("phc_") else {
                throw Refusal("dry-run keys must be synthetic, without PostHog key prefixes")
            }
        }
        return Secrets(captureToken: token, apiKey: apiKey)
    }

    /// True when text holds key material: either configured value, a PostHog key prefix or a header.
    static func containsSecret(_ text: String, _ secrets: Secrets) -> Bool {
        let lowered = text.lowercased()
        return text.contains(secrets.apiKey) || text.contains(secrets.captureToken)
            || ["phx_", "phc_", "bearer ", "authorization:"].contains { lowered.contains($0) }
    }
}

/// Every provider request of the run passes here. It refuses anything outside the sandbox
/// allowlist before sending, and records a secret-free summary of each call.
actor PostHogL7Router {
    struct Call: Codable, Sendable {
        let seq: Int
        let at: String
        let origin: String
        let method: String
        let endpoint: String
        let status: Int?
        let summary: [String: String]
        let refused: String?
    }

    private let guardrail: PostHogL7Guard
    private let secrets: PostHogL7Guard.Secrets
    private let captureClient: MeasurementDirectHTTPClient
    private let apiClient: PostHogErasureHTTPClient
    private var subject: String?
    private var persons: Set<String> = []
    private var calls: [Call]
    private var sequence: Int
    private var holdNext = false
    private var held = 0
    private var releaser: CheckedContinuation<Void, Never>?
    private var releasedEarly = false

    init(guardrail: PostHogL7Guard, secrets: PostHogL7Guard.Secrets, captureClient: MeasurementDirectHTTPClient,
         apiClient: PostHogErasureHTTPClient, previous: [Call]) {
        self.guardrail = guardrail
        self.secrets = secrets
        self.captureClient = captureClient
        self.apiClient = apiClient
        self.calls = previous
        self.sequence = previous.last?.seq ?? 0
    }

    func setSubject(_ value: String) { subject = value }
    func allowPersons(_ ids: [String]) { persons.formUnion(ids.map { $0.lowercased() }) }
    func allCalls() -> [Call] { calls }
    func callCount(origin: String) -> Int { calls.filter { $0.origin == origin && $0.refused == nil }.count }
    func holdNextCapture() { holdNext = true; releasedEarly = false }
    func heldCount() -> Int { held }
    func release() {
        if let releaser { self.releaser = nil; releaser.resume() } else { releasedEarly = true }
    }

    nonisolated func captureTransport(origin: String) -> MeasurementDispatchService.Transport {
        { uri, headers, body in try await self.capture(uri, headers, body, origin: origin) }
    }
    nonisolated func apiTransport(origin: String) -> PostHogErasureService.Transport {
        { method, uri, headers, body in try await self.api(method, uri, headers, body, origin: origin) }
    }

    func capture(_ uri: URI, _ headers: HTTPHeaders, _ body: Data, origin: String) async throws -> MeasurementDispatchService.Reply {
        let checked: (distinct: String, event: String)
        do { checked = try checkCapture(uri, headers, body) } catch let refusal as PostHogL7Guard.Refusal {
            record(origin, "POST", "capture", nil, [:], refusal.description)
            throw refusal
        }
        let target = guardrail.mode == .live ? uri : URI(string: (guardrail.fakeBase ?? "http://127.0.0.1:9") + "/capture/")
        let reply: MeasurementDispatchService.Reply
        do { reply = try await captureClient.post(target, headers: headers, body: body) } catch {
            record(origin, "POST", "capture", nil, ["error": "transport"], nil)
            throw error
        }
        record(origin, "POST", "capture", reply.status, ["distinct_id": checked.distinct, "event": checked.event], nil)
        if holdNext {
            // The provider already has the bytes; the sender has not been answered yet.
            holdNext = false
            held += 1
            if !releasedEarly { await withCheckedContinuation { releaser = $0 } }
        }
        return reply
    }

    func api(_ method: HTTPMethod, _ uri: URI, _ headers: HTTPHeaders, _ body: Data?,
             origin: String) async throws -> PostHogErasureService.Reply {
        let endpoint: String
        do { endpoint = try checkAPI(method, uri, headers, body) } catch let refusal as PostHogL7Guard.Refusal {
            record(origin, method.rawValue, "refused", nil, [:], refusal.description)
            throw refusal
        }
        let target: URI
        switch guardrail.mode {
        case .live: target = uri
        case .dryRun:
            target = URI(string: (guardrail.fakeBase ?? "http://127.0.0.1:9")
                         + String(uri.string.dropFirst(PostHogL7Guard.apiHost.count)))
        }
        let reply: PostHogErasureService.Reply
        do { reply = try await apiClient.request(method, target, headers: headers, body: body) } catch {
            record(origin, method.rawValue, endpoint, nil, ["error": "transport"], nil)
            throw error
        }
        record(origin, method.rawValue, endpoint, reply.status, summarize(endpoint, reply), nil)
        return reply
    }

    private func isOurSubject(_ distinct: String) -> Bool {
        guard let subject, distinct == subject else { return false }
        return distinct.hasPrefix(guardrail.subjectPrefix + "-") && UUID(uuidString: distinct)?.uuidString.lowercased() == distinct
    }

    private func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func checkCapture(_ uri: URI, _ headers: HTTPHeaders, _ body: Data) throws -> (distinct: String, event: String) {
        guard uri.string == PostHogL7Guard.captureURL else {
            throw PostHogL7Guard.Refusal("capture to a host other than the EU sandbox ingestion endpoint")
        }
        guard headers.bearerAuthorization == nil else { throw PostHogL7Guard.Refusal("a capture must not carry a personal key") }
        guard let object = json(body), object["api_key"] as? String == secrets.captureToken else {
            throw PostHogL7Guard.Refusal("capture with a project token other than the sandbox project's")
        }
        guard let properties = object["properties"] as? [String: Any], let distinct = properties["distinct_id"] as? String,
              isOurSubject(distinct) else {
            throw PostHogL7Guard.Refusal("capture for a subject other than this run's synthetic subject")
        }
        guard properties["$geoip_disable"] as? Bool == true, properties["$process_person_profile"] as? Bool == true else {
            throw PostHogL7Guard.Refusal("capture without the profile and GeoIP controls")
        }
        guard let event = object["event"] as? String else { throw PostHogL7Guard.Refusal("capture without an event name") }
        return (distinct, event)
    }

    private func checkAPI(_ method: HTTPMethod, _ uri: URI, _ headers: HTTPHeaders, _ body: Data?) throws -> String {
        let text = uri.string
        guard text.hasPrefix(PostHogL7Guard.apiPrefix) else {
            throw PostHogL7Guard.Refusal("API request outside EU sandbox project \(PostHogL7Guard.sandboxProjectID)")
        }
        guard headers.bearerAuthorization?.token == secrets.apiKey else {
            throw PostHogL7Guard.Refusal("API request with a credential other than the sandbox erasure key")
        }
        let rest = String(text.dropFirst(PostHogL7Guard.apiPrefix.count))
        let pieces = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        var parameters: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parameters[String(parts[0])] == nil else {
                    throw PostHogL7Guard.Refusal("malformed query string")
                }
                parameters[String(parts[0])] = String(parts[1])
            }
        }
        switch (method, path) {
        case (.GET, "persons/"):
            guard parameters.count == 1, let distinct = parameters["distinct_id"], isOurSubject(distinct) else {
                throw PostHogL7Guard.Refusal("persons lookup for a subject other than this run's")
            }
            return "persons"
        case (.POST, "persons/bulk_delete/"):
            guard parameters.isEmpty, let body, let object = json(body), object.count == 4,
                  let ids = object["distinct_ids"] as? [String], ids.count == 1, isOurSubject(ids[0]),
                  object["delete_events"] as? Bool == true, object["keep_person"] as? Bool == false,
                  object["delete_recordings"] as? Bool == false else {
                throw PostHogL7Guard.Refusal("bulk_delete other than one deletion of this run's synthetic subject")
            }
            return "bulk_delete"
        case (.GET, "persons/deletion_status/"):
            guard parameters.count == 2, parameters["status"] == "all", let person = parameters["person_uuid"],
                  persons.contains(person) else {
                throw PostHogL7Guard.Refusal("deletion status for a person this run did not resolve")
            }
            return "deletion_status"
        case (.POST, "query/"):
            guard parameters.isEmpty, let body, let subject, let object = json(body) else {
                throw PostHogL7Guard.Refusal("query without this run's subject")
            }
            let allowed = [PostHogErasureService.eventCountQuery(distinctID: subject), PostHogL7Run.personQuery(subject)]
                .compactMap { $0 }.compactMap { json($0) }
            guard allowed.contains(where: { NSDictionary(dictionary: $0).isEqual(to: object) }) else {
                throw PostHogL7Guard.Refusal("query other than this run's allowlisted read-only counts")
            }
            return "query"
        default:
            throw PostHogL7Guard.Refusal("\(method.rawValue) \(path) is not on the harness allowlist")
        }
    }

    private func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "absent"
        case is NSNull: return "null"
        case let text as String: return String(text.prefix(120))
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            guard let any = value, JSONSerialization.isValidJSONObject(any),
                  let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else { return "?" }
            return String(String(decoding: data, as: UTF8.self).prefix(300))
        }
    }

    private func summarize(_ endpoint: String, _ reply: PostHogErasureService.Reply) -> [String: String] {
        guard let object = json(reply.body) else { return ["body": reply.body.isEmpty ? "empty" : "not a JSON object"] }
        switch endpoint {
        case "persons":
            let results = (object["results"] as? [[String: Any]]) ?? []
            let ours = results.filter { ($0["distinct_ids"] as? [String]) == [subject ?? ""] }
            let ids = results.compactMap { ($0["uuid"] as? String)?.lowercased() }
            persons.formUnion(ours.compactMap { ($0["uuid"] as? String)?.lowercased() })
            return ["results": String(results.count), "uuids": ids.joined(separator: ","),
                    "exclusive_to_subject": String(ours.count == results.count)]
        case "bulk_delete":
            return ["persons_found": describe(object["persons_found"]),
                    "persons_queued_for_deletion": describe(object["persons_queued_for_deletion"]),
                    "events_queued_for_deletion": describe(object["events_queued_for_deletion"]),
                    "deletion_errors": String((object["deletion_errors"] as? [Any])?.count ?? -1)]
        case "deletion_status":
            let rows = (object["results"] as? [[String: Any]]) ?? []
            var summary = ["rows": String(rows.count)]
            if let first = rows.first {
                for key in ["person_uuid", "created_at", "status", "delete_verified_at"] { summary[key] = describe(first[key]) }
            }
            return summary
        case "query":
            return ["results": describe(object["results"]), "is_cached": describe(object["is_cached"])]
        default:
            return [:]
        }
    }

    private func record(_ origin: String, _ method: String, _ endpoint: String, _ status: Int?,
                        _ summary: [String: String], _ refused: String?) {
        sequence += 1
        calls.append(Call(seq: sequence, at: PostHogL7Run.iso(Date()), origin: origin, method: method,
                          endpoint: endpoint, status: status, summary: summary, refused: refused))
    }
}

/// Durable, secret-free run state. A live run can stop (run-time limit) and resume against the
/// same disposable database while PostHog processes its deletion queue.
struct PostHogL7State: Codable {
    struct Step: Codable, Sendable { let at: String; let name: String; let ok: Bool; let detail: [String: String] }
    var schemaVersion = 1
    var runID: String
    var mode: String
    var reportName: String
    var subjectPrefix: String
    var lateCapture: String
    var startedAt: String
    var invocations = 0
    var userID: UUID?
    var subjectID: UUID?
    var opaque: String?
    var jobID: UUID?
    var revokedAt: String?
    var recordedInFlightUntil: String?
    var setupComplete = false
    var settleShortened = false
    var lateInjected = false
    var lateInjectedAt: String?
    var lateVisible = false
    var restartedMidQuiet = false
    var quietShortenings = 0
    var unchangedPolls = 0
    var steps: [Step] = []
    var calls: [PostHogL7Router.Call] = []
}

struct PostHogL7Report: Codable {
    struct Expectation: Codable { let id: String; let description: String; let expected: String; let observed: String; let matches: Bool }
    struct Pass: Codable {
        let sequence: Int; let round: Int; let stage: String; let check: String; let outcome: String; let checkedAt: String
        let personUuid: String?; let requestedAt: String?; let providerCreatedAt: String?; let providerVerifiedAt: String?
        let eventCount: Int?
    }
    struct Receipt: Codable {
        let phase: String; let round: Int; let personUuid: String; let requestedAt: String?; let providerCreatedAt: String?
        let eventsVerifiedAt: String?; let profileAbsentAt: String?; let inFlightUntil: String?; let quietUntil: String?
        let completedAt: String?; let manualReason: String?; let manualAt: String?
    }
    struct Job: Codable { let state: String; let lastErrorKind: String?; let completedAt: String? }
    let schemaVersion: Int
    let harness: String
    let mode: String
    let status: String
    let error: String?
    let runId: String
    let invocations: Int
    let startedAt: String
    let reportedAt: String
    let backendGitHead: String
    let target: [String: String]
    let guards: [String: String]
    let parameters: [String: String]
    let subject: [String: String]
    let steps: [PostHogL7State.Step]
    let providerCalls: [PostHogL7Router.Call]
    let refusals: [PostHogL7Router.Call]
    let job: Job?
    let receipt: Receipt?
    let passes: [Pass]
    let expectations: [Expectation]
    let conclusion: String
    let secretScan: String
}

struct PostHogL7Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

actor PostHogL7Probe {
    private(set) var finished = false
    func finish() { finished = true }
}

final class PostHogL7Run {
    let guardrail: PostHogL7Guard
    private let secrets: PostHogL7Guard.Secrets
    private let started = Date()
    private(set) var state: PostHogL7State
    private var app: Application?
    private var jwt: String?
    private let installation = UUID()
    private let captureClient: MeasurementDirectHTTPClient
    private let apiClient: PostHogErasureHTTPClient
    let router: PostHogL7Router
    private(set) var lastReport: PostHogL7Report?

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    /// The harness's second read-only observation: which person IDs the subject's events carry.
    static func personQuery(_ distinctID: String) -> Data? {
        guard distinctID.utf8.count == 36, UUID(uuidString: distinctID)?.uuidString.lowercased() == distinctID else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "name": "snaglist-l7-observation",
            "query": ["kind": "HogQLQuery",
                      "query": "SELECT count(), groupUniqArray(toString(person_id)) FROM events WHERE distinct_id = '\(distinctID)'"],
            "refresh": "force_blocking"], options: [.sortedKeys])
    }

    private var stateURL: URL {
        URL(fileURLWithPath: guardrail.outputDirectory).appendingPathComponent("\(guardrail.reportName)-state.json")
    }
    private var sql: SQLDatabase {
        get throws {
            guard let app else { throw PostHogL7Failure("the application is not running") }
            return try VerifiedIdentityService.sql(app.db)
        }
    }

    init(guardrail: PostHogL7Guard, secrets: PostHogL7Guard.Secrets) throws {
        self.guardrail = guardrail
        self.secrets = secrets
        let logger = Logger(label: "posthog-l7-harness")
        let capture = MeasurementDirectHTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, logger: logger)
        let api = PostHogErasureHTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, logger: logger)
        captureClient = capture
        apiClient = api
        var initial: PostHogL7State
        let path = URL(fileURLWithPath: guardrail.outputDirectory)
            .appendingPathComponent("\(guardrail.reportName)-state.json").path
        if guardrail.resume {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw PostHogL7Guard.Refusal("resume needs \(guardrail.reportName)-state.json from the earlier invocation")
            }
            let loaded = try JSONDecoder().decode(PostHogL7State.self, from: data)
            guard loaded.mode == guardrail.mode.rawValue, loaded.subjectPrefix == guardrail.subjectPrefix,
                  loaded.lateCapture == guardrail.lateCapture.rawValue, loaded.setupComplete else {
                throw PostHogL7Guard.Refusal("the saved state belongs to another mode, prefix or variant, or its setup never finished")
            }
            initial = loaded
        } else {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw PostHogL7Guard.Refusal("\(guardrail.reportName)-state.json already exists; choose a new report name or resume")
            }
            initial = PostHogL7State(runID: UUID().uuidString.lowercased(), mode: guardrail.mode.rawValue,
                                     reportName: guardrail.reportName, subjectPrefix: guardrail.subjectPrefix,
                                     lateCapture: guardrail.lateCapture.rawValue, startedAt: PostHogL7Run.iso(Date()))
        }
        initial.invocations += 1
        state = initial
        router = PostHogL7Router(guardrail: guardrail, secrets: secrets, captureClient: capture,
                                 apiClient: api, previous: initial.calls)
    }

    func close() async {
        if let app { try? await app.asyncShutdown() }
        app = nil
        try? await captureClient.close()
        try? await apiClient.close()
    }

    // MARK: Run

    func execute() async throws -> String {
        try FileManager.default.createDirectory(atPath: guardrail.outputDirectory, withIntermediateDirectories: true)
        try await boot()
        if guardrail.resume {
            if let opaque = state.opaque { await router.setSubject(opaque) }
            let known = try await knownPersons()
            await router.allowPersons(known)
            step("resume", ok: true, ["invocation": String(state.invocations)])
        } else {
            try await setup()
        }
        let status = try await drive()
        if status == "finished" { try await finalObservation() }
        try await writeReport(status: status, error: nil)
        return status
    }

    private func boot() async throws {
        let app = try await Application.make(.testing)
        do { try await configure(app) } catch { try await app.asyncShutdown(); throw error }
        app.storage[PlatformConfigurationKey.self] = .init(origin: "http://127.0.0.1:8080", environment: "local")
        app.storage[MeasurementCredentialCipher.Key.self] = Data(repeating: 0x5a, count: 32)
        app.storage[MeasurementDispatchService.ConfigurationKey.self] = .init(
            postHogProjectKey: secrets.captureToken, postHogEnvironment: .sandbox,
            singularURL: nil, singularAPIKey: nil, linkedInAccessToken: nil,
            linkedInSignupRule: nil, linkedInSubscriptionRule: nil, linkedInEnvironment: nil)
        app.storage[MeasurementDispatchService.TransportKey.self] = router.captureTransport(origin: "product")
        app.storage[PostHogErasureService.ConfigurationKey.self] = .init(
            projectID: PostHogL7Guard.sandboxProjectID, apiKey: secrets.apiKey, ingestionLagWindow: guardrail.window)
        app.storage[PostHogErasureService.TransportKey.self] = router.apiTransport(origin: "product")
        guard PostHogErasureService.configuration(app)?.valid == true else {
            try await app.asyncShutdown()
            throw PostHogL7Guard.Refusal("the erasure configuration is invalid")
        }
        self.app = app
    }

    private func setup() async throws {
        guard let app else { throw PostHogL7Failure("no application") }
        let user = User(appleUserId: nil, email: "posthog-l7-\(guardrail.subjectPrefix)-\(state.runID.prefix(8))@example.test",
                        name: nil, authProvider: .magicLink)
        try await user.save(on: app.db)
        let userID = try user.requireID()
        state.userID = userID
        jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3_600)), userId: userID,
            authVersion: user.authVersion, authenticatedAt: Date()))
        try await FeatureFlag.query(on: app.db).filter(\.$key == "productAnalyticsEnabled").delete()
        try await FeatureFlag(key: "productAnalyticsEnabled", enabled: true).save(on: app.db)

        // 1. Grant, then tag the synthetic subject with the run's prefix before anything is sent.
        let granted = try await request(.PUT, "api/v2/measurement/permissions/productAnalytics", [
            "requestId": UUID().uuidString, "decision": "granted", "occurredAt": Self.iso(Date())])
        guard granted.status == .ok else { throw PostHogL7Failure("grant answered \(granted.status.code)") }
        let revision = try await sql.raw("""
            SELECT revision FROM measurement_permission_current WHERE account_id=\(bind:userID) AND purpose='productAnalytics'
            """).first()!.decode(column: "revision", as: UUID.self)
        let opaque = guardrail.subjectPrefix + String(UUID().uuidString.lowercased().dropFirst(8))
        guard let tagged = try await sql.raw("""
            UPDATE measurement_subjects SET opaque_subject=\(bind:UUID(uuidString: opaque)!)
            WHERE account_id=\(bind:userID) AND purpose='productAnalytics' AND state='active' RETURNING id
            """).first() else { throw PostHogL7Failure("no active product-analytics subject after the grant") }
        let subjectID = try tagged.decode(column: "id", as: UUID.self)
        state.subjectID = subjectID
        state.opaque = opaque
        await router.setSubject(opaque)
        step("grant and synthetic subject", ok: true, ["distinct_id": opaque])

        // 2. Three product events through the real relay.
        let fixtures: [(String, [String: String])] = [
            ("session_started", [:]),
            ("project_created", ["creation_source": "fresh", "workspace_kind": "personal"]),
            ("snag_created", ["photo_count": "1", "offline": "false"])]
        var accepted = 0
        for (name, properties) in fixtures {
            let status = try await relay(name, properties, revision)
            if status == .accepted { accepted += 1 }
        }
        step("relay", ok: accepted == fixtures.count, ["accepted": "\(accepted)/\(fixtures.count)"])

        // 3. The outbox dispatcher sends them through the guarded transport.
        let delivered = await MeasurementDispatchService.run(app: app, limit: 20, on: app.db)
        step("dispatch", ok: delivered.delivered == fixtures.count,
             ["delivered": "\(delivered.delivered)", "uncertain": "\(delivered.uncertain)", "manual": "\(delivered.manualRequired)"])

        // 4. One capture is held in flight (sent, not yet answered) while withdrawal is requested.
        _ = try await relay("first_project_created", [:], revision)
        await router.holdNextCapture()
        let dispatch = Task { await MeasurementDispatchService.run(app: app, limit: 5, on: app.db) }
        let held = try await waitUntil(timeout: 30, every: 0.05) { await self.router.heldCount() > 0 }
        let probe = PostHogL7Probe()
        let withdrawal = Task { () -> UInt in
            let response = try await self.request(.PUT, "api/v2/measurement/permissions/productAnalytics", [
                "requestId": UUID().uuidString, "expectedRevision": revision.uuidString,
                "decision": "withdrawn", "occurredAt": Self.iso(Date())])
            await probe.finish()
            return response.status.code
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let finishedEarly = await probe.finished
        let waited = !finishedEarly
        await router.release()
        let heldDelivered = await dispatch.value
        let withdrawalStatus = try await withdrawal.value
        let barrier = try await sql.raw("""
            SELECT revoked_at,last_send_started_at,send_in_flight_until FROM measurement_subjects WHERE id=\(bind:subjectID)
            """).first()!
        let revokedAt = try barrier.decode(column: "revoked_at", as: Date?.self)
        let lastSend = try barrier.decode(column: "last_send_started_at", as: Date?.self)
        let inFlight = try barrier.decode(column: "send_in_flight_until", as: Date?.self)
        state.revokedAt = revokedAt.map(Self.iso)
        state.recordedInFlightUntil = inFlight.map(Self.iso)
        var barrierOK = false
        if let revokedAt, let lastSend, let inFlight {
            barrierOK = lastSend < revokedAt && inFlight.timeIntervalSince(lastSend)
                >= MeasurementDispatchService.sendDeadline + MeasurementDispatchService.sendStartMargin
        }
        step("held in-flight capture during withdrawal", ok: held && waited && heldDelivered.delivered == 1
             && withdrawalStatus == 200 && barrierOK,
             ["held": String(held), "withdrawal_waited_for_barrier": String(waited),
              "held_capture_delivered": "\(heldDelivered.delivered)", "withdrawal_status": "\(withdrawalStatus)",
              "barrier_recorded": String(barrierOK), "in_flight_until": state.recordedInFlightUntil ?? "none"])

        guard let job = try await sql.raw("""
            SELECT id FROM measurement_erasure_jobs WHERE subject_id=\(bind:subjectID) AND destination='posthog'
            """).first()?.decode(column: "id", as: UUID.self) else { throw PostHogL7Failure("withdrawal created no PostHog erasure job") }
        state.jobID = job

        // 5. Independent read through the same guard: all four captures stored, one exclusive profile.
        let stored = try await waitUntil(timeout: guardrail.ingestTimeout, every: guardrail.observationPoll) {
            let people = try await self.observePersons()
            let count = try await self.observeCount()
            return people?.count == 1 && count == fixtures.count + 1
        }
        let people = try await observePersons()
        let count = try await observeCount()
        if let people { await router.allowPersons(people) }
        step("observation: captures stored and one profile", ok: stored,
             ["persons": people?.joined(separator: ",") ?? "unreadable", "event_count": count.map { String($0) } ?? "unreadable"])

        // 6. Settle: the worker makes no provider call before the in-flight bound plus the window.
        let before = await router.callCount(origin: "product")
        try await runWorkerOnce(job)
        let after = await router.callCount(origin: "product")
        let receipt = try await receiptRow(job)
        step("settle: no provider call before the in-flight bound plus the window", ok: before == after && receipt == nil,
             ["provider_calls": "\(after - before)", "receipt": receipt == nil ? "none" : "present"])
        state.setupComplete = true
        try await saveState()
    }

    private func drive() async throws -> String {
        guard let job = state.jobID, let subjectID = state.subjectID else { throw PostHogL7Failure("the saved state has no job") }
        while true {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > guardrail.maxRun {
                step("paused at the run-time limit; resume with --resume", ok: true, ["elapsed_s": "\(Int(elapsed))"])
                return "waiting"
            }
            let current = try await jobRow(job)
            if current.state == "completed" || current.state == "manual_required" { return "finished" }
            let receipt = try await receiptRow(job)
            switch receipt?.phase ?? "none" {
            case "none":
                if !state.settleShortened {
                    // Only the window is shortened: the real wait starts once both the cutoff and
                    // the recorded in-flight bound (the held send's lease end) have passed.
                    let since = max(state.revokedAt.flatMap(Self.date) ?? Date(),
                                    state.recordedInFlightUntil.flatMap(Self.date) ?? .distantPast)
                    let remaining = guardrail.realWait - Date().timeIntervalSince(since)
                    if remaining > 0 { try await pause(remaining); continue }
                    try await sql.raw("""
                        UPDATE measurement_subjects SET send_in_flight_until=NOW()-make_interval(secs => \(bind:guardrail.window + 1))
                        WHERE id=\(bind:subjectID) AND send_in_flight_until IS NOT NULL
                        """).run()
                    state.settleShortened = true
                    step("settle shortened by the harness", ok: true,
                         ["configured_window_s": "\(Int(guardrail.window))", "real_wait_s": "\(Int(guardrail.realWait))",
                          "real_wait_counted_from": "later of the cutoff and the recorded in-flight bound",
                          "recorded_in_flight_until": state.recordedInFlightUntil ?? "none"])
                }
                try await worker(job, "resolve the profile")
            case "resolved":
                try await worker(job, "deletion request (round \(receipt?.round ?? 0))")
                if guardrail.lateCapture == .afterRequest, !state.lateInjected, receipt?.round == 1,
                   try await receiptRow(job)?.phase == "polling" {
                    try await injectLateCapture()
                }
            case "submitting", "polling":
                if let requested = receipt?.requestedAt, Date().timeIntervalSince(requested) > guardrail.maxDeletionWait {
                    step("stopped: the provider did not verify the deletion within the harness limit", ok: false,
                         ["requested_at": Self.iso(requested)])
                    return "timeout"
                }
                let progressed = try await worker(job, "poll deletion status")
                if !progressed { try await pause(guardrail.poll) }
            case "events_verified":
                try await worker(job, "pass 1: profile lookup")
            case "quiet":
                if guardrail.lateCapture == .afterPassOne, !state.lateInjected, receipt?.round == 1 {
                    try await injectLateCapture()
                }
                if state.lateInjected, !state.lateVisible, receipt?.round == 1 { try await observeLateEvent() }
                if !state.restartedMidQuiet { try await restartMidQuiet(job); continue }
                let since = max(receipt?.profileAbsentAt ?? Date(), state.lateInjectedAt.flatMap(Self.date) ?? .distantPast)
                let remaining = guardrail.realWait - Date().timeIntervalSince(since)
                if remaining > 0 { try await pause(remaining); continue }
                try await sql.raw("""
                    UPDATE measurement_posthog_erasure_receipts SET quiet_until=NOW()-INTERVAL '1 second'
                    WHERE job_id=\(bind:job) AND phase='quiet'
                    """).run()
                state.quietShortenings += 1
                step("quiet period shortened by the harness", ok: true,
                     ["round": "\(receipt?.round ?? 0)", "configured_quiet_until": receipt?.quietUntil.map(Self.iso) ?? "none",
                      "real_wait_s": "\(Int(guardrail.realWait))"])
                try await worker(job, "pass 2: uncached event count")
            case "quiet_events_absent":
                try await worker(job, "pass 2: profile lookup")
            case "reresolving":
                try await worker(job, "re-resolve after late data")
            default:
                let progressed = try await worker(job, "worker step")
                if !progressed { try await pause(guardrail.poll) }
            }
        }
    }

    // MARK: Steps

    private func pause(_ seconds: TimeInterval) async throws {
        let left = guardrail.maxRun - Date().timeIntervalSince(started)
        let duration = max(0.05, min(seconds, max(left, 0) + 0.05))
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    private func runWorkerOnce(_ job: UUID) async throws {
        guard let app else { throw PostHogL7Failure("no application") }
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET available_at=NOW() WHERE id=\(bind:job) AND state IN ('pending','failing')
            """).run()
        _ = await MeasurementErasureService.run(app: app, limit: 1, on: app.db)
    }

    /// One erasure-worker step (one provider request at most). Returns whether anything changed.
    @discardableResult
    private func worker(_ job: UUID, _ label: String) async throws -> Bool {
        let beforeReceipt = try await receiptRow(job)
        let beforeJob = try await jobRow(job)
        let calls = await router.callCount(origin: "product")
        try await runWorkerOnce(job)
        let afterReceipt = try await receiptRow(job)
        let afterJob = try await jobRow(job)
        let made = await router.callCount(origin: "product") - calls
        let changed = afterReceipt?.phase != beforeReceipt?.phase || afterReceipt?.round != beforeReceipt?.round
            || afterJob.state != beforeJob.state
        if changed || !label.hasPrefix("poll") {
            var detail = ["phase": "\(beforeReceipt?.phase ?? "none") -> \(afterReceipt?.phase ?? "none")",
                          "job": "\(beforeJob.state) -> \(afterJob.state)", "provider_calls": "\(made)",
                          "round": "\(afterReceipt?.round ?? 0)"]
            if state.unchangedPolls > 0 { detail["unchanged_polls_before"] = "\(state.unchangedPolls)"; state.unchangedPolls = 0 }
            if let reason = afterJob.reason { detail["last_error_kind"] = reason }
            step(label, ok: true, detail)
        } else {
            state.unchangedPolls += 1
        }
        try await saveState()
        return changed
    }

    private func restartMidQuiet(_ job: UUID) async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
        try await boot()
        let calls = await router.callCount(origin: "product")
        try await runWorkerOnce(job)
        let made = await router.callCount(origin: "product") - calls
        let phase = try await receiptRow(job)?.phase
        let current = try await jobRow(job)
        state.restartedMidQuiet = true
        step("worker restart mid-quiet: no provider call and no completion inside the window",
             ok: made == 0 && phase == "quiet" && current.state == "pending",
             ["provider_calls": "\(made)", "phase": phase ?? "none", "job": current.state])
        try await saveState()
    }

    private func injectLateCapture() async throws {
        guard let opaque = state.opaque, let revokedAt = state.revokedAt.flatMap(Self.date) else {
            throw PostHogL7Failure("no subject or cutoff to inject a late capture for")
        }
        // The dispatcher's body shape, timestamped before the cutoff: a capture accepted before
        // withdrawal that PostHog writes late. Sent now, after the cutoff, through the same guard.
        let body = try JSONSerialization.data(withJSONObject: [
            "api_key": secrets.captureToken, "event": "first_project_created", "uuid": UUID().uuidString.lowercased(),
            "timestamp": Self.iso(revokedAt.addingTimeInterval(-1)),
            "properties": ["distinct_id": opaque, "source_event_id": UUID().uuidString.lowercased(),
                           "$process_person_profile": true, "$geoip_disable": true]], options: [.sortedKeys])
        var headers = HTTPHeaders()
        headers.contentType = .json
        var phase: String?
        if let job = state.jobID { phase = try await receiptRow(job)?.phase }
        let reply = try await router.capture(URI(string: PostHogL7Guard.captureURL), headers, body, origin: "harness-late-capture")
        state.lateInjected = true
        state.lateInjectedAt = Self.iso(Date())
        step("late capture injected after the cutoff", ok: (200..<300).contains(reply.status),
             ["status": "\(reply.status)", "event_timestamp": "cutoff - 1 s", "variant": guardrail.lateCapture.rawValue,
              "receipt_phase": phase ?? "none"])
        try await saveState()
    }

    private func observeLateEvent() async throws {
        let visible = try await waitUntil(timeout: guardrail.ingestTimeout, every: guardrail.observationPoll) {
            (try await self.observeCount() ?? 0) >= 1
        }
        let people = try await observePersons()
        let ids = try await observePersonIDs()
        state.lateVisible = visible
        step("observation: late event stored after the first deletion", ok: visible,
             ["event_count": ids.map { String($0.count) } ?? "unreadable",
              "event_person_ids": ids?.ids.joined(separator: ",") ?? "unreadable",
              "persons": people?.joined(separator: ",") ?? "unreadable"])
        try await saveState()
    }

    private func finalObservation() async throws {
        let known = try await knownPersons()
        await router.allowPersons(known)
        let people = try await observePersons()
        let ids = try await observePersonIDs()
        var detail = ["persons": people?.joined(separator: ",") ?? "unreadable",
                      "event_count": ids.map { String($0.count) } ?? "unreadable",
                      "event_person_ids": ids?.ids.joined(separator: ",") ?? "unreadable"]
        for person in known {
            detail["deletion_status_\(person.prefix(8))"] = try await observeDeletionStatus(person)
        }
        step("final observation", ok: true, detail)
    }

    // MARK: Observations (harness reads through the same guard)

    private var apiHeaders: HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: secrets.apiKey)
        headers.contentType = .json
        return headers
    }

    private func observe(_ method: HTTPMethod, _ path: String, _ body: Data?) async throws -> PostHogErasureService.Reply? {
        do {
            return try await router.api(method, URI(string: PostHogL7Guard.apiPrefix + path), apiHeaders, body, origin: "harness")
        } catch let refusal as PostHogL7Guard.Refusal { throw refusal } catch { return nil }
    }

    private func observePersons() async throws -> [String]? {
        guard let opaque = state.opaque, let reply = try await observe(.GET, "persons/?distinct_id=" + opaque, nil),
              reply.status == 200,
              let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        return results.compactMap { ($0["uuid"] as? String)?.lowercased() }
    }

    private func observeCount() async throws -> Int? {
        guard let opaque = state.opaque, let body = PostHogErasureService.eventCountQuery(distinctID: opaque),
              let reply = try await observe(.POST, "query/", body), reply.status == 200,
              case .count(let count) = PostHogErasureService.eventCount(reply.body) else { return nil }
        return count
    }

    private func observePersonIDs() async throws -> (count: Int, ids: [String])? {
        guard let opaque = state.opaque, let body = Self.personQuery(opaque),
              let reply = try await observe(.POST, "query/", body), reply.status == 200,
              let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any],
              let rows = object["results"] as? [[Any]], rows.count == 1, rows[0].count == 2,
              let count = (rows[0][0] as? NSNumber)?.intValue else { return nil }
        return (count, ((rows[0][1] as? [String]) ?? []).map { $0.lowercased() })
    }

    private func observeDeletionStatus(_ person: String) async throws -> String {
        guard let reply = try await observe(.GET, "persons/deletion_status/?person_uuid=\(person)&status=all", nil) else {
            return "unreadable"
        }
        guard reply.status == 200, let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any],
              let rows = object["results"] as? [[String: Any]] else { return "status \(reply.status)" }
        func show(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "absent" }
        let described = rows.map { row -> String in
            ["created_at", "status", "delete_verified_at"].map { key in "\(key)=\(show(row[key]))" }.joined(separator: " ")
        }
        return described.joined(separator: "; ") + " (rows: \(rows.count))"
    }

    // MARK: Database

    struct JobRow { let state: String; let reason: String?; let completedAt: Date? }
    struct ReceiptRow {
        let phase: String; let round: Int; let person: UUID; let requestedAt: Date?; let providerCreatedAt: Date?
        let eventsVerifiedAt: Date?; let profileAbsentAt: Date?; let inFlightUntil: Date?; let quietUntil: Date?
        let completedAt: Date?; let manualReason: String?; let manualAt: Date?
    }

    private func jobRow(_ job: UUID) async throws -> JobRow {
        let row = try await sql.raw("SELECT state,last_error_kind,completed_at FROM measurement_erasure_jobs WHERE id=\(bind:job)").first()!
        return JobRow(state: try row.decode(column: "state", as: String.self),
                      reason: try row.decode(column: "last_error_kind", as: String?.self),
                      completedAt: try row.decode(column: "completed_at", as: Date?.self))
    }

    private func receiptRow(_ job: UUID) async throws -> ReceiptRow? {
        guard let row = try await sql.raw("SELECT * FROM measurement_posthog_erasure_receipts WHERE job_id=\(bind:job)").first()
        else { return nil }
        return ReceiptRow(phase: try row.decode(column: "phase", as: String.self),
                          round: try row.decode(column: "round", as: Int.self),
                          person: try row.decode(column: "person_uuid", as: UUID.self),
                          requestedAt: try row.decode(column: "requested_at", as: Date?.self),
                          providerCreatedAt: try row.decode(column: "provider_created_at", as: Date?.self),
                          eventsVerifiedAt: try row.decode(column: "events_verified_at", as: Date?.self),
                          profileAbsentAt: try row.decode(column: "profile_absent_at", as: Date?.self),
                          inFlightUntil: try row.decode(column: "in_flight_until", as: Date?.self),
                          quietUntil: try row.decode(column: "quiet_until", as: Date?.self),
                          completedAt: try row.decode(column: "completed_at", as: Date?.self),
                          manualReason: try row.decode(column: "manual_reason", as: String?.self),
                          manualAt: try row.decode(column: "manual_at", as: Date?.self))
    }

    private func passRows(_ job: UUID) async throws -> [PostHogL7Report.Pass] {
        try await sql.raw("""
            SELECT sequence,round,stage,check_kind,outcome,checked_at,person_uuid,requested_at,provider_created_at,
                   provider_verified_at,event_count FROM measurement_posthog_erasure_passes WHERE job_id=\(bind:job) ORDER BY sequence
            """).all().map { row in
            PostHogL7Report.Pass(sequence: try row.decode(column: "sequence", as: Int.self),
                round: try row.decode(column: "round", as: Int.self),
                stage: try row.decode(column: "stage", as: String.self),
                check: try row.decode(column: "check_kind", as: String.self),
                outcome: try row.decode(column: "outcome", as: String.self),
                checkedAt: Self.iso(try row.decode(column: "checked_at", as: Date.self)),
                personUuid: try row.decode(column: "person_uuid", as: UUID?.self)?.uuidString.lowercased(),
                requestedAt: try row.decode(column: "requested_at", as: Date?.self).map(Self.iso),
                providerCreatedAt: try row.decode(column: "provider_created_at", as: Date?.self).map(Self.iso),
                providerVerifiedAt: try row.decode(column: "provider_verified_at", as: Date?.self).map(Self.iso),
                eventCount: try row.decode(column: "event_count", as: Int?.self))
        }
    }

    private func knownPersons() async throws -> [String] {
        guard let job = state.jobID else { return [] }
        var ids = Set(try await passRows(job).compactMap(\.personUuid))
        if let receipt = try await receiptRow(job) { ids.insert(receipt.person.uuidString.lowercased()) }
        return ids.sorted()
    }

    // MARK: HTTP into the app

    private func request(_ method: HTTPMethod, _ path: String, _ object: [String: Any]) async throws -> XCTHTTPResponse {
        guard let app, let jwt else { throw PostHogL7Failure("no application or session") }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: jwt)
        headers.contentType = .json
        var answer: XCTHTTPResponse?
        try await app.test(method, path, headers: headers, body: ByteBuffer(data: body),
                           afterResponse: { response async throws in answer = response })
        guard let answer else { throw PostHogL7Failure("no response from \(path)") }
        return answer
    }

    private func relay(_ name: String, _ properties: [String: String], _ revision: UUID) async throws -> HTTPStatus {
        try await request(.POST, "api/v2/measurement/events", [
            "eventId": UUID().uuidString, "occurredAt": Self.iso(Date().addingTimeInterval(1)),
            "consentRevision": revision.uuidString, "installationId": installation.uuidString,
            "event": ["schemaVersion": 1, "name": name, "properties": properties]]).status
    }

    private func waitUntil(timeout: TimeInterval, every: TimeInterval, _ check: () async throws -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if try await check() { return true }
            if Date() >= end { return false }
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
    }

    private func step(_ name: String, ok: Bool, _ detail: [String: String] = [:]) {
        state.steps.append(.init(at: Self.iso(Date()), name: name, ok: ok, detail: detail))
        let text = detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("POSTHOG-L7 \(ok ? "ok  " : "FAIL") \(name) \(text)")
    }

    private func saveState() async throws {
        state.calls = await router.allCalls()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        guard !PostHogL7Guard.containsSecret(String(decoding: data, as: UTF8.self), secrets) else {
            throw PostHogL7Failure("refusing to save state that contains key material")
        }
        try data.write(to: stateURL, options: .atomic)
    }

    // MARK: Report

    func writeReport(status: String, error: String?) async throws {
        state.calls = await router.allCalls()
        var job: PostHogL7Report.Job?
        var receipt: PostHogL7Report.Receipt?
        var passes: [PostHogL7Report.Pass] = []
        if app != nil, let jobID = state.jobID {
            let row = try await jobRow(jobID)
            job = .init(state: row.state, lastErrorKind: row.reason, completedAt: row.completedAt.map(Self.iso))
            if let r = try await receiptRow(jobID) {
                receipt = .init(phase: r.phase, round: r.round, personUuid: r.person.uuidString.lowercased(),
                                requestedAt: r.requestedAt.map(Self.iso), providerCreatedAt: r.providerCreatedAt.map(Self.iso),
                                eventsVerifiedAt: r.eventsVerifiedAt.map(Self.iso), profileAbsentAt: r.profileAbsentAt.map(Self.iso),
                                inFlightUntil: r.inFlightUntil.map(Self.iso), quietUntil: r.quietUntil.map(Self.iso),
                                completedAt: r.completedAt.map(Self.iso), manualReason: r.manualReason,
                                manualAt: r.manualAt.map(Self.iso))
            }
            passes = try await passRows(jobID)
        }
        let calls = state.calls
        let expectations = Self.expectations(variant: guardrail.lateCapture, steps: state.steps, calls: calls,
                                             job: job, passes: passes)
        let allMatch = !expectations.isEmpty && expectations.allSatisfy(\.matches)
        let conclusion: String
        switch (status, allMatch) {
        case ("finished", true):
            conclusion = "Matches PostHog's documented source semantics: late data survived the first deletion; "
                + "the job did not complete and is manual_required (\(job?.lastErrorKind ?? "?")) with every pass recorded."
        case ("finished", false):
            conclusion = "Finished with deviations from the documented semantics; read the expectations marked false. "
                + "A deviation in live mode is evidence about PostHog, not a harness failure."
        case ("waiting", _):
            conclusion = "Paused at the run-time limit; rerun with --resume against the same database and state file."
        default:
            conclusion = "Did not finish (\(status)); see the error and the last steps."
        }
        let parameters = [
            "label": "PROVISIONAL SANDBOX PARAMETERS - not a PostHog figure and not a production deletion guarantee",
            "ingestion_lag_window_s": "\(Int(guardrail.window))",
            "maximum_rounds": "\(PostHogErasureService.maximumRounds)",
            "observation_window_s": "\(Int(PostHogErasureService.observationWindow))",
            "harness_real_wait_s": "\(guardrail.realWait)",
            "harness_poll_s": "\(guardrail.poll)",
            "settle_and_quiet": "shortened by the harness only, after the real wait; the worker code paths are unchanged",
            "quiet_anchor": "max(pass 1 completion, request, in-flight bound) + window",
            "late_capture_variant": guardrail.lateCapture.rawValue]
        let report = PostHogL7Report(
            schemaVersion: 1, harness: "posthog-l7-real-transport", mode: guardrail.mode.rawValue, status: status,
            error: error, runId: state.runID, invocations: state.invocations, startedAt: state.startedAt,
            reportedAt: Self.iso(Date()), backendGitHead: guardrail.gitHead,
            target: ["capture": PostHogL7Guard.captureURL, "api": PostHogL7Guard.apiPrefix,
                     "transport": "MeasurementDirectHTTPClient and PostHogErasureHTTPClient (redirects refused)",
                     "routed_to": guardrail.mode == .live ? "PostHog EU sandbox" : "local fake PostHog \(guardrail.fakeBase ?? "")"],
            guards: ["project": PostHogL7Guard.sandboxProjectID, "subject_prefix": guardrail.subjectPrefix,
                     "erasure_key_file": (guardrail.erasureKeyFile as NSString).lastPathComponent + " (mode 0600, value never read into logs)",
                     "capture_config": (guardrail.captureConfigFile as NSString).lastPathComponent + " (mode 0600)",
                     "live_approval": guardrail.liveApproval ?? "none (dry run)", "operator": guardrail.operatorName],
            parameters: parameters,
            subject: ["distinct_id": state.opaque ?? "none", "job_id": state.jobID?.uuidString.lowercased() ?? "none",
                      "cutoff": state.revokedAt ?? "none", "in_flight_until": state.recordedInFlightUntil ?? "none"],
            steps: state.steps, providerCalls: calls, refusals: calls.filter { $0.refused != nil },
            job: job, receipt: receipt, passes: passes, expectations: expectations, conclusion: conclusion,
            secretScan: "no key value, PostHog key prefix or authorization header in this report")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(report)
        let markdown = Self.markdown(report)
        let directory = URL(fileURLWithPath: guardrail.outputDirectory)
        guard !PostHogL7Guard.containsSecret(String(decoding: json, as: UTF8.self) + markdown, secrets) else {
            try Data("{\"status\":\"withheld\",\"reason\":\"key material detected\"}\n".utf8)
                .write(to: directory.appendingPathComponent("\(guardrail.reportName)-report.json"), options: .atomic)
            throw PostHogL7Failure("the report contained key material and was withheld")
        }
        try json.write(to: directory.appendingPathComponent("\(guardrail.reportName)-report.json"), options: .atomic)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("\(guardrail.reportName)-report.md"), options: .atomic)
        try? await saveState()
        lastReport = report
    }

    static func expectations(variant: PostHogL7Guard.LateCapture, steps: [PostHogL7State.Step], calls: [PostHogL7Router.Call],
                             job: PostHogL7Report.Job?, passes: [PostHogL7Report.Pass]) -> [PostHogL7Report.Expectation] {
        func stepOK(_ prefix: String) -> (Bool, String) {
            guard let found = steps.last(where: { $0.name.hasPrefix(prefix) }) else { return (false, "step not reached") }
            return (found.ok, found.detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        let product = calls.filter { $0.origin == "product" && $0.refused == nil }
        let captures = product.filter { $0.endpoint == "capture" }
        let deletes = product.filter { $0.endpoint == "bulk_delete" }
        let statusPasses = passes.filter { $0.check == "deletion_status" }
        func statusText(_ call: PostHogL7Router.Call?) -> String { call?.status.map { String($0) } ?? "none" }
        func summaryText(_ call: PostHogL7Router.Call) -> String {
            call.summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        let captureStatuses = captures.map { statusText($0) }.joined(separator: ",")
        var list: [PostHogL7Report.Expectation] = []
        func add(_ id: String, _ description: String, _ expected: String, _ observed: String, _ matches: Bool) {
            list.append(.init(id: id, description: description, expected: expected, observed: observed, matches: matches))
        }
        add("E1", "Product captures through the real relay and outbox are accepted", "4 captures, all 2xx",
            "\(captures.count) captures, statuses \(captureStatuses)",
            captures.count == 4 && captures.allSatisfy { (200..<300).contains($0.status ?? 0) })
        let held = stepOK("held in-flight capture during withdrawal")
        add("E2", "Withdrawal waits for the held in-flight send and records its bound", "barrier waited and recorded", held.1, held.0)
        let settle = stepOK("settle:")
        add("E3", "No provider call before the in-flight bound plus the window", "0 calls, no receipt", settle.1, settle.0)
        let first = deletes.first
        add("E4", "Round 1: one bulk_delete answered 202 queuing exactly one person", "202, persons_queued_for_deletion=1",
            first.map { "status \(statusText($0)) \(summaryText($0))" } ?? "no request",
            first?.status == 202 && first?.summary["persons_queued_for_deletion"] == "1"
                && first?.summary["events_queued_for_deletion"] == "true")
        let fresh = statusPasses.first { $0.round == 1 && $0.outcome == "absent" }
        add("E5", "Round 1: deletion status created by this request and verified", "fresh created_at, delete_verified_at set",
            fresh.map { "created_at \($0.providerCreatedAt ?? "?") verified \($0.providerVerifiedAt ?? "?")" } ?? "no fresh status pass",
            fresh != nil)
        let restart = stepOK("worker restart mid-quiet")
        add("E6", "No provider call and no completion inside the quiet period, across a worker restart",
            "0 calls, still quiet", restart.1, restart.0)
        let injected = stepOK("late capture injected")
        let visible = stepOK("observation: late event stored")
        add("E7", "The late capture is accepted after the cutoff and later stored", "2xx, then event count >= 1",
            "\(injected.1) | \(visible.1)", injected.0 && visible.0)
        let late = passes.first { $0.round == 1 && $0.stage == "quiet" && $0.check == "events" && $0.outcome == "present" }
        add("E8", "Pass 2 (uncached Query API count) finds the late data", "events present, count >= 1",
            late.map { "count \($0.eventCount.map { String($0) } ?? "?")" } ?? "not found", (late?.eventCount ?? 0) >= 1)
        let primary: PostHogErasureService.ManualReason = variant == .afterPassOne ? .staleReceipt : .profilelessLateEvents
        let acceptable = [PostHogErasureService.ManualReason.staleReceipt.rawValue,
                          PostHogErasureService.ManualReason.profilelessLateEvents.rawValue]
        add("E9", "The job does not complete: manual_required with a reason distinguishing the case",
            "manual_required, \(primary.rawValue) expected for \(variant.rawValue) (either late-data reason is consistent with source)",
            "\(job?.state ?? "unknown") \(job?.lastErrorKind ?? "")",
            job?.state == "manual_required" && acceptable.contains(job?.lastErrorKind ?? ""))
        add("E10", "The job never reports completion", "completed_at absent",
            job?.completedAt ?? "absent", job != nil && job?.completedAt == nil && job?.state != "completed")
        if job?.lastErrorKind == PostHogErasureService.ManualReason.staleReceipt.rawValue {
            let stale = statusPasses.last { $0.outcome == "stale" }
            let second = deletes.dropFirst().first
            add("E11", "The re-issued deletion is answered 202 but its status is the original row",
                "202 for round 2; stale pass created_at == round 1 created_at",
                "round-2 status \(statusText(second)); stale created_at \(stale?.providerCreatedAt ?? "?"), round 1 \(fresh?.providerCreatedAt ?? "?")",
                second?.status == 202 && stale != nil && stale?.providerCreatedAt == fresh?.providerCreatedAt)
        }
        let shape = passes.prefix(4).map { "\($0.round)/\($0.stage)/\($0.check)/\($0.outcome)" }
        let expectedShape = ["1/deletion/deletion_status/absent", "1/deletion/profile/absent", "1/quiet/events/present"]
        let lastShape = passes.last.map { "\($0.stage)/\($0.check)/\($0.outcome)" } ?? "none"
        let expectedLast = job?.lastErrorKind == PostHogErasureService.ManualReason.staleReceipt.rawValue
            ? "deletion/deletion_status/stale" : "reresolve/profile/absent"
        add("E12", "Every provider pass is recorded", "starts \(expectedShape.joined(separator: ", ")), ends \(expectedLast)",
            "\(passes.count) passes: \(passes.map { "\($0.round)/\($0.stage)/\($0.check)/\($0.outcome)" }.joined(separator: ", "))",
            Array(shape.prefix(3)) == expectedShape && lastShape == expectedLast)
        let refused = calls.filter { $0.refused != nil }
        add("E13", "No request outside the sandbox allowlist was attempted", "0 refusals",
            refused.isEmpty ? "0 refusals" : refused.map { $0.refused ?? "" }.joined(separator: "; "), refused.isEmpty)
        return list
    }

    static func markdown(_ report: PostHogL7Report) -> String {
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
        var lines: [String] = []
        lines.append("# PostHog L7 harness report: \(report.mode), \(report.status)")
        lines.append("")
        lines.append("Run `\(report.runId)`, invocation \(report.invocations), backend `\(report.backendGitHead)`. Started \(report.startedAt), reported \(report.reportedAt).")
        lines.append("")
        lines.append("**Conclusion.** \(report.conclusion)")
        if let error = report.error { lines.append(""); lines.append("**Error.** \(cell(error))") }
        lines.append("")
        lines.append("Routed to: \(report.target["routed_to"] ?? "?"). Endpoints: `\(PostHogL7Guard.captureURL)` and `\(PostHogL7Guard.apiPrefix)` only. Transport: \(report.target["transport"] ?? "?").")
        lines.append("")
        lines.append("## Guards and parameters")
        lines.append("")
        for (key, value) in report.guards.sorted(by: { $0.key < $1.key }) { lines.append("- \(key): \(value)") }
        lines.append("")
        lines.append("**\(report.parameters["label"] ?? "")**")
        lines.append("")
        for (key, value) in report.parameters.sorted(by: { $0.key < $1.key }) where key != "label" { lines.append("- \(key): \(value)") }
        lines.append("")
        lines.append("Synthetic subject: `\(report.subject["distinct_id"] ?? "?")`, erasure job `\(report.subject["job_id"] ?? "?")`, cutoff \(report.subject["cutoff"] ?? "?").")
        lines.append("")
        lines.append("## Expectations")
        lines.append("")
        lines.append("| | Check | Expected | Observed | Match |")
        lines.append("| --- | --- | --- | --- | --- |")
        for e in report.expectations {
            lines.append("| \(e.id) | \(cell(e.description)) | \(cell(e.expected)) | \(cell(e.observed)) | \(e.matches ? "yes" : "**no**") |")
        }
        lines.append("")
        lines.append("## Erasure job")
        lines.append("")
        if let job = report.job {
            lines.append("- state: `\(job.state)`; last_error_kind: `\(job.lastErrorKind ?? "none")`; completed_at: \(job.completedAt ?? "absent")")
        }
        if let r = report.receipt {
            lines.append("- receipt: round \(r.round), phase `\(r.phase)`, person `\(r.personUuid)`, requested \(r.requestedAt ?? "-"), provider created \(r.providerCreatedAt ?? "-"), quiet until \(r.quietUntil ?? "-"), manual reason `\(r.manualReason ?? "none")` at \(r.manualAt ?? "-")")
        }
        lines.append("")
        lines.append("| # | Round | Stage | Check | Outcome | Count | Person | Requested | Provider created | Verified |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for p in report.passes {
            lines.append("| \(p.sequence) | \(p.round) | \(p.stage) | \(p.check) | \(p.outcome) | \(p.eventCount.map { String($0) } ?? "") | \(p.personUuid ?? "") | \(p.requestedAt ?? "") | \(p.providerCreatedAt ?? "") | \(p.providerVerifiedAt ?? "") |")
        }
        lines.append("")
        lines.append("## Timeline")
        lines.append("")
        lines.append("| Time | Step | OK | Detail |")
        lines.append("| --- | --- | --- | --- |")
        for s in report.steps {
            let detail = s.detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            lines.append("| \(s.at) | \(cell(s.name)) | \(s.ok ? "yes" : "**no**") | \(cell(detail)) |")
        }
        lines.append("")
        lines.append("## Provider requests (\(report.providerCalls.count); \(report.refusals.count) refused before sending)")
        lines.append("")
        lines.append("| # | Time | Origin | Request | Status | Summary |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for c in report.providerCalls {
            let summary = c.refused.map { "REFUSED: \($0)" }
                ?? c.summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            lines.append("| \(c.seq) | \(c.at) | \(c.origin) | \(c.method) \(c.endpoint) | \(c.status.map { String($0) } ?? "-") | \(cell(summary)) |")
        }
        lines.append("")
        lines.append("Secret scan: \(report.secretScan).")
        if report.mode == "live" {
            lines.append("")
            lines.append("The synthetic late event is left in the sandbox by design. Close it with POSTHOG-MANUAL-REMEDIATION.md; never by deleting the project without Dan's separate approval.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
