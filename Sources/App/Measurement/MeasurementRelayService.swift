import Vapor
import Fluent
import FluentSQL
import Crypto

struct MeasurementWireKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct MeasurementATTObservation: Content, Sendable {
    let installationId: UUID
    let consentRevision: UUID
    let attStatus: MeasurementATTStatus
    let observedAt: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try Self.exact(c, ["installationId", "consentRevision", "attStatus", "observedAt"], decoder)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        consentRevision = try c.decode(UUID.self, forKey: .init(stringValue: "consentRevision")!)
        attStatus = try c.decode(MeasurementATTStatus.self, forKey: .init(stringValue: "attStatus")!)
        observedAt = try c.decode(Date.self, forKey: .init(stringValue: "observedAt")!)
    }

    static func exact(_ c: KeyedDecodingContainer<MeasurementWireKey>, _ names: Set<String>, _ decoder: Decoder) throws {
        guard Set(c.allKeys.map(\.stringValue)) == names else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected measurement fields"))
        }
    }
}

struct MeasurementDeviceBinding: Content, Sendable {
    let installationId: UUID
    let consentRevision: UUID
    let singularDeviceId: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["installationId", "consentRevision", "singularDeviceId"], decoder)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        consentRevision = try c.decode(UUID.self, forKey: .init(stringValue: "consentRevision")!)
        singularDeviceId = try c.decode(String.self, forKey: .init(stringValue: "singularDeviceId")!)
    }
}

struct MeasurementProductEventUpload: Content, Sendable {
    struct Event: Codable, Sendable {
        let schemaVersion: Int
        let name: String
        let properties: [String: String]

        init(schemaVersion: Int, name: String, properties: [String: String]) {
            self.schemaVersion = schemaVersion; self.name = name; self.properties = properties
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: MeasurementWireKey.self)
            try MeasurementATTObservation.exact(c, ["schemaVersion", "name", "properties"], decoder)
            schemaVersion = try c.decode(Int.self, forKey: .init(stringValue: "schemaVersion")!)
            name = try c.decode(String.self, forKey: .init(stringValue: "name")!)
            properties = try c.decode([String: String].self, forKey: .init(stringValue: "properties")!)
        }
    }

    let eventId: UUID
    let occurredAt: Date
    let consentRevision: UUID
    let installationId: UUID
    let event: Event

    init(eventId: UUID, occurredAt: Date, consentRevision: UUID, installationId: UUID, event: Event) {
        self.eventId = eventId; self.occurredAt = occurredAt; self.consentRevision = consentRevision
        self.installationId = installationId; self.event = event
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["eventId", "occurredAt", "consentRevision", "installationId", "event"], decoder)
        eventId = try c.decode(UUID.self, forKey: .init(stringValue: "eventId")!)
        occurredAt = try c.decode(Date.self, forKey: .init(stringValue: "occurredAt")!)
        consentRevision = try c.decode(UUID.self, forKey: .init(stringValue: "consentRevision")!)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        event = try c.decode(Event.self, forKey: .init(stringValue: "event")!)
    }
}

struct MeasurementAppleUpload: Content, Sendable {
    let token: String
    let installationId: UUID
    let consentRevision: UUID
    let appVersion: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MeasurementWireKey.self)
        try MeasurementATTObservation.exact(c, ["token", "installationId", "consentRevision", "appVersion"], decoder)
        token = try c.decode(String.self, forKey: .init(stringValue: "token")!)
        installationId = try c.decode(UUID.self, forKey: .init(stringValue: "installationId")!)
        consentRevision = try c.decode(UUID.self, forKey: .init(stringValue: "consentRevision")!)
        appVersion = try c.decode(String.self, forKey: .init(stringValue: "appVersion")!)
    }
}

enum MeasurementCredentialCipher {
    struct Key: StorageKey { typealias Value = Data }

    private static func key(_ app: Application) throws -> SymmetricKey {
        if app.environment == .testing, let bytes = app.storage[Key.self], bytes.count == 32 { return .init(data: bytes) }
        guard let raw = Environment.get("MEASUREMENT_CREDENTIAL_KEY"), let bytes = Data(base64Encoded: raw), bytes.count == 32 else {
            throw Abort(.serviceUnavailable, reason: "Measurement credential storage is unavailable", identifier: "measurement_credential_unavailable")
        }
        return .init(data: bytes)
    }

    static func seal(_ value: String, accountID: UUID, installationID: UUID, revision: UUID,
                     app: Application) throws -> String {
        let aad = Data("\(accountID.uuidString):\(installationID.uuidString):\(revision.uuidString)".utf8)
        let box = try AES.GCM.seal(Data(value.utf8), using: key(app), authenticating: aad)
        guard let combined = box.combined else { throw Abort(.serviceUnavailable, reason: "Measurement credential storage is unavailable") }
        return combined.base64EncodedString()
    }

    static func open(_ value: String, accountID: UUID, installationID: UUID, revision: UUID,
                     app: Application) throws -> String {
        guard let combined = Data(base64Encoded: value) else {
            throw Abort(.serviceUnavailable, reason: "Measurement credential storage is unavailable")
        }
        let aad = Data("\(accountID.uuidString):\(installationID.uuidString):\(revision.uuidString)".utf8)
        let clear = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key(app), authenticating: aad)
        guard let result = String(data: clear, encoding: .utf8) else {
            throw Abort(.serviceUnavailable, reason: "Measurement credential storage is unavailable")
        }
        return result
    }
}

enum MeasurementRelayService {
    enum ServerOutcome: String, Sendable {
        case completionSubmitted = "completion_submitted"
        case completionAccepted = "completion_accepted"
        case completionRejected = "completion_rejected"
        case reportIssued = "report_issued"
    }

    /// Transient authority captured only for a newly committed business mutation.
    /// It is deliberately not reconstructed from a later request or consent grant.
    struct OutcomeCandidate: Sendable {
        let accountID: UUID
        let operationID: UUID
        let installationID: UUID
        let event: ServerOutcome
        let occurredAt: Date
        fileprivate let consentRevision: UUID
        fileprivate let subjectID: UUID
    }

    static let futureSkew: TimeInterval = 300
    static let maximumEventAge: TimeInterval = 86_400

    static func observeATT(accountID: UUID, input: MeasurementATTObservation, now: Date = Date(), on db: Database) async throws -> MeasurementPermissionsEnvelope {
        guard input.observedAt <= now.addingTimeInterval(futureSkew), input.observedAt >= now.addingTimeInterval(-MeasurementPrivacyService.attClaimMaximumAge) else {
            throw Abort(.badRequest, reason: "Use a current ATT observation", identifier: "measurement_att_invalid")
        }
        return try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):crossCompanyAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            let current = try await requirePermission(accountID: accountID, purpose: .crossCompanyAds,
                                                      revision: input.consentRevision, requireSubject: false, on: sql)
            guard current.decision == .granted else { throw permissionRequired() }
            if let old = try await sql.raw("""
                SELECT status,asserted_at FROM measurement_att_assertions
                WHERE account_id=\(bind:accountID) AND installation_id=\(bind:input.installationId) FOR UPDATE
                """).first() {
                let oldAt = try old.decode(column: "asserted_at", as: Date.self)
                guard input.observedAt >= oldAt else { throw Abort(.conflict, reason: "A newer ATT observation is already recorded", identifier: "measurement_att_stale") }
                if abs(input.observedAt.timeIntervalSince(oldAt)) < 0.001 {
                    guard try old.decode(column: "status", as: String.self) == input.attStatus.rawValue else {
                        throw Abort(.conflict, reason: "This ATT observation conflicts with the stored observation", identifier: "measurement_att_conflict")
                    }
                    return try await MeasurementPrivacyService.readSnapshot(accountID: accountID, installationID: input.installationId, now: now, on: tx)
                }
            }
            let expiry = now.addingTimeInterval(MeasurementPrivacyService.attLifetime)
            try await sql.raw("""
                INSERT INTO measurement_att_assertions(account_id,installation_id,purpose,consent_revision,status,asserted_at,received_at,expires_at)
                VALUES (\(bind:accountID),\(bind:input.installationId),'crossCompanyAds',\(bind:input.consentRevision),
                        \(bind:input.attStatus.rawValue),\(bind:input.observedAt),\(bind:now),\(bind:expiry))
                ON CONFLICT (account_id,installation_id) DO UPDATE SET consent_revision=EXCLUDED.consent_revision,
                    status=EXCLUDED.status,asserted_at=EXCLUDED.asserted_at,received_at=EXCLUDED.received_at,expires_at=EXCLUDED.expires_at
                """).run()
            if input.attStatus == .authorized, current.subjectID == nil {
                let erasurePending = try await sql.raw("""
                    SELECT 1 FROM measurement_erasure_jobs e JOIN measurement_subjects s ON s.id=e.subject_id
                    WHERE e.account_id=\(bind:accountID) AND s.purpose='crossCompanyAds' AND e.state<>'completed' LIMIT 1
                    """).first() != nil
                if !erasurePending {
                    let subject = try await MeasurementPrivacyService.createSubject(accountID: accountID,
                        purpose: .crossCompanyAds, now: now, on: sql)
                    try await sql.raw("""
                        UPDATE measurement_permission_current SET subject_id=\(bind:subject)
                        WHERE account_id=\(bind:accountID) AND purpose='crossCompanyAds' AND revision=\(bind:input.consentRevision)
                        """).run()
                }
            }
            return try await MeasurementPrivacyService.readSnapshot(accountID: accountID, installationID: input.installationId, now: now, on: tx)
        }
    }

    static func bindDevice(accountID: UUID, input: MeasurementDeviceBinding, app: Application, now: Date = Date(), on db: Database) async throws {
        guard validDeviceID(input.singularDeviceId) else {
            throw Abort(.badRequest, reason: "Use a valid measurement device identifier", identifier: "measurement_device_invalid")
        }
        guard await flag("crossCompanyAdsEnabled", on: db) else { throw switchedOff() }
        try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):crossCompanyAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            let current = try await requirePermission(accountID: accountID, purpose: .crossCompanyAds,
                                                      revision: input.consentRevision, requireSubject: true, on: sql)
            guard current.decision == .granted, !current.erasurePending, let subject = current.subjectID,
                  try await effectiveATT(accountID: accountID, installationID: input.installationId,
                                         revision: input.consentRevision, now: now, on: sql) else { throw permissionRequired() }
            let ciphertext = try MeasurementCredentialCipher.seal(input.singularDeviceId, accountID: accountID,
                installationID: input.installationId, revision: input.consentRevision, app: app)
            let digest = SHA256Hasher.hash(token: input.singularDeviceId)
            try await sql.raw("""
                INSERT INTO measurement_device_bindings
                    (account_id,installation_id,purpose,consent_revision,subject_id,singular_device_id_ciphertext,singular_device_id_hash,received_at)
                VALUES (\(bind:accountID),\(bind:input.installationId),'crossCompanyAds',\(bind:input.consentRevision),\(bind:subject),
                        \(bind:ciphertext),\(bind:digest),\(bind:now))
                ON CONFLICT(subject_id,installation_id) DO UPDATE SET consent_revision=EXCLUDED.consent_revision,
                    singular_device_id_ciphertext=EXCLUDED.singular_device_id_ciphertext,
                    singular_device_id_hash=EXCLUDED.singular_device_id_hash,received_at=EXCLUDED.received_at,revoked_at=NULL
                """).run()
        }
    }

    static func acceptProductEvent(accountID: UUID, input: MeasurementProductEventUpload, now: Date = Date(), on db: Database) async throws {
        try validateEvent(input, now: now)
        guard await flag("productAnalyticsEnabled", on: db) else { throw switchedOff() }
        let properties = try canonicalJSON(input.event.properties)
        let bodyHash = eventHash(input)
        try await db.transaction { tx in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):productAnalytics", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            if let row = try await sql.raw("SELECT body_hash FROM measurement_product_events WHERE account_id=\(bind:accountID) AND event_id=\(bind:input.eventId)").first() {
                guard try row.decode(column: "body_hash", as: String.self) == bodyHash else {
                    throw Abort(.conflict, reason: "This measurement event ID was already used", identifier: "measurement_event_conflict")
                }
                return
            }
            let current = try await requirePermission(accountID: accountID, purpose: .productAnalytics,
                                                      revision: input.consentRevision, requireSubject: true, on: sql)
            guard current.decision == .granted, !current.erasurePending, let subject = current.subjectID,
                  input.occurredAt >= current.updatedAt else { throw permissionRequired() }
            try await sql.raw("""
                INSERT INTO measurement_product_events
                    (account_id,event_id,installation_id,purpose,consent_revision,subject_id,occurred_at,received_at,
                     schema_version,event_name,properties,body_hash)
                VALUES (\(bind:accountID),\(bind:input.eventId),\(bind:input.installationId),'productAnalytics',
                        \(bind:input.consentRevision),\(bind:subject),\(bind:input.occurredAt),\(bind:now),1,
                        \(bind:input.event.name),CAST(\(bind:properties) AS JSONB),\(bind:bodyHash))
                """).run()
            let payload = try canonicalJSON(["event": input.event.name, "occurredAt": ISO8601DateFormatter().string(from: input.occurredAt)]
                                            .merging(input.event.properties) { first, _ in first })
            try await sql.raw("""
                INSERT INTO measurement_dispatch_jobs
                    (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,state,available_at,payload,created_at)
                VALUES (\(bind:UUID()),'posthog','productEvent',\(bind:input.eventId),\(bind:accountID),\(bind:subject),
                        \(bind:input.consentRevision),'pending',\(bind:now),CAST(\(bind:payload) AS JSONB),\(bind:now))
                ON CONFLICT(account_id,destination,source_kind,source_id) DO NOTHING
                """).run()
        }
    }

    /// Called inside the genuine new-mutation transaction, after its durable receipt
    /// was written. The purpose lock makes this an exact snapshot of the grant which
    /// covered the operation. A replay never reaches this call.
    static func outcomeCandidate(accountID: UUID, operationID: UUID, installationID: UUID,
                                 event: ServerOutcome, occurredAt: Date,
                                 on db: Database) async -> OutcomeCandidate? {
        guard let sql = try? VerifiedIdentityService.sql(db) else { return nil }
        do {
            try await sql.raw("SAVEPOINT optional_measurement_candidate").run()
            let lockKey = "measurement-permission:\(accountID.uuidString):productAnalytics"
            guard let lock = try await sql.raw("""
                SELECT pg_try_advisory_xact_lock(hashtextextended(\(bind:lockKey),0)) AS acquired
                """).first(), try lock.decode(column: "acquired", as: Bool.self) else {
                try await sql.raw("RELEASE SAVEPOINT optional_measurement_candidate").run()
                return nil
            }
            let flags = try await FeatureFlagService.resolve(on: db)
            guard flags["productAnalyticsEnabled"] == true else {
                try await sql.raw("RELEASE SAVEPOINT optional_measurement_candidate").run()
                return nil
            }
            let row = try await sql.raw("""
                SELECT c.revision,c.subject_id FROM measurement_permission_current c
                JOIN measurement_subjects s ON s.id=c.subject_id AND s.account_id=c.account_id
                  AND s.purpose=c.purpose AND s.state='active'
                JOIN users u ON u.id=c.account_id AND u.lifecycle_state='active'
                WHERE c.account_id=\(bind:accountID) AND c.purpose='productAnalytics'
                  AND c.decision='granted' AND c.updated_at<=\(bind:occurredAt)
                  AND NOT EXISTS(
                    SELECT 1 FROM measurement_erasure_jobs e
                    WHERE e.account_id=c.account_id AND e.subject_id=c.subject_id AND e.state<>'completed')
                LIMIT 1
                """).first()
            let candidate: OutcomeCandidate?
            if let row {
                candidate = .init(accountID: accountID, operationID: operationID,
                    installationID: installationID, event: event, occurredAt: occurredAt,
                    consentRevision: try row.decode(column: "revision", as: UUID.self),
                    subjectID: try row.decode(column: "subject_id", as: UUID.self))
            } else { candidate = nil }
            try await sql.raw("RELEASE SAVEPOINT optional_measurement_candidate").run()
            return candidate
        } catch {
            try? await sql.raw("ROLLBACK TO SAVEPOINT optional_measurement_candidate").run()
            try? await sql.raw("RELEASE SAVEPOINT optional_measurement_candidate").run()
            return nil
        }
    }

    /// Best-effort postcommit recording. Failures cannot change the business result.
    /// If this is lost, a receipt replay does not reconstruct it under later consent.
    static func recordOutcome(_ candidate: OutcomeCandidate,
                              app: Application, logger _: Logger, on db: Database) async {
        do {
            try await persistOutcome(candidate, environment: app.environment.name, on: db)
        } catch {
            // Measurement is deliberately best-effort. A busy privacy barrier or
            // unavailable measurement store must not delay or change the product result.
        }
    }

    private static func persistOutcome(_ candidate: OutcomeCandidate, environment: String,
                                       on db: Database) async throws {
        let accountID = candidate.accountID
        let eventID = outcomeEventID(environment: environment, accountID: accountID,
                                     event: candidate.event, operationID: candidate.operationID)
        let bodyHash = SHA256Hasher.hash(token: ["server-outcome-v1", environment,
            accountID.uuidString.lowercased(), candidate.event.rawValue,
            candidate.operationID.uuidString.lowercased(), candidate.installationID.uuidString.lowercased(),
            candidate.consentRevision.uuidString.lowercased(),
            candidate.subjectID.uuidString.lowercased()].joined(separator: "|"))
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            guard let account = try await sql.raw("""
                SELECT lifecycle_state FROM users WHERE id=\(bind:accountID) FOR UPDATE NOWAIT
                """).first(), try account.decode(column: "lifecycle_state", as: String.self) == "active" else { return }
            let lockKey = "measurement-permission:\(accountID.uuidString):productAnalytics"
            guard let lock = try await sql.raw("""
                SELECT pg_try_advisory_xact_lock(hashtextextended(\(bind:lockKey),0)) AS acquired
                """).first(), try lock.decode(column: "acquired", as: Bool.self) else { return }
            let flags = try await FeatureFlagService.resolve(on: tx)
            guard flags["productAnalyticsEnabled"] == true else { return }
            if let existing = try await sql.raw("""
                SELECT body_hash FROM measurement_product_events
                WHERE account_id=\(bind:accountID) AND event_id=\(bind:eventID)
                """).first() {
                guard try existing.decode(column: "body_hash", as: String.self) == bodyHash else {
                    throw Abort(.conflict, reason: "Product outcome identity conflict")
                }
                return
            }
            guard try await sql.raw("""
                SELECT 1 FROM measurement_permission_current c
                JOIN measurement_subjects s ON s.id=c.subject_id AND s.account_id=c.account_id
                  AND s.purpose=c.purpose AND s.state='active'
                WHERE c.account_id=\(bind:accountID) AND c.purpose='productAnalytics'
                  AND c.revision=\(bind:candidate.consentRevision)
                  AND c.subject_id=\(bind:candidate.subjectID)
                  AND c.decision='granted' AND c.updated_at<=\(bind:candidate.occurredAt)
                  AND NOT EXISTS(
                    SELECT 1 FROM measurement_erasure_jobs e
                    WHERE e.account_id=c.account_id AND e.subject_id=c.subject_id AND e.state<>'completed')
                LIMIT 1
                """).first() != nil else { return }
            let receivedAt = Date()
            try await sql.raw("""
                INSERT INTO measurement_product_events
                    (account_id,event_id,installation_id,purpose,consent_revision,subject_id,occurred_at,received_at,
                     schema_version,event_name,properties,body_hash)
                VALUES (\(bind:accountID),\(bind:eventID),\(bind:candidate.installationID),'productAnalytics',
                        \(bind:candidate.consentRevision),\(bind:candidate.subjectID),\(bind:candidate.occurredAt),\(bind:receivedAt),1,
                        \(bind:candidate.event.rawValue),'{}'::jsonb,\(bind:bodyHash))
                """).run()
            let payload = try canonicalJSON(["event": candidate.event.rawValue,
                "occurredAt": ISO8601DateFormatter().string(from: candidate.occurredAt)])
            try await sql.raw("""
                INSERT INTO measurement_dispatch_jobs
                    (id,destination,source_kind,source_id,account_id,subject_id,consent_revision,state,available_at,payload,created_at)
                VALUES (\(bind:UUID()),'posthog','productEvent',\(bind:eventID),\(bind:accountID),\(bind:candidate.subjectID),
                        \(bind:candidate.consentRevision),'pending',\(bind:receivedAt),CAST(\(bind:payload) AS JSONB),\(bind:receivedAt))
                ON CONFLICT(account_id,destination,source_kind,source_id) DO NOTHING
                """).run()
        }
    }

    private static func outcomeEventID(environment: String, accountID: UUID,
                                       event: ServerOutcome, operationID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data(["server-outcome-id-v1", environment,
            accountID.uuidString.lowercased(), event.rawValue,
            operationID.uuidString.lowercased()].joined(separator: "|").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func acceptApple(accountID: UUID, input: MeasurementAppleUpload, app: Application,
                            now: Date = Date(), on db: Database) async throws -> String {
        guard AdAttributionStore.Upload.isToken(input.token), AdAttributionStore.Upload.isAppVersion(input.appVersion) else {
            throw Abort(.badRequest, reason: "This measurement request could not be accepted", identifier: "ad_measurement_invalid")
        }
        guard await AdMeasurementPolicy.isEnabled(on: db) else { throw switchedOff() }
        let claim = try await db.transaction { tx -> (String, Bool) in
            try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):appleAds", on: tx)
            let sql = try VerifiedIdentityService.sql(tx)
            let current = try await requirePermission(accountID: accountID, purpose: .appleAds,
                                                      revision: input.consentRevision, requireSubject: false, on: sql)
            guard current.decision == .granted, !current.erasurePending else { throw permissionRequired() }
            if let row = try await sql.raw("""
                SELECT reference,exchange_state FROM ad_attribution_records
                WHERE canonical_account_id=\(bind:accountID) AND canonical_installation_id=\(bind:input.installationId)
                  AND canonical_consent_revision=\(bind:input.consentRevision)
                """).first() {
                let state = try row.decode(column: "exchange_state", as: String.self)
                guard state != "processing" else { throw Abort(.conflict, reason: "Apple measurement is already processing", identifier: "ad_measurement_processing") }
                return (try row.decode(column: "reference", as: String.self), false)
            }
            let reference = try await AdAttributionStore.insertCanonicalProcessing(accountID: accountID,
                installationID: input.installationId, consentRevision: input.consentRevision,
                appVersion: input.appVersion, now: now, on: tx)
            return (reference, true)
        }
        guard claim.1 else { return claim.0 }
        guard let transport = AppleAttributionExchangeService.transport(app) else {
            _ = try? await AdAttributionStore.delete(reference: claim.0, on: db)
            throw Abort(.serviceUnavailable, reason: "Apple measurement is unavailable", identifier: "ad_measurement_unavailable")
        }
        let result = await AppleAttributionExchangeService.exchange(token: input.token, transport: transport,
                                                                     sleep: AppleAttributionExchangeService.sleep(app))
        switch result.outcome {
        case .attributed, .invalid:
            return try await db.transaction { tx in
                try await MeasurementPrivacyService.lockActiveAccount(accountID, on: tx)
                try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):appleAds", on: tx)
                let sql = try VerifiedIdentityService.sql(tx)
                let current = try await requirePermission(accountID: accountID, purpose: .appleAds,
                                                          revision: input.consentRevision, requireSubject: false, on: sql)
                guard current.decision == .granted, !current.erasurePending, await AdMeasurementPolicy.isEnabled(on: tx) else {
                    _ = try await AdAttributionStore.delete(reference: claim.0, on: tx)
                    throw permissionRequired()
                }
                let evidence: AdAttributionStore.Evidence
                if case .attributed(let fields) = result.outcome {
                    evidence = ApplePurchaseOriginService.evidence(for: fields, app: app)
                } else { evidence = .unknown }
                let settledAt = Date()
                guard try await AdAttributionStore.record(result.outcome, attempts: result.attempts,
                                                          reference: claim.0, evidence: evidence,
                                                          now: settledAt, on: tx) else {
                    throw Abort(.conflict, reason: "Apple measurement changed while processing", identifier: "ad_measurement_changed")
                }
                try await ApplePurchaseOriginService.reconcileAttribution(
                    reference: claim.0, app: app, now: settledAt, on: tx)
                return claim.0
            }
        case .notYetAvailable, .failing:
            _ = try? await AdAttributionStore.delete(reference: claim.0, on: db)
            throw Abort(.serviceUnavailable, reason: "Apple measurement is temporarily unavailable", identifier: "ad_measurement_unavailable")
        }
    }

    private struct Permission { let decision: MeasurementDecision; let subjectID: UUID?; let updatedAt: Date; let erasurePending: Bool }

    private static func requirePermission(accountID: UUID, purpose: MeasurementPurpose, revision: UUID,
                                          requireSubject: Bool, on sql: SQLDatabase) async throws -> Permission {
        guard let row = try await sql.raw("""
            SELECT c.decision,c.subject_id,c.updated_at,
                   EXISTS(SELECT 1 FROM measurement_erasure_jobs e JOIN measurement_subjects s ON s.id=e.subject_id
                          WHERE e.account_id=c.account_id AND s.purpose=c.purpose AND e.state<>'completed') AS erasure_pending
            FROM measurement_permission_current c
            WHERE c.account_id=\(bind:accountID) AND c.purpose=\(bind:purpose.rawValue) AND c.revision=\(bind:revision)
            """).first(), let decision = MeasurementDecision(rawValue: try row.decode(column: "decision", as: String.self)) else {
            throw Abort(.conflict, reason: "Measurement permission changed. Refresh before sending", identifier: "measurement_revision_conflict")
        }
        let subject = try row.decode(column: "subject_id", as: UUID?.self)
        if requireSubject && subject == nil { throw permissionRequired() }
        return .init(decision: decision, subjectID: subject, updatedAt: try row.decode(column: "updated_at", as: Date.self),
                     erasurePending: try row.decode(column: "erasure_pending", as: Bool.self))
    }

    private static func effectiveATT(accountID: UUID, installationID: UUID, revision: UUID,
                                     now: Date, on sql: SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM measurement_att_assertions WHERE account_id=\(bind:accountID)
              AND installation_id=\(bind:installationID) AND consent_revision=\(bind:revision)
              AND status='authorized' AND expires_at>\(bind:now)
            """).first() != nil
    }

    private static func flag(_ key: String, on db: Database) async -> Bool {
        guard let flags = try? await FeatureFlagService.resolve(on: db) else { return false }
        return flags[key] == true
    }

    private static func validateEvent(_ input: MeasurementProductEventUpload, now: Date) throws {
        guard input.event.schemaVersion == 1, input.occurredAt <= now.addingTimeInterval(futureSkew),
              input.occurredAt >= now.addingTimeInterval(-maximumEventAge) else { throw invalidEvent() }
        let p = input.event.properties
        let none: Set<String> = ["session_started", "onboarding_started", "onboarding_completed", "welcome_card_shown", "welcome_card_create_tapped",
                                 "first_project_created", "first_snag_created", "portal_introduction_shown",
                                 "portal_introduction_dismissed", "invitation_shown", "invitation_dismissed"]
        if none.contains(input.event.name) { guard p.isEmpty else { throw invalidEvent() }; return }
        if ["onboarding_screen_viewed", "onboarding_skipped"].contains(input.event.name) {
            guard Set(p.keys) == ["screen_index"], validIndex(p["screen_index"]) else { throw invalidEvent() }; return
        }
        if input.event.name == "onboarding_screen_duration" {
            guard Set(p.keys) == ["screen_index", "duration_seconds"], validIndex(p["screen_index"]),
                  let raw = p["duration_seconds"], let duration = Double(raw), duration.isFinite,
                  (0...86_400).contains(duration), String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), duration) == raw else { throw invalidEvent() }
            return
        }
        if input.event.name == "onboarding_swiped_back" {
            guard Set(p.keys) == ["from_screen", "to_screen"], validIndex(p["from_screen"]), validIndex(p["to_screen"]),
                  p["from_screen"] != p["to_screen"] else { throw invalidEvent() }; return
        }
        if input.event.name == "project_created" {
            guard Set(p.keys) == ["creation_source", "workspace_kind"], p["creation_source"] == "fresh",
                  ["device", "personal", "company"].contains(p["workspace_kind"] ?? "") else { throw invalidEvent() }
            return
        }
        if input.event.name == "snag_created" {
            guard Set(p.keys) == ["photo_count", "offline"],
                  ["0", "1", "2-5", "6+"].contains(p["photo_count"] ?? ""),
                  ["true", "false"].contains(p["offline"] ?? "") else { throw invalidEvent() }
            return
        }
        if ["contractor_link_create_started", "contractor_link_activated", "portal_open_requested"].contains(input.event.name) {
            guard p.isEmpty else { throw invalidEvent() }
            return
        }
        let purchase: Set<String> = ["limit_wall_shown", "paywall_viewed", "paywall_dismissed", "purchase_started",
                                     "purchase_cancelled", "purchase_pending", "purchase_verified", "restore_verified", "purchase_failed"]
        let contexts: Set<String> = ["onboarding", "settings", "contractorLinks", "projects", "copyToAccount", "snags", "snagsInForm", "photos", "reports"]
        guard purchase.contains(input.event.name), let context = p["context"], contexts.contains(context) else { throw invalidEvent() }
        if input.event.name == "purchase_failed" {
            guard Set(p.keys) == ["context", "reason"], ["unconfirmed", "error"].contains(p["reason"] ?? "") else { throw invalidEvent() }
        } else { guard Set(p.keys) == ["context"] else { throw invalidEvent() } }
    }

    private static func validIndex(_ value: String?) -> Bool { ["0", "1", "2"].contains(value ?? "") }
    private static func validDeviceID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,58,95].contains($0)
        }
    }
    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func eventHash(_ input: MeasurementProductEventUpload) -> String {
        let properties = input.event.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return SHA256Hasher.hash(token: "\(input.eventId.uuidString)|\(input.occurredAt.timeIntervalSince1970)|\(input.consentRevision.uuidString)|\(input.installationId.uuidString)|1|\(input.event.name)|\(properties)")
    }
    private static func invalidEvent() -> Abort { .init(.badRequest, reason: "Use a supported measurement event", identifier: "measurement_event_invalid") }
    private static func permissionRequired() -> Abort { .init(.forbidden, reason: "Current measurement permission is required", identifier: "measurement_permission_required") }
    private static func switchedOff() -> Abort { .init(.serviceUnavailable, reason: "Measurement is switched off", identifier: "measurement_off") }
}
