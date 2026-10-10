import Vapor
import Fluent
import FluentSQL

/// What a withdrawal or an account deletion does about LinkedIn conversions that were already sent
/// (outputs/measurement-2026-10-07/LINKEDIN-ERASURE-RESOLUTION.md).
///
/// LinkedIn's Conversions API documents only `POST /rest/conversionEvents`. It has no endpoint that
/// deletes or retracts a conversion event once it has been sent. A LinkedIn erasure job therefore never
/// calls LinkedIn and is never `completed`. It ends in `provider_retention_bound` once, under the purpose
/// lock that dispatch, withdrawal and account deletion take:
/// - the subject is revoked, so nothing more is sent for it (dispatch refuses a revoked subject);
/// - no LinkedIn outbox row of the subject is still open or still holds a payload (our copy of the hashed
///   email and, for a payment, the amount). A row that does is suppressed and scrubbed here, exactly as the
///   revocation barrier does;
/// and it records the latest time a send could have reached LinkedIn, the retention basis relied on, and
/// the date LinkedIn's copy is due to age out under that basis. That date is an expected age-out under
/// LinkedIn's own published terms. It is not a deletion we performed or one LinkedIn confirmed.
enum LinkedInErasureResolution {
    /// The reviewed resolution. Production LinkedIn dispatch needs exactly this value in
    /// `LINKEDIN_ERASURE_RESOLUTION_ACCEPTED`. A changed resolution gets a new version and a new acceptance.
    static let version = "linkedin-erasure-2026-10-10"
    static let acceptanceVariable = "LINKEDIN_ERASURE_RESOLUTION_ACCEPTED"
    /// The terminal state. Deliberately not `completed`: nothing was deleted at LinkedIn.
    static let terminalState = "provider_retention_bound"
    /// Erasure-job states after which no erasure work remains for us. Account-level "erasure pending"
    /// checks (regrant, the permissions envelope, the deletion barrier, receipt cleanup) use this list.
    static let settledStates = "('completed','provider_retention_bound')"
    /// The deletion period for conversion data that LinkedIn's privacy FAQ was recorded as stating on
    /// 7 October 2026 (LINKEDIN-INTEGRATION.md). It could not be re-read on 10 October 2026 (LinkedIn's
    /// help and legal pages refuse automated fetches), so Dan confirms it on LinkedIn's page as part of
    /// accepting this resolution. A different stated period means a new `version`.
    static let providerRetention: TimeInterval = 180 * 86_400

    /// The release gate. Production LinkedIn dispatch stays off until this resolution has been accepted
    /// by its exact version. Other environments (staging synthetic test rules) are not gated here.
    static func productionDispatchPermitted(platformEnvironment: String?, accepted: String?) -> Bool {
        platformEnvironment != "production" || accepted == version
    }

    static func productionDispatchPermitted(environment: LinkedInConversion.Environment?, accepted: String?) -> Bool {
        environment != .production || accepted == version
    }

    struct Bound: Sendable, Equatable {
        /// The latest time a send for this subject could have reached LinkedIn.
        let lastSendBy: Date
        /// `lastSendBy` plus `providerRetention`.
        let expiresAt: Date
    }

    /// The LinkedIn erasure step for one leased job. No provider call. Returns nil when the lease is no
    /// longer this one's, or the subject is not revoked (nothing is recorded then).
    static func settle(jobID: UUID, leaseToken: UUID, accountID: UUID, subjectID: UUID,
                       on db: Database) async throws -> Bound? {
        try await db.transaction { tx in
            let sql = try VerifiedIdentityService.sql(tx)
            try await VerifiedIdentityService.lock(
                "measurement-permission:\(accountID.uuidString):\(MeasurementPurpose.crossCompanyAds.rawValue)", on: tx)
            guard let job = try await sql.raw("""
                SELECT j.created_at,s.state AS subject_state,s.revoked_at,s.send_in_flight_until
                FROM measurement_erasure_jobs j JOIN measurement_subjects s ON s.id=j.subject_id
                WHERE j.id=\(bind:jobID) AND j.lease_token=\(bind:leaseToken) AND j.state='leased'
                  AND j.destination='linkedin' AND j.account_id=\(bind:accountID) AND j.subject_id=\(bind:subjectID)
                """).first(),
                  try job.decode(column: "subject_state", as: String.self) == "revoked" else { return nil }
            // Our copies: the same transition as the revocation barrier, for anything still open or
            // still holding a payload. A leased row's lease end stays as its send window.
            try await sql.raw("""
                UPDATE measurement_dispatch_jobs SET
                    state=CASE WHEN state='pending' THEN 'suppressed'
                               WHEN state IN ('leased','failing') THEN 'uncertain' ELSE state END,
                    send_window_until=CASE WHEN state='leased'
                        THEN GREATEST(COALESCE(send_window_until,lease_expires_at),lease_expires_at)
                        ELSE send_window_until END,
                    payload=NULL,lease_token=NULL,lease_expires_at=NULL
                WHERE subject_id=\(bind:subjectID) AND destination='linkedin'
                  AND (state IN ('pending','leased','failing') OR payload IS NOT NULL)
                """).run()
            let outbox = try await sql.raw("""
                SELECT GREATEST(MAX(send_window_until),MAX(delivered_at)) AS latest
                FROM measurement_dispatch_jobs WHERE subject_id=\(bind:subjectID) AND destination='linkedin'
                """).first()
            // Account deletion removes the outbox rows; the subject keeps the in-flight bound the
            // barrier recorded, and the revocation and job times bound everything sent before them.
            let candidates: [Date?] = [try job.decode(column: "created_at", as: Date.self),
                                       try job.decode(column: "revoked_at", as: Date?.self),
                                       try job.decode(column: "send_in_flight_until", as: Date?.self),
                                       try outbox?.decode(column: "latest", as: Date?.self)]
            guard let lastSendBy = candidates.compactMap({ $0 }).max() else { return nil }
            return Bound(lastSendBy: lastSendBy, expiresAt: lastSendBy.addingTimeInterval(providerRetention))
        }
    }
}
