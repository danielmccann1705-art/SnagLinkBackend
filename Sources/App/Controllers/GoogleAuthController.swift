import Vapor
import Fluent
import FluentSQL

struct GoogleClientResponse: Content {
    let enabled: Bool
    let webClientID: String?
    let iosClientID: String?
}
struct GoogleChallengeResponse: Content {
    let challengeToken: String
    let nonce: String
    let clientID: String
    let serverClientID: String
    /// Native sign-in only. Browser binding is an HttpOnly cookie; account linking
    /// is bound to the existing authenticated session instead.
    let verifier: String?
    let expiresIn: Int
}
struct GoogleVerifyRequest: Content {
    let challengeToken: String
    let identityToken: String
    let verifier: String?
}
struct GoogleConnectionResponse: Content { let connected: Bool }

struct GoogleAuthController: RouteCollection {
    static func bindingCookie(for challengeToken: String) -> String {
        // Each open sign-in tab keeps its own binding. Rendering a second Google
        // button must not invalidate the first tab's pending provider request.
        "__Host-snaglist_google_" + SHA256Hasher.hash(token: challengeToken).prefix(24)
    }

    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v2", "auth", "google")
        auth.get("configuration", use: configuration)
        auth.post("challenge", use: webChallenge)
        auth.post("verify", use: webVerify)
        auth.post("ios", "challenge", use: iosChallenge)
        auth.post("ios", "verify", use: iosVerify)
        let account = routes.grouped("api", "v2", "account", "google").grouped(PlatformAuthMiddleware())
        account.get(use: connection)
        account.post("challenge", use: linkChallenge)
        account.post("verify", use: linkVerify)
    }

    @Sendable func configuration(req: Request) async throws -> Response {
        let config = try? settings(req).1
        let response = Response(status: .ok)
        try response.content.encode(GoogleClientResponse(enabled: config != nil, webClientID: config?.webClientID, iosClientID: config?.iosClientID))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func webChallenge(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        try platform.requireOrigin(req)
        try await limit(req, platform: platform)
        let binding = try SecureTokenGenerator.generate(byteCount: 32)
        let issued = try await GoogleIdentityChallengeService.issue(purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: req.db)
        let response = try challengeResponse(issued, surface: .web, verifier: nil, provider: provider)
        response.cookies[Self.bindingCookie(for: issued.token)] = BrowserSessionService.cookie(binding, maxAge: Int(GoogleIdentityChallengeService.lifetime))
        return response
    }

    @Sendable func webVerify(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        try platform.requireOrigin(req)
        let input = try req.content.decode(GoogleVerifyRequest.self)
        guard input.verifier == nil, (32...128).contains(input.challengeToken.utf8.count), let binding = RequestCredentialCookie.value(Self.bindingCookie(for: input.challengeToken), on: req) else { throw contextError() }
        let context = try await GoogleIdentityChallengeService.context(input.challengeToken, purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: req.db)
        let proof = try await GoogleIdentityVerifier.verify(input.identityToken, surface: .web, nonceHash: context.nonceHash, challengeCreatedAt: context.createdAt, config: provider, on: req)
        let result = try await req.db.transaction { db in
            _ = try await GoogleIdentityChallengeService.consume(input.challengeToken, purpose: .signIn, surface: .web, binding: binding, platform: platform, provider: provider, on: db)
            let user = try await GoogleIdentityService.resolve(proof, on: db)
            let session = try await BrowserSessionService.create(for: user, config: platform, on: db)
            return (user, session)
        }
        let response = Response(status: .ok)
        try response.content.encode(try await BrowserAuthController().response(for: result.0, csrf: result.1.principal.csrfToken, on: req.db))
        response.cookies[BrowserSessionService.cookieName] = BrowserSessionService.cookie(result.1.token, maxAge: Int(BrowserSessionService.lifetime))
        response.cookies[Self.bindingCookie(for: input.challengeToken)] = BrowserSessionService.cookie("", maxAge: 0)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func iosChallenge(req: Request) async throws -> Response {
        try requireNative(req)
        let (platform, provider) = try settings(req)
        try await limit(req, platform: platform)
        let verifier = try SecureTokenGenerator.generate(byteCount: 32)
        let issued = try await GoogleIdentityChallengeService.issue(purpose: .signIn, surface: .ios, binding: verifier, platform: platform, provider: provider, on: req.db)
        return try challengeResponse(issued, surface: .ios, verifier: verifier, provider: provider)
    }

    @Sendable func iosVerify(req: Request) async throws -> Response {
        try requireNative(req)
        let (platform, provider) = try settings(req)
        let input = try req.content.decode(GoogleVerifyRequest.self)
        guard let verifier = input.verifier else { throw contextError() }
        let context = try await GoogleIdentityChallengeService.context(input.challengeToken, purpose: .signIn, surface: .ios, binding: verifier, platform: platform, provider: provider, on: req.db)
        let proof = try await GoogleIdentityVerifier.verify(input.identityToken, surface: .ios, nonceHash: context.nonceHash, challengeCreatedAt: context.createdAt, config: provider, on: req)
        let user = try await req.db.transaction { db in
            _ = try await GoogleIdentityChallengeService.consume(input.challengeToken, purpose: .signIn, surface: .ios, binding: verifier, platform: platform, provider: provider, on: db)
            return try await GoogleIdentityService.resolve(proof, on: db)
        }
        let response = Response(status: .ok)
        try response.content.encode(AuthController().issueAuthResponse(for: user, on: req))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func connection(req: Request) async throws -> Response {
        let userID = try req.requireAuthenticatedUserId()
        let row = try await VerifiedIdentityService.sql(req.db).raw("SELECT id FROM user_identities WHERE user_id = \(bind: userID) AND provider = 'google'").first()
        return try connectionResponse(row != nil)
    }

    @Sendable func linkChallenge(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        let account = try accountContext(req)
        try await limit(req, platform: platform)
        let issued = try await GoogleIdentityChallengeService.issue(purpose: .link, surface: account.surface, binding: account.binding,
            targetUserID: account.userID, browserSessionID: account.sessionID, platform: platform, provider: provider, on: req.db)
        return try challengeResponse(issued, surface: account.surface, verifier: nil, provider: provider)
    }

    @Sendable func linkVerify(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        let account = try accountContext(req)
        let input = try req.content.decode(GoogleVerifyRequest.self)
        guard input.verifier == nil else { throw contextError() }
        let context = try await GoogleIdentityChallengeService.context(input.challengeToken, purpose: .link, surface: account.surface, binding: account.binding,
            targetUserID: account.userID, browserSessionID: account.sessionID, platform: platform, provider: provider, on: req.db)
        let proof = try await GoogleIdentityVerifier.verify(input.identityToken, surface: account.surface, nonceHash: context.nonceHash, challengeCreatedAt: context.createdAt, config: provider, on: req)
        try await req.db.transaction { db in
            _ = try await GoogleIdentityChallengeService.consume(input.challengeToken, purpose: .link, surface: account.surface, binding: account.binding,
                targetUserID: account.userID, browserSessionID: account.sessionID, platform: platform, provider: provider, on: db)
            try await GoogleIdentityService.link(proof, to: account.userID, on: db)
        }
        return try connectionResponse(true)
    }

    private func connectionResponse(_ connected: Bool) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(GoogleConnectionResponse(connected: connected))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    private func settings(_ req: Request) throws -> (PlatformConfiguration, GoogleIdentityConfiguration) {
        let platform = try PlatformConfiguration.load(on: req.application)
        return (platform, try GoogleIdentityConfiguration.load(platform: platform, on: req.application))
    }
    private func challengeResponse(_ issued: GoogleIdentityChallengeService.Issued, surface: GoogleIdentitySurface, verifier: String?, provider: GoogleIdentityConfiguration) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(GoogleChallengeResponse(challengeToken: issued.token, nonce: issued.nonce,
            clientID: surface == .web ? provider.webClientID : provider.iosClientID, serverClientID: provider.webClientID,
            verifier: verifier, expiresIn: Int(GoogleIdentityChallengeService.lifetime)))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
    private func requireNative(_ req: Request) throws {
        guard req.headers["Origin"].isEmpty, req.headers["Sec-Fetch-Site"].isEmpty else {
            throw Abort(.forbidden, reason: "Use Google sign-in from the Snaglist app")
        }
    }
    private func accountContext(_ req: Request) throws -> (userID: UUID, surface: GoogleIdentitySurface, binding: String, sessionID: UUID?) {
        let userID = try req.requireAuthenticatedUserId()
        let authenticatedAt = req.auth.get(BrowserPrincipal.self)?.authenticatedAt ?? req.auth.get(UserJWTPayload.self)?.authenticatedAt
        guard let authenticatedAt, authenticatedAt > Date().addingTimeInterval(-600), authenticatedAt <= Date().addingTimeInterval(30) else {
            throw Abort(.forbidden, reason: "Sign in to your current Snaglist account again before connecting Google", identifier: "reauthentication_required")
        }
        if let principal = req.auth.get(BrowserPrincipal.self) {
            return (userID, .web, "session:" + principal.sessionID.uuidString, principal.sessionID)
        }
        try requireNative(req)
        guard let version = req.auth.get(UserJWTPayload.self)?.authVersion else { throw Abort(.unauthorized) }
        return (userID, .ios, "native:\(userID.uuidString):\(version)", nil)
    }
    private func contextError() -> Abort {
        Abort(.conflict, reason: "Return to the browser or app that started Google sign-in", identifier: "verification_context_mismatch")
    }
    private func limit(_ req: Request, platform: PlatformConfiguration) async throws {
        let key = "google-signin:" + SHA256Hasher.hash(token: platform.environment + ":" + platform.origin + ":" + IPAddressExtractor.extract(from: req))
        try await req.db.transaction { db in
            try await VerifiedIdentityService.lock("rate:" + key, on: db)
            try await RateLimitService.enforce(key: key, action: .googleSignIn, on: db)
        }
    }
}
