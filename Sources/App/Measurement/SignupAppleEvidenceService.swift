import Vapor
import Fluent
import FluentSQL

/// `POST /api/v2/measurement/signup-intents/:id/apple-evidence`. Exactly
/// `{capability, token, appVersion}`; the AdServices token is memory-only.
struct SignupAppleEvidenceRequest: Content, Sendable {
    let capability: String
    let token: String
    let appVersion: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["capability", "token", "appVersion"], decoder)
        capability = try c.decode(String.self, forKey: .init(stringValue: "capability")!)
        token = try c.decode(String.self, forKey: .init(stringValue: "token")!)
        appVersion = try c.decode(String.self, forKey: .init(stringValue: "appVersion")!)
    }
}

/// Apple Ads pre-auth campaign evidence for a genuine signup. Independent of ATT and
/// of cross-company consent; optional and never a prerequisite for authentication.
///
/// The slot is reserved for the exact intent (and so its installation) before the
/// account exists, the token is exchanged outside every database lock, and only the
/// existing bounded normalized outcome and provenance are stored. New-account adoption
/// links the slot to the exact Apple consent revision; a still-running exchange may
/// fill only that frozen slot after rechecking cancellation, the current revision and
/// account lifecycle. No slot before creation means no campaign join for that signup.
/// The signed-in collector reuses the linked canonical row instead of exchanging twice.
enum SignupAppleEvidenceService {
    /// A reservation still processing after this long is treated as abandoned by retention.
    static let processingTimeout: TimeInterval = 900

    static func marker(_ intentID: UUID) -> String { "$SignupIntent:" + intentID.uuidString.lowercased() }

    static func submit(intentID: UUID, input: SignupAppleEvidenceRequest, app: Application,
                       now: Date = Date(), on db: Database) async throws -> String {
        guard SignupIntentService.validOpaque(input.capability) else { throw SignupIntentService.notFound() }
        guard AdAttributionStore.Upload.isToken(input.token), AdAttributionStore.Upload.isAppVersion(input.appVersion) else {
            throw Abort(.badRequest, reason: "This measurement request could not be accepted", identifier: "ad_measurement_invalid")
        }
        guard await AdMeasurementPolicy.isEnabled(on: db) else {
            throw Abort(.serviceUnavailable, reason: "Measurement is switched off", identifier: "measurement_off")
        }
        let platform = try PlatformConfiguration.load(on: app)
        let expected = SignupIntentService.capabilityHash(input.capability)
        let appVersion = input.appVersion
        let claim: (reference: String, fresh: Bool) = try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let row = try await sql.raw("""
                SELECT state,capability_hash,apple_ads,environment,expires_at,apple_slot_reference
                FROM measurement_signup_intents WHERE id=\(bind:intentID) FOR UPDATE
                """).first(), let stored = try row.decode(column: "capability_hash", as: String?.self),
                  BrowserSessionService.constantTimeEqual(stored, expected) else { throw SignupIntentService.notFound() }
            if let existing = try row.decode(column: "apple_slot_reference", as: String?.self),
               let record = try await sql.raw("SELECT exchange_state FROM ad_attribution_records WHERE reference=\(bind:existing)").first() {
                // One exchange per slot: a settled slot answers with its reference.
                guard try record.decode(column: "exchange_state", as: String.self) != "processing" else {
                    throw Abort(.conflict, reason: "Apple measurement is already processing", identifier: "ad_measurement_processing")
                }
                return (existing, false)
            }
            guard ["issued", "bound"].contains(try row.decode(column: "state", as: String.self)),
                  try row.decode(column: "apple_ads", as: Bool?.self) == true,
                  try row.decode(column: "environment", as: String.self) == platform.environment,
                  try row.decode(column: "expires_at", as: Date.self) > now else { throw slotClosed() }
            let reference = try await insertSlot(intentID: intentID, appVersion: appVersion, now: now, on: sql)
            try await sql.raw("""
                UPDATE measurement_signup_intents SET apple_slot_reference=\(bind:reference),apple_slot_reserved_at=\(bind:now)
                WHERE id=\(bind:intentID)
                """).run()
            return (reference, true)
        }
        guard claim.fresh else { return claim.reference }
        // Outside every database lock. The token never leaves this function.
        guard let transport = AppleAttributionExchangeService.transport(app) else {
            try? await release(intentID: intentID, reference: claim.reference, on: db)
            throw Abort(.serviceUnavailable, reason: "Apple measurement is unavailable", identifier: "ad_measurement_unavailable")
        }
        let result = await AppleAttributionExchangeService.exchange(token: input.token, transport: transport,
                                                                     sleep: AppleAttributionExchangeService.sleep(app))
        switch result.outcome {
        case .attributed, .invalid:
            try await settle(intentID: intentID, reference: claim.reference, outcome: result.outcome,
                             attempts: result.attempts, app: app, on: db)
            return claim.reference
        case .notYetAvailable, .failing:
            // Release the reservation so the app may try again while still pre-auth.
            try? await release(intentID: intentID, reference: claim.reference, on: db)
            throw Abort(.serviceUnavailable, reason: "Apple measurement is temporarily unavailable", identifier: "ad_measurement_unavailable")
        }
    }

    /// Records the exchange only onto the frozen slot, after rechecking the intent's
    /// lifecycle under the shared lock order. Anything else discards the result.
    private static func settle(intentID: UUID, reference: String, outcome: AppleAttributionExchangeService.Outcome,
                               attempts: Int, app: Application, on db: Database) async throws {
        let recorded: Bool = try await lockedIntent(intentID, on: db) { tx, row in
            let sql = try VerifiedIdentityService.sql(tx)
            guard try row.decode(column: "apple_slot_reference", as: String?.self) == reference else {
                try await discard(reference: reference, on: sql)
                return false
            }
            let now = Date()
            switch try row.decode(column: "state", as: String.self) {
            case "issued", "bound":
                guard await AdMeasurementPolicy.isEnabled(on: tx) else {
                    try await discard(intentID: intentID, reference: reference, on: sql)
                    return false
                }
            case "consumed_new":
                guard let accountID = try row.decode(column: "account_id", as: UUID?.self),
                      let revision = try row.decode(column: "apple_revision", as: UUID?.self),
                      let installation = try row.decode(column: "installation_id", as: UUID?.self),
                      try await sql.raw("SELECT 1 FROM users WHERE id=\(bind:accountID) AND lifecycle_state='active'").first() != nil,
                      try await sql.raw("""
                        SELECT 1 FROM measurement_permission_current WHERE account_id=\(bind:accountID) AND purpose='appleAds'
                          AND revision=\(bind:revision) AND decision='granted'
                        """).first() != nil,
                      try await sql.raw("""
                        SELECT 1 FROM ad_attribution_records WHERE reference=\(bind:reference)
                          AND canonical_account_id=\(bind:accountID) AND canonical_consent_revision=\(bind:revision)
                          AND canonical_installation_id=\(bind:installation)
                        """).first() != nil,
                      await AdMeasurementPolicy.isEnabled(on: tx) else {
                    try await discard(intentID: intentID, reference: reference, on: sql)
                    return false
                }
            default:
                try await discard(intentID: intentID, reference: reference, on: sql)
                return false
            }
            let evidence: AdAttributionStore.Evidence
            if case .attributed(let fields) = outcome {
                evidence = ApplePurchaseOriginService.evidence(for: fields, app: app)
            } else { evidence = .unknown }
            guard try await AdAttributionStore.record(outcome, attempts: attempts, reference: reference,
                                                      evidence: evidence, now: now, on: tx) else { return false }
            if try row.decode(column: "state", as: String.self) == "consumed_new" {
                try await ApplePurchaseOriginService.reconcileAttribution(reference: reference, app: app, now: now, on: tx)
            }
            return true
        }
        guard recorded else { throw slotClosed() }
    }

    private static func release(intentID: UUID, reference: String, on db: Database) async throws {
        _ = try await lockedIntent(intentID, on: db) { tx, row -> Bool in
            let sql = try VerifiedIdentityService.sql(tx)
            guard try row.decode(column: "apple_slot_reference", as: String?.self) == reference else { return false }
            try await discard(intentID: intentID, reference: reference, on: sql)
            return true
        }
    }

    /// Shared lock order: an adopted intent takes account row → Apple purpose barrier →
    /// intent row, like permission mutation, deletion and cancellation; any other intent
    /// takes its row alone. A route change during discovery retries.
    static func lockedIntent<T: Sendable>(_ intentID: UUID, on db: Database,
                                          _ body: @escaping @Sendable (Database, SQLRow) async throws -> T) async throws -> T {
        let sql = try VerifiedIdentityService.sql(db)
        for _ in 0..<4 {
            guard let route = try await sql.raw("""
                SELECT state,account_id FROM measurement_signup_intents WHERE id=\(bind:intentID)
                """).first() else { throw SignupIntentService.notFound() }
            let state = try route.decode(column: "state", as: String.self)
            let account = try route.decode(column: "account_id", as: UUID?.self)
            let result: T? = try await db.transaction { tx in
                let txSQL = try VerifiedIdentityService.sql(tx)
                if state == "consumed_new", let account {
                    _ = try await txSQL.raw("SELECT id FROM users WHERE id=\(bind:account) FOR UPDATE").first()
                    try await VerifiedIdentityService.lock("measurement-permission:\(account.uuidString):appleAds", on: tx)
                }
                guard let row = try await txSQL.raw("""
                    SELECT state,account_id,apple_revision,installation_id,apple_slot_reference
                    FROM measurement_signup_intents WHERE id=\(bind:intentID) FOR UPDATE
                    """).first() else { throw SignupIntentService.notFound() }
                guard try row.decode(column: "state", as: String.self) == state,
                      try row.decode(column: "account_id", as: UUID?.self) == account else { return nil }
                return try await body(tx, row)
            }
            if let result { return result }
        }
        throw Abort(.conflict, reason: "This measurement choice is changing. Try again", identifier: "measurement_signup_intent_busy")
    }

    /// Inside the identity savepoint, for a new account whose Apple choice was adopted.
    /// Links the slot reserved before creation to the exact revision, installation and
    /// account. Never waits: a locked slot aborts the optional block instead.
    static func link(intentID: UUID, reference: String?, accountID: UUID, appleRevision: UUID,
                     installationID: UUID, on sql: SQLDatabase) async throws {
        guard let reference else { return }
        guard let record = try await sql.raw("""
            SELECT id FROM ad_attribution_records WHERE reference=\(bind:reference) AND canonical_account_id IS NULL
              AND rc_app_user_id=\(bind:marker(intentID)) FOR UPDATE NOWAIT
            """).first() else { return }
        try await sql.raw("""
            UPDATE ad_attribution_records SET canonical_account_id=\(bind:accountID),canonical_consent_revision=\(bind:appleRevision),
                canonical_installation_id=\(bind:installationID),rc_app_user_id=\(bind:accountID.uuidString)
            WHERE id=\(bind:try record.decode(column: "id", as: UUID.self))
            """).run()
    }

    /// Deletes this intent's slot row (linked or not) and clears the pointer. Caller
    /// holds the intent row and, for an adopted intent, the account and Apple barrier.
    static func discard(intentID: UUID, reference: String, on sql: SQLDatabase) async throws {
        try await discard(reference: reference, on: sql)
        try await sql.raw("""
            UPDATE measurement_signup_intents SET apple_slot_reference=NULL,apple_slot_reserved_at=NULL
            WHERE id=\(bind:intentID) AND apple_slot_reference=\(bind:reference)
            """).run()
    }

    static func discard(reference: String, on sql: SQLDatabase) async throws {
        let ids = try await sql.raw("SELECT id FROM ad_attribution_records WHERE reference=\(bind:reference) FOR UPDATE").all()
            .map { try $0.decode(column: "id", as: UUID.self) }
        try await ApplePurchaseOriginService.revoke(attributionIDs: ids, now: Date(), on: sql)
        try await sql.raw("DELETE FROM ad_attribution_records WHERE reference=\(bind:reference)").run()
    }

    /// Retention: unlinked slots of intents that can no longer adopt, and reservations
    /// abandoned while processing, are deleted before intents become tombstones.
    static func cleanup(now: Date = Date(), limit: Int = 500, on db: Database) async throws -> Int {
        let sql = try VerifiedIdentityService.sql(db)
        let candidates = try await sql.raw("""
            SELECT i.id,i.apple_slot_reference FROM measurement_signup_intents i
            JOIN ad_attribution_records a ON a.reference=i.apple_slot_reference
            WHERE (a.canonical_account_id IS NULL AND (i.state IN ('consumed_existing','cancelled','expired')
                                                       OR i.expires_at<=\(bind:now)))
               OR (a.exchange_state='processing' AND i.apple_slot_reserved_at<=\(bind:now.addingTimeInterval(-processingTimeout)))
            ORDER BY i.apple_slot_reserved_at LIMIT \(bind:max(0, min(limit, 5_000)))
            """).all()
        var removed = 0
        for candidate in candidates {
            let intentID = try candidate.decode(column: "id", as: UUID.self)
            let reference = try candidate.decode(column: "apple_slot_reference", as: String.self)
            let done = try? await lockedIntent(intentID, on: db) { tx, row -> Bool in
                guard try row.decode(column: "apple_slot_reference", as: String?.self) == reference else { return false }
                try await discard(intentID: intentID, reference: reference, on: try VerifiedIdentityService.sql(tx))
                return true
            }
            if done == true { removed += 1 }
        }
        return removed
    }

    private static func insertSlot(intentID: UUID, appVersion: String, now: Date, on sql: SQLDatabase) async throws -> String {
        for _ in 0..<3 {
            let reference = AdAttributionStore.newReference()
            if try await sql.raw("""
                INSERT INTO ad_attribution_records
                    (id,reference,rc_app_user_id,app_version,token,exchange_state,exchange_attempts,created_at)
                VALUES (\(bind:UUID()),\(bind:reference),\(bind:marker(intentID)),\(bind:appVersion),NULL,'processing',0,\(bind:now))
                ON CONFLICT DO NOTHING RETURNING reference
                """).first() != nil { return reference }
        }
        throw Abort(.conflict, reason: "Apple measurement is already processing", identifier: "ad_measurement_processing")
    }

    static func slotClosed() -> Abort {
        Abort(.conflict, reason: "Apple measurement for this sign-up is no longer available", identifier: "measurement_signup_slot_closed")
    }
}
