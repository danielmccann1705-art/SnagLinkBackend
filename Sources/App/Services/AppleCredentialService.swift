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

    /// Replaces only this client's credential. Native and web audiences coexist.
    static func store(refreshToken: String, userID: UUID, clientID: String, app: Application, on db: Database) async throws {
        let sealed = try seal(refreshToken, userID: userID, app: app)
        let now = Date()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO apple_credentials (user_id, refresh_token_ciphertext, client_id, created_at, updated_at)
            VALUES (\(bind: userID), \(bind: sealed), \(bind: clientID), \(bind: now), \(bind: now))
            ON CONFLICT (user_id, client_id) DO UPDATE SET
                refresh_token_ciphertext = EXCLUDED.refresh_token_ciphertext,
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    /// The compatibility overload is valid only for a single client. Never choose
    /// an arbitrary audience once a user has both native and web credentials.
    static func load(userID: UUID, app: Application, on db: Database) async throws -> (refreshToken: String, clientID: String)? {
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT refresh_token_ciphertext,client_id FROM apple_credentials WHERE user_id=\(bind: userID) ORDER BY client_id LIMIT 2").all()
        guard rows.count <= 1 else { throw AppleCredentialError.misconfigured("Choose an explicit Apple client") }
        guard let row = rows.first else { return nil }
        return try (open(row.decode(column: "refresh_token_ciphertext", as: String.self), userID: userID, app: app), row.decode(column: "client_id", as: String.self))
    }

    static func load(userID: UUID, clientID: String, app: Application, on db: Database) async throws -> (refreshToken: String, clientID: String)? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT refresh_token_ciphertext FROM apple_credentials WHERE user_id=\(bind: userID) AND client_id=\(bind: clientID)
            """).first() else { return nil }
        return try (open(row.decode(column: "refresh_token_ciphertext", as: String.self), userID: userID, app: app), clientID)
    }

    /// Removed only once revocation has reached a terminal successful state. Clearing
    /// it on the first failure would turn a retryable step into a one-shot.
    static func discard(userID: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("DELETE FROM apple_credentials WHERE user_id = \(bind: userID)").run()
    }
}

struct AppleCredentialKeyStorage: StorageKey { typealias Value = Data }
