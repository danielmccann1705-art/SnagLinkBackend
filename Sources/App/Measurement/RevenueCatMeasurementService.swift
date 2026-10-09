import Vapor
import Fluent
import FluentSQL

/// Authenticated RevenueCat ingress. The provider body is reduced to one monetary
/// fact before any transaction starts and is never persisted or logged.
enum RevenueCatMeasurementService {
    struct Configuration: Sendable {
        let authorization: String
        let appID: String
    }
    struct ConfigurationKey: StorageKey { typealias Value = Configuration }

    static func configuration(_ app: Application) -> Configuration? {
        if app.environment == .testing { return app.storage[ConfigurationKey.self] }
        guard let authorization = Environment.get("REVENUECAT_WEBHOOK_AUTHORIZATION"),
              let appID = Environment.get("REVENUECAT_APP_ID") else { return nil }
        return .init(authorization: authorization, appID: appID)
    }

    static func ingest(body: Data, authorization: String?, app: Application,
                       now: Date = Date(), on db: Database) async throws {
        guard let configuration = configuration(app), configuration.authorization.hasPrefix("Bearer "),
              configuration.authorization.count >= 24 else {
            throw Abort(.serviceUnavailable, reason: "RevenueCat measurement ingress is unavailable",
                        identifier: "measurement_revenuecat_unavailable")
        }
        guard let supplied = authorization,
              ConstantTimeComparison.compare(SHA256Hasher.hash(token: supplied),
                                             SHA256Hasher.hash(token: configuration.authorization)) else {
            throw Abort(.unauthorized, reason: "RevenueCat webhook authentication failed")
        }
        guard let fact = RevenueCatLifecycleNormalizer.parse(body, expectedAppID: configuration.appID) else {
            throw Abort(.badRequest, reason: "Unsupported RevenueCat measurement event",
                        identifier: "measurement_revenuecat_invalid")
        }
        guard fact.eventGeneratedAt <= now.addingTimeInterval(300),
              fact.eventGeneratedAt >= now.addingTimeInterval(-10 * 365 * 86_400) else {
            throw Abort(.badRequest, reason: "RevenueCat measurement event time is invalid",
                        identifier: "measurement_revenuecat_time_invalid")
        }
        let freshForRelay = fact.eventGeneratedAt >= now.addingTimeInterval(-7 * 86_400)
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let user = try await sql.raw("SELECT lifecycle_state FROM users WHERE id=\(bind:fact.accountID) FOR UPDATE").first(),
                  try user.decode(column: "lifecycle_state", as: String.self) == "active" else {
                return // Valid provider event for no current canonical account: acknowledge without joining it.
            }
            try await VerifiedIdentityService.lock("measurement-revenuecat-event:\(fact.providerEventKeyHash)", on: tx)
            if let replay = try await sql.raw("SELECT normalized_hash,charge_key_hash FROM measurement_revenuecat_lifecycle_events WHERE provider_event_key_hash=\(bind:fact.providerEventKeyHash)").first() {
                if try replay.decode(column: "normalized_hash", as: String.self) != fact.normalizedHash {
                    let chargeKey = try replay.decode(column: "charge_key_hash", as: String.self)
                    try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(chargeKey)", on: tx)
                    try await sql.raw("""
                        UPDATE measurement_revenuecat_lifecycle_events
                        SET resolution='unresolved',conflict_hash=\(bind:fact.normalizedHash),conflicted_at=\(bind:now)
                        WHERE provider_event_key_hash=\(bind:fact.providerEventKeyHash)
                        """).run()
                    try await markAdjustmentConflict(chargeKeyHash: chargeKey, now: now, on: sql)
                    try await quarantine(chargeKeyHash: chargeKey, on: sql)
                }
                return
            }
            let lifecycleID = UUID()
            let flags = try await FeatureFlagService.resolve(on: tx)
            let linkedInIngestEligible = flags["crossCompanyAdsEnabled"] == true
                && flags["linkedInConversionsEnabled"] == true
            let initialResolution = fact.effect == .unresolved ? "unresolved" :
                ([RevenueCatLifecycleFact.Effect.refund, .refundReversal].contains(fact.effect) ? "pending_charge" : "resolved")
            try await sql.raw("""
                INSERT INTO measurement_revenuecat_lifecycle_events
                    (id,provider_event_key_hash,normalized_hash,account_id,environment,event_kind,effect,resolution,
                     charge_key_hash,subscription_chain_key_hash,event_generated_at,purchased_at,expiration_at,
                     reason,currency_code,monetary_delta,received_at)
                VALUES (\(bind:lifecycleID),\(bind:fact.providerEventKeyHash),\(bind:fact.normalizedHash),\(bind:fact.accountID),
                        \(bind:fact.environment.rawValue),\(bind:fact.kind.rawValue),\(bind:fact.effect.rawValue),
                        \(bind:initialResolution),\(bind:fact.chargeKeyHash),\(bind:fact.subscriptionChainKeyHash),
                        \(bind:fact.eventGeneratedAt),\(bind:fact.purchasedAt),\(bind:fact.expirationAt),\(bind:fact.reason),
                        \(bind:fact.currency),\(bind:fact.monetaryDelta),\(bind:now))
                """).run()

            var chargeID: UUID?
            var lifecycleResolution = initialResolution
            var chargeDispatchEligible = true
            if fact.isPositiveCharge, let currency = fact.currency, let amount = fact.monetaryDelta {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(fact.chargeKeyHash)", on: tx)
                if let replay = try await sql.raw("SELECT id,fact_hash FROM measurement_revenuecat_events WHERE durable_key_hash=\(bind:fact.chargeKeyHash)").first() {
                    if try replay.decode(column: "fact_hash", as: String.self) != fact.chargeFactHash {
                        try await sql.raw("""
                            UPDATE measurement_revenuecat_lifecycle_events
                            SET resolution='unresolved',conflict_hash=normalized_hash,conflicted_at=\(bind:now)
                            WHERE id=\(bind:lifecycleID)
                            """).run()
                        try await markAdjustmentConflict(chargeKeyHash: fact.chargeKeyHash, now: now, on: sql)
                        try await quarantine(chargeKeyHash: fact.chargeKeyHash, on: sql)
                        return
                    }
                    chargeID = try replay.decode(column: "id", as: UUID.self)
                } else {
                    let sourceID = UUID()
                    try await sql.raw("""
                        INSERT INTO measurement_revenuecat_events
                            (id,account_id,durable_key_hash,fact_hash,event_kind,charge_kind,subscription_chain_key_hash,
                             environment,occurred_at,purchased_at,received_at,currency_code,amount,linkedin_ingest_eligible)
                        VALUES (\(bind:sourceID),\(bind:fact.accountID),\(bind:fact.chargeKeyHash),\(bind:fact.chargeFactHash),
                                'subscription_payment',\(bind:fact.kind.rawValue),\(bind:fact.subscriptionChainKeyHash),
                                \(bind:fact.environment.rawValue),\(bind:fact.eventGeneratedAt),\(bind:fact.purchasedAt),
                                \(bind:now),\(bind:currency),\(bind:amount),\(bind:linkedInIngestEligible))
                        """).run()
                    chargeID = sourceID
                }
                chargeDispatchEligible = try await refreshAdjustment(chargeKeyHash: fact.chargeKeyHash,
                    accountID: fact.accountID, now: now, on: sql) != "unresolved"
                if let chargeID, chargeDispatchEligible {
                    try await ApplePurchaseOriginService.acceptRevenueCatCharge(
                        fact, chargeID: chargeID, app: app, now: now, on: tx)
                    try await PurchaseOriginService.acceptRevenueCatCharge(
                        fact, chargeID: chargeID, app: app, now: now, on: tx)
                }
            } else if fact.effect == .refund || fact.effect == .refundReversal {
                try await VerifiedIdentityService.lock("measurement-revenuecat-charge:\(fact.chargeKeyHash)", on: tx)
                let state = try await reconcileAdjustment(fact, eventID: lifecycleID, now: now, on: sql)
                lifecycleResolution = state == "unresolved" ? "unresolved" : (state == "pending_charge" ? "pending_charge" : "resolved")
                try await sql.raw("UPDATE measurement_revenuecat_lifecycle_events SET resolution=\(bind:lifecycleResolution) WHERE id=\(bind:lifecycleID)").run()
            }

            if freshForRelay, flags["productAnalyticsEnabled"] == true,
               let permission = try await currentPermission(accountID: fact.accountID, purpose: .productAnalytics,
                                                             occurredAt: fact.eventGeneratedAt,
                                                             purchasedAt: fact.purchasedAt, on: sql) {
                if let chargeID, chargeDispatchEligible,
                   let currency = fact.currency, let amount = fact.monetaryDelta {
                    if relaysAsNewPurchase(fact) {
                        let payload = try canonicalJSON(["event": "subscription_payment", "occurredAt": iso(fact.eventGeneratedAt),
                                                         "currency": currency, "amount": amount,
                                                         "lifecycleKind": fact.kind.rawValue])
                        try await enqueue(destination: "posthog", sourceKind: "revenueCatLifecycle", sourceID: chargeID,
                                          accountID: fact.accountID, permission: permission, installationID: nil,
                                          payload: payload, now: now, on: sql)
                    }
                    try await enqueueResolvedAdjustments(accountID: fact.accountID, chargeKeyHash: fact.chargeKeyHash,
                                                         now: now, on: sql)
                } else if [.refund, .refundReversal].contains(fact.effect), lifecycleResolution == "resolved" {
                    // The adjustment row chooses one canonical provider event for each
                    // economic effect. Re-enqueueing that canonical pair is safe and
                    // also handles reversal-before-refund arrival order.
                    try await enqueueResolvedAdjustments(accountID: fact.accountID, chargeKeyHash: fact.chargeKeyHash,
                                                         now: now, on: sql)
                } else if fact.isResolved, fact.effect != .charge, lifecycleResolution == "resolved",
                          relaysAsNewPurchase(fact) {
                    let payload = try lifecyclePayload(fact)
                    try await enqueue(destination: "posthog", sourceKind: "revenueCatEvent", sourceID: lifecycleID,
                                      accountID: fact.accountID, permission: permission, installationID: nil,
                                      payload: payload, now: now, on: sql)
                }
            }
            // RevenueCat does not identify the installation that originated the
            // purchase. Cross-company dispatch is created only by the exact optional
            // purchase-origin join above, never by guessing from another device.
        }
    }

    private struct Permission {
        let subjectID: UUID
        let revision: UUID
    }

    /// How far an initial purchase may precede its provider event and still be relayed to
    /// product analytics as a new purchase.
    static let newPurchaseLag: TimeInterval = 72 * 3_600

    /// Restore is never new money. A restore or transfer arrives as an unsupported type
    /// and is refused by the normalizer; a restore on another app account reuses a charge
    /// key that already exists. The remaining path is a store transaction RevenueCat
    /// first learns about during a restore, which it reports as INITIAL_PURCHASE with the
    /// original, older purchase time. Such a fact stays in the money ledger but is not
    /// relayed to product analytics as `subscription_payment`/`subscription_zero_value`
    /// with `lifecycleKind=initial_purchase`.
    static func relaysAsNewPurchase(_ fact: RevenueCatLifecycleFact) -> Bool {
        fact.kind != .initialPurchase || fact.purchasedAt >= fact.eventGeneratedAt.addingTimeInterval(-newPurchaseLag)
    }

    private struct LinkedInPurchaseAuthority {
        let accountID: UUID
        let installationID: UUID
        let subjectID: UUID
        let revision: UUID
        let occurredAt: Date
        let purchasedAt: Date
        let currency: String
        let amount: String
        let lifecycleKind: String
        let verifiedEmailHash: String?
        let attContinuityStartedAt: Date
        let attContinuityID: UUID
    }

    /// Enqueues only at the moment a verified RevenueCat charge has acquired an
    /// exact cross-company purchase-origin link. There is deliberately no scan:
    /// enabling a flag or granting permission later cannot backfill old money.
    static func enqueueLinkedInPurchase(chargeID: UUID, app: Application, now: Date,
                                        on db: Database) async throws {
        let flags = try await FeatureFlagService.resolve(on: db)
        guard flags["crossCompanyAdsEnabled"] == true,
              flags["linkedInConversionsEnabled"] == true else { return }
        let sql = try VerifiedIdentityService.sql(db)
        guard let authority = try await linkedInPurchaseAuthority(
            chargeID: chargeID, now: now, requireEventTimeATT: true, on: sql),
              let verifiedEmailHash = authority.verifiedEmailHash else {
            return
        }
        let payload = try canonicalJSON([
            "event": "subscription_payment",
            "occurredAt": iso(authority.occurredAt),
            "currency": authority.currency,
            "amount": authority.amount,
            "lifecycleKind": authority.lifecycleKind,
            "emailSha256": verifiedEmailHash,
            "attContinuityId": authority.attContinuityID.uuidString.lowercased()
        ])
        try await enqueue(destination: "linkedin", sourceKind: "revenueCatLifecycle", sourceID: chargeID,
                          accountID: authority.accountID,
                          permission: .init(subjectID: authority.subjectID, revision: authority.revision),
                          installationID: authority.installationID, payload: payload, now: now, on: sql)
    }

    /// Dispatch-time recheck of the same immutable acquisition and event-time
    /// authority. Current permission and ATT alone are insufficient: both must
    /// be the exact revision/install that existed no later than the charge fact.
    static func linkedInPurchaseIsEligible(chargeID: UUID, accountID: UUID, subjectID: UUID,
                                           revision: UUID, installationID: UUID,
                                           verifiedEmailHash: String,
                                           attContinuityID: UUID,
                                           now: Date, on sql: SQLDatabase) async throws -> Bool {
        guard let authority = try await linkedInPurchaseAuthority(
            chargeID: chargeID, now: now, requireEventTimeATT: false, on: sql) else {
            return false
        }
        return authority.accountID == accountID && authority.subjectID == subjectID
            && authority.revision == revision && authority.installationID == installationID
            && authority.verifiedEmailHash == verifiedEmailHash
            && authority.attContinuityID == attContinuityID
    }

    private static func linkedInPurchaseAuthority(chargeID: UUID, now: Date, requireEventTimeATT: Bool,
                                                   on sql: SQLDatabase) async throws -> LinkedInPurchaseAuthority? {
        guard let row = try await sql.raw("""
            SELECT r.account_id,r.occurred_at,r.purchased_at,r.currency_code,r.amount,r.charge_kind,
                   a.installation_id,a.consent_revision,a.subject_id,att.continuity_started_at,att.continuity_id
            FROM measurement_revenuecat_events r
            JOIN measurement_purchase_charge_links l
              ON l.charge_id=r.id AND l.purpose='crossCompanyAds' AND l.outcome='origin'
            JOIN measurement_purchase_acquisitions a
              ON a.id=l.acquisition_id AND a.purpose='crossCompanyAds' AND a.state='active'
            JOIN users u ON u.id=r.account_id AND u.lifecycle_state='active'
            JOIN measurement_permission_current c
              ON c.account_id=r.account_id AND c.purpose='crossCompanyAds' AND c.decision='granted'
             AND c.revision=a.consent_revision AND c.subject_id=a.subject_id
            JOIN measurement_subjects s ON s.id=a.subject_id AND s.account_id=r.account_id
             AND s.purpose='crossCompanyAds' AND s.state='active'
            JOIN measurement_att_assertions att ON att.account_id=r.account_id
             AND att.installation_id=a.installation_id AND att.consent_revision=a.consent_revision
             AND att.status='authorized'
            WHERE r.id=\(bind:chargeID) AND r.event_kind='subscription_payment'
              AND r.charge_kind IN ('initial_purchase','renewal')
              AND r.linkedin_ingest_eligible=TRUE
              AND a.account_id=r.account_id AND a.product_id=r.product_id AND a.environment=r.environment
              AND c.updated_at<=r.occurred_at AND c.updated_at<=r.purchased_at
              AND att.expires_at>\(bind:now)
              AND ((r.charge_kind='initial_purchase' AND EXISTS (
                    SELECT 1 FROM measurement_purchase_intents i
                    WHERE i.purpose='crossCompanyAds' AND i.state='matched' AND i.matched_charge_id=r.id
                      AND i.linkedin_witness_eligible=TRUE
                      AND i.account_id=r.account_id AND i.installation_id=a.installation_id
                      AND i.consent_revision=a.consent_revision AND i.subject_id=a.subject_id
                      AND i.att_asserted_at<=r.occurred_at AND i.att_asserted_at<=r.purchased_at
                      AND i.att_expires_at>r.occurred_at AND i.att_expires_at>r.purchased_at
                      AND i.att_continuity_started_at=att.continuity_started_at
                      AND i.att_continuity_id=att.continuity_id))
                   OR (r.charge_kind='renewal' AND
                       (NOT \(bind:requireEventTimeATT) OR
                        (att.continuity_started_at<=r.occurred_at
                         AND att.continuity_started_at<=r.purchased_at))))
              AND r.occurred_at<=\(bind:now) AND r.occurred_at>\(bind:now.addingTimeInterval(-7 * 86_400))
              AND NOT EXISTS (
                SELECT 1 FROM measurement_erasure_jobs e
                WHERE e.subject_id=a.subject_id AND e.state<>'completed')
              AND NOT EXISTS (
                SELECT 1 FROM measurement_revenuecat_lifecycle_events le
                WHERE le.charge_key_hash=r.durable_key_hash
                  AND (le.conflict_hash IS NOT NULL OR le.resolution='unresolved'))
            LIMIT 1
            """).first() else { return nil }
        guard let accountID = try row.decode(column: "account_id", as: UUID?.self),
              let installationID = try row.decode(column: "installation_id", as: UUID?.self),
              let subjectID = try row.decode(column: "subject_id", as: UUID?.self),
              let revision = try row.decode(column: "consent_revision", as: UUID?.self),
              let continuityStartedAt = try row.decode(column: "continuity_started_at", as: Date?.self),
              let continuityID = try row.decode(column: "continuity_id", as: UUID?.self) else { return nil }
        let occurredAt = try row.decode(column: "occurred_at", as: Date.self)
        let purchasedAt = try row.decode(column: "purchased_at", as: Date.self)
        let verifiedEmail = try await sql.raw("""
            SELECT subject FROM user_identities
            WHERE user_id=\(bind:accountID) AND provider='email'
              AND verified_at<=\(bind:occurredAt) AND verified_at<=\(bind:purchasedAt)
            ORDER BY verified_at DESC LIMIT 1
            """).first()?.decode(column: "subject", as: String.self)
        return .init(accountID: accountID, installationID: installationID, subjectID: subjectID,
                     revision: revision,
                     occurredAt: occurredAt, purchasedAt: purchasedAt,
                     currency: try row.decode(column: "currency_code", as: String.self),
                     amount: try row.decode(column: "amount", as: String.self),
                     lifecycleKind: try row.decode(column: "charge_kind", as: String.self),
                     verifiedEmailHash: verifiedEmail.flatMap(LinkedInConversion.verifiedEmailHash),
                     attContinuityStartedAt: continuityStartedAt, attContinuityID: continuityID)
    }

    private static func currentPermission(accountID: UUID, purpose: MeasurementPurpose, occurredAt: Date,
                                          purchasedAt: Date,
                                          on sql: SQLDatabase) async throws -> Permission? {
        guard let row = try await sql.raw("""
            SELECT c.subject_id,c.revision,c.updated_at
            FROM measurement_permission_current c JOIN measurement_subjects s ON s.id=c.subject_id AND s.state='active'
            WHERE c.account_id=\(bind:accountID) AND c.purpose=\(bind:purpose.rawValue) AND c.decision='granted'
              AND NOT EXISTS(SELECT 1 FROM measurement_erasure_jobs e WHERE e.subject_id=s.id AND e.state<>'completed')
            """).first() else { return nil }
        let grantedAt = try row.decode(column: "updated_at", as: Date.self)
        // Event generation can lag the purchase, while an Apple renewal period can
        // start after it. Consent must predate both provider timestamps so a webhook
        // arriving after a new grant cannot authorise an earlier charge.
        guard occurredAt >= grantedAt, purchasedAt >= grantedAt else { return nil }
        let subject = try row.decode(column: "subject_id", as: UUID.self)
        let revision = try row.decode(column: "revision", as: UUID.self)
        return .init(subjectID: subject, revision: revision)
    }

    private static func enqueue(destination: String, sourceKind: String, sourceID: UUID, accountID: UUID, permission: Permission,
                                installationID: UUID?, payload: String, now: Date, on sql: SQLDatabase) async throws {
        if destination == "singular" {
            guard let installationID,
                  try await sql.raw("""
                    SELECT 1 FROM measurement_device_bindings WHERE account_id=\(bind:accountID)
                      AND installation_id=\(bind:installationID) AND subject_id=\(bind:permission.subjectID)
                      AND consent_revision=\(bind:permission.revision) AND revoked_at IS NULL LIMIT 1
                    """).first() != nil else { return }
        }
        try await sql.raw("""
            INSERT INTO measurement_dispatch_jobs
                (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,installation_id,
                 state,available_at,payload,created_at)
            VALUES (\(bind:UUID()),\(bind:destination),\(bind:sourceKind),\(bind:sourceID),\(bind:accountID),
                    \(bind:permission.subjectID),\(bind:permission.revision),\(bind:installationID),
                    'pending',\(bind:now),CAST(\(bind:payload) AS JSONB),\(bind:now))
            ON CONFLICT(account_id,destination,source_kind,source_id) DO NOTHING
            """).run()
    }

    private static func lifecyclePayload(_ fact: RevenueCatLifecycleFact) throws -> String {
        var value = ["event": "subscription_\(fact.effect.rawValue)",
                     "occurredAt": iso(fact.eventGeneratedAt), "lifecycleKind": fact.kind.rawValue]
        if let reason = fact.reason { value["reason"] = reason }
        if let currency = fact.currency { value["currency"] = currency }
        if let amount = fact.monetaryDelta { value["amount"] = amount }
        return try canonicalJSON(value)
    }

    private static func reconcileAdjustment(_ fact: RevenueCatLifecycleFact, eventID: UUID, now: Date,
                                            on sql: SQLDatabase) async throws -> String {
        let existing = try await sql.raw("SELECT * FROM measurement_revenuecat_adjustments WHERE charge_key_hash=\(bind:fact.chargeKeyHash) FOR UPDATE").first()
        if let existing, try existing.decode(column: "account_id", as: UUID?.self) != fact.accountID {
            try await markAdjustmentConflict(chargeKeyHash: fact.chargeKeyHash, now: now, on: sql)
            try await quarantine(chargeKeyHash: fact.chargeKeyHash, on: sql)
            return "unresolved"
        }
        if existing == nil {
            try await sql.raw("""
                INSERT INTO measurement_revenuecat_adjustments
                    (charge_key_hash,account_id,currency_code,refund_amount,refund_event_id,refund_at,
                     reversal_amount,reversal_event_id,reversal_at,state,updated_at)
                VALUES (\(bind:fact.chargeKeyHash),\(bind:fact.accountID),\(bind:fact.currency),
                        \(bind:fact.effect == .refund ? fact.monetaryDelta : nil),
                        \(bind:fact.effect == .refund ? eventID : nil),
                        \(bind:fact.effect == .refund ? fact.eventGeneratedAt : nil),
                        \(bind:fact.effect == .refundReversal ? fact.monetaryDelta : nil),
                        \(bind:fact.effect == .refundReversal ? eventID : nil),
                        \(bind:fact.effect == .refundReversal ? fact.eventGeneratedAt : nil),
                        'pending_charge',\(bind:now))
                """).run()
        } else if fact.effect == .refund {
            let oldAmount = try existing!.decode(column: "refund_amount", as: String?.self)
            let oldCurrency = try existing!.decode(column: "currency_code", as: String?.self)
            if (oldCurrency != nil && oldCurrency != fact.currency) ||
                (oldAmount != nil && oldAmount != fact.monetaryDelta) {
                try await markAdjustmentConflict(chargeKeyHash: fact.chargeKeyHash, now: now, on: sql)
                try await quarantine(chargeKeyHash: fact.chargeKeyHash, on: sql)
                return "unresolved"
            }
            if oldAmount == nil {
                try await sql.raw("""
                    UPDATE measurement_revenuecat_adjustments SET currency_code=\(bind:fact.currency),
                        refund_amount=\(bind:fact.monetaryDelta),refund_event_id=\(bind:eventID),
                        refund_at=\(bind:fact.eventGeneratedAt),updated_at=\(bind:now)
                    WHERE charge_key_hash=\(bind:fact.chargeKeyHash)
                    """).run()
            }
        } else {
            let oldAmount = try existing!.decode(column: "reversal_amount", as: String?.self)
            let oldCurrency = try existing!.decode(column: "currency_code", as: String?.self)
            if (oldCurrency != nil && oldCurrency != fact.currency) ||
                (oldAmount != nil && oldAmount != fact.monetaryDelta) {
                try await markAdjustmentConflict(chargeKeyHash: fact.chargeKeyHash, now: now, on: sql)
                try await quarantine(chargeKeyHash: fact.chargeKeyHash, on: sql)
                return "unresolved"
            }
            if oldAmount == nil {
                try await sql.raw("""
                    UPDATE measurement_revenuecat_adjustments SET currency_code=COALESCE(currency_code,\(bind:fact.currency)),
                        reversal_amount=\(bind:fact.monetaryDelta),reversal_event_id=\(bind:eventID),
                        reversal_at=\(bind:fact.eventGeneratedAt),updated_at=\(bind:now)
                    WHERE charge_key_hash=\(bind:fact.chargeKeyHash)
                    """).run()
            }
        }
        return try await refreshAdjustment(chargeKeyHash: fact.chargeKeyHash, accountID: fact.accountID,
                                           now: now, on: sql)
    }

    @discardableResult private static func refreshAdjustment(chargeKeyHash: String, accountID: UUID, now: Date,
                                                             on sql: SQLDatabase) async throws -> String {
        if try await sql.raw("""
            SELECT 1 FROM measurement_revenuecat_lifecycle_events
            WHERE charge_key_hash=\(bind:chargeKeyHash) AND conflict_hash IS NOT NULL LIMIT 1
            """).first() != nil {
            try await sql.raw("UPDATE measurement_revenuecat_adjustments SET state='unresolved',updated_at=\(bind:now) WHERE charge_key_hash=\(bind:chargeKeyHash)").run()
            return "unresolved"
        }
        guard let row = try await sql.raw("SELECT * FROM measurement_revenuecat_adjustments WHERE charge_key_hash=\(bind:chargeKeyHash) FOR UPDATE").first() else {
            return "resolved"
        }
        guard try row.decode(column: "account_id", as: UUID?.self) == accountID else { return "unresolved" }
        let charge = try await sql.raw("""
            SELECT currency_code,amount FROM measurement_revenuecat_events
            WHERE durable_key_hash=\(bind:chargeKeyHash) AND account_id=\(bind:accountID) LIMIT 1
            """).first()
        let refund = try row.decode(column: "refund_amount", as: String?.self)
        let reversal = try row.decode(column: "reversal_amount", as: String?.self)
        let currency = try row.decode(column: "currency_code", as: String?.self)
        let state: String
        if let refund {
            if let charge {
                let chargeCurrency = try charge.decode(column: "currency_code", as: String.self)
                let chargeAmount = try charge.decode(column: "amount", as: String.self)
                let consistentRefund = currency == chargeCurrency && opposite(refund, chargeAmount)
                let consistentReversal = reversal.map { opposite(refund, $0) } ?? true
                guard consistentRefund, consistentReversal else {
                    try await markAdjustmentConflict(chargeKeyHash: chargeKeyHash, now: now, on: sql)
                    try await quarantine(chargeKeyHash: chargeKeyHash, on: sql)
                    return "unresolved"
                }
                state = reversal == nil ? "refunded" : "reversed"
            } else {
                state = "pending_charge"
            }
        } else {
            state = "unresolved"
        }
        try await sql.raw("UPDATE measurement_revenuecat_adjustments SET state=\(bind:state),updated_at=\(bind:now) WHERE charge_key_hash=\(bind:chargeKeyHash)").run()
        let resolution = state == "unresolved" ? "unresolved" : (state == "pending_charge" ? "pending_charge" : "resolved")
        try await sql.raw("""
            UPDATE measurement_revenuecat_lifecycle_events SET resolution=\(bind:resolution)
            WHERE charge_key_hash=\(bind:chargeKeyHash) AND effect IN ('refund','refund_reversal')
            """).run()
        return state
    }

    private static func markAdjustmentConflict(chargeKeyHash: String, now: Date,
                                               on sql: SQLDatabase) async throws {
        try await sql.raw("UPDATE measurement_revenuecat_adjustments SET state='unresolved',updated_at=\(bind:now) WHERE charge_key_hash=\(bind:chargeKeyHash)").run()
        try await sql.raw("""
            UPDATE measurement_revenuecat_lifecycle_events
            SET resolution='unresolved',conflict_hash=COALESCE(conflict_hash,normalized_hash),conflicted_at=COALESCE(conflicted_at,\(bind:now))
            WHERE id IN (
                SELECT refund_event_id FROM measurement_revenuecat_adjustments WHERE charge_key_hash=\(bind:chargeKeyHash)
                UNION
                SELECT reversal_event_id FROM measurement_revenuecat_adjustments WHERE charge_key_hash=\(bind:chargeKeyHash)
            )
            """).run()
    }

    private static func quarantine(chargeKeyHash: String, on sql: SQLDatabase) async throws {
        try await sql.raw("""
            DELETE FROM measurement_purchase_charge_links WHERE charge_id IN
              (SELECT id FROM measurement_revenuecat_events WHERE durable_key_hash=\(bind:chargeKeyHash))
            """).run()
        try await sql.raw("""
            UPDATE measurement_revenuecat_events SET origin_acquisition_id=NULL
            WHERE durable_key_hash=\(bind:chargeKeyHash)
            """).run()
        try await sql.raw("""
            UPDATE measurement_purchase_acquisitions SET state='conflict',conflicted_at=COALESCE(conflicted_at,NOW())
            WHERE state='active' AND initial_charge_id IN (
                SELECT id FROM measurement_revenuecat_events WHERE durable_key_hash=\(bind:chargeKeyHash))
            """).run()
        try await sql.raw("""
            UPDATE measurement_revenuecat_lifecycle_events SET resolution='unresolved'
            WHERE charge_key_hash=\(bind:chargeKeyHash)
            """).run()
        try await sql.raw("""
            UPDATE measurement_dispatch_jobs SET state='suppressed',payload=NULL,lease_token=NULL,
                lease_expires_at=NULL,last_error_kind='provider_fact_conflict'
            WHERE state IN ('pending','failing','leased') AND (
                (source_kind='revenueCatEvent' AND source_id IN
                    (SELECT id FROM measurement_revenuecat_lifecycle_events WHERE charge_key_hash=\(bind:chargeKeyHash)))
                OR (source_kind='revenueCatLifecycle' AND source_id IN
                    (SELECT id FROM measurement_revenuecat_events WHERE durable_key_hash=\(bind:chargeKeyHash)))
            )
            """).run()
    }

    private static func enqueueResolvedAdjustments(accountID: UUID, chargeKeyHash: String, now: Date,
                                                   on sql: SQLDatabase) async throws {
        let rows = try await sql.raw("""
            SELECT l.id,l.event_kind,l.effect,l.event_generated_at,l.purchased_at,l.reason,l.currency_code,l.monetary_delta
            FROM measurement_revenuecat_lifecycle_events l
            JOIN measurement_revenuecat_adjustments a ON a.charge_key_hash=l.charge_key_hash
            WHERE l.account_id=\(bind:accountID) AND l.charge_key_hash=\(bind:chargeKeyHash)
              AND l.id IN (a.refund_event_id,a.reversal_event_id) AND l.resolution='resolved'
              AND a.state IN ('refunded','reversed')
              AND l.event_generated_at>=\(bind:now.addingTimeInterval(-7 * 86_400))
            """).all()
        for row in rows {
            let occurredAt = try row.decode(column: "event_generated_at", as: Date.self)
            let purchasedAt = try row.decode(column: "purchased_at", as: Date.self)
            guard let permission = try await currentPermission(accountID: accountID, purpose: .productAnalytics,
                                                                occurredAt: occurredAt, purchasedAt: purchasedAt,
                                                                on: sql) else { continue }
            var payload = ["event": "subscription_\(try row.decode(column: "effect", as: String.self))",
                           "occurredAt": iso(occurredAt),
                           "lifecycleKind": try row.decode(column: "event_kind", as: String.self)]
            if let reason = try row.decode(column: "reason", as: String?.self) { payload["reason"] = reason }
            if let currency = try row.decode(column: "currency_code", as: String?.self) { payload["currency"] = currency }
            if let amount = try row.decode(column: "monetary_delta", as: String?.self) { payload["amount"] = amount }
            try await enqueue(destination: "posthog", sourceKind: "revenueCatEvent",
                              sourceID: try row.decode(column: "id", as: UUID.self), accountID: accountID,
                              permission: permission, installationID: nil, payload: try canonicalJSON(payload),
                              now: now, on: sql)
        }
    }

    private static func opposite(_ negative: String, _ positive: String) -> Bool {
        guard let a = Decimal(string: negative, locale: Locale(identifier: "en_US_POSIX")),
              let b = Decimal(string: positive, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return a < 0 && b > 0 && a + b == 0
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

struct RevenueCatMeasurementController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.on(.POST, "api", "v2", "measurement", "webhooks", "revenuecat",
                  body: .collect(maxSize: "64kb"), use: receive)
    }

    @Sendable private func receive(req: Request) async throws -> Response {
        let data = req.body.data.map { Data($0.readableBytesView) } ?? Data()
        try await RevenueCatMeasurementService.ingest(body: data,
            authorization: req.headers.first(name: .authorization), app: req.application, on: req.db)
        // RevenueCat retries every response other than 200, including other 2xx codes.
        return Response(status: .ok)
    }
}
