import Vapor
import Fluent

struct BrowserSessionResponse: Content {
    let user: AuthUserResponse
    let verifiedEmails: [String]
    let csrfToken: String
}

struct BrowserAuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v2", "auth")
        auth.post("email", use: requestEmail)
        auth.post("verify", use: verify)
        let protected = auth.grouped(PlatformAuthMiddleware())
        protected.get("session", use: session)
        protected.post("logout", use: logout)
        protected.post("logout-all", use: logoutAll)

        let account = routes.grouped("api", "v2", "account").grouped(PlatformAuthMiddleware())
        account.get("emails", use: emails)
        account.post("email", "request", use: requestAccountEmail)
        account.post("email", "verify", use: verifyAccountEmail)
    }

    @Sendable func requestEmail(req: Request) async throws -> Response {
        let config = try PlatformConfiguration.load(on: req.application)
        try config.requireOrigin(req)
        let input = try req.content.decode(MagicLinkRequestBody.self)
        let email = try validatedEmail(input.email)
        try await limit(email: email, req: req)
        let binding = try SecureTokenGenerator.generate(byteCount: 32)
        let raw = try await IdentityChallengeService.issue(email: email, purpose: .browserSignIn, targetUserID: nil, binding: binding,
                                                          name: input.name.map { String($0.prefix(100)) }, config: config, on: req.db)
        try await deliver(email: email, raw: raw, path: "/sign-in/verify", config: config, req: req)
        let response = Response(status: .noContent)
        response.cookies[BrowserSessionService.bindingCookieName] = BrowserSessionService.cookie(binding, maxAge: 900)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func verify(req: Request) async throws -> Response {
        let config = try PlatformConfiguration.load(on: req.application)
        try config.requireOrigin(req)
        let input = try req.content.decode(MagicLinkVerifyBody.self)
        guard let binding = req.cookies[BrowserSessionService.bindingCookieName]?.string else {
            throw Abort(.conflict, reason: "Return to the browser that requested this link, or request a new link here", identifier: "verification_context_mismatch")
        }
        let result = try await req.db.transaction { db in
            let challenge = try await IdentityChallengeService.consume(input.token, purpose: .browserSignIn, binding: binding, targetUserID: nil, config: config, on: db)
            let user = try await VerifiedIdentityService.resolveEmail(challenge.email, name: challenge.requestedName, on: db)
            let session = try await BrowserSessionService.create(for: user, config: config, on: db)
            return (user, session)
        }
        let response = Response(status: .ok)
        try response.content.encode(try await self.response(for: result.0, csrf: result.1.principal.csrfToken, on: req.db))
        response.cookies[BrowserSessionService.cookieName] = BrowserSessionService.cookie(result.1.token, maxAge: Int(BrowserSessionService.lifetime))
        response.cookies[BrowserSessionService.bindingCookieName] = BrowserSessionService.cookie("", maxAge: 0)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func session(req: Request) async throws -> BrowserSessionResponse {
        let user = try await VerifiedIdentityService.activeUser(req.requireAuthenticatedUserId(), on: req.db)
        return try await response(for: user, csrf: req.auth.get(BrowserPrincipal.self)?.csrfToken ?? "", on: req.db)
    }

    @Sendable func logout(req: Request) async throws -> Response {
        guard let principal = req.auth.get(BrowserPrincipal.self) else {
            throw Abort(.badRequest, reason: "Use sign out everywhere to revoke native sessions")
        }
        try await BrowserSessionService.revoke(principal.sessionID, on: req.db)
        let response = Response(status: .noContent)
        response.cookies[BrowserSessionService.cookieName] = BrowserSessionService.cookie("", maxAge: 0)
        return response
    }

    @Sendable func logoutAll(req: Request) async throws -> Response {
        let userID = try req.requireAuthenticatedUserId()
        try await req.db.transaction { db in try await BrowserSessionService.revokeAll(for: userID, on: db) }
        let response = Response(status: .noContent)
        response.cookies[BrowserSessionService.cookieName] = BrowserSessionService.cookie("", maxAge: 0)
        return response
    }

    @Sendable func emails(req: Request) async throws -> [String] {
        try await VerifiedIdentityService.verifiedEmails(for: req.requireAuthenticatedUserId(), on: req.db)
    }

    @Sendable func requestAccountEmail(req: Request) async throws -> HTTPStatus {
        let userID = try req.requireAuthenticatedUserId()
        let config = try PlatformConfiguration.load(on: req.application)
        let input = try req.content.decode(MagicLinkRequestBody.self)
        let email = try validatedEmail(input.email)
        try await limit(email: email, req: req)
        // Browser proof is session-bound; native proof is bound to the account and
        // its revocation version. Verification still requires that authenticated actor.
        let binding = try await accountBinding(req)
        let raw = try await IdentityChallengeService.issue(email: email, purpose: .verifyEmail, targetUserID: userID, binding: binding, config: config, on: req.db)
        try await deliver(email: email, raw: raw, path: "/account/verify-email", config: config, req: req)
        return .noContent
    }

    @Sendable func verifyAccountEmail(req: Request) async throws -> [String] {
        let userID = try req.requireAuthenticatedUserId()
        let config = try PlatformConfiguration.load(on: req.application)
        let input = try req.content.decode(MagicLinkVerifyBody.self)
        let binding = try await accountBinding(req)
        try await req.db.transaction { db in
            let challenge = try await IdentityChallengeService.consume(input.token, purpose: .verifyEmail, binding: binding, targetUserID: userID, config: config, on: db)
            try await VerifiedIdentityService.linkEmail(challenge.email, to: userID, on: db)
        }
        return try await VerifiedIdentityService.verifiedEmails(for: userID, on: req.db)
    }

    private func accountBinding(_ req: Request) async throws -> String {
        if let principal = req.auth.get(BrowserPrincipal.self) { return "session:" + principal.sessionID.uuidString }
        let user = try await VerifiedIdentityService.activeUser(req.requireAuthenticatedUserId(), on: req.db)
        return "native:\(try user.requireID()):\(user.authVersion)"
    }

    private func validatedEmail(_ value: String) throws -> String {
        let email = EmailValidator.normalize(value)
        guard email.count <= 254, EmailValidator.isValidFormat(email), !EmailValidator.isDisposable(email) else { throw Abort(.badRequest, reason: "Enter a valid email address") }
        return email
    }

    private func limit(email: String, req: Request) async throws {
        // Hash the key; serialise the old rate-limit counter under a DB lock.
        try await req.db.transaction { db in
            let key = "identity-email:" + SHA256Hasher.hash(token: email)
            try await VerifiedIdentityService.lock("rate:" + key, on: db)
            try await RateLimitService.enforce(key: key, action: .magicLinkRequest, on: db)
        }
    }

    private func deliver(email: String, raw: String, path: String, config: PlatformConfiguration, req: Request) async throws {
        // Fragment is not sent on landing GET or in HTTP referrers. Only the
        // explicit confirmation POST consumes the token. No arbitrary redirects.
        do {
            try await NotificationService.sendMagicSignInEmail(to: email, name: nil, magicLinkURL: config.origin + path + "#token=" + raw, client: req.client)
        } catch {
            // Fail explicitly without leaking the recipient or provider error/token.
            throw Abort(.serviceUnavailable, reason: "We could not send a verification email. Try again shortly")
        }
    }

    private func response(for user: User, csrf: String, on db: Database) async throws -> BrowserSessionResponse {
        let id = try user.requireID()
        return BrowserSessionResponse(user: AuthUserResponse(id: id, email: user.email, name: user.name, appleUserId: nil, authProvider: user.authProvider), verifiedEmails: try await VerifiedIdentityService.verifiedEmails(for: id, on: db), csrfToken: csrf)
    }
}
