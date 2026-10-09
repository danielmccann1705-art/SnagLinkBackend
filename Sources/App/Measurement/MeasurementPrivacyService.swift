import Vapor
import Fluent
import FluentSQL

enum MeasurementPurpose: String, Codable, CaseIterable, Sendable {
    case productAnalytics, appleAds, crossCompanyAds
}

enum MeasurementDecision: String, Codable, Sendable {
    case granted, denied, withdrawn
}

enum MeasurementATTStatus: String, Codable, Sendable {
    case authorized, denied, restricted, notDetermined
}

struct MeasurementPermissionUpdate: Content, Sendable, Equatable {
    let requestId: UUID
    let expectedRevision: UUID?
    let decision: MeasurementDecision
    let occurredAt: Date
    let installationId: UUID?
    let attStatus: MeasurementATTStatus?
    let attAssertedAt: Date?

    private struct Key: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let allowed: Set<String> = ["requestId", "expectedRevision", "decision", "occurredAt",
                                    "installationId", "attStatus", "attAssertedAt"]
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown measurement permission field"))
        }
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        requestId = try values.decode(UUID.self, forKey: key("requestId"))
        expectedRevision = try values.decodeIfPresent(UUID.self, forKey: key("expectedRevision"))
        decision = try values.decode(MeasurementDecision.self, forKey: key("decision"))
        occurredAt = try values.decode(Date.self, forKey: key("occurredAt"))
        installationId = try values.decodeIfPresent(UUID.self, forKey: key("installationId"))
        attStatus = try values.decodeIfPresent(MeasurementATTStatus.self, forKey: key("attStatus"))
        attAssertedAt = try values.decodeIfPresent(Date.self, forKey: key("attAssertedAt"))
    }
}

struct MeasurementPermissionResponse: Content, Sendable {
    let purpose: MeasurementPurpose
    let revision: UUID?
    let decision: String
    let effective: Bool
    let subjectId: UUID?
    let updatedAt: Date?
    let attStatus: MeasurementATTStatus?
    let attAssertedAt: Date?
    let attExpiresAt: Date?
    let erasurePending: Bool
}

struct MeasurementPermissionsEnvelope: Content, Sendable {
    let permissions: [MeasurementPermissionResponse]
}

enum MeasurementPrivacyService {
    static let clientClaimMaximumAge: TimeInterval = 86_400
    static let clientAuditMaximumAge: TimeInterval = 10 * 365 * 86_400
    static let clientFutureSkew: TimeInterval = 300
    static let attClaimMaximumAge: TimeInterval = 900
    static let attLifetime: TimeInterval = 86_400

    static func read(accountID: UUID, installationID: UUID?, now: Date = Date(), on db: Database) async throws -> MeasurementPermissionsEnvelope {
        _ = try await VerifiedIdentityService.activeUser(accountID, on: db)
        return try await readSnapshot(accountID: accountID, installationID: installationID, now: now, on: db)
    }

    static func update(accountID: UUID, purpose: MeasurementPurpose, input: MeasurementPermissionUpdate,
                       now: Date = Date(), on db: Database) async throws -> MeasurementPermissionsEnvelope {
        return try await db.transaction { transaction in
            try await lockActiveAccount(accountID, on: transaction)
            try await VerifiedIdentityService.lock("measurement-permission:\(accountID.uuidString):\(purpose.rawValue)", on: transaction)
            let sql = try VerifiedIdentityService.sql(transaction)

            if let replay = try await sql.raw("""
                SELECT purpose,expected_revision,decision,occurred_at,installation_id,att_status,att_asserted_at
                FROM measurement_consent_events WHERE account_id=\(bind:accountID) AND request_id=\(bind:input.requestId)
                """).first() {
                guard try identical(input, purpose: purpose, row: replay) else {
                    throw Abort(.conflict, reason: "This measurement request ID was already used", identifier: "measurement_request_conflict")
                }
                return try await readSnapshot(accountID: accountID, installationID: input.installationId, now: now, on: transaction)
            }

            try validate(input, purpose: purpose, now: now)

            let current = try await sql.raw("""
                SELECT revision,subject_id FROM measurement_permission_current
                WHERE account_id=\(bind:accountID) AND purpose=\(bind:purpose.rawValue) FOR UPDATE
                """).first()
            let currentRevision = try current?.decode(column: "revision", as: UUID.self)
            guard currentRevision == input.expectedRevision else {
                throw Abort(.conflict, reason: "Measurement permission changed. Refresh before saving", identifier: "measurement_revision_conflict")
            }

            _ = try await recordDecisionInTransaction(
                accountID: accountID, purpose: purpose, requestID: input.requestId,
                expectedRevision: input.expectedRevision,
                currentSubjectID: try current?.decode(column: "subject_id", as: UUID?.self),
                decision: input.decision, occurredAt: input.occurredAt,
                installationID: input.installationId, attStatus: input.attStatus,
                attAssertedAt: input.attAssertedAt, now: now, on: transaction)
            return try await readSnapshot(accountID: accountID, installationID: input.installationId, now: now, on: transaction)
        }
    }

    /// Transaction-internal consent write shared by the settings route and new-account
    /// signup adoption. The caller owns the transaction, the active account row and this
    /// purpose's barrier, has already validated the input and has read the current row
    /// `FOR UPDATE`. It never opens a transaction of its own.
    @discardableResult
    static func recordDecisionInTransaction(accountID: UUID, purpose: MeasurementPurpose, requestID: UUID,
                                            expectedRevision: UUID?, currentSubjectID: UUID?,
                                            decision: MeasurementDecision, occurredAt: Date,
                                            installationID: UUID?, attStatus: MeasurementATTStatus?,
                                            attAssertedAt: Date?, now: Date,
                                            on transaction: Database) async throws -> (revision: UUID, subjectID: UUID?) {
        let sql = try VerifiedIdentityService.sql(transaction)
        let revision = UUID()
        let attExpiry = attAssertedAt == nil ? nil : now.addingTimeInterval(attLifetime)
        try await sql.raw("""
            INSERT INTO measurement_consent_events
                (id,request_id,account_id,purpose,expected_revision,decision,occurred_at,received_at,
                 installation_id,att_status,att_asserted_at,att_expires_at)
            VALUES (\(bind:revision),\(bind:requestID),\(bind:accountID),\(bind:purpose.rawValue),
                    \(bind:expectedRevision),\(bind:decision.rawValue),\(bind:occurredAt),\(bind:now),
                    \(bind:installationID),\(bind:attStatus?.rawValue),\(bind:attAssertedAt),\(bind:attExpiry))
            """).run()

        var subjectID = currentSubjectID
        if decision == .granted {
            let mayCreate = purpose == .productAnalytics || (purpose == .crossCompanyAds && attStatus == .authorized)
            if mayCreate && subjectID == nil {
                let erasurePending = try await sql.raw("""
                    SELECT 1 FROM measurement_erasure_jobs e JOIN measurement_subjects s ON s.id=e.subject_id
                    WHERE e.account_id=\(bind:accountID) AND s.purpose=\(bind:purpose.rawValue) AND e.state<>'completed' LIMIT 1
                    """).first() != nil
                if !erasurePending {
                    subjectID = try await createSubject(accountID: accountID, purpose: purpose, now: now, on: sql)
                }
            }
        } else {
            let revoked = try await revokeSubjects(accountID: accountID, purpose: purpose, accountDeletionJobID: nil, now: now, on: sql)
            if purpose == .crossCompanyAds {
                try await sql.raw("DELETE FROM measurement_att_assertions WHERE account_id=\(bind:accountID)").run()
            }
            if purpose == .appleAds {
                try await ApplePurchaseOriginService.revoke(accountID: accountID, now: now, on: sql)
                _ = try await AdAttributionStore.eraseAccount(accountID, on: transaction)
            }
            if revoked { subjectID = nil }
        }

        if purpose == .crossCompanyAds, decision == .granted,
           let installationID, let status = attStatus,
           let assertedAt = attAssertedAt, let attExpiry {
            let continuityStartedAt: Date? = status == .authorized ? now : nil
            let continuityID: UUID? = status == .authorized ? UUID() : nil
            try await sql.raw("""
                INSERT INTO measurement_att_assertions
                    (account_id,installation_id,purpose,consent_revision,status,asserted_at,received_at,expires_at,
                     continuity_started_at,continuity_id)
                VALUES (\(bind:accountID),\(bind:installationID),'crossCompanyAds',\(bind:revision),\(bind:status.rawValue),
                        \(bind:assertedAt),\(bind:now),\(bind:attExpiry),
                        \(bind:continuityStartedAt),\(bind:continuityID))
                ON CONFLICT (account_id,installation_id) DO UPDATE SET
                    consent_revision=EXCLUDED.consent_revision,status=EXCLUDED.status,asserted_at=EXCLUDED.asserted_at,
                    received_at=EXCLUDED.received_at,expires_at=EXCLUDED.expires_at,
                    continuity_started_at=EXCLUDED.continuity_started_at,
                    continuity_id=EXCLUDED.continuity_id
                """).run()
        }

        try await sql.raw("""
            INSERT INTO measurement_permission_current(account_id,purpose,revision,decision,subject_id,updated_at)
            VALUES (\(bind:accountID),\(bind:purpose.rawValue),\(bind:revision),\(bind:decision.rawValue),\(bind:subjectID),\(bind:now))
            ON CONFLICT (account_id,purpose) DO UPDATE SET revision=EXCLUDED.revision,decision=EXCLUDED.decision,
                subject_id=EXCLUDED.subject_id,updated_at=EXCLUDED.updated_at
            """).run()
        return (revision, subjectID)
    }

    /// Called inside account deletion's transaction, before verified identities disappear.
    /// Provider failure cannot fail this step: only durable local revocation and queued work occur here.
    static func eraseAccount(_ accountID: UUID, accountDeletionJobID: UUID, now: Date, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        // The caller already owns the user row. Take purpose barriers in this
        // fixed order before exposure capture or outbox removal, matching dispatch
        // and permission mutation without holding the user row in provider I/O.
        for purpose in [MeasurementPurpose.productAnalytics, .crossCompanyAds, .appleAds] {
            try await VerifiedIdentityService.lock(
                "measurement-permission:\(accountID.uuidString):\(purpose.rawValue)", on: db)
        }
        var queued = false
        for purpose in [MeasurementPurpose.productAnalytics, .crossCompanyAds] {
            queued = try await revokeSubjects(accountID: accountID, purpose: purpose,
                                               accountDeletionJobID: accountDeletionJobID, now: now, on: sql) || queued
        }
        try await sql.raw("""
            UPDATE measurement_erasure_jobs SET account_deletion_job_id=\(bind:accountDeletionJobID)
            WHERE account_id=\(bind:accountID) AND state<>'completed' AND account_deletion_job_id IS NULL
            """).run()
        queued = try await sql.raw("""
            SELECT 1 FROM measurement_erasure_jobs WHERE account_id=\(bind:accountID) AND state<>'completed' LIMIT 1
            """).first() != nil
        try await sql.raw("DELETE FROM measurement_att_assertions WHERE account_id=\(bind:accountID)").run()
        try await ApplePurchaseOriginService.revoke(accountID: accountID, now: now, on: sql)
        try await PurchaseOriginService.eraseAccount(accountID, now: now, on: sql)
        let permissions = try await sql.raw("SELECT purpose,revision FROM measurement_permission_current WHERE account_id=\(bind:accountID) FOR UPDATE").all()
        for row in permissions {
            let purpose = try row.decode(column: "purpose", as: String.self)
            let expected = try row.decode(column: "revision", as: UUID.self)
            let revision = UUID()
            try await sql.raw("""
                INSERT INTO measurement_consent_events
                    (id,request_id,account_id,purpose,expected_revision,decision,occurred_at,received_at)
                VALUES (\(bind:revision),\(bind:UUID()),\(bind:accountID),\(bind:purpose),\(bind:expected),'withdrawn',\(bind:now),\(bind:now))
                """).run()
            try await sql.raw("""
                UPDATE measurement_permission_current SET revision=\(bind:revision),decision='withdrawn',subject_id=NULL,updated_at=\(bind:now)
                WHERE account_id=\(bind:accountID) AND purpose=\(bind:purpose)
                """).run()
        }
        // Keep only provider/charge hashes needed to reject duplicate money after
        // deletion. Remove the account join; these tombstones are not entitlement
        // state and can never restore a measurement subject.
        // Erasure exposure was captured above, so the delivery ledger no longer
        // needs to retain an account/source join back to economic facts.
        try await sql.raw("DELETE FROM measurement_dispatch_jobs WHERE account_id=\(bind:accountID)").run()
        // Pre-auth signup intents and the canonical signup fact keep only their
        // deduplication tombstones; their account, installation and revision joins go.
        try await SignupIntentService.eraseAccount(accountID, now: now, on: sql)
        try await sql.raw("UPDATE measurement_revenuecat_lifecycle_events SET account_id=NULL WHERE account_id=\(bind:accountID)").run()
        try await sql.raw("UPDATE measurement_revenuecat_adjustments SET account_id=NULL WHERE account_id=\(bind:accountID)").run()
        try await sql.raw("UPDATE measurement_revenuecat_events SET account_id=NULL WHERE account_id=\(bind:accountID)").run()
        if queued {
            try await sql.raw("UPDATE account_deletion_jobs SET measurement_erasure_state='pending' WHERE id=\(bind:accountDeletionJobID)").run()
        }
    }

    private static func validate(_ input: MeasurementPermissionUpdate, purpose: MeasurementPurpose, now: Date) throws {
        let maximumAge = input.decision == .granted ? clientClaimMaximumAge : clientAuditMaximumAge
        guard input.occurredAt <= now.addingTimeInterval(clientFutureSkew),
              input.occurredAt >= now.addingTimeInterval(-maximumAge) else {
            throw Abort(.badRequest, reason: "Measurement permission time is invalid", identifier: "measurement_time_invalid")
        }
        let hasAnyATT = input.installationId != nil || input.attStatus != nil || input.attAssertedAt != nil
        if purpose == .crossCompanyAds && input.decision == .granted {
            guard input.installationId != nil, input.attStatus != nil, let asserted = input.attAssertedAt,
                  asserted <= now.addingTimeInterval(clientFutureSkew),
                  asserted >= now.addingTimeInterval(-attClaimMaximumAge) else {
                throw Abort(.badRequest, reason: "A current installation ATT assertion is required", identifier: "measurement_att_invalid")
            }
        } else if hasAnyATT {
            throw Abort(.badRequest, reason: "ATT fields do not apply to this decision", identifier: "measurement_att_unexpected")
        }
    }

    private static func identical(_ input: MeasurementPermissionUpdate, purpose: MeasurementPurpose, row: SQLRow) throws -> Bool {
        func same(_ a: Date?, _ b: Date?) -> Bool {
            switch (a, b) { case let (.some(x), .some(y)): return abs(x.timeIntervalSince(y)) < 0.001; case (nil, nil): return true; default: return false }
        }
        return try row.decode(column: "purpose", as: String.self) == purpose.rawValue &&
            row.decode(column: "expected_revision", as: UUID?.self) == input.expectedRevision &&
            row.decode(column: "decision", as: String.self) == input.decision.rawValue &&
            same(row.decode(column: "occurred_at", as: Date.self), input.occurredAt) &&
            row.decode(column: "installation_id", as: UUID?.self) == input.installationId &&
            row.decode(column: "att_status", as: String?.self) == input.attStatus?.rawValue &&
            same(row.decode(column: "att_asserted_at", as: Date?.self), input.attAssertedAt)
    }

    static func createSubject(accountID: UUID, purpose: MeasurementPurpose, now: Date, on sql: SQLDatabase) async throws -> UUID {
        let id = UUID(), opaque = UUID()
        try await sql.raw("""
            INSERT INTO measurement_subjects(id,account_id,purpose,opaque_subject,state,created_at)
            VALUES (\(bind:id),\(bind:accountID),\(bind:purpose.rawValue),\(bind:opaque),'active',\(bind:now))
            """).run()
        return id
    }

    @discardableResult
    private static func revokeSubjects(accountID: UUID, purpose: MeasurementPurpose, accountDeletionJobID: UUID?,
                                       now: Date, on sql: SQLDatabase) async throws -> Bool {
        let subjects = try await sql.raw("""
            UPDATE measurement_subjects SET state='revoked',revoked_at=\(bind:now)
            WHERE account_id=\(bind:accountID) AND purpose=\(bind:purpose.rawValue) AND state='active'
            RETURNING id
            """).all()
        let subjectIDs = try subjects.map { try $0.decode(column: "id", as: UUID.self) }
        if purpose == .crossCompanyAds {
            try await PurchaseOriginService.revoke(subjectIDs: subjectIDs, now: now, on: sql)
        }
        if purpose == .productAnalytics {
            try await ProductPurchaseOriginService.revoke(subjectIDs: subjectIDs, on: sql)
        }
        let destinations: [String]
        switch purpose {
        case .productAnalytics: destinations = ["posthog"]
        case .crossCompanyAds: destinations = ["singular", "linkedin"]
        case .appleAds: destinations = []
        }
        if purpose == .productAnalytics {
            // A leased row keeps its lease end: a send under it may still be in flight.
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET
                    state=CASE WHEN state='pending' THEN 'suppressed'
                               WHEN state IN ('leased','failing') THEN 'uncertain' ELSE state END,
                    send_window_until=CASE WHEN state='leased'
                        THEN GREATEST(COALESCE(send_window_until,lease_expires_at),lease_expires_at)
                        ELSE send_window_until END,
                    payload=NULL,lease_token=NULL,lease_expires_at=NULL
                WHERE account_id=\(bind:accountID) AND destination='posthog' AND state<>'delivered'
                """).run()
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET payload=NULL
                WHERE account_id=\(bind:accountID) AND destination='posthog' AND state='delivered'
                """).run()
            try await sql.raw("""
                UPDATE measurement_product_events SET event_name=NULL,properties=NULL,revoked_at=\(bind:now)
                WHERE account_id=\(bind:accountID) AND revoked_at IS NULL
                """).run()
        } else if purpose == .crossCompanyAds {
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET
                    state=CASE WHEN state='pending' THEN 'suppressed'
                               WHEN state IN ('leased','failing') THEN 'uncertain' ELSE state END,
                    send_window_until=CASE WHEN state='leased'
                        THEN GREATEST(COALESCE(send_window_until,lease_expires_at),lease_expires_at)
                        ELSE send_window_until END,
                    payload=NULL,lease_token=NULL,lease_expires_at=NULL
                WHERE account_id=\(bind:accountID) AND destination IN ('singular','linkedin') AND state<>'delivered'
                """).run()
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET payload=NULL
                WHERE account_id=\(bind:accountID) AND destination IN ('singular','linkedin') AND state='delivered'
                """).run()
        }
        for subjectID in subjectIDs {
            // Per-subject in-flight record at the barrier: the last send attempt and
            // the latest lease end under which a send could still be in flight.
            // Account deletion removes the outbox rows right after this.
            try await sql.raw("""
                UPDATE measurement_subjects s SET
                    last_send_started_at=(SELECT MAX(d.last_send_started_at) FROM measurement_dispatch_jobs d
                        WHERE d.subject_id=s.id),
                    send_in_flight_until=(SELECT MAX(COALESCE(d.send_window_until,d.delivered_at))
                        FROM measurement_dispatch_jobs d WHERE d.subject_id=s.id)
                WHERE s.id=\(bind:subjectID)
                """).run()
            if purpose == .crossCompanyAds {
                try await sql.raw("UPDATE measurement_device_bindings SET revoked_at=\(bind:now) WHERE subject_id=\(bind:subjectID) AND revoked_at IS NULL").run()
            }
            for destination in destinations {
                let exposed: Bool
                if destination == "singular" {
                    exposed = try await sql.raw("SELECT 1 FROM measurement_device_bindings WHERE subject_id=\(bind:subjectID) LIMIT 1").first() != nil
                } else {
                    exposed = try await sql.raw("""
                        SELECT 1 FROM measurement_dispatch_jobs WHERE subject_id=\(bind:subjectID)
                          AND destination=\(bind:destination) AND state IN ('delivered','uncertain','manual_required') LIMIT 1
                        """).first() != nil
                }
                let state = exposed ? "pending" : "completed"
                let completedAt: Date? = exposed ? nil : now
                try await sql.raw("""
                    INSERT INTO measurement_erasure_jobs
                        (id,account_id,subject_id,destination,account_deletion_job_id,state,available_at,created_at,completed_at)
                    VALUES (\(bind:UUID()),\(bind:accountID),\(bind:subjectID),\(bind:destination),
                            \(bind:accountDeletionJobID),\(bind:state),\(bind:now),\(bind:now),\(bind:completedAt))
                    ON CONFLICT (subject_id,destination) DO UPDATE SET
                        account_deletion_job_id=COALESCE(measurement_erasure_jobs.account_deletion_job_id,EXCLUDED.account_deletion_job_id)
                    """).run()
            }
        }
        return !subjects.isEmpty
    }

    static func readSnapshot(accountID: UUID, installationID: UUID?, now: Date, on db: Database) async throws -> MeasurementPermissionsEnvelope {
        let sql = try VerifiedIdentityService.sql(db)
        let rows = try await sql.raw("""
            SELECT c.purpose,c.revision,c.decision,c.updated_at,s.opaque_subject,
                   EXISTS(SELECT 1 FROM measurement_erasure_jobs e JOIN measurement_subjects es ON es.id=e.subject_id
                          WHERE e.account_id=c.account_id AND es.purpose=c.purpose AND e.state<>'completed') AS erasure_pending
            FROM measurement_permission_current c
            LEFT JOIN measurement_subjects s ON s.id=c.subject_id AND s.state='active'
            WHERE c.account_id=\(bind:accountID)
            """).all()
        var current: [String: SQLRow] = [:]
        for row in rows { current[try row.decode(column: "purpose", as: String.self)] = row }

        var assertion: SQLRow?
        if let installationID {
            assertion = try await sql.raw("""
                SELECT consent_revision,status,asserted_at,expires_at FROM measurement_att_assertions
                WHERE account_id=\(bind:accountID) AND installation_id=\(bind:installationID)
                """).first()
        }

        let permissions = try MeasurementPurpose.allCases.map { purpose -> MeasurementPermissionResponse in
            guard let row = current[purpose.rawValue] else {
                return .init(purpose: purpose, revision: nil, decision: "undecided", effective: false, subjectId: nil,
                             updatedAt: nil, attStatus: nil, attAssertedAt: nil, attExpiresAt: nil, erasurePending: false)
            }
            let revision = try row.decode(column: "revision", as: UUID.self)
            let decision = try row.decode(column: "decision", as: String.self)
            let erasure = try row.decode(column: "erasure_pending", as: Bool.self)
            var status: MeasurementATTStatus?, asserted: Date?, expires: Date?
            var attEffective = purpose != .crossCompanyAds
            if purpose == .crossCompanyAds, let assertion,
               try assertion.decode(column: "consent_revision", as: UUID.self) == revision {
                status = try MeasurementATTStatus(rawValue: assertion.decode(column: "status", as: String.self))
                asserted = try assertion.decode(column: "asserted_at", as: Date.self)
                expires = try assertion.decode(column: "expires_at", as: Date.self)
                attEffective = status == .authorized && expires! > now
            }
            let opaque = try row.decode(column: "opaque_subject", as: UUID?.self)
            let hasRequiredSubject = purpose == .appleAds || opaque != nil
            let effective = decision == MeasurementDecision.granted.rawValue && attEffective && !erasure && hasRequiredSubject
            return .init(purpose: purpose, revision: revision, decision: decision, effective: effective,
                         subjectId: purpose == .crossCompanyAds && effective ? opaque : nil,
                         updatedAt: try row.decode(column: "updated_at", as: Date.self),
                         attStatus: status, attAssertedAt: asserted, attExpiresAt: expires, erasurePending: erasure)
        }
        return .init(permissions: permissions)
    }

    /// Mutation lock order shared with account deletion: user row, then purpose.
    /// Holding the row makes it impossible to admit new measurement data after the
    /// deletion transaction has started or after it has committed redaction.
    static func lockActiveAccount(_ accountID: UUID, on db: Database) async throws {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT lifecycle_state FROM users WHERE id=\(bind:accountID) FOR UPDATE
            """).first(), try row.decode(column: "lifecycle_state", as: String.self) == "active" else {
            throw Abort(.unauthorized, reason: "Account is no longer available")
        }
    }
}
