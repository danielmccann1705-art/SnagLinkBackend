import Vapor
import Fluent
import FluentSQL

/// Each audience keeps independent progress. A parent's current, unexpired lease
/// fences every child write; a delayed provider reply cannot finish a new lease.
enum AccountDeletionAppleRevocationService {
    static func preserveLegacyWork(_ lease: AccountDeletionWorker.Lease, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO account_deletion_apple_credentials(id,job_id,client_id,credential_ciphertext,state)
            SELECT gen_random_uuid(),id,apple_client_id,apple_credential_ciphertext,
                CASE WHEN apple_credential_ciphertext IS NOT NULL AND apple_client_id IS NOT NULL
                     AND apple_revocation_state IN ('pending','misconfigured','failing') THEN apple_revocation_state
                     ELSE 'unavailable' END
            FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token)
                AND state='leased' AND lease_expires_at>NOW()
                AND (apple_credential_ciphertext IS NOT NULL OR
                    (apple_revocation_state IN ('pending','misconfigured','failing','unavailable')
                     AND NOT EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=\(bind: lease.id))))
            ON CONFLICT DO NOTHING
            """).run()
    }

    static func perform(_ lease: AccountDeletionWorker.Lease, app: Application, on db: Database,
                        transactionMode: AccountDeletionWorker.TransactionMode = .managed) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        try await preserveLegacyWork(lease, on: db)
        let children = try await sql.raw("""
            SELECT id,client_id,credential_ciphertext FROM account_deletion_apple_credentials
            WHERE job_id=\(bind: lease.id) AND state IN ('pending','failing','misconfigured')
            ORDER BY attempts,id LIMIT 16
            """).all()
        for child in children {
            guard try await AccountDeletionWorker.renew(lease, on: db) else { return }
            let childID = try child.decode(column: "id", as: UUID.self)
            let clientID = try child.decode(column: "client_id", as: String?.self)
            let ciphertext = try child.decode(column: "credential_ciphertext", as: String?.self)
            var outcome = "unavailable"
            if let clientID, let ciphertext {
                do {
                    if app.environment == .testing, let dependencies = app.storage[AccountDeletionWorkerDependenciesKey.self] {
                        outcome = try await dependencies.revokeApple(lease.userID, ciphertext, clientID).rawValue
                    } else if let configuration = AppleTokenExchange.load() {
                        let exchange = AppleTokenExchange(teamID: configuration.teamID, keyID: configuration.keyID,
                            privateKeyPEM: configuration.privateKeyPEM, clientID: clientID)
                        let token = try AppleCredentialService.open(ciphertext, userID: lease.userID, app: app)
                        outcome = await AppleTokenService.revoke(refreshToken: token, clientID: clientID, exchange: exchange,
                            on: app.client, logger: app.logger).rawValue
                    } else { outcome = "misconfigured" }
                } catch is AppleCredentialError { outcome = "misconfigured" }
                catch { outcome = "failing" }
            }
            let succeeded = ["revoked", "already_revoked"].contains(outcome)
            let recordedOutcome = outcome
            try await AccountDeletionWorker.writeIfCurrent(lease, on: db, transactionMode: transactionMode) { sql in
            try await sql.raw("""
                UPDATE account_deletion_apple_credentials SET state=\(bind: recordedOutcome),attempts=attempts+1,last_attempt_at=NOW(),
                    credential_ciphertext=CASE WHEN \(bind: succeeded) THEN NULL ELSE credential_ciphertext END,
                    completed_at=CASE WHEN \(bind: succeeded) THEN NOW() ELSE NULL END
                WHERE id=\(bind: childID) AND job_id=\(bind: lease.id)
                    AND EXISTS(SELECT 1 FROM account_deletion_jobs WHERE id=\(bind: lease.id)
                        AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW())
                """).run()
            }
        }
        try await refreshSummary(lease, on: db)
    }

    static func refreshSummary(_ lease: AccountDeletionWorker.Lease, on db: Database) async throws {
        try await preserveLegacyWork(lease, on: db)
        try await VerifiedIdentityService.sql(db).raw("""
            UPDATE account_deletion_jobs j SET
                apple_revocation_state=CASE
                    WHEN EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=j.id AND state='unavailable') THEN 'unavailable'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=j.id AND state='misconfigured') THEN 'misconfigured'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=j.id AND state='failing') THEN 'failing'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=j.id AND state='pending') THEN 'pending'
                    WHEN EXISTS(SELECT 1 FROM account_deletion_apple_credentials WHERE job_id=j.id) THEN 'revoked'
                    ELSE apple_revocation_state END,
                apple_credential_ciphertext=CASE WHEN NOT EXISTS(SELECT 1 FROM account_deletion_apple_credentials
                    WHERE job_id=j.id AND state NOT IN ('revoked','already_revoked')) THEN NULL ELSE apple_credential_ciphertext END,
                apple_client_id=CASE WHEN NOT EXISTS(SELECT 1 FROM account_deletion_apple_credentials
                    WHERE job_id=j.id AND state NOT IN ('revoked','already_revoked')) THEN NULL ELSE apple_client_id END
            WHERE id=\(bind: lease.id) AND lease_token=\(bind: lease.token) AND state='leased' AND lease_expires_at>NOW()
            """).run()
    }
}
