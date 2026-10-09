import Vapor
import Fluent
import FluentSQL
import Crypto

// MARK: - Wire contract (native only)

enum SignupProvider: String, Codable, Sendable { case apple, google, email }

/// `POST /api/v2/measurement/signup-intents`. Strict allowlist: no account target,
/// email, provider token, IP attribution or advertising identifier is accepted.
struct SignupIntentRequest: Content, Sendable {
    struct Choices: Codable, Sendable, Equatable {
        let productAnalytics: Bool
        let appleAds: Bool
        let crossCompanyAds: Bool

        init(productAnalytics: Bool, appleAds: Bool, crossCompanyAds: Bool) {
            self.productAnalytics = productAnalytics; self.appleAds = appleAds; self.crossCompanyAds = crossCompanyAds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: MeasurementWireKey.self)
            try MeasurementATTObservation.exact(c, ["productAnalytics", "appleAds", "crossCompanyAds"], decoder)
            productAnalytics = try c.decode(Bool.self, forKey: .init(stringValue: "productAnalytics")!)
            appleAds = try c.decode(Bool.self, forKey: .init(stringValue: "appleAds")!)
            crossCompanyAds = try c.decode(Bool.self, forKey: .init(stringValue: "crossCompanyAds")!)
        }
    }

    let provider: SignupProvider
    let installationId: UUID
    let noticeVersion: String
    let choices: Choices
    let attStatus: MeasurementATTStatus?
    let attObservedAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        let names = Set(c.allKeys.map(\.stringValue))
        let required: Set<String> = ["provider", "installationId", "noticeVersion", "choices"]
        guard required.isSubset(of: names), names.isSubset(of: required.union(["attStatus", "attObservedAt"])) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected measurement fields"))
        }
        provider = try c.decode(SignupProvider.self, forKey: .init(stringValue: "provider")!)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        noticeVersion = try c.decode(String.self, forKey: .init(stringValue: "noticeVersion")!)
        choices = try c.decode(Choices.self, forKey: .init(stringValue: "choices")!)
        attStatus = try c.decodeIfPresent(MeasurementATTStatus.self, forKey: .init(stringValue: "attStatus")!)
        attObservedAt = try c.decodeIfPresent(Date.self, forKey: .init(stringValue: "attObservedAt")!)
    }
}

struct SignupIntentResponse: Content, Sendable {
    let intentId: UUID
    let capability: String
    let expiresAt: Date
    /// Present only for `provider=apple`: set verbatim as `ASAuthorizationAppleIDRequest.nonce`.
    let appleNonce: String?
}

/// Request-start context sent when issuing the Google native challenge or the
/// email sign-in link. Exactly `{intentId, capability}`.
struct SignupIntentBindingContext: Codable, Sendable {
    let intentId: UUID
    let capability: String

    init(intentId: UUID, capability: String) { self.intentId = intentId; self.capability = capability }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["intentId", "capability"], decoder)
        intentId = try c.decode(UUID.self, forKey: .init(stringValue: "intentId")!)
        capability = try c.decode(String.self, forKey: .init(stringValue: "capability")!)
    }
}

/// Optional `measurementContext` on each final native verify request. Choices and
/// provider authority come only from the server intent; the ATT fields matter only to
/// a cross-company opt-in and must be read immediately before the verify request.
struct SignupMeasurementContext: Codable, Sendable {
    let intentId: UUID
    let capability: String
    let installationId: UUID?
    let attStatus: MeasurementATTStatus?
    let attObservedAt: Date?

    init(intentId: UUID, capability: String, installationId: UUID? = nil,
         attStatus: MeasurementATTStatus? = nil, attObservedAt: Date? = nil) {
        self.intentId = intentId; self.capability = capability; self.installationId = installationId
        self.attStatus = attStatus; self.attObservedAt = attObservedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        let names = Set(c.allKeys.map(\.stringValue))
        guard names.isSuperset(of: ["intentId", "capability"]),
              names.isSubset(of: ["intentId", "capability", "installationId", "attStatus", "attObservedAt"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected measurement fields"))
        }
        intentId = try c.decode(UUID.self, forKey: .init(stringValue: "intentId")!)
        capability = try c.decode(String.self, forKey: .init(stringValue: "capability")!)
        installationId = try c.decodeIfPresent(UUID.self, forKey: .init(stringValue: "installationId")!)
        attStatus = try c.decodeIfPresent(MeasurementATTStatus.self, forKey: .init(stringValue: "attStatus")!)
        attObservedAt = try c.decodeIfPresent(Date.self, forKey: .init(stringValue: "attObservedAt")!)
    }
}

/// Authentication bodies carry optional measurement. A malformed context is treated
/// exactly like an absent one: it can never fail, weaken or delay authentication.
struct OptionalSignupBindingContext: Codable, Sendable {
    let value: SignupIntentBindingContext?
    init(from decoder: Decoder) throws { value = try? SignupIntentBindingContext(from: decoder) }
    func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
}

struct OptionalSignupMeasurementContext: Codable, Sendable {
    let value: SignupMeasurementContext?
    init(from decoder: Decoder) throws { value = try? SignupMeasurementContext(from: decoder) }
    func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
}

struct SignupIntentCancelRequest: Content, Sendable {
    let capability: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["capability"], decoder)
        capability = try c.decode(String.self, forKey: .init(stringValue: "capability")!)
    }
}

struct SignupIntentCancelResponse: Content, Sendable {
    let intentId: UUID
    let state: String
}

// MARK: - Service

/// One short-lived optional consent intent per new-account authentication attempt.
/// This is an application capability association, not proof of a physical device.
/// Only the identity branch that inserted a `users` row can adopt it; everything
/// optional happens inside one savepoint and never decides the authentication result.
enum SignupIntentService {
    /// Exact notice texts the native consent screen may present. A new notice text
    /// needs a new version here before any client may send it.
    static let acceptedNoticeVersions: Set<String> = ["signup-measurement-v1"]
    static let socialLifetime: TimeInterval = 600
    static let emailLifetime: TimeInterval = 900
    /// How long a settled intent keeps its capability for late cancellation before it
    /// is reduced to a tombstone. Later changes use the ordinary account settings flow.
    static let settledCancellationWindow: TimeInterval = 7 * 86_400
    static let futureSkew: TimeInterval = 300

    enum Proof: Sendable {
        /// `verifiedNonce` and `issuedAt` come only from the verified Apple identity token.
        case apple(verifiedNonce: String?, issuedAt: Date)
        case googleChallenge(UUID)
        case emailToken(UUID)
    }

    enum BindingTarget: Sendable {
        case googleChallenge(id: UUID, expiresAt: Date)
        case emailToken(id: UUID, expiresAt: Date)

        var kind: String { if case .googleChallenge = self { return "google_challenge" }; return "email_token" }
        var provider: SignupProvider { if case .googleChallenge = self { return .google }; return .email }
        var id: UUID { switch self { case .googleChallenge(let id, _), .emailToken(let id, _): return id } }
        var expiresAt: Date { switch self { case .googleChallenge(_, let at), .emailToken(_, let at): return at } }
    }

    enum Settlement: String, Sendable, Equatable {
        /// No intent was bound to this proof, or the presented one did not match it.
        case none
        /// A newly inserted account adopted the intent's choices atomically.
        case adopted
        /// Terminal: an existing account, or the binding was used without its capability.
        case consumedWithoutImport
        /// Optional work could not complete; authentication committed unmeasured.
        case suppressed
    }

    /// Test-only seam (honoured only in `.testing`) for real lock contention and SQL
    /// failure inside the optional savepoint.
    enum Stage: String, Sendable { case beforePurposeLocks, afterConsent }
    struct HookKey: StorageKey { typealias Value = @Sendable (Stage, UUID, SQLDatabase) async throws -> Void }

    private struct Suppressed: Error {}

    static func capabilityHash(_ capability: String) -> String {
        "sha256v1:" + SHA256Hasher.hash(token: "snaglist-signup-intent-capability-v1:" + capability)
    }

    static func validOpaque(_ value: String) -> Bool { AppleWebChallengeService.validOpaque(value) }

    static func providerEnvironment(_ platformEnvironment: String) -> LinkedInConversion.Environment {
        platformEnvironment == "production" ? .production : .sandbox
    }

    // MARK: Issue

    static func issue(_ input: SignupIntentRequest, platform: PlatformConfiguration, now: Date = Date(),
                      on db: Database) async throws -> SignupIntentResponse {
        guard acceptedNoticeVersions.contains(input.noticeVersion) else {
            throw Abort(.badRequest, reason: "Use a current measurement notice", identifier: "measurement_notice_invalid")
        }
        let choices = input.choices
        guard choices.productAnalytics || choices.appleAds || choices.crossCompanyAds else {
            throw Abort(.badRequest, reason: "Choose at least one measurement purpose", identifier: "measurement_choices_empty")
        }
        if choices.crossCompanyAds {
            guard input.attStatus != nil, let observed = input.attObservedAt,
                  observed <= now.addingTimeInterval(futureSkew),
                  observed >= now.addingTimeInterval(-MeasurementPrivacyService.attClaimMaximumAge) else {
                throw Abort(.badRequest, reason: "A current installation ATT assertion is required", identifier: "measurement_att_invalid")
            }
        } else if input.attStatus != nil || input.attObservedAt != nil {
            throw Abort(.badRequest, reason: "ATT fields do not apply to this choice", identifier: "measurement_att_unexpected")
        }
        let id = UUID()
        let capability = try SecureTokenGenerator.generate(byteCount: 32)
        let apple = input.provider == .apple
        let nonce = apple ? try SecureTokenGenerator.generate(byteCount: 32) : nil
        let expiresAt = now.addingTimeInterval(input.provider == .email ? emailLifetime : socialLifetime)
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO measurement_signup_intents
                (id,capability_hash,provider,surface,environment,installation_id,notice_version,
                 product_analytics,apple_ads,cross_company_ads,att_status,att_observed_at,apple_nonce_hash,
                 binding_kind,state,received_at,expires_at,bound_at)
            VALUES (\(bind:id),\(bind:capabilityHash(capability)),\(bind:input.provider.rawValue),'native',
                    \(bind:platform.environment),\(bind:input.installationId),\(bind:input.noticeVersion),
                    \(bind:choices.productAnalytics),\(bind:choices.appleAds),\(bind:choices.crossCompanyAds),
                    \(bind:input.attStatus?.rawValue),\(bind:input.attObservedAt),
                    \(bind:nonce.map { SHA256Hasher.hash(token: $0) }),
                    \(bind:apple ? "apple_nonce" : nil),\(bind:apple ? "bound" : "issued"),
                    \(bind:now),\(bind:expiresAt),\(bind:apple ? now : nil))
            """).run()
        return .init(intentId: id, capability: capability, expiresAt: expiresAt, appleNonce: nonce)
    }

    // MARK: Bind (Google challenge / email token)

    /// Called inside the transaction that inserts the provider challenge or email token,
    /// before any mail leaves. Never throws: a mismatch leaves that challenge unbound.
    @discardableResult
    static func bind(_ context: SignupIntentBindingContext?, to target: BindingTarget, app: Application,
                     now: Date = Date(), on db: Database) async -> Bool {
        guard let context, validOpaque(context.capability),
              let platform = try? PlatformConfiguration.load(on: app),
              let sql = try? VerifiedIdentityService.sql(db) else { return false }
        do { try await sql.raw("SAVEPOINT signup_intent_binding").run() } catch { return false }
        do {
            guard let row = try await sql.raw("""
                SELECT capability_hash,provider,environment,state,expires_at FROM measurement_signup_intents
                WHERE id=\(bind:context.intentId) FOR UPDATE NOWAIT
                """).first(),
                  try row.decode(column: "state", as: String.self) == "issued",
                  try row.decode(column: "provider", as: String.self) == target.provider.rawValue,
                  try row.decode(column: "environment", as: String.self) == platform.environment,
                  try row.decode(column: "expires_at", as: Date.self) > now,
                  let stored = try row.decode(column: "capability_hash", as: String?.self),
                  BrowserSessionService.constantTimeEqual(stored, capabilityHash(context.capability)) else {
                throw Suppressed()
            }
            try await sql.raw("""
                UPDATE measurement_signup_intents SET state='bound',binding_kind=\(bind:target.kind),
                    binding_id=\(bind:target.id),bound_at=\(bind:now),
                    expires_at=LEAST(expires_at,\(bind:target.expiresAt))
                WHERE id=\(bind:context.intentId) AND state='issued'
                """).run()
            try await sql.raw("RELEASE SAVEPOINT signup_intent_binding").run()
            return true
        } catch {
            try? await sql.raw("ROLLBACK TO SAVEPOINT signup_intent_binding").run()
            try? await sql.raw("RELEASE SAVEPOINT signup_intent_binding").run()
            return false
        }
    }

    // MARK: Settle inside the identity transaction

    /// Called inside the successful identity transaction, after the one-use provider
    /// proof was consumed and the account resolved under the identity locks. Never throws.
    /// The whole optional block runs in one savepoint: on any failure it rolls back to
    /// the savepoint and authentication commits unmeasured, with no partial rows.
    @discardableResult
    static func settle(_ proof: Proof, context: SignupMeasurementContext?,
                       resolution: VerifiedIdentityService.Resolution, app: Application,
                       now: Date = Date(), on db: Database) async -> Settlement {
        guard let sql = try? VerifiedIdentityService.sql(db) else { return .none }
        if case .apple = proof, context == nil { return .none }
        do { try await sql.raw("SAVEPOINT signup_measurement").run() } catch { return .suppressed }
        do {
            let result = try await settleInSavepoint(proof, context: context, resolution: resolution,
                                                     app: app, now: now, db: db, sql: sql)
            try await sql.raw("RELEASE SAVEPOINT signup_measurement").run()
            return result
        } catch {
            try? await sql.raw("ROLLBACK TO SAVEPOINT signup_measurement").run()
            try? await sql.raw("RELEASE SAVEPOINT signup_measurement").run()
            return .suppressed
        }
    }

    private static func settleInSavepoint(_ proof: Proof, context: SignupMeasurementContext?,
                                          resolution: VerifiedIdentityService.Resolution, app: Application,
                                          now: Date, db: Database, sql: SQLDatabase) async throws -> Settlement {
        let candidate: UUID?
        switch proof {
        case .apple: candidate = context?.intentId
        case .googleChallenge(let id):
            candidate = try await sql.raw("""
                SELECT id FROM measurement_signup_intents WHERE binding_kind='google_challenge' AND binding_id=\(bind:id)
                """).first()?.decode(column: "id", as: UUID.self)
        case .emailToken(let id):
            candidate = try await sql.raw("""
                SELECT id FROM measurement_signup_intents WHERE binding_kind='email_token' AND binding_id=\(bind:id)
                """).first()?.decode(column: "id", as: UUID.self)
        }
        guard let intentID = candidate else { return .none }
        // The cancellation route takes this same row lock. NOWAIT: if it is busy the
        // optional block is abandoned rather than making authentication wait.
        guard let row = try await sql.raw("""
            SELECT state,provider,environment,expires_at,received_at,capability_hash,binding_kind,binding_id,
                   apple_nonce_hash,installation_id,product_analytics,apple_ads,cross_company_ads,apple_slot_reference
            FROM measurement_signup_intents WHERE id=\(bind:intentID) FOR UPDATE NOWAIT
            """).first() else { return .none }
        guard try row.decode(column: "state", as: String.self) == "bound" else { return .none }
        let provider = try row.decode(column: "provider", as: String.self)
        let bindingKind = try row.decode(column: "binding_kind", as: String?.self)
        let receivedAt = try row.decode(column: "received_at", as: Date.self)
        let bindingID = try row.decode(column: "binding_id", as: UUID?.self)
        let proven: Bool
        switch proof {
        case .apple(let nonce, let issuedAt):
            if let nonce, validOpaque(nonce), provider == "apple", bindingKind == "apple_nonce",
               let stored = try row.decode(column: "apple_nonce_hash", as: String?.self),
               issuedAt >= receivedAt.addingTimeInterval(-30) {
                proven = BrowserSessionService.constantTimeEqual(SHA256Hasher.hash(token: nonce), stored)
            } else { proven = false }
        case .googleChallenge(let id):
            proven = provider == "google" && bindingKind == "google_challenge" && bindingID == id
        case .emailToken(let id):
            proven = provider == "email" && bindingKind == "email_token" && bindingID == id
        }
        // A context naming an intent this proof did not bind is left untouched.
        guard proven else { return .none }
        let environment = try row.decode(column: "environment", as: String.self)
        guard try row.decode(column: "expires_at", as: Date.self) > now,
              let platform = try? PlatformConfiguration.load(on: app), platform.environment == environment else {
            return .none
        }
        let presented: Bool
        if let context, context.intentId == intentID, validOpaque(context.capability),
           let stored = try row.decode(column: "capability_hash", as: String?.self) {
            presented = BrowserSessionService.constantTimeEqual(stored, capabilityHash(context.capability))
        } else { presented = false }
        guard presented, resolution.insertedNewAccount else {
            // Terminal and import-free: another device used the emailed link, the
            // local context was lost, or the account already existed.
            try await sql.raw("""
                UPDATE measurement_signup_intents SET state='consumed_existing',
                    consumed_reason=\(bind:presented ? "existing_account" : "context_absent"),consumed_at=\(bind:now)
                WHERE id=\(bind:intentID) AND state='bound'
                """).run()
            return .consumedWithoutImport
        }

        let accountID = try resolution.user.requireID()
        let installationID = try row.decode(column: "installation_id", as: UUID.self)
        let wantsProduct = try row.decode(column: "product_analytics", as: Bool.self)
        let wantsApple = try row.decode(column: "apple_ads", as: Bool.self)
        let wantsCross = try row.decode(column: "cross_company_ads", as: Bool.self)
        // Cross-company needs fresh authorised ATT from the very installation that made
        // the choice. Anything else suppresses that purpose only.
        var crossATT: Date?
        if wantsCross, let context, context.installationId == installationID, context.attStatus == .authorized,
           let observed = context.attObservedAt, observed <= now.addingTimeInterval(futureSkew),
           observed >= now.addingTimeInterval(-MeasurementPrivacyService.attClaimMaximumAge) {
            crossATT = observed
        }
        var purposes: [MeasurementPurpose] = []
        if wantsProduct { purposes.append(.productAnalytics) }
        if crossATT != nil { purposes.append(.crossCompanyAds) }
        if wantsApple { purposes.append(.appleAds) }
        guard !purposes.isEmpty else {
            // Only cross-company was chosen and its ATT evidence did not qualify: a new
            // account, but nothing to adopt, so no fact and no consent rows.
            try await sql.raw("""
                UPDATE measurement_signup_intents SET state='consumed_existing',consumed_reason='nothing_eligible',
                    consumed_at=\(bind:now) WHERE id=\(bind:intentID) AND state='bound'
                """).run()
            return .consumedWithoutImport
        }

        try await hook(app, .beforePurposeLocks, accountID, sql)
        // Same order as permission mutation and deletion: account row, then the fixed
        // purpose barriers. The account was inserted by this transaction; the purpose
        // barriers are only ever tried, never awaited.
        try await MeasurementPrivacyService.lockActiveAccount(accountID, on: db)
        for purpose in purposes {
            let key = "measurement-permission:\(accountID.uuidString):\(purpose.rawValue)"
            guard let lock = try await sql.raw("""
                SELECT pg_try_advisory_xact_lock(hashtextextended(\(bind:key),0)) AS acquired
                """).first(), try lock.decode(column: "acquired", as: Bool.self) else { throw Suppressed() }
        }
        let flags = try await FeatureFlagService.resolve(on: db)

        var productRevision: UUID?, productSubject: UUID?, appleRevision: UUID?, crossRevision: UUID?, crossSubject: UUID?
        for purpose in purposes {
            // The pre-auth choice was received at `receivedAt`; the account grant becomes
            // effective now, at adoption, inside the account-creating transaction.
            let written = try await MeasurementPrivacyService.recordDecisionInTransaction(
                accountID: accountID, purpose: purpose,
                requestID: derivedID("signup-consent-v1", intentID, purpose.rawValue),
                expectedRevision: nil, currentSubjectID: nil, decision: .granted, occurredAt: receivedAt,
                installationID: purpose == .crossCompanyAds ? installationID : nil,
                attStatus: purpose == .crossCompanyAds ? .authorized : nil,
                attAssertedAt: purpose == .crossCompanyAds ? crossATT : nil,
                now: now, on: db)
            switch purpose {
            case .productAnalytics: (productRevision, productSubject) = (written.revision, written.subjectID)
            case .appleAds: appleRevision = written.revision
            case .crossCompanyAds: (crossRevision, crossSubject) = (written.revision, written.subjectID)
            }
        }
        try await hook(app, .afterConsent, accountID, sql)
        // A pre-auth Apple slot, if one was reserved before creation, joins this signup
        // only through the exact Apple revision, installation and new account.
        if let appleRevision {
            try await SignupAppleEvidenceService.link(intentID: intentID,
                reference: try row.decode(column: "apple_slot_reference", as: String?.self),
                accountID: accountID, appleRevision: appleRevision, installationID: installationID, on: sql)
        }

        var continuityID: UUID?
        if let crossRevision {
            continuityID = try await sql.raw("""
                SELECT continuity_id FROM measurement_att_assertions
                WHERE account_id=\(bind:accountID) AND installation_id=\(bind:installationID)
                  AND consent_revision=\(bind:crossRevision) AND status='authorized'
                """).first()?.decode(column: "continuity_id", as: UUID?.self)
        }
        // Only an address the provider or our own email challenge verified no later than
        // the signup occurrence. Apple relay and malformed addresses never qualify.
        let verifiedEmail = try await sql.raw("""
            SELECT subject FROM user_identities WHERE user_id=\(bind:accountID) AND provider='email'
              AND verified_at<=\(bind:now) ORDER BY verified_at DESC LIMIT 1
            """).first()?.decode(column: "subject", as: String.self)
        let emailHash = verifiedEmail.flatMap(LinkedInConversion.verifiedEmailHash)
        // Eligibility is frozen here. A flag, grant or ATT authorisation that appears
        // later can never add a destination to this signup.
        let productEligible = productSubject != nil && flags["productAnalyticsEnabled"] == true
        let linkedInEligible = crossSubject != nil && continuityID != nil && emailHash != nil
            && flags["crossCompanyAdsEnabled"] == true && flags["linkedInConversionsEnabled"] == true
        let factID = UUID()
        try await sql.raw("""
            INSERT INTO measurement_signup_facts
                (id,account_id,intent_id,provider,environment,occurred_at,product_eligible,linkedin_eligible,created_at)
            VALUES (\(bind:factID),\(bind:accountID),\(bind:intentID),\(bind:provider),\(bind:environment),\(bind:now),
                    \(bind:productEligible),\(bind:linkedInEligible),\(bind:now))
            """).run()
        let occurred = ISO8601DateFormatter().string(from: now)
        if productEligible, let productRevision, let productSubject {
            let payload = try canonicalJSON(["event": "account_created", "occurredAt": occurred])
            try await sql.raw("""
                INSERT INTO measurement_dispatch_jobs
                    (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,state,available_at,payload,created_at)
                VALUES (\(bind:UUID()),'posthog','signupFact',\(bind:factID),\(bind:accountID),\(bind:productSubject),
                        \(bind:productRevision),'pending',\(bind:now),CAST(\(bind:payload) AS JSONB),\(bind:now))
                """).run()
        }
        if linkedInEligible, let crossRevision, let crossSubject, let continuityID, let emailHash {
            let payload = try canonicalJSON(["event": "account_created", "occurredAt": occurred,
                                             "emailSha256": emailHash,
                                             "attContinuityId": continuityID.uuidString.lowercased()])
            try await sql.raw("""
                INSERT INTO measurement_dispatch_jobs
                    (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,installation_id,
                     state,available_at,payload,created_at)
                VALUES (\(bind:UUID()),'linkedin','signupFact',\(bind:factID),\(bind:accountID),\(bind:crossSubject),
                        \(bind:crossRevision),\(bind:installationID),'pending',\(bind:now),CAST(\(bind:payload) AS JSONB),\(bind:now))
                """).run()
        }
        // TODO(SDK-ACTIVATION-DECISION.md): Singular signup delivery is held. No Singular
        // or Meta identifier or adapter is created for signup facts until that decision
        // and the supported receiver/erasure contracts exist.
        try await sql.raw("""
            UPDATE measurement_signup_intents SET state='consumed_new',consumed_reason='new_account',consumed_at=\(bind:now),
                account_id=\(bind:accountID),product_revision=\(bind:productRevision),apple_revision=\(bind:appleRevision),
                cross_revision=\(bind:crossRevision),signup_fact_id=\(bind:factID)
            WHERE id=\(bind:intentID) AND state='bound'
            """).run()
        return .adopted
    }

    // MARK: Cancel

    /// Idempotent, capability-bound cancellation that serialises with adoption on the
    /// intent row. Before adoption it prevents import; after adoption it withdraws only
    /// the exact revisions this intent created, plus its pending signup dispatch.
    static func cancel(intentID: UUID, capability: String, now: Date = Date(), on db: Database) async throws -> String {
        guard validOpaque(capability) else { throw notFound() }
        let expected = capabilityHash(capability)
        let sql = try VerifiedIdentityService.sql(db)
        for _ in 0..<4 {
            // Nonlocking route discovery; every route re-reads under its locks.
            guard let row = try await sql.raw("""
                SELECT state,capability_hash,account_id FROM measurement_signup_intents WHERE id=\(bind:intentID)
                """).first(), let stored = try row.decode(column: "capability_hash", as: String?.self),
                  BrowserSessionService.constantTimeEqual(stored, expected) else { throw notFound() }
            let state = try row.decode(column: "state", as: String.self)
            switch state {
            case "cancelled", "expired":
                return state
            case "issued", "bound", "consumed_existing":
                let settled: String? = try await db.transaction { tx in
                    let txSQL = try VerifiedIdentityService.sql(tx)
                    guard let locked = try await txSQL.raw("""
                        SELECT state,capability_hash,apple_slot_reference FROM measurement_signup_intents
                        WHERE id=\(bind:intentID) FOR UPDATE
                        """).first(), let lockedHash = try locked.decode(column: "capability_hash", as: String?.self),
                          BrowserSessionService.constantTimeEqual(lockedHash, expected) else { throw notFound() }
                    guard try locked.decode(column: "state", as: String.self) == state else { return nil }
                    if let slot = try locked.decode(column: "apple_slot_reference", as: String?.self) {
                        // Never linked to an account: an in-flight exchange finds nothing to fill.
                        try await SignupAppleEvidenceService.discard(intentID: intentID, reference: slot, on: txSQL)
                    }
                    try await txSQL.raw("""
                        UPDATE measurement_signup_intents SET state='cancelled',cancelled_at=\(bind:now) WHERE id=\(bind:intentID)
                        """).run()
                    return "cancelled"
                }
                if let settled { return settled }
            case "consumed_new":
                guard let accountID = try row.decode(column: "account_id", as: UUID?.self) else { throw notFound() }
                let settled: String? = try await db.transaction { tx in
                    let txSQL = try VerifiedIdentityService.sql(tx)
                    // account -> fixed purpose barriers -> intent, as permission mutation and deletion.
                    let account = try await txSQL.raw("""
                        SELECT lifecycle_state FROM users WHERE id=\(bind:accountID) FOR UPDATE
                        """).first()
                    for purpose in [MeasurementPurpose.productAnalytics, .crossCompanyAds, .appleAds] {
                        try await VerifiedIdentityService.lock(
                            "measurement-permission:\(accountID.uuidString):\(purpose.rawValue)", on: tx)
                    }
                    guard let locked = try await txSQL.raw("""
                        SELECT state,capability_hash,account_id,product_revision,apple_revision,cross_revision,signup_fact_id,
                               apple_slot_reference
                        FROM measurement_signup_intents WHERE id=\(bind:intentID) FOR UPDATE
                        """).first(), let lockedHash = try locked.decode(column: "capability_hash", as: String?.self),
                          BrowserSessionService.constantTimeEqual(lockedHash, expected) else { throw notFound() }
                    guard try locked.decode(column: "state", as: String.self) == "consumed_new",
                          try locked.decode(column: "account_id", as: UUID?.self) == accountID else { return nil }
                    if try account?.decode(column: "lifecycle_state", as: String.self) == "active" {
                        let created: [(MeasurementPurpose, UUID?)] = [
                            (.productAnalytics, try locked.decode(column: "product_revision", as: UUID?.self)),
                            (.crossCompanyAds, try locked.decode(column: "cross_revision", as: UUID?.self)),
                            (.appleAds, try locked.decode(column: "apple_revision", as: UUID?.self))]
                        for (purpose, revision) in created {
                            guard let revision else { continue }
                            let current = try await txSQL.raw("""
                                SELECT revision,subject_id FROM measurement_permission_current
                                WHERE account_id=\(bind:accountID) AND purpose=\(bind:purpose.rawValue) FOR UPDATE
                                """).first()
                            // A later, independently chosen revision is never touched.
                            guard let current, try current.decode(column: "revision", as: UUID.self) == revision else { continue }
                            try await MeasurementPrivacyService.recordDecisionInTransaction(
                                accountID: accountID, purpose: purpose,
                                requestID: derivedID("signup-cancel-v1", intentID, purpose.rawValue),
                                expectedRevision: revision,
                                currentSubjectID: try current.decode(column: "subject_id", as: UUID?.self),
                                decision: .withdrawn, occurredAt: now, installationID: nil, attStatus: nil,
                                attAssertedAt: nil, now: now, on: tx)
                        }
                    }
                    if let slot = try locked.decode(column: "apple_slot_reference", as: String?.self) {
                        // This intent's own Apple evidence goes with it, whatever the current revision.
                        try await SignupAppleEvidenceService.discard(intentID: intentID, reference: slot, on: txSQL)
                    }
                    if let factID = try locked.decode(column: "signup_fact_id", as: UUID?.self) {
                        try await txSQL.raw("""
                            UPDATE measurement_dispatch_jobs SET
                                state=CASE WHEN state='pending' THEN 'suppressed'
                                           WHEN state IN ('leased','failing') THEN 'uncertain' ELSE state END,
                                payload=NULL,lease_token=NULL,lease_expires_at=NULL
                            WHERE source_kind='signupFact' AND source_id=\(bind:factID) AND state<>'delivered'
                            """).run()
                        try await txSQL.raw("""
                            UPDATE measurement_signup_facts SET withdrawn_at=COALESCE(withdrawn_at,\(bind:now))
                            WHERE id=\(bind:factID)
                            """).run()
                    }
                    try await txSQL.raw("""
                        UPDATE measurement_signup_intents SET state='cancelled',cancelled_at=\(bind:now) WHERE id=\(bind:intentID)
                        """).run()
                    return "cancelled"
                }
                if let settled { return settled }
            default:
                throw notFound()
            }
        }
        throw Abort(.conflict, reason: "This measurement choice is changing. Try again", identifier: "measurement_signup_intent_busy")
    }

    // MARK: Dispatch-time source loader

    /// Rechecks the dedicated signup source immediately before provider delivery. The
    /// generic dispatch gate has already checked current revision, active subject,
    /// pending erasure, flags and (for LinkedIn) live same-install ATT.
    static func dispatchIsEligible(factID: UUID, destination: String, accountID: UUID, revision: UUID,
                                   installationID: UUID?, payload: [String: String], now: Date,
                                   on sql: SQLDatabase) async throws -> Bool {
        let purpose = destination == "posthog" ? MeasurementPurpose.productAnalytics : .crossCompanyAds
        guard let fact = try await sql.raw("""
            SELECT f.occurred_at,f.product_eligible,f.linkedin_eligible
            FROM measurement_signup_facts f
            JOIN measurement_permission_current c ON c.account_id=f.account_id AND c.purpose=\(bind:purpose.rawValue)
             AND c.revision=\(bind:revision) AND c.decision='granted' AND c.updated_at<=f.occurred_at
            WHERE f.id=\(bind:factID) AND f.account_id=\(bind:accountID)
              AND f.withdrawn_at IS NULL AND f.scrubbed_at IS NULL
            """).first() else { return false }
        let occurredAt = try fact.decode(column: "occurred_at", as: Date.self)
        switch destination {
        case "posthog":
            return try fact.decode(column: "product_eligible", as: Bool.self) && payload["event"] == "account_created"
        case "linkedin":
            guard try fact.decode(column: "linkedin_eligible", as: Bool.self), payload["event"] == "account_created",
                  let installationID, let emailHash = payload["emailSha256"],
                  let continuityText = payload["attContinuityId"], let continuity = UUID(uuidString: continuityText),
                  occurredAt <= now, occurredAt > now.addingTimeInterval(-7 * 86_400) else { return false }
            guard try await sql.raw("""
                SELECT 1 FROM measurement_att_assertions WHERE account_id=\(bind:accountID)
                  AND installation_id=\(bind:installationID) AND consent_revision=\(bind:revision)
                  AND status='authorized' AND expires_at>\(bind:now) AND continuity_id=\(bind:continuity)
                """).first() != nil else { return false }
            let emails = try await sql.raw("""
                SELECT subject FROM user_identities WHERE user_id=\(bind:accountID) AND provider='email'
                  AND verified_at<=\(bind:occurredAt)
                """).all().map { try $0.decode(column: "subject", as: String.self) }
            return emails.contains { LinkedInConversion.verifiedEmailHash($0) == emailHash }
        default:
            // Singular is held for signup facts (SDK-ACTIVATION-DECISION.md).
            return false
        }
    }

    // MARK: Retention and deletion

    private static let scrubAssignments = """
        capability_hash=NULL,installation_id=NULL,product_analytics=NULL,apple_ads=NULL,cross_company_ads=NULL,
        att_status=NULL,att_observed_at=NULL,apple_nonce_hash=NULL,binding_id=NULL,account_id=NULL,
        product_revision=NULL,apple_revision=NULL,cross_revision=NULL,apple_slot_reference=NULL,apple_slot_reserved_at=NULL
        """

    /// Scheduled retention: unclaimed expired intents become `expired` tombstones and
    /// settled intents lose their capability and joins after the cancellation window.
    static func cleanup(now: Date = Date(), limit: Int = 5_000, on db: Database) async throws -> Int {
        let sql = try VerifiedIdentityService.sql(db)
        let bounded = max(0, min(limit, 50_000))
        // Unlinked Apple slots go before their intents lose the pointer.
        let slots = try await SignupAppleEvidenceService.cleanup(now: now, on: db)
        let expired = try await sql.raw("""
            WITH due AS (
                SELECT id FROM measurement_signup_intents
                WHERE state IN ('issued','bound') AND expires_at<=\(bind:now)
                ORDER BY expires_at LIMIT \(bind:bounded) FOR UPDATE SKIP LOCKED),
            changed AS (
                UPDATE measurement_signup_intents i SET state='expired',\(unsafeRaw: scrubAssignments),scrubbed_at=\(bind:now)
                FROM due WHERE i.id=due.id RETURNING 1)
            SELECT count(*) AS total FROM changed
            """).first()?.decode(column: "total", as: Int.self) ?? 0
        let settled = try await sql.raw("""
            WITH due AS (
                SELECT id FROM measurement_signup_intents
                WHERE scrubbed_at IS NULL AND state IN ('consumed_new','consumed_existing','cancelled')
                  AND COALESCE(cancelled_at,consumed_at)<=\(bind:now.addingTimeInterval(-settledCancellationWindow))
                LIMIT \(bind:bounded) FOR UPDATE SKIP LOCKED),
            changed AS (
                UPDATE measurement_signup_intents i SET \(unsafeRaw: scrubAssignments),scrubbed_at=\(bind:now)
                FROM due WHERE i.id=due.id RETURNING 1)
            SELECT count(*) AS total FROM changed
            """).first()?.decode(column: "total", as: Int.self) ?? 0
        return expired + settled + slots
    }

    /// Called from `MeasurementPrivacyService.eraseAccount`, which already holds the
    /// account row and every purpose barrier, after exposure capture.
    static func eraseAccount(_ accountID: UUID, now: Date, on sql: SQLDatabase) async throws {
        let slots = try await sql.raw("""
            SELECT apple_slot_reference FROM measurement_signup_intents
            WHERE account_id=\(bind:accountID) AND apple_slot_reference IS NOT NULL
            """).all().map { try $0.decode(column: "apple_slot_reference", as: String.self) }
        for slot in slots { try await SignupAppleEvidenceService.discard(reference: slot, on: sql) }
        try await sql.raw("""
            UPDATE measurement_signup_intents SET \(unsafeRaw: scrubAssignments),scrubbed_at=COALESCE(scrubbed_at,\(bind:now))
            WHERE account_id=\(bind:accountID)
            """).run()
        try await sql.raw("""
            UPDATE measurement_signup_facts SET account_id=NULL,withdrawn_at=COALESCE(withdrawn_at,\(bind:now)),
                scrubbed_at=COALESCE(scrubbed_at,\(bind:now))
            WHERE account_id=\(bind:accountID)
            """).run()
    }

    // MARK: Helpers

    private static func hook(_ app: Application, _ stage: Stage, _ accountID: UUID, _ sql: SQLDatabase) async throws {
        guard app.environment == .testing, let hook = app.storage[HookKey.self] else { return }
        try await hook(stage, accountID, sql)
    }

    static func derivedID(_ domain: String, _ intentID: UUID, _ purpose: String) -> UUID {
        let digest = SHA256.hash(data: Data([domain, intentID.uuidString.lowercased(), purpose].joined(separator: "|").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func canonicalJSON(_ value: [String: String]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func notFound() -> Abort {
        Abort(.notFound, reason: "This measurement choice is no longer available", identifier: "measurement_signup_intent_not_found")
    }
}
