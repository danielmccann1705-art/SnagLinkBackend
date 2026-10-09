import Crypto
import Fluent
import FluentSQL
import Vapor

/// Product-purpose purchase-origin evidence and the conversion classification of
/// verified RevenueCat initial purchases (outputs PURCHASE-ORIGIN-OCT9.md).
///
/// The verified, deduplicated money ledger is unchanged. What changes is what product
/// analytics may say about a new-money candidate:
///
/// - `confirmed_origin`: this account's accepted StoreKit purchase callback witnessed the
///   same HMACed store transaction, under current product permission, and the witness
///   joined the verified charge exactly (account, product, environment, initial purchase,
///   charge no earlier than the intent, callback date within five minutes).
/// - `recovered_history`: evidence that the transaction was discovered rather than bought
///   here: the store transaction is already in the ledger under another (or an erased)
///   account, or this account's consented `restore_verified` arrived with RevenueCat's
///   event for a transaction that already existed before that restore.
/// - `unknown_origin`: neither. Never presented as confirmed, never dropped from the ledger.
///
/// Product analytics never reads advertising evidence. The cross-company and Apple
/// witnesses belong to their own consents; their presence is not borrowed and their
/// absence is not evidence. This purpose reuses the same exact-callback contract as
/// `PurchaseOriginService`: a short-lived capability issued before StoreKit, completed
/// only from the accepted purchase callback (never restore, refresh or delegate).
/// Purchase age is a freshness label (`reportLag`), never proof.
enum ProductPurchaseOriginService {
    enum Origin: String, Sendable, CaseIterable {
        case confirmedOrigin = "confirmed_origin"
        case recoveredHistory = "recovered_history"
        case unknownOrigin = "unknown_origin"
    }

    /// A witness is accepted only while its intent is live (15 minutes from issue) and a
    /// match needs the charge no earlier than the issue, so every witness that can ever
    /// confirm a charge exists by `purchased_at + 15 min`. An undecided initial purchase
    /// waits this long, with margin, before dispatch freezes its classification.
    static let settleWindow: TimeInterval = 30 * 60
    /// A consented restore observed this close to RevenueCat's event generation is the
    /// restore that reported the transaction. The transaction must also predate that
    /// restore by the settle window, so a restore tapped just after a purchase never
    /// relabels that purchase.
    static let restoreWindow: TimeInterval = 30 * 60
    /// RevenueCat: `event_timestamp_ms` "doesn't necessarily coincide with when the action
    /// that triggered the event occurred". The lag is a sanity label only.
    static let reportLagThreshold: TimeInterval = 72 * 3_600

    static func reportLag(_ fact: RevenueCatLifecycleFact) -> String {
        fact.eventGeneratedAt.timeIntervalSince(fact.purchasedAt) > reportLagThreshold ? "over_72h" : "within_72h"
    }

    // MARK: - Product-purpose intent and witness

    static func prepare(accountID: UUID, input: MeasurementPurchaseIntentRequest, app: Application,
                        now: Date = Date(), on db: Database) async throws -> MeasurementPurchaseIntentResponse {
        guard PurchaseOriginService.products.contains(input.productId) else { throw invalid() }
        guard let config = PurchaseOriginService.configuration(app),
              try await FeatureFlagService.resolve(on: db)["productAnalyticsEnabled"] == true else { throw unavailable() }
        let capability = try SecureTokenGenerator.generate()
        let id = UUID(), expires = now.addingTimeInterval(PurchaseOriginService.intentLifetime)
        try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):productAnalytics", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard let subjectID = try await currentSubject(accountID, input.consentRevision, authorityAt: now, sql) else {
                throw permissionRequired()
            }
            try await sql.raw("""
                INSERT INTO measurement_purchase_intents
                    (id,capability_hash,account_id,installation_id,consent_revision,subject_id,product_id,purpose,
                     environment,state,issued_at,expires_at)
                VALUES (\(bind:id),\(bind:capabilityHash(capability)),\(bind:accountID),\(bind:input.installationId),
                        \(bind:input.consentRevision),\(bind:subjectID),\(bind:input.productId),'productAnalytics',
                        \(bind:config.environment.rawValue),'prepared',\(bind:now),\(bind:expires))
                """).run()
        }
        return .init(intentId: id, capability: capability, expiresAt: expires)
    }

    static func complete(accountID: UUID, intentID: UUID, input: MeasurementPurchaseWitnessRequest,
                         app: Application, now: Date = Date(), on db: Database) async throws -> PurchaseOriginService.Completion {
        guard let config = PurchaseOriginService.configuration(app),
              try await FeatureFlagService.resolve(on: db)["productAnalyticsEnabled"] == true else { throw unavailable() }
        guard PurchaseOriginService.products.contains(input.productId), input.source == "purchaseCallback",
              validReference(input.transactionId), validCapability(input.capability) else { throw invalid() }
        return try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):productAnalytics", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard let candidate = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID) AND purpose='productAnalytics'
                """).first(), try candidate.decode(column: "account_id", as: UUID.self) == accountID,
                  ConstantTimeComparison.compare(try candidate.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            let environment = try candidate.decode(column: "environment", as: String.self)
            let transactionHMAC = PurchaseOriginService.hmac("transaction", environment, input.transactionId, config.hmacKey)
            // Same lock order as RevenueCat ingestion: charge, then transaction.
            if let route = try await sql.raw("""
                SELECT durable_key_hash FROM measurement_revenuecat_events
                WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1
                """).first(), let chargeKey = try route.decode(column: "durable_key_hash", as: String?.self) {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(chargeKey)", on: tx)
            }
            try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transactionHMAC)", on: tx)
            guard let intent = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID) AND purpose='productAnalytics' FOR UPDATE
                """).first(), try intent.decode(column: "account_id", as: UUID.self) == accountID,
                  ConstantTimeComparison.compare(try intent.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            let hash = witnessHash(transactionHMAC, input)
            guard environment == config.environment.rawValue,
                  try intent.decode(column: "product_id", as: String.self) == input.productId else {
                try await markConflict(intentID, hash: hash, sql); return .conflict
            }
            let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
            guard input.purchaseDate >= issuedAt.addingTimeInterval(-PurchaseOriginService.issuanceTolerance),
                  input.purchaseDate <= now.addingTimeInterval(PurchaseOriginService.futureSkew) else { throw invalid() }
            let state = try intent.decode(column: "state", as: String.self)
            if state != "prepared" {
                guard try intent.decode(column: "witness_hash", as: String?.self) == hash else {
                    try await markConflict(intentID, hash: hash, sql); return .conflict
                }
                return state == "conflict" || state == "revoked" ? .conflict : .accepted
            }
            guard try intent.decode(column: "expires_at", as: Date.self) > now else {
                throw Abort(.gone, reason: "Purchase measurement intent expired",
                            identifier: "measurement_purchase_intent_expired")
            }
            let revision = try intent.decode(column: "consent_revision", as: UUID.self)
            guard let subject = try intent.decode(column: "subject_id", as: UUID?.self),
                  try await currentSubject(accountID, revision, authorityAt: input.purchaseDate, sql) == subject else {
                throw permissionRequired()
            }
            if let other = try await sql.raw("""
                SELECT id FROM measurement_purchase_intents
                WHERE purpose='productAnalytics' AND transaction_key_hmac=\(bind:transactionHMAC) AND id<>\(bind:intentID) LIMIT 1
                """).first() {
                try await markConflict(intentID, hash: hash, sql)
                try await markConflict(try other.decode(column: "id", as: UUID.self), hash: hash, sql)
                return .conflict
            }
            try await sql.raw("""
                UPDATE measurement_purchase_intents SET state='witnessed',witness_hash=\(bind:hash),
                    transaction_key_hmac=\(bind:transactionHMAC),purchase_observed_at=\(bind:input.purchaseDate),
                    witnessed_at=\(bind:now),pending_expires_at=\(bind:now.addingTimeInterval(PurchaseOriginService.pendingLifetime))
                WHERE id=\(bind:intentID)
                """).run()
            if let charge = try await sql.raw("""
                SELECT * FROM measurement_revenuecat_events WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1
                """).first() {
                return try await match(intentID: intentID, intent: intent, charge: charge,
                                       witnessDate: input.purchaseDate, sql)
            }
            return .accepted
        }
    }

    /// Runs inside authenticated RevenueCat ingestion, after the charge row exists.
    /// Records only the local join; never performs network I/O.
    static func acceptRevenueCatCharge(_ fact: RevenueCatLifecycleFact, chargeID: UUID,
                                       app: Application, now: Date, on db: Database) async throws {
        guard fact.isPositiveCharge, fact.kind == .initialPurchase,
              let config = PurchaseOriginService.configuration(app), fact.environment == config.environment else { return }
        let sql = try VerifiedIdentityService.sql(db)
        let transactionHMAC = PurchaseOriginService.hmac("transaction", fact.environment.rawValue, fact.transactionID, config.hmacKey)
        let chainHMAC = PurchaseOriginService.hmac("chain", fact.environment.rawValue, fact.originalTransactionID, config.hmacKey)
        try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transactionHMAC)", on: db)
        guard let owner = try await sql.raw("SELECT account_id FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").first(),
              try owner.decode(column: "account_id", as: UUID?.self) == fact.accountID,
              try await sql.raw("""
                SELECT 1 FROM measurement_revenuecat_events
                WHERE transaction_key_hmac=\(bind:transactionHMAC) AND id<>\(bind:chargeID) LIMIT 1
                """).first() == nil else { return }
        try await sql.raw("""
            UPDATE measurement_revenuecat_events SET product_id=COALESCE(product_id,\(bind:fact.productID)),
                transaction_key_hmac=COALESCE(transaction_key_hmac,\(bind:transactionHMAC)),
                chain_key_hmac=COALESCE(chain_key_hmac,\(bind:chainHMAC)) WHERE id=\(bind:chargeID)
            """).run()
        guard let intent = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE purpose='productAnalytics'
                  AND transaction_key_hmac=\(bind:transactionHMAC) AND state='witnessed' AND pending_expires_at>\(bind:now)
                FOR UPDATE
                """).first(),
              let charge = try await sql.raw("SELECT * FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").first()
        else { return }
        _ = try await match(intentID: try intent.decode(column: "id", as: UUID.self), intent: intent, charge: charge,
                            witnessDate: try intent.decode(column: "purchase_observed_at", as: Date.self), sql)
    }

    private static func match(intentID: UUID, intent: SQLRow, charge: SQLRow, witnessDate: Date,
                              _ sql: SQLDatabase) async throws -> PurchaseOriginService.Completion {
        let chargeID = try charge.decode(column: "id", as: UUID.self)
        let account = try intent.decode(column: "account_id", as: UUID.self)
        let revision = try intent.decode(column: "consent_revision", as: UUID.self)
        let subject = try intent.decode(column: "subject_id", as: UUID?.self)
        let chargedAt = try charge.decode(column: "purchased_at", as: Date.self)
        let lifecycleConflicted: Bool
        if let chargeKey = try charge.decode(column: "durable_key_hash", as: String?.self) {
            lifecycleConflicted = try await sql.raw("""
                SELECT 1 FROM measurement_revenuecat_lifecycle_events
                WHERE charge_key_hash=\(bind:chargeKey) AND (conflict_hash IS NOT NULL OR resolution='unresolved') LIMIT 1
                """).first() != nil
        } else {
            lifecycleConflicted = true
        }
        let chargeAccount = try charge.decode(column: "account_id", as: UUID?.self)
        let chargeProduct = try charge.decode(column: "product_id", as: String?.self)
        let chargeEnvironment = try charge.decode(column: "environment", as: String.self)
        let chargeKind = try charge.decode(column: "charge_kind", as: String.self)
        let product = try intent.decode(column: "product_id", as: String.self)
        let environment = try intent.decode(column: "environment", as: String.self)
        let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
        let exact = account == chargeAccount && product == chargeProduct && environment == chargeEnvironment
            && chargeKind == RevenueCatLifecycleFact.Kind.initialPurchase.rawValue
            && chargedAt >= issuedAt
            && abs(witnessDate.timeIntervalSince(chargedAt)) <= PurchaseOriginService.providerDateTolerance
            && !lifecycleConflicted
        guard exact, let subject,
              try await currentSubject(account, revision, authorityAt: chargedAt, sql) == subject else {
            try await markConflict(intentID, hash: nil, sql)
            return .conflict
        }
        try await sql.raw("""
            UPDATE measurement_purchase_intents SET state='matched',matched_charge_id=\(bind:chargeID) WHERE id=\(bind:intentID)
            """).run()
        return .accepted
    }

    /// Product withdrawal and subject rotation delete this purpose's evidence.
    static func revoke(subjectIDs: [UUID], on sql: SQLDatabase) async throws {
        for subject in subjectIDs {
            try await sql.raw("""
                DELETE FROM measurement_purchase_intents WHERE purpose='productAnalytics' AND subject_id=\(bind:subject)
                """).run()
        }
    }

    // MARK: - Classification

    /// When an initial purchase's product job may first be claimed. Confirmed at ingest is
    /// final (confirmation outranks every other class); otherwise wait for the settle window.
    static func availableAt(chargeID: UUID?, accountID: UUID, subjectID: UUID, revision: UUID,
                            purchasedAt: Date, now: Date, on sql: SQLDatabase) async throws -> Date {
        if let chargeID, try await confirmed(chargeID: chargeID, accountID: accountID, subjectID: subjectID,
                                             revision: revision, sql) {
            return now
        }
        return max(now, purchasedAt).addingTimeInterval(settleWindow)
    }

    /// Frozen into the job payload at its first dispatch attempt. Precedence:
    /// confirmed, then recovered, then unknown.
    static func classify(sourceKind: String, sourceID: UUID, accountID: UUID, subjectID: UUID, revision: UUID,
                         on sql: SQLDatabase) async throws -> Origin {
        let row: SQLRow?
        switch sourceKind {
        case "revenueCatLifecycle":
            row = try await sql.raw("""
                SELECT account_id,occurred_at,purchased_at FROM measurement_revenuecat_events WHERE id=\(bind:sourceID)
                """).first()
        case "revenueCatEvent":
            row = try await sql.raw("""
                SELECT account_id,event_generated_at AS occurred_at,purchased_at
                FROM measurement_revenuecat_lifecycle_events WHERE id=\(bind:sourceID)
                """).first()
        default:
            return .unknownOrigin
        }
        guard let row else { return .unknownOrigin }
        guard try row.decode(column: "account_id", as: UUID?.self) == accountID else { return .recoveredHistory }
        if sourceKind == "revenueCatLifecycle",
           try await confirmed(chargeID: sourceID, accountID: accountID, subjectID: subjectID, revision: revision, sql) {
            return .confirmedOrigin
        }
        let occurredAt = try row.decode(column: "occurred_at", as: Date.self)
        let purchasedAt = try row.decode(column: "purchased_at", as: Date.self)
        let restored = try await sql.raw("""
            SELECT 1 FROM measurement_product_events
            WHERE account_id=\(bind:accountID) AND subject_id=\(bind:subjectID) AND event_name='restore_verified'
              AND revoked_at IS NULL
              AND received_at>=\(bind:occurredAt.addingTimeInterval(-restoreWindow))
              AND received_at<=\(bind:occurredAt.addingTimeInterval(restoreWindow))
              AND received_at>=\(bind:purchasedAt.addingTimeInterval(settleWindow))
            LIMIT 1
            """).first() != nil
        return restored ? .recoveredHistory : .unknownOrigin
    }

    private static func confirmed(chargeID: UUID, accountID: UUID, subjectID: UUID, revision: UUID,
                                  _ sql: SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM measurement_purchase_intents
            WHERE purpose='productAnalytics' AND state='matched' AND matched_charge_id=\(bind:chargeID)
              AND account_id=\(bind:accountID) AND subject_id=\(bind:subjectID) AND consent_revision=\(bind:revision)
            LIMIT 1
            """).first() != nil
    }

    // MARK: - Helpers

    private static func currentSubject(_ account: UUID, _ revision: UUID, authorityAt: Date,
                                       _ sql: SQLDatabase) async throws -> UUID? {
        try await sql.raw("""
            SELECT c.subject_id FROM measurement_permission_current c
            JOIN measurement_subjects s ON s.id=c.subject_id AND s.state='active'
            WHERE c.account_id=\(bind:account) AND c.purpose='productAnalytics' AND c.decision='granted'
              AND c.revision=\(bind:revision) AND c.updated_at<=\(bind:authorityAt)
              AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.state<>'completed')
            """).first()?.decode(column: "subject_id", as: UUID.self)
    }

    private static func markConflict(_ id: UUID, hash: String?, _ sql: SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE measurement_purchase_intents SET state='conflict',
                conflict_hash=COALESCE(conflict_hash,\(bind:hash),witness_hash) WHERE id=\(bind:id)
            """).run()
    }

    private static func witnessHash(_ transactionHMAC: String, _ input: MeasurementPurchaseWitnessRequest) -> String {
        SHA256Hasher.hash(token: ["product", transactionHMAC, input.productId,
            String(Int64((input.purchaseDate.timeIntervalSince1970 * 1_000).rounded())), input.source].joined(separator: "|"))
    }
    private static func capabilityHash(_ value: String) -> String {
        SHA256Hasher.hash(token: "product-purchase-origin-capability:v1:\(value)")
    }
    private static func validReference(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func validCapability(_ value: String) -> Bool {
        (32...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func unavailable() -> Abort {
        .init(.serviceUnavailable, reason: "Purchase measurement is unavailable", identifier: "measurement_purchase_unavailable")
    }
    private static func permissionRequired() -> Abort {
        .init(.forbidden, reason: "Current purchase measurement permission is required",
              identifier: "measurement_purchase_permission_required")
    }
    private static func invalid() -> Abort {
        .init(.badRequest, reason: "Use a valid purchase measurement request", identifier: "measurement_purchase_invalid")
    }
}
