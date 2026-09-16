import Vapor
import Fluent
import FluentSQL
import Crypto

/// Stores the Apple refresh token encrypted at rest, sealed to the user it belongs to.
///
/// Same shape as `LinkGrantTokenService`: AES-GCM, the user's identifier as additional
/// authenticated data so a row cannot be moved between accounts, and a previous key
/// accepted during rotation.
enum AppleCredentialService {
    static func keys(_ app: Application) throws -> [SymmetricKey] {
        if app.environment == .testing, let bytes = app.storage[AppleCredentialKeyStorage.self], bytes.count == 32 {
            return [SymmetricKey(data: bytes)]
        }
        guard let raw = Environment.get("APPLE_CREDENTIAL_KEY"), let data = Data(base64Encoded: raw), data.count == 32 else {
            throw AppleCredentialError.misconfigured("Apple credential storage is not configured")
        }
        var keys = [SymmetricKey(data: data)]
        if let old = Environment.get("APPLE_CREDENTIAL_PREVIOUS_KEY"), let data = Data(base64Encoded: old), data.count == 32 {
            keys.append(SymmetricKey(data: data))
        }
        return keys
    }

    static func seal(_ refreshToken: String, userID: UUID, app: Application) throws -> String {
        let box = try AES.GCM.seal(Data(refreshToken.utf8), using: keys(app)[0], authenticating: Data(userID.uuidString.utf8))
        guard let combined = box.combined else { throw AppleCredentialError.misconfigured("The Apple credential could not be sealed") }
        return combined.base64EncodedString()
    }

    static func open(_ ciphertext: String, userID: UUID, app: Application) throws -> String {
        guard let data = Data(base64Encoded: ciphertext), let box = try? AES.GCM.SealedBox(combined: data) else {
            throw AppleCredentialError.misconfigured("The stored Apple credential could not be read")
        }
        for key in try keys(app) {
            if let opened = try? AES.GCM.open(box, using: key, authenticating: Data(userID.uuidString.utf8)),
               let token = String(data: opened, encoding: .utf8) {
                return token
            }
        }
        throw AppleCredentialError.misconfigured("The stored Apple credential could not be read")
    }

    /// Replaces any existing credential. Sign-in is the only writer, and the newest
    /// refresh token is the one revocation should use.
    static func store(refreshToken: String, userID: UUID, clientID: String, app: Application, on db: Database) async throws {
        let sealed = try seal(refreshToken, userID: userID, app: app)
        let now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO apple_credentials (user_id, refresh_token_ciphertext, client_id, created_at, updated_at)
            VALUES (\(bind: userID), \(bind: sealed), \(bind: clientID), \(bind: now), \(bind: now))
            ON CONFLICT (user_id) DO UPDATE SET
                refresh_token_ciphertext = EXCLUDED.refresh_token_ciphertext,
                client_id = EXCLUDED.client_id,
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    static func load(userID: UUID, app: Application, on db: Database) async throws -> (refreshToken: String, clientID: String)? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT refresh_token_ciphertext, client_id FROM apple_credentials WHERE user_id = \(bind: userID)
            """).first() else { return nil }
        let ciphertext = try row.decode(column: "refresh_token_ciphertext", as: String.self)
        let clientID = try row.decode(column: "client_id", as: String.self)
        return (try open(ciphertext, userID: userID, app: app), clientID)
    }

    /// Removed only once revocation has reached a terminal successful state. Clearing
    /// it on the first failure would turn a retryable step into a one-shot.
    static func discard(userID: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("DELETE FROM apple_credentials WHERE user_id = \(bind: userID)").run()
    }
}

struct AppleCredentialKeyStorage: StorageKey { typealias Value = Data }
