import Crypto
import Foundation
import Vapor

/// A PIN session is signed for one link and expires independently of the link.
/// Cookies keep the existing web, iOS and App Clip response bodies compatible.
enum PINSessionService {
    static let cookieName = "snaglist_pin"
    static let lifetime: TimeInterval = 2 * 60 * 60

    static func requireVerified(_ req: Request, link: MagicLink) throws {
        guard !link.requiresPIN || isVerified(req, link: link) else {
            throw Abort(.forbidden, reason: "PIN verification required")
        }
    }

    static func isVerified(_ req: Request, link: MagicLink, now: Date = Date()) -> Bool {
        guard let value = req.cookies[cookieName]?.string,
              let id = link.id,
              let secret = Environment.get("JWT_SECRET"), !secret.isEmpty else { return false }
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let timestamp = TimeInterval(parts[0]), timestamp.isFinite,
              let signature = Data(base64Encoded: String(parts[1])) else { return false }
        let age = now.timeIntervalSince1970 - timestamp
        guard age >= 0 && age < lifetime else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(signature,
            authenticating: Data("\(parts[0]):\(id.uuidString)".utf8),
            using: SymmetricKey(data: Data(secret.utf8)))
    }

    static func attach(to response: inout Response, link: MagicLink, now: Date = Date()) {
        guard let id = link.id,
              let secret = Environment.get("JWT_SECRET"), !secret.isEmpty else { return }
        let timestamp = String(Int(now.timeIntervalSince1970))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data("\(timestamp):\(id.uuidString)".utf8),
            using: SymmetricKey(data: Data(secret.utf8)))
        response.cookies[cookieName] = HTTPCookies.Value(
            string: "\(timestamp):\(Data(signature).base64EncodedString())",
            expires: now.addingTimeInterval(lifetime), maxAge: Int(lifetime),
            path: "/", isSecure: true, isHTTPOnly: true, sameSite: .lax)
    }
}
