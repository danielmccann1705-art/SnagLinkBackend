import Crypto
import Fluent
import FluentSQL
import Vapor

struct MeasurementPurchaseIntentRequest: Content, Sendable {
    let installationId: UUID
    let consentRevision: UUID
    let productId: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["installationId", "consentRevision", "productId"], decoder)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        consentRevision = try c.decode(UUID.self, forKey: .init(stringValue: "consentRevision")!)
        productId = try c.decode(String.self, forKey: .init(stringValue: "productId")!)
    }
}

struct MeasurementPurchaseIntentResponse: Content, Sendable {
    let intentId: UUID
    let capability: String
    let expiresAt: Date
}

struct MeasurementPurchaseWitnessRequest: Content, Sendable {
    let capability: String
    let transactionId: String
    let productId: String
    let purchaseDate: Date
    let source: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["capability", "transactionId", "productId", "purchaseDate", "source"], decoder)
        capability = try c.decode(String.self, forKey: .init(stringValue: "capability")!)
        transactionId = try c.decode(String.self, forKey: .init(stringValue: "transactionId")!)
        productId = try c.decode(String.self, forKey: .init(stringValue: "productId")!)
        purchaseDate = try c.decode(Date.self, forKey: .init(stringValue: "purchaseDate")!)
        source = try c.decode(String.self, forKey: .init(stringValue: "source")!)
    }
}

/// Optional acquisition-origin evidence. These endpoints are side effects around
/// StoreKit, never part of purchase fulfilment. A match never creates an ad job.
enum PurchaseOriginService {
    static let intentLifetime: TimeInterval = 15 * 60
    static let pendingLifetime: TimeInterval = 7 * 86_400
    static let futureSkew: TimeInterval = 300
    static let issuanceTolerance: TimeInterval = 300
    static let providerDateTolerance: TimeInterval = 300
    static let products: Set<String> = ["com.snaglist.pro.monthly", "com.snaglist.pro.annual"]

    struct Configuration: Sendable {
        let hmacKey: Data
        let environment: LinkedInConversion.Environment
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }
    enum Completion: Sendable, Equatable { case accepted, conflict }

    static func configuration(_ app: Application) -> Configuration? {
        if app.environment == .testing { return app.storage[ConfigurationKey.self] }
        guard let raw = Environment.get("MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY"),
              let key = Data(base64Encoded: raw), key.count == 32,
              let environment = LinkedInConversion.Environment(
                rawValue: Environment.get("MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT") ?? "") else { return nil }
        return .init(hmacKey: key, environment: environment)
    }

    static func prepare(accountID: UUID, input: MeasurementPurchaseIntentRequest, app: Application,
                        now: Date = Date(), on db: Database) async throws -> MeasurementPurchaseIntentResponse {
        guard products.contains(input.productId) else { throw invalid() }
        guard let config = configuration(app),
              try await FeatureFlagService.resolve(on: db)["crossCompanyAdsEnabled"] == true else { throw unavailable() }
        let capability = try SecureTokenGenerator.generate()
        let id = UUID(), expires = now.addingTimeInterval(intentLifetime)
        try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):crossCompanyAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard let row = try await sql.raw("""
                SELECT c.subject_id FROM measurement_permission_current c
                JOIN measurement_subjects s ON s.id=c.subject_id AND s.state='active'
                WHERE c.account_id=\(bind:accountID) AND c.purpose='crossCompanyAds'
                  AND c.revision=\(bind:input.consentRevision) AND c.decision='granted'
                  AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e
                                 WHERE e.subject_id=s.id AND e.state<>'completed')
                """).first(),
                  try await sql.raw("""
                    SELECT 1 FROM measurement_att_assertions
                    WHERE account_id=\(bind:accountID) AND installation_id=\(bind:input.installationId)
                      AND consent_revision=\(bind:input.consentRevision)
                      AND status='authorized' AND expires_at>\(bind:now)
                    """).first() != nil else { throw permissionRequired() }
            let subjectID = try row.decode(column: "subject_id", as: UUID.self)
            try await sql.raw("""
                INSERT INTO measurement_purchase_intents
                    (id,capability_hash,account_id,installation_id,consent_revision,subject_id,product_id,
                     environment,state,issued_at,expires_at)
                VALUES (\(bind:id),\(bind:capabilityHash(capability)),\(bind:accountID),\(bind:input.installationId),
                        \(bind:input.consentRevision),\(bind:subjectID),\(bind:input.productId),
                        \(bind:config.environment.rawValue),'prepared',\(bind:now),\(bind:expires))
                """).run()
        }
        return .init(intentId: id, capability: capability, expiresAt: expires)
    }

    static func complete(accountID: UUID, intentID: UUID, input: MeasurementPurchaseWitnessRequest,
                         app: Application, now: Date = Date(), on db: Database) async throws -> Completion {
        guard let config = configuration(app),
              try await FeatureFlagService.resolve(on: db)["crossCompanyAdsEnabled"] == true else { throw unavailable() }
        guard products.contains(input.productId), input.source == "purchaseCallback",
              validReference(input.transactionId), validCapability(input.capability) else { throw invalid() }
        return try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):crossCompanyAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard let candidate = try await sql.raw("SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID)").first() else {
                throw Abort(.notFound)
            }
            guard try candidate.decode(column: "account_id", as: UUID.self) == accountID else { throw Abort(.notFound) }
            guard ConstantTimeComparison.compare(try candidate.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            let environment = try candidate.decode(column: "environment", as: String.self)
            let transactionHMAC = hmac("transaction", environment, input.transactionId, config.hmacKey)

            // RevenueCat ingestion takes the durable charge lock before purchase
            // transaction and chain locks. Discovering an already committed charge
            // without a row lock lets completion take that same order, while an
            // uncommitted provider arrival safely finishes matching after this
            // short transaction releases the transaction lock.
            if let route = try await sql.raw("""
                SELECT durable_key_hash FROM measurement_revenuecat_events
                WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1
                """).first(),
               let chargeKey = try route.decode(column: "durable_key_hash", as: String?.self) {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(chargeKey)", on: tx)
            }
            try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transactionHMAC)", on: tx)

            guard let intent = try await sql.raw("SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID) FOR UPDATE").first() else {
                throw Abort(.notFound)
            }
            guard try intent.decode(column: "account_id", as: UUID.self) == accountID else { throw Abort(.notFound) }
            guard ConstantTimeComparison.compare(try intent.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            guard environment == config.environment.rawValue,
                  try intent.decode(column: "environment", as: String.self) == environment,
                  try intent.decode(column: "product_id", as: String.self) == input.productId else {
                try await markIntentConflict(intentID, hash: conflictHash(input, environment), on: sql)
                return .conflict
            }
            let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
            guard input.purchaseDate >= issuedAt.addingTimeInterval(-issuanceTolerance),
                  input.purchaseDate <= now.addingTimeInterval(futureSkew) else { throw invalid() }
            let witnessHash = normalizedWitnessHash(transactionHMAC, input)
            let state = try intent.decode(column: "state", as: String.self)
            if state != "prepared" {
                guard try intent.decode(column: "witness_hash", as: String?.self) == witnessHash else {
                    try await markIntentConflict(intentID, hash: witnessHash, on: sql)
                    return .conflict
                }
                return state == "conflict" || state == "revoked" ? .conflict : .accepted
            }
            guard try intent.decode(column: "expires_at", as: Date.self) > now else {
                throw Abort(.gone, reason: "Purchase measurement intent expired",
                            identifier: "measurement_purchase_intent_expired")
            }
            let revision = try intent.decode(column: "consent_revision", as: UUID.self)
            let installation = try intent.decode(column: "installation_id", as: UUID.self)
            let subject = try intent.decode(column: "subject_id", as: UUID.self)
            guard try await permissionCurrent(accountID, revision, installation, subject, now, sql) else {
                throw permissionRequired()
            }
            if let other = try await sql.raw("""
                SELECT id FROM measurement_purchase_intents
                WHERE transaction_key_hmac=\(bind:transactionHMAC) AND id<>\(bind:intentID) LIMIT 1
                """).first() {
                let otherID = try other.decode(column: "id", as: UUID.self)
                try await markIntentConflict(intentID, hash: witnessHash, on: sql)
                try await markIntentConflict(otherID, hash: witnessHash, on: sql)
                return .conflict
            }
            try await sql.raw("""
                UPDATE measurement_purchase_intents SET state='witnessed',witness_hash=\(bind:witnessHash),
                    transaction_key_hmac=\(bind:transactionHMAC),purchase_observed_at=\(bind:input.purchaseDate),
                    witnessed_at=\(bind:now),pending_expires_at=\(bind:now.addingTimeInterval(pendingLifetime))
                WHERE id=\(bind:intentID)
                """).run()
            if let charge = try await sql.raw("""
                SELECT * FROM measurement_revenuecat_events
                WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1
                """).first() {
                if let chain = try charge.decode(column: "chain_key_hmac", as: String?.self) {
                    try await VerifiedIdentityService.lock("measurement-purchase-chain:\(chain)", on: tx)
                }
                guard try await FeatureFlagService.resolve(on: tx)["crossCompanyAdsEnabled"] == true else {
                    throw unavailable()
                }
                return try await matchInitial(intentID: intentID, intent: intent, charge: charge,
                                              witnessDate: input.purchaseDate, now: now, on: sql)
            }
            return .accepted
        }
    }

    /// Runs inside authenticated RevenueCat ingestion and never performs network I/O.
    static func acceptRevenueCatCharge(_ fact: RevenueCatLifecycleFact, chargeID: UUID,
                                       app: Application, now: Date, on db: Database) async throws {
        guard fact.isPositiveCharge, let config = configuration(app),
              fact.environment == config.environment else { return }
        let sql = try VerifiedIdentityService.sql(db)
        let transactionHMAC = hmac("transaction", fact.environment.rawValue, fact.transactionID, config.hmacKey)
        let chainHMAC = hmac("chain", fact.environment.rawValue, fact.originalTransactionID, config.hmacKey)
        try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transactionHMAC)", on: db)
        try await VerifiedIdentityService.lock("measurement-purchase-chain:\(chainHMAC)", on: db)
        if let other = try await sql.raw("""
            SELECT id FROM measurement_revenuecat_events
            WHERE transaction_key_hmac=\(bind:transactionHMAC) AND id<>\(bind:chargeID) LIMIT 1
            """).first() {
            let otherID = try other.decode(column: "id", as: UUID.self)
            try await sql.raw("""
                UPDATE measurement_purchase_intents SET state='conflict',conflict_hash=COALESCE(conflict_hash,witness_hash)
                WHERE transaction_key_hmac=\(bind:transactionHMAC)
                """).run()
            try await sql.raw("""
                UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=\(bind:now)
                WHERE initial_charge_id IN (\(bind:chargeID),\(bind:otherID))
                  AND state<>'revoked'
                """).run()
            return
        }
        try await sql.raw("""
            UPDATE measurement_revenuecat_events SET product_id=\(bind:fact.productID),
                transaction_key_hmac=COALESCE(transaction_key_hmac,\(bind:transactionHMAC)),
                chain_key_hmac=COALESCE(chain_key_hmac,\(bind:chainHMAC)) WHERE id=\(bind:chargeID)
            """).run()
        if fact.kind == .renewal {
            guard let acquisition = try await sql.raw("""
                SELECT * FROM measurement_purchase_acquisitions
                WHERE chain_key_hmac=\(bind:chainHMAC) FOR UPDATE
                """).first() else { return }
            let acquisitionID = try acquisition.decode(column: "id", as: UUID.self)
            let acquisitionState = try acquisition.decode(column: "state", as: String.self)
            if acquisitionState == "revoked" { return }
            guard acquisitionState == "active",
                  try acquisition.decode(column: "account_id", as: UUID?.self) == fact.accountID,
                  try acquisition.decode(column: "product_id", as: String?.self) == fact.productID,
                  try acquisition.decode(column: "environment", as: String.self) == fact.environment.rawValue else {
                try await sql.raw("""
                    UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=\(bind:now)
                    WHERE id=\(bind:acquisitionID)
                    """).run()
                return
            }
            try await sql.raw("""
                UPDATE measurement_revenuecat_events SET origin_acquisition_id=\(bind:acquisitionID)
                WHERE id=\(bind:chargeID)
                """).run()
            return
        }
        guard fact.kind == .initialPurchase,
              let intent = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE transaction_key_hmac=\(bind:transactionHMAC)
                  AND state='witnessed' AND pending_expires_at>\(bind:now) FOR UPDATE
                """).first(),
              let charge = try await sql.raw("SELECT * FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").first() else { return }
        let account = try intent.decode(column: "account_id", as: UUID.self)
        let revision = try intent.decode(column: "consent_revision", as: UUID.self)
        let installation = try intent.decode(column: "installation_id", as: UUID.self)
        let subject = try intent.decode(column: "subject_id", as: UUID.self)
        guard try await FeatureFlagService.resolve(on: db)["crossCompanyAdsEnabled"] == true,
              try await permissionCurrent(account, revision, installation, subject, now, sql,
                                          authorityAt: fact.purchasedAt) else { return }
        _ = try await matchInitial(intentID: intent.decode(column: "id", as: UUID.self), intent: intent,
                                   charge: charge, witnessDate: intent.decode(column: "purchase_observed_at", as: Date.self),
                                   now: now, on: sql)
    }

    private static func matchInitial(intentID: UUID, intent: SQLRow, charge: SQLRow, witnessDate: Date,
                                     now: Date, on sql: SQLDatabase) async throws -> Completion {
        let chargeID = try charge.decode(column: "id", as: UUID.self)
        let account = try intent.decode(column: "account_id", as: UUID.self)
        let installation = try intent.decode(column: "installation_id", as: UUID.self)
        let revision = try intent.decode(column: "consent_revision", as: UUID.self)
        let subject = try intent.decode(column: "subject_id", as: UUID.self)
        let product = try intent.decode(column: "product_id", as: String.self)
        let environment = try intent.decode(column: "environment", as: String.self)
        let chargeAccount = try charge.decode(column: "account_id", as: UUID?.self)
        let chargeProduct = try charge.decode(column: "product_id", as: String?.self)
        let chargeEnvironment = try charge.decode(column: "environment", as: String.self)
        let chargeKind = try charge.decode(column: "charge_kind", as: String.self)
        let chargeKey = try charge.decode(column: "durable_key_hash", as: String?.self)
        let chargedAt = try charge.decode(column: "purchased_at", as: Date.self)
        let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
        let permissionStillCurrent = try await permissionCurrent(
            account, revision, installation, subject, now, sql, authorityAt: chargedAt)
        let lifecycleConflicted: Bool
        if let chargeKey {
            lifecycleConflicted = try await sql.raw("""
                SELECT 1 FROM measurement_revenuecat_lifecycle_events
                WHERE charge_key_hash=\(bind:chargeKey)
                  AND (conflict_hash IS NOT NULL OR resolution='unresolved') LIMIT 1
                """).first() != nil
        } else {
            lifecycleConflicted = true
        }
        let exact = account == chargeAccount && product == chargeProduct
            && environment == chargeEnvironment && chargeKind == "initial_purchase"
            && chargedAt >= issuedAt
            && abs(witnessDate.timeIntervalSince(chargedAt)) <= providerDateTolerance
            && permissionStillCurrent && !lifecycleConflicted
        guard exact, let chain = try charge.decode(column: "chain_key_hmac", as: String?.self) else {
            try await markIntentConflict(intentID, hash: nil, on: sql)
            return .conflict
        }
        if let existing = try await sql.raw("""
            SELECT * FROM measurement_purchase_acquisitions WHERE chain_key_hmac=\(bind:chain) FOR UPDATE
            """).first() {
            let acquisitionID = try existing.decode(column: "id", as: UUID.self)
            let existingState = try existing.decode(column: "state", as: String.self)
            if existingState == "revoked" {
                try await markIntentConflict(intentID, hash: nil, on: sql)
                return .conflict
            }
            let existingAccount = try existing.decode(column: "account_id", as: UUID?.self)
            let existingInstallation = try existing.decode(column: "installation_id", as: UUID?.self)
            let existingRevision = try existing.decode(column: "consent_revision", as: UUID?.self)
            let existingSubject = try existing.decode(column: "subject_id", as: UUID?.self)
            let existingProduct = try existing.decode(column: "product_id", as: String?.self)
            let existingEnvironment = try existing.decode(column: "environment", as: String.self)
            let existingCharge = try existing.decode(column: "initial_charge_id", as: UUID.self)
            let same = existingState == "active"
                && existingAccount == account && existingInstallation == installation
                && existingRevision == revision && existingSubject == subject
                && existingProduct == product && existingEnvironment == environment
                && existingCharge == chargeID
            guard same else {
                try await sql.raw("""
                    UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=\(bind:now)
                    WHERE id=\(bind:acquisitionID)
                    """).run()
                try await markIntentConflict(intentID, hash: nil, on: sql)
                return .conflict
            }
            try await sql.raw("UPDATE measurement_purchase_intents SET state='matched',matched_charge_id=\(bind:chargeID) WHERE id=\(bind:intentID)").run()
            try await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=\(bind:acquisitionID) WHERE id=\(bind:chargeID)").run()
            return .accepted
        }
        let acquisitionID = UUID()
        try await sql.raw("""
            INSERT INTO measurement_purchase_acquisitions
                (id,chain_key_hmac,account_id,installation_id,consent_revision,subject_id,product_id,
                 environment,initial_charge_id,state,bound_at)
            VALUES (\(bind:acquisitionID),\(bind:chain),\(bind:account),\(bind:installation),\(bind:revision),
                    \(bind:subject),\(bind:product),\(bind:environment),\(bind:chargeID),'active',\(bind:now))
            """).run()
        try await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=\(bind:acquisitionID) WHERE id=\(bind:chargeID)").run()
        try await sql.raw("UPDATE measurement_purchase_intents SET state='matched',matched_charge_id=\(bind:chargeID) WHERE id=\(bind:intentID)").run()
        return .accepted
    }

    static func revoke(subjectIDs: [UUID], now: Date, on sql: SQLDatabase) async throws {
        for subject in subjectIDs {
            let acquisitions = try await sql.raw("SELECT id FROM measurement_purchase_acquisitions WHERE subject_id=\(bind:subject)").all()
            for row in acquisitions {
                let id = try row.decode(column: "id", as: UUID.self)
                try await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE origin_acquisition_id=\(bind:id)").run()
            }
            try await sql.raw("""
                UPDATE measurement_purchase_acquisitions SET state='revoked',account_id=NULL,installation_id=NULL,
                    consent_revision=NULL,subject_id=NULL,product_id=NULL,revoked_at=\(bind:now)
                WHERE subject_id=\(bind:subject)
                """).run()
            try await sql.raw("DELETE FROM measurement_purchase_intents WHERE subject_id=\(bind:subject)").run()
        }
    }

    static func eraseAccount(_ accountID: UUID, now: Date, on sql: SQLDatabase) async throws {
        let acquisitions = try await sql.raw("SELECT id FROM measurement_purchase_acquisitions WHERE account_id=\(bind:accountID)").all()
        for row in acquisitions {
            let id = try row.decode(column: "id", as: UUID.self)
            try await sql.raw("UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL WHERE origin_acquisition_id=\(bind:id)").run()
        }
        try await sql.raw("""
            UPDATE measurement_purchase_acquisitions SET state='revoked',account_id=NULL,installation_id=NULL,
                consent_revision=NULL,subject_id=NULL,product_id=NULL,revoked_at=\(bind:now)
            WHERE account_id=\(bind:accountID)
            """).run()
        try await sql.raw("DELETE FROM measurement_purchase_intents WHERE account_id=\(bind:accountID)").run()
    }

    static func cleanup(now: Date = Date(), limit: Int = 5_000, on db: Database) async throws -> Int {
        let sql = try VerifiedIdentityService.sql(db)
        let row = try await sql.raw("""
            WITH removed AS (
                DELETE FROM measurement_purchase_intents WHERE id IN (
                    SELECT id FROM measurement_purchase_intents
                    WHERE (state='prepared' AND expires_at<\(bind:now))
                       OR (state='witnessed' AND pending_expires_at<\(bind:now))
                       OR (state='matched' AND witnessed_at<\(bind:now.addingTimeInterval(-pendingLifetime)))
                    ORDER BY issued_at LIMIT \(bind:max(0, limit))) RETURNING 1)
            SELECT count(*) AS total FROM removed
            """).first()
        return try row?.decode(column: "total", as: Int.self) ?? 0
    }

    private static func permissionCurrent(_ account: UUID, _ revision: UUID, _ installation: UUID,
                                          _ subject: UUID, _ now: Date, _ sql: SQLDatabase,
                                          authorityAt: Date? = nil) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM measurement_permission_current c JOIN measurement_subjects s ON s.id=c.subject_id
            JOIN measurement_att_assertions a ON a.account_id=c.account_id AND a.installation_id=\(bind:installation)
            WHERE c.account_id=\(bind:account) AND c.purpose='crossCompanyAds' AND c.decision='granted'
              AND c.revision=\(bind:revision) AND c.subject_id=\(bind:subject) AND s.state='active'
              AND (\(bind:authorityAt) IS NULL OR c.updated_at<=\(bind:authorityAt))
              AND a.consent_revision=\(bind:revision) AND a.status='authorized' AND a.expires_at>\(bind:now)
              AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.state<>'completed')
            LIMIT 1
            """).first() != nil
    }

    private static func markIntentConflict(_ id: UUID, hash: String?, on sql: SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=COALESCE(conflicted_at,NOW())
            WHERE id IN (
                SELECT origin_acquisition_id FROM measurement_revenuecat_events
                WHERE id=(SELECT matched_charge_id FROM measurement_purchase_intents WHERE id=\(bind:id)))
              AND state='active'
            """).run()
        try await sql.raw("""
            UPDATE measurement_purchase_intents SET state='conflict',
                conflict_hash=COALESCE(conflict_hash,\(bind:hash),witness_hash) WHERE id=\(bind:id)
            """).run()
    }

    private static func normalizedWitnessHash(_ transactionHMAC: String,
                                              _ input: MeasurementPurchaseWitnessRequest) -> String {
        SHA256Hasher.hash(token: [transactionHMAC, input.productId,
            String(Int64((input.purchaseDate.timeIntervalSince1970 * 1_000).rounded())), input.source].joined(separator: "|"))
    }

    private static func conflictHash(_ input: MeasurementPurchaseWitnessRequest, _ environment: String) -> String {
        SHA256Hasher.hash(token: [environment, input.productId,
            String(Int64((input.purchaseDate.timeIntervalSince1970 * 1_000).rounded())), input.source].joined(separator: "|"))
    }

    private static func hmac(_ kind: String, _ environment: String, _ reference: String, _ key: Data) -> String {
        let data = Data("purchase-origin:v1:\(kind):\(environment):APP_STORE:\(reference)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func capabilityHash(_ value: String) -> String {
        SHA256Hasher.hash(token: "purchase-origin-capability:v1:\(value)")
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
