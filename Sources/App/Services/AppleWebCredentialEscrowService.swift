import Vapor
import Fluent
import FluentSQL
import Crypto

struct AppleWebEscrowDependencies: Sendable {
    let revoke: @Sendable (String, String) async -> AppleTokenService.RevocationOutcome
}
struct AppleWebEscrowDependenciesKey: StorageKey { typealias Value = AppleWebEscrowDependencies }

enum AppleWebCredentialEscrowService {
    struct Held: Sendable { let challengeID: UUID; let token: UUID; let clientID: String }
    struct Counts: Content, Sendable { var processed = 0; var revoked = 0; var blocked = 0; var retrying = 0 }

    /// Persist immediately after the confidential exchange, before JWT lookup or
    /// account resolution can fail. No verified subject/account is assumed here.
    static func hold(refreshToken: String, context: AppleWebChallengeService.Context, clientID: String, app: Application, on db: Database) async throws -> Held {
        let held = Held(challengeID: context.id, token: UUID(), clientID: clientID)
        let ciphertext = try seal(refreshToken, id: context.id, clientID: clientID, app: app)
        let deadline = min(Date().addingTimeInterval(300), context.createdAt.addingTimeInterval(AppleWebChallengeService.lifetime))
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO apple_web_credential_escrow(challenge_id,client_id,credential_ciphertext,state,lease_token,available_at,created_at)
            VALUES(\(bind: context.id),\(bind: clientID),\(bind: ciphertext),'held',\(bind: held.token),\(bind: deadline),NOW())
            """).run()
        return held
    }
    /// Caller owns the same real transaction as identity, verified-email and
    /// browser-session creation. A failed session rolls adoption back as well.
    static func adopt(_ held: Held, userID: UUID, app: Application, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        _ = try await sql.raw("SELECT challenge_id FROM apple_web_credential_escrow WHERE challenge_id=\(bind: held.challengeID) FOR UPDATE").first()
        guard let row = try await sql.raw("SELECT credential_ciphertext FROM apple_web_credential_escrow WHERE challenge_id=\(bind: held.challengeID) AND client_id=\(bind: held.clientID) AND state='held' AND lease_token=\(bind: held.token) AND available_at>clock_timestamp()").first() else {
            throw AppleWebChallengeService.expired()
        }
        let ciphertext = try row.decode(column: "credential_ciphertext", as: String.self)
        let refresh = try open(ciphertext, id: held.challengeID, clientID: held.clientID, app: app)
        try await AppleCredentialService.store(refreshToken: refresh, userID: userID, clientID: held.clientID, app: app, on: db)
        try await sql.raw("UPDATE apple_web_credential_escrow SET state='adopted',credential_ciphertext=NULL,lease_token=NULL,completed_at=NOW() WHERE challenge_id=\(bind: held.challengeID)").run()
    }
    static func abandon(_ held: Held, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("""
            UPDATE apple_web_credential_escrow SET state='ready',lease_token=NULL,available_at=NOW(),error_kind='signin_not_completed'
            WHERE challenge_id=\(bind: held.challengeID) AND state='held' AND lease_token=\(bind: held.token)
            """).run()
    }
    /// Uses only atomic single-row claims/fenced writes, so the maintenance
    /// autocommit connection is safe and does not open a nested pool connection.
    static func run(app: Application, on db: Database, limit: Int = 8) async throws -> Counts {
        let sql = try VerifiedIdentityService.sql(db)
        var counts = Counts()
        for _ in 0..<max(0,min(limit,32)) {
            let lease = UUID()
            guard let row = try await sql.raw("""
                UPDATE apple_web_credential_escrow SET state='leased',lease_token=\(bind: lease),lease_expires_at=NOW()+INTERVAL '5 minutes',attempts=attempts+1
                WHERE challenge_id IN (SELECT challenge_id FROM apple_web_credential_escrow
                    WHERE (state IN ('held','ready','blocked') AND available_at<=NOW()) OR (state='leased' AND lease_expires_at<=NOW())
                    ORDER BY available_at,challenge_id FOR UPDATE SKIP LOCKED LIMIT 1)
                RETURNING challenge_id,client_id,credential_ciphertext
                """).first() else { break }
            counts.processed += 1
            let id = try row.decode(column: "challenge_id", as: UUID.self)
            let clientID = try row.decode(column: "client_id", as: String.self)
            let outcome: AppleTokenService.RevocationOutcome
            do {
                let refresh = try open(row.decode(column: "credential_ciphertext", as: String.self), id: id, clientID: clientID, app: app)
                if app.environment == .testing, let dependencies = app.storage[AppleWebEscrowDependenciesKey.self] {
                    outcome = await dependencies.revoke(refresh, clientID)
                } else if let base = AppleTokenExchange.load() {
                    let configuration = AppleTokenExchange(teamID: base.teamID, keyID: base.keyID, privateKeyPEM: base.privateKeyPEM, clientID: clientID)
                    outcome = await AppleTokenService.revoke(refreshToken: refresh, clientID: clientID, exchange: configuration, on: app.client, logger: app.logger)
                } else { outcome = .misconfigured }
            } catch { outcome = .misconfigured }
            let succeeded = outcome == .revoked || outcome == .alreadyRevoked
            let next = succeeded ? "revoked" : (outcome == .misconfigured ? "blocked" : "ready")
            let changed = try await sql.raw("""
                UPDATE apple_web_credential_escrow SET state=\(bind: next),lease_token=NULL,lease_expires_at=NULL,
                    credential_ciphertext=CASE WHEN \(bind: succeeded) THEN NULL ELSE credential_ciphertext END,
                    completed_at=CASE WHEN \(bind: succeeded) THEN NOW() ELSE NULL END,
                    available_at=NOW()+INTERVAL '5 minutes',error_kind=\(bind: succeeded ? nil : outcome.rawValue)
                WHERE challenge_id=\(bind: id) AND state='leased' AND lease_token=\(bind: lease) AND lease_expires_at>clock_timestamp() RETURNING challenge_id
                """).first() != nil
            if changed && succeeded { counts.revoked += 1 }
            else if changed && next == "blocked" { counts.blocked += 1 }
            else { counts.retrying += 1 }
        }
        return counts
    }
    private static func associatedData(id: UUID, clientID: String) -> Data {
        Data(("snaglist-apple-web-escrow:" + id.uuidString.lowercased() + ":" + clientID).utf8)
    }
    private static func seal(_ token: String, id: UUID, clientID: String, app: Application) throws -> String {
        let sealed = try AES.GCM.seal(Data(token.utf8), using: AppleCredentialService.keys(app)[0], authenticating: associatedData(id: id, clientID: clientID))
        guard let combined = sealed.combined else { throw AppleWebIdentityService.exchangeUnavailable() }
        return combined.base64EncodedString()
    }
    private static func open(_ ciphertext: String, id: UUID, clientID: String, app: Application) throws -> String {
        guard let data = Data(base64Encoded: ciphertext), let box = try? AES.GCM.SealedBox(combined: data) else { throw AppleWebIdentityService.exchangeUnavailable() }
        for key in try AppleCredentialService.keys(app) {
            if let data = try? AES.GCM.open(box, using: key, authenticating: associatedData(id: id, clientID: clientID)), let token = String(data: data, encoding: .utf8) { return token }
        }
        throw AppleWebIdentityService.exchangeUnavailable()
    }
}
