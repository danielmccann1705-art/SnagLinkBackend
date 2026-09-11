import Vapor
import Crypto

struct LinkGrantTokenKey: StorageKey { typealias Value = Data }

/// Digests identify bearer capabilities. Authenticated encryption permits a lost
/// activation response to be retried without storing a raw token in receipts.
/// Keep both current and previous keys during rotation; rewrap before retiring one.
enum LinkGrantTokenService {
    static func keys(_ app: Application) throws -> [SymmetricKey] {
        if app.environment == .testing, let bytes = app.storage[LinkGrantTokenKey.self], bytes.count == 32 { return [SymmetricKey(data: bytes)] }
        guard let raw = Environment.get("LINK_GRANT_TOKEN_KEY"), let data = Data(base64Encoded: raw), data.count == 32 else {
            throw Abort(.serviceUnavailable, reason: "Contractor sharing is not configured")
        }
        var keys = [SymmetricKey(data: data)]
        if let old = Environment.get("LINK_GRANT_TOKEN_PREVIOUS_KEY"), let data = Data(base64Encoded: old), data.count == 32 { keys.append(SymmetricKey(data: data)) }
        return keys
    }
    static func requestHashes<T: Encodable>(_ command: T, route: String, app: Application) throws -> [String] {
        let data = Data(("link-prepare-v1:" + route + "\n" + (try PlatformMutationService.encode(command))).utf8)
        return try keys(app).map { Data(HMAC<SHA256>.authenticationCode(for: data, using: $0)).base64EncodedString() }
    }
    static func seal(_ token: String, id: UUID, app: Application) throws -> String {
        let box = try AES.GCM.seal(Data(token.utf8), using: keys(app)[0], authenticating: Data(id.uuidString.utf8))
        guard let combined = box.combined else { throw Abort(.internalServerError) }
        return combined.base64EncodedString()
    }
    static func open(_ ciphertext: String, id: UUID, app: Application) throws -> String {
        guard let data = Data(base64Encoded: ciphertext), let box = try? AES.GCM.SealedBox(combined: data) else { throw Abort(.serviceUnavailable, reason: "This link cannot be retrieved; create a new Contractor link") }
        for key in try keys(app) {
            if let data = try? AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8)), let token = String(data: data, encoding: .utf8) { return token }
        }
        throw Abort(.serviceUnavailable, reason: "This link cannot be retrieved; create a new Contractor link")
    }
}
