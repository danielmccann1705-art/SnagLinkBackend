import Crypto
import Fluent
import FluentSQL
import Vapor

/// First-party Apple Ads acquisition evidence. This ledger does not depend on
/// ATT or cross-company consent and never creates provider delivery work.
enum ApplePurchaseOriginService {
    struct CampaignConfiguration: Sendable {
        let organizationID: Int64
        let campaignIDs: Set<Int64>

        var provenanceHash: String {
            SHA256Hasher.hash(token: "apple-owned-campaign:v1:\(organizationID):" +
                campaignIDs.sorted().map(String.init).joined(separator: ","))
        }
    }
    struct CampaignConfigurationKey: StorageKey { typealias Value = CampaignConfiguration }

    static func campaignConfiguration(_ app: Application) -> CampaignConfiguration? {
        if app.environment == .testing { return app.storage[CampaignConfigurationKey.self] }
        guard let orgRaw = Environment.get("APPLE_ADSERVICES_OWNED_ORG_ID"),
              let organizationID = Int64(orgRaw), organizationID > 0,
              let campaignsRaw = Environment.get("APPLE_ADSERVICES_OWNED_CAMPAIGN_IDS") else { return nil }
        let parts = campaignsRaw.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let campaigns = Set(parts.compactMap { Int64($0) })
        guard campaigns.count == parts.count, campaigns.allSatisfy({ $0 > 0 }) else { return nil }
        return .init(organizationID: organizationID, campaignIDs: campaigns)
    }

    static func evidence(for fields: AppleAttributionExchangeService.StandardFields,
                         app: Application) -> AdAttributionStore.Evidence {
        if fields.attribution == false {
            return .init(classification: .organic, configurationHash: nil)
        }
        if fields.organizationId == 1_234_567_890, fields.campaignId == 1_234_567_890,
           fields.adGroupId == 1_234_567_890, fields.keywordId == 123_222,
           fields.adId == 542_317_136 {
            return .init(classification: .test, configurationHash: nil)
        }
        guard fields.attribution == true, let configuration = campaignConfiguration(app),
              fields.organizationId == configuration.organizationID,
              let campaign = fields.campaignId, configuration.campaignIDs.contains(campaign) else {
            return .unknown
        }
        return .init(classification: .verified, configurationHash: configuration.provenanceHash)
    }

    static func prepare(accountID: UUID, input: MeasurementPurchaseIntentRequest, app: Application,
                        now: Date = Date(), on db: Database) async throws -> MeasurementPurchaseIntentResponse {
        guard PurchaseOriginService.products.contains(input.productId) else { throw invalid() }
        guard let purchaseConfig = PurchaseOriginService.configuration(app), campaignConfiguration(app) != nil,
              await AdMeasurementPolicy.isEnabled(on: db) else { throw unavailable() }
        let capability = try SecureTokenGenerator.generate()
        let id = UUID(), expires = now.addingTimeInterval(PurchaseOriginService.intentLifetime)
        try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):appleAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard try await permissionCurrent(accountID, input.consentRevision, authorityAt: now, sql),
                  let attribution = try await sql.raw("""
                    SELECT id FROM ad_attribution_records
                    WHERE canonical_account_id=\(bind:accountID)
                      AND canonical_installation_id=\(bind:input.installationId)
                      AND canonical_consent_revision=\(bind:input.consentRevision)
                      AND created_at<=\(bind:now) AND exchange_state IN ('processing','done')
                    LIMIT 1
                    """).first() else { throw permissionRequired() }
            let attributionID = try attribution.decode(column: "id", as: UUID.self)
            try await sql.raw("""
                INSERT INTO measurement_purchase_intents
                    (id,capability_hash,account_id,installation_id,consent_revision,subject_id,product_id,purpose,
                     attribution_record_id,environment,state,issued_at,expires_at)
                VALUES (\(bind:id),\(bind:capabilityHash(capability)),\(bind:accountID),\(bind:input.installationId),
                        \(bind:input.consentRevision),NULL,\(bind:input.productId),'appleAds',\(bind:attributionID),
                        \(bind:purchaseConfig.environment.rawValue),'prepared',\(bind:now),\(bind:expires))
                """).run()
        }
        return .init(intentId: id, capability: capability, expiresAt: expires)
    }

    static func complete(accountID: UUID, intentID: UUID, input: MeasurementPurchaseWitnessRequest,
                         app: Application, now: Date = Date(), on db: Database) async throws -> PurchaseOriginService.Completion {
        guard let config = PurchaseOriginService.configuration(app), let campaignConfig = campaignConfiguration(app),
              await AdMeasurementPolicy.isEnabled(on: db) else { throw unavailable() }
        guard PurchaseOriginService.products.contains(input.productId), input.source == "purchaseCallback",
              validReference(input.transactionId), validCapability(input.capability) else { throw invalid() }
        return try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):appleAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            guard let candidate = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID) AND purpose='appleAds'
                """).first(), try candidate.decode(column: "account_id", as: UUID.self) == accountID,
                  ConstantTimeComparison.compare(try candidate.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            let environment = try candidate.decode(column: "environment", as: String.self)
            let transactionHMAC = PurchaseOriginService.hmac("transaction", environment, input.transactionId, config.hmacKey)
            if let route = try await sql.raw("""
                SELECT durable_key_hash FROM measurement_revenuecat_events
                WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1
                """).first(), let chargeKey = try route.decode(column: "durable_key_hash", as: String?.self) {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(chargeKey)", on: tx)
            }
            try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transactionHMAC)", on: tx)
            guard let intent = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE id=\(bind:intentID) AND purpose='appleAds' FOR UPDATE
                """).first(), try intent.decode(column: "account_id", as: UUID.self) == accountID,
                  ConstantTimeComparison.compare(try intent.decode(column: "capability_hash", as: String.self),
                                                 capabilityHash(input.capability)) else { throw Abort(.notFound) }
            guard environment == config.environment.rawValue,
                  try intent.decode(column: "product_id", as: String.self) == input.productId else {
                try await markConflict(intentID, hash: witnessHash(transactionHMAC, input), now: now, sql)
                return .conflict
            }
            let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
            guard input.purchaseDate >= issuedAt,
                  input.purchaseDate <= now.addingTimeInterval(PurchaseOriginService.futureSkew) else { throw invalid() }
            let hash = witnessHash(transactionHMAC, input)
            let state = try intent.decode(column: "state", as: String.self)
            if state != "prepared" {
                guard try intent.decode(column: "witness_hash", as: String?.self) == hash else {
                    try await markConflict(intentID, hash: hash, now: now, sql); return .conflict
                }
                return state == "conflict" || state == "revoked" ? .conflict : .accepted
            }
            guard try intent.decode(column: "expires_at", as: Date.self) > now else {
                throw Abort(.gone, reason: "Purchase measurement intent expired",
                            identifier: "measurement_purchase_intent_expired")
            }
            guard try await appleAuthorityCurrent(intent, authorityAt: input.purchaseDate, now: now, sql) else {
                throw permissionRequired()
            }
            if let other = try await sql.raw("""
                SELECT id FROM measurement_purchase_intents
                WHERE purpose='appleAds' AND transaction_key_hmac=\(bind:transactionHMAC) AND id<>\(bind:intentID) LIMIT 1
                """).first() {
                try await markConflict(intentID, hash: hash, now: now, sql)
                try await markConflict(other.decode(column: "id", as: UUID.self), hash: hash, now: now, sql)
                return .conflict
            }
            try await sql.raw("""
                UPDATE measurement_purchase_intents SET state='witnessed',witness_hash=\(bind:hash),
                    transaction_key_hmac=\(bind:transactionHMAC),purchase_observed_at=\(bind:input.purchaseDate),
                    witnessed_at=\(bind:now),pending_expires_at=\(bind:now.addingTimeInterval(PurchaseOriginService.pendingLifetime))
                WHERE id=\(bind:intentID)
                """).run()
            if let charge = try await sql.raw("SELECT * FROM measurement_revenuecat_events WHERE transaction_key_hmac=\(bind:transactionHMAC) LIMIT 1").first() {
                if let chain = try charge.decode(column: "chain_key_hmac", as: String?.self) {
                    try await VerifiedIdentityService.lock("measurement-purchase-chain:\(chain)", on: tx)
                }
                return try await matchInitial(intentID: intentID, intent: intent, charge: charge,
                                              witnessDate: input.purchaseDate, configurationHash: campaignConfig.provenanceHash,
                                              now: now, sql)
            }
            return .accepted
        }
    }

    /// Runs inside RevenueCat ingestion. It records only local links and never performs network I/O.
    static func acceptRevenueCatCharge(_ fact: RevenueCatLifecycleFact, chargeID: UUID,
                                       app: Application, now: Date, on db: Database) async throws {
        guard fact.isPositiveCharge, let config = PurchaseOriginService.configuration(app),
              let campaignConfig = campaignConfiguration(app), fact.environment == config.environment,
              await AdMeasurementPolicy.isEnabled(on: db) else { return }
        let sql = try VerifiedIdentityService.sql(db)
        let transaction = PurchaseOriginService.hmac("transaction", fact.environment.rawValue, fact.transactionID, config.hmacKey)
        let chain = PurchaseOriginService.hmac("chain", fact.environment.rawValue, fact.originalTransactionID, config.hmacKey)
        try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transaction)", on: db)
        try await VerifiedIdentityService.lock("measurement-purchase-chain:\(chain)", on: db)
        try await sql.raw("""
            UPDATE measurement_revenuecat_events SET product_id=\(bind:fact.productID),
              transaction_key_hmac=COALESCE(transaction_key_hmac,\(bind:transaction)),
              chain_key_hmac=COALESCE(chain_key_hmac,\(bind:chain)) WHERE id=\(bind:chargeID)
            """).run()
        if fact.kind == .renewal {
            guard let acquisition = try await sql.raw("""
                SELECT * FROM measurement_purchase_acquisitions
                WHERE purpose='appleAds' AND chain_key_hmac=\(bind:chain) FOR UPDATE
                """).first(), try acquisition.decode(column: "state", as: String.self) == "active" else { return }
            let acquisitionID = try acquisition.decode(column: "id", as: UUID.self)
            let ownershipMatches = try acquisition.decode(column: "account_id", as: UUID?.self) == fact.accountID
                && acquisition.decode(column: "product_id", as: String?.self) == fact.productID
                && acquisition.decode(column: "environment", as: String.self) == fact.environment.rawValue
            guard ownershipMatches else {
                try await sql.raw("""
                    UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=\(bind:now)
                    WHERE id=\(bind:acquisitionID) AND state='active'
                    """).run()
                try await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND acquisition_id=\(bind:acquisitionID)").run()
                return
            }
            guard
                  try await appleAuthorityCurrent(acquisition, authorityAt: fact.purchasedAt, now: now, sql),
                  try await verifiedEvidence(
                    acquisition.decode(column: "attribution_record_id", as: UUID.self),
                    configurationHash: campaignConfig.provenanceHash, sql) else { return }
            try await link(chargeID: chargeID, acquisitionID: acquisitionID,
                           attributionID: acquisition.decode(column: "attribution_record_id", as: UUID.self), now: now, sql)
            return
        }
        guard fact.kind == .initialPurchase,
              let intent = try await sql.raw("""
                SELECT * FROM measurement_purchase_intents WHERE purpose='appleAds'
                  AND transaction_key_hmac=\(bind:transaction) AND state='witnessed'
                  AND pending_expires_at>\(bind:now) FOR UPDATE
                """).first(),
              let charge = try await sql.raw("SELECT * FROM measurement_revenuecat_events WHERE id=\(bind:chargeID)").first(),
              try await appleAuthorityCurrent(intent, authorityAt: fact.purchasedAt, now: now, sql) else { return }
        _ = try await matchInitial(intentID: intent.decode(column: "id", as: UUID.self), intent: intent,
                                   charge: charge, witnessDate: intent.decode(column: "purchase_observed_at", as: Date.self),
                                   configurationHash: campaignConfig.provenanceHash, now: now, sql)
    }

    static func reconcileAttribution(reference: String, app: Application, now: Date, on db: Database) async throws {
        guard let campaignConfig = campaignConfiguration(app), await AdMeasurementPolicy.isEnabled(on: db) else { return }
        let sql = try VerifiedIdentityService.sql(db)
        let candidates = try await sql.raw("""
            SELECT i.id,i.transaction_key_hmac FROM measurement_purchase_intents i
            JOIN ad_attribution_records a ON a.id=i.attribution_record_id
            WHERE i.purpose='appleAds' AND i.state='witnessed' AND i.pending_expires_at>\(bind:now)
              AND a.reference=\(bind:reference)
            """).all()
        for candidate in candidates {
            let intentID = try candidate.decode(column: "id", as: UUID.self)
            guard let transaction = try candidate.decode(column: "transaction_key_hmac", as: String?.self),
                  let route = try await sql.raw("""
                    SELECT durable_key_hash,chain_key_hmac FROM measurement_revenuecat_events
                    WHERE transaction_key_hmac=\(bind:transaction) LIMIT 1
                    """).first() else { continue }
            if let chargeKey = try route.decode(column: "durable_key_hash", as: String?.self) {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(chargeKey)", on: db)
            }
            try await VerifiedIdentityService.lock("measurement-purchase-transaction:\(transaction)", on: db)
            if let chain = try route.decode(column: "chain_key_hmac", as: String?.self) {
                try await VerifiedIdentityService.lock("measurement-purchase-chain:\(chain)", on: db)
            }
            guard let intent = try await sql.raw("""
                SELECT i.* FROM measurement_purchase_intents i
                JOIN ad_attribution_records a ON a.id=i.attribution_record_id
                WHERE i.id=\(bind:intentID) AND i.purpose='appleAds' AND i.state='witnessed'
                  AND i.pending_expires_at>\(bind:now) AND a.reference=\(bind:reference) FOR UPDATE OF i
                """).first(),
                  let charge = try await sql.raw("SELECT * FROM measurement_revenuecat_events WHERE transaction_key_hmac=\(bind:transaction) LIMIT 1").first() else { continue }
            _ = try await matchInitial(intentID: intent.decode(column: "id", as: UUID.self), intent: intent,
                charge: charge, witnessDate: intent.decode(column: "purchase_observed_at", as: Date.self),
                configurationHash: campaignConfig.provenanceHash, now: now, sql)
        }
    }

    static func revoke(accountID: UUID, now: Date, on sql: SQLDatabase) async throws {
        let acquisitions = try await sql.raw("SELECT id FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND account_id=\(bind:accountID)").all()
        for row in acquisitions {
            let acquisitionID = try row.decode(column: "id", as: UUID.self)
            try await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND acquisition_id=\(bind:acquisitionID)").run()
        }
        try await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND attribution_record_id IN (SELECT id FROM ad_attribution_records WHERE canonical_account_id=\(bind:accountID))").run()
        try await sql.raw("""
            UPDATE measurement_purchase_acquisitions SET state='revoked',account_id=NULL,installation_id=NULL,
              consent_revision=NULL,subject_id=NULL,product_id=NULL,attribution_record_id=NULL,revoked_at=\(bind:now)
            WHERE purpose='appleAds' AND account_id=\(bind:accountID)
            """).run()
        try await sql.raw("DELETE FROM measurement_purchase_intents WHERE purpose='appleAds' AND account_id=\(bind:accountID)").run()
    }

    static func revoke(attributionIDs: [UUID], now: Date, on sql: SQLDatabase) async throws {
        for attributionID in attributionIDs {
            try await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND attribution_record_id=\(bind:attributionID)").run()
            try await sql.raw("""
                UPDATE measurement_purchase_acquisitions SET state='revoked',account_id=NULL,installation_id=NULL,
                  consent_revision=NULL,subject_id=NULL,product_id=NULL,attribution_record_id=NULL,revoked_at=\(bind:now)
                WHERE purpose='appleAds' AND attribution_record_id=\(bind:attributionID)
                """).run()
            try await sql.raw("DELETE FROM measurement_purchase_intents WHERE purpose='appleAds' AND attribution_record_id=\(bind:attributionID)").run()
        }
    }

    private static func matchInitial(intentID: UUID, intent: SQLRow, charge: SQLRow, witnessDate: Date,
                                     configurationHash: String, now: Date,
                                     _ sql: SQLDatabase) async throws -> PurchaseOriginService.Completion {
        let chargeID = try charge.decode(column: "id", as: UUID.self)
        let account = try intent.decode(column: "account_id", as: UUID.self)
        let installation = try intent.decode(column: "installation_id", as: UUID.self)
        let revision = try intent.decode(column: "consent_revision", as: UUID.self)
        let product = try intent.decode(column: "product_id", as: String.self)
        let environment = try intent.decode(column: "environment", as: String.self)
        let attributionID = try intent.decode(column: "attribution_record_id", as: UUID.self)
        let chargedAt = try charge.decode(column: "purchased_at", as: Date.self)
        let issuedAt = try intent.decode(column: "issued_at", as: Date.self)
        let chargeKey = try charge.decode(column: "durable_key_hash", as: String?.self)
        let lifecycleConflicted: Bool
        if let chargeKey {
            lifecycleConflicted = try await sql.raw("""
                SELECT 1 FROM measurement_revenuecat_lifecycle_events WHERE charge_key_hash=\(bind:chargeKey)
                  AND (conflict_hash IS NOT NULL OR resolution='unresolved') LIMIT 1
                """).first() != nil
        } else { lifecycleConflicted = true }
        let authorityCurrent = try await appleAuthorityCurrent(intent, authorityAt: chargedAt, now: now, sql)
        let exact = try charge.decode(column: "account_id", as: UUID?.self) == account
            && charge.decode(column: "product_id", as: String?.self) == product
            && charge.decode(column: "environment", as: String.self) == environment
            && charge.decode(column: "charge_kind", as: String.self) == "initial_purchase"
            && chargedAt >= issuedAt && abs(witnessDate.timeIntervalSince(chargedAt)) <= PurchaseOriginService.providerDateTolerance
            && !lifecycleConflicted && authorityCurrent
        guard exact, let chain = try charge.decode(column: "chain_key_hmac", as: String?.self) else {
            try await markConflict(intentID, hash: nil, now: now, sql); return .conflict
        }
        guard let attribution = try await sql.raw("""
            SELECT evidence_class,evidence_config_hash FROM ad_attribution_records WHERE id=\(bind:attributionID)
              AND canonical_account_id=\(bind:account) AND canonical_installation_id=\(bind:installation)
              AND canonical_consent_revision=\(bind:revision) AND created_at<=\(bind:issuedAt) AND exchange_state='done'
            """).first() else { return .accepted }
        let evidence = try attribution.decode(column: "evidence_class", as: String.self)
        if evidence == "organic" {
            try await sql.raw("""
                INSERT INTO measurement_purchase_charge_links(charge_id,purpose,attribution_record_id,outcome,linked_at)
                VALUES (\(bind:chargeID),'appleAds',\(bind:attributionID),'organic',\(bind:now))
                ON CONFLICT(charge_id,purpose) DO NOTHING
                """).run()
            try await sql.raw("UPDATE measurement_purchase_intents SET state='matched',matched_charge_id=\(bind:chargeID) WHERE id=\(bind:intentID)").run()
            return .accepted
        }
        guard evidence == "verified",
              try attribution.decode(column: "evidence_config_hash", as: String?.self) == configurationHash else {
            return .accepted
        }
        let existing = try await sql.raw("SELECT * FROM measurement_purchase_acquisitions WHERE purpose='appleAds' AND chain_key_hmac=\(bind:chain) FOR UPDATE").first()
        let acquisitionID: UUID
        if let existing {
            acquisitionID = try existing.decode(column: "id", as: UUID.self)
            let same = try existing.decode(column: "state", as: String.self) == "active"
                && existing.decode(column: "account_id", as: UUID?.self) == account
                && existing.decode(column: "installation_id", as: UUID?.self) == installation
                && existing.decode(column: "consent_revision", as: UUID?.self) == revision
                && existing.decode(column: "product_id", as: String?.self) == product
                && existing.decode(column: "environment", as: String.self) == environment
                && existing.decode(column: "initial_charge_id", as: UUID.self) == chargeID
                && existing.decode(column: "attribution_record_id", as: UUID?.self) == attributionID
            guard same else {
                if try existing.decode(column: "state", as: String.self) == "active" {
                    try await sql.raw("""
                        UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=\(bind:now)
                        WHERE id=\(bind:acquisitionID) AND state='active'
                        """).run()
                    try await sql.raw("DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds' AND acquisition_id=\(bind:acquisitionID)").run()
                }
                try await markConflict(intentID, hash: nil, now: now, sql)
                return .conflict
            }
        } else {
            acquisitionID = UUID()
            try await sql.raw("""
                INSERT INTO measurement_purchase_acquisitions
                  (id,purpose,chain_key_hmac,account_id,installation_id,consent_revision,subject_id,product_id,
                   attribution_record_id,environment,initial_charge_id,state,bound_at)
                VALUES (\(bind:acquisitionID),'appleAds',\(bind:chain),\(bind:account),\(bind:installation),\(bind:revision),NULL,
                        \(bind:product),\(bind:attributionID),\(bind:environment),\(bind:chargeID),'active',\(bind:now))
                """).run()
        }
        try await link(chargeID: chargeID, acquisitionID: acquisitionID, attributionID: attributionID, now: now, sql)
        try await sql.raw("UPDATE measurement_purchase_intents SET state='matched',matched_charge_id=\(bind:chargeID) WHERE id=\(bind:intentID)").run()
        return .accepted
    }

    private static func link(chargeID: UUID, acquisitionID: UUID, attributionID: UUID,
                             now: Date, _ sql: SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO measurement_purchase_charge_links(charge_id,purpose,acquisition_id,attribution_record_id,outcome,linked_at)
            VALUES (\(bind:chargeID),'appleAds',\(bind:acquisitionID),\(bind:attributionID),'paid_campaign',\(bind:now))
            ON CONFLICT(charge_id,purpose) DO NOTHING
            """).run()
    }

    private static func appleAuthorityCurrent(_ row: SQLRow, authorityAt: Date, now: Date,
                                              _ sql: SQLDatabase) async throws -> Bool {
        let account = try row.decode(column: "account_id", as: UUID.self)
        let revision = try row.decode(column: "consent_revision", as: UUID.self)
        let attribution = try row.decode(column: "attribution_record_id", as: UUID.self)
        let installation = try row.decode(column: "installation_id", as: UUID.self)
        let current = try await permissionCurrent(account, revision, authorityAt: authorityAt, sql)
        let exactAttribution = try await sql.raw("""
                SELECT 1 FROM ad_attribution_records WHERE id=\(bind:attribution)
                  AND canonical_account_id=\(bind:account) AND canonical_installation_id=\(bind:installation)
                  AND canonical_consent_revision=\(bind:revision) LIMIT 1
                """).first() != nil
        return current && exactAttribution
    }

    private static func permissionCurrent(_ account: UUID, _ revision: UUID, authorityAt: Date,
                                          _ sql: SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM measurement_permission_current
            WHERE account_id=\(bind:account) AND purpose='appleAds' AND revision=\(bind:revision)
              AND decision='granted' AND updated_at<=\(bind:authorityAt) LIMIT 1
            """).first() != nil
    }

    private static func verifiedEvidence(_ attributionID: UUID, configurationHash: String,
                                         _ sql: SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM ad_attribution_records WHERE id=\(bind:attributionID) AND exchange_state='done'
              AND evidence_class='verified' AND evidence_config_hash=\(bind:configurationHash) LIMIT 1
            """).first() != nil
    }

    private static func markConflict(_ id: UUID, hash: String?, now: Date, _ sql: SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=COALESCE(conflicted_at,\(bind:now))
            WHERE purpose='appleAds' AND id IN
              (SELECT acquisition_id FROM measurement_purchase_charge_links WHERE purpose='appleAds'
               AND charge_id=(SELECT matched_charge_id FROM measurement_purchase_intents WHERE id=\(bind:id)))
              AND state='active'
            """).run()
        try await sql.raw("""
            DELETE FROM measurement_purchase_charge_links WHERE purpose='appleAds'
              AND charge_id=(SELECT matched_charge_id FROM measurement_purchase_intents WHERE id=\(bind:id))
            """).run()
        try await sql.raw("""
            UPDATE measurement_purchase_intents SET state='conflict',conflict_hash=COALESCE(conflict_hash,\(bind:hash),witness_hash)
            WHERE id=\(bind:id) AND purpose='appleAds'
            """).run()
    }

    private static func capabilityHash(_ value: String) -> String {
        SHA256Hasher.hash(token: "purchase-origin-capability:v1:\(value)")
    }
    private static func witnessHash(_ transaction: String, _ input: MeasurementPurchaseWitnessRequest) -> String {
        SHA256Hasher.hash(token: [transaction,input.productId,
            String(Int64((input.purchaseDate.timeIntervalSince1970 * 1_000).rounded())),input.source].joined(separator: "|"))
    }
    private static func validReference(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func validCapability(_ value: String) -> Bool {
        (32...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func unavailable() -> Abort {
        .init(.serviceUnavailable, reason: "Apple purchase measurement is unavailable", identifier: "apple_purchase_measurement_unavailable")
    }
    private static func permissionRequired() -> Abort {
        .init(.forbidden, reason: "Current Apple measurement permission is required", identifier: "apple_purchase_measurement_permission_required")
    }
    private static func invalid() -> Abort {
        .init(.badRequest, reason: "Use a valid Apple purchase measurement request", identifier: "apple_purchase_measurement_invalid")
    }
}
