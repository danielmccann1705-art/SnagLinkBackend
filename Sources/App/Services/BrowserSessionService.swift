import Vapor
import Fluent
import FluentSQL

struct PlatformConfiguration: Sendable {
    let origin: String
    let environment: String

    static func load(on app: Application) throws -> Self {
        if let configured = app.storage[PlatformConfigurationKey.self] { return configured }
        guard let origin = Environment.get("PORTAL_ORIGIN"),
              let environment = Environment.get("PLATFORM_ENVIRONMENT"),
              ["local", "staging", "production"].contains(environment),
              let parts = URLComponents(string: origin), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, !origin.hasSuffix("/"),
              parts.scheme == "https" || (environment == "local" && app.environment != .production && parts.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else {
            throw Abort(.serviceUnavailable, reason: "Manager sign-in is not configured")
        }
        return Self(origin: origin, environment: environment)
    }

    func requireOrigin(_ req: Request) throws {
        guard req.headers["Origin"] == [origin],
              !["cross-site", "none"].contains(req.headers.first(name: "Sec-Fetch-Site") ?? "") else {
            throw Abort(.forbidden, reason: "Open this action from Snaglist", identifier: "origin_required")
        }
    }
}

struct PlatformConfigurationKey: StorageKey { typealias Value = PlatformConfiguration }

struct BrowserPrincipal: Authenticatable, Sendable {
    let userID: UUID
    let sessionID: UUID
    let authenticatedAt: Date
    let csrfToken: String
}

struct BrowserSessionService {
    static let cookieName = "__Host-snaglist_session"
    static let bindingCookieName = "__Host-snaglist_login"
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    static func cookie(_ value: String, maxAge: Int) -> HTTPCookies.Value {
        .init(string: value, maxAge: maxAge, path: "/", isSecure: true, isHTTPOnly: true, sameSite: .lax)
    }

    static func csrf(for token: String) -> String { SHA256Hasher.hash(token: "snaglist-csrf:" + token) }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func create(for user: User, config: PlatformConfiguration, on db: Database) async throws -> (token: String, principal: BrowserPrincipal) {
        guard user.lifecycleState == "active" else { throw Abort(.unauthorized) }
        let token = try SecureTokenGenerator.generate(byteCount: 32)
        let csrf = csrf(for: token)
        let id = UUID(), now = Date(), userID = try user.requireID()
        try await VerifiedIdentityService.sql(db).raw("""
            INSERT INTO browser_sessions (id, user_id, token_hash, csrf_hash, environment, origin, auth_version, authenticated_at, created_at, expires_at)
            VALUES (\(bind: id), \(bind: userID), \(bind: SHA256Hasher.hash(token: token)), \(bind: SHA256Hasher.hash(token: csrf)),
                    \(bind: config.environment), \(bind: config.origin), \(bind: user.authVersion), \(bind: now), \(bind: now), \(bind: now.addingTimeInterval(lifetime)))
            """).run()
        return (token, BrowserPrincipal(userID: userID, sessionID: id, authenticatedAt: now, csrfToken: csrf))
    }

    static func authenticate(_ req: Request, config: PlatformConfiguration) async throws -> BrowserPrincipal {
        guard let raw = RequestCredentialCookie.value(cookieName, on: req), raw.count <= 128,
              let row = try await VerifiedIdentityService.sql(req.db).raw("""
                SELECT s.id, s.user_id, s.authenticated_at, s.csrf_hash
                FROM browser_sessions s JOIN users u ON u.id = s.user_id
                WHERE s.token_hash = \(bind: SHA256Hasher.hash(token: raw))
                  AND s.environment = \(bind: config.environment) AND s.origin = \(bind: config.origin)
                  AND s.expires_at > \(bind: Date()) AND s.revoked_at IS NULL
                  AND u.lifecycle_state = 'active' AND u.auth_version = s.auth_version
                """).first() else {
            throw Abort(.unauthorized, reason: "Sign in to continue", identifier: "session_required")
        }
        let csrfToken = csrf(for: raw)
        if ![HTTPMethod.GET, .HEAD, .OPTIONS].contains(req.method) {
            try config.requireOrigin(req)
            guard let supplied = req.headers.first(name: "X-CSRF-Token"), supplied.count <= 128,
                  constantTimeEqual(SHA256Hasher.hash(token: supplied), try row.decode(column: "csrf_hash", as: String.self)) else {
                throw Abort(.forbidden, reason: "Refresh Snaglist and try again", identifier: "csrf_required")
            }
        }
        return try BrowserPrincipal(userID: row.decode(column: "user_id", as: UUID.self), sessionID: row.decode(column: "id", as: UUID.self), authenticatedAt: row.decode(column: "authenticated_at", as: Date.self), csrfToken: csrfToken)
    }

    static func revoke(_ id: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("UPDATE browser_sessions SET revoked_at = \(bind: Date()) WHERE id = \(bind: id) AND revoked_at IS NULL").run()
    }

    static func revokeAll(for userID: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("UPDATE users SET auth_version = auth_version + 1 WHERE id = \(bind: userID)").run()
        try await VerifiedIdentityService.sql(db).raw("UPDATE browser_sessions SET revoked_at = \(bind: Date()) WHERE user_id = \(bind: userID) AND revoked_at IS NULL").run()
    }
}

/// V2 accepts native bearer tokens or browser sessions. Cookie authentication
/// always checks CSRF and Origin for mutations; v1 remains bearer-only.
struct PlatformAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if request.headers.bearerAuthorization != nil {
            return try await JWTAuthMiddleware().respond(to: request, chainingTo: next)
        }
        let config = try PlatformConfiguration.load(on: request.application)
        request.auth.login(try await BrowserSessionService.authenticate(request, config: config))
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
}
