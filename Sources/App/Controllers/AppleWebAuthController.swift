import Vapor
import Fluent
import FluentSQL

struct AppleWebClientResponse: Content { let enabled: Bool }
struct AppleWebChallengeResponse: Content { let authorizationURL: String; let expiresIn: Int }
private struct AppleWebCallback: Content { let state: String; let code: String?; let error: String? }

struct AppleWebAuthController: RouteCollection {
    static func bindingCookie(for state: String) -> String {
        "__Host-snaglist_apple_" + SHA256Hasher.hash(token: state).prefix(24)
    }
    static func challengeCookie(_ value: String, maxAge: Int) -> HTTPCookies.Value {
        // Apple's cross-site form_post cannot carry a Lax cookie. Only this
        // short-lived challenge binding uses None; the session stays Lax.
        .init(string: value, maxAge: maxAge, path: "/", isSecure: true, isHTTPOnly: true, sameSite: HTTPCookies.SameSitePolicy.none)
    }
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v2", "auth", "apple").grouped(AppleWebPrivacyMiddleware())
        auth.get("configuration", use: configuration)
        auth.post("challenge", use: challenge)
        auth.on(.POST, "callback", body: .collect(maxSize: "16kb"), use: callback)
    }
    @Sendable func configuration(req: Request) async throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(AppleWebClientResponse(enabled: (try? settings(req)) != nil))
        return response
    }
    @Sendable func challenge(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        try platform.requireOrigin(req)
        try await limit(req, platform: platform)
        let binding = try SecureTokenGenerator.generate(byteCount: 32)
        let issued = try await AppleWebChallengeService.issue(binding: binding, platform: platform, provider: provider, on: req.db)
        var url = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: provider.clientID),
            .init(name: "redirect_uri", value: provider.redirectURI), .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "form_post"), .init(name: "scope", value: "name email"),
            .init(name: "state", value: issued.state), .init(name: "nonce", value: issued.nonce)]
        let response = Response(status: .ok)
        try response.content.encode(AppleWebChallengeResponse(authorizationURL: url.string!, expiresIn: Int(AppleWebChallengeService.lifetime)))
        response.cookies[Self.bindingCookie(for: issued.state)] = Self.challengeCookie(binding, maxAge: Int(AppleWebChallengeService.lifetime))
        return response
    }
    @Sendable func callback(req: Request) async throws -> Response {
        let (platform, provider) = try settings(req)
        guard req.headers["Origin"] == ["https://appleid.apple.com"], req.headers.contentType == .urlEncodedForm else {
            throw Abort(.forbidden, reason: "Return to Apple to finish signing in", identifier: "apple_callback_origin_invalid")
        }
        try await limit(req, platform: platform)
        let input: AppleWebCallback
        do { input = try req.content.decode(AppleWebCallback.self) }
        catch { throw Abort(.badRequest, reason: "Apple sign-in could not be read. Start again", identifier: "apple_callback_invalid") }
        guard AppleWebChallengeService.validOpaque(input.state),
              let binding = RequestCredentialCookie.value(Self.bindingCookie(for: input.state), on: req) else {
            throw AppleWebChallengeService.contextMismatch()
        }
        let context = try await AppleWebChallengeService.consume(state: input.state, binding: binding, platform: platform, provider: provider, on: req.db)
        guard input.error == nil, let code = input.code, (1...4096).contains(code.utf8.count),
              code.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw AppleWebIdentityService.invalidIdentity() }
        let tokens = try await AppleWebIdentityService.exchange(code: code, configuration: provider, req: req)
        let held: AppleWebCredentialEscrowService.Held
        do {
            held = try await AppleWebCredentialEscrowService.hold(refreshToken: tokens.refreshToken, context: context,
                clientID: provider.clientID, app: req.application, on: req.db)
        } catch {
            // A database failure after an external exchange has no atomic commit
            // across both systems. Try immediate revocation, issue no session,
            // and log only a bounded operational classification if it fails.
            let result = await AppleTokenService.revoke(refreshToken: tokens.refreshToken, clientID: provider.clientID,
                exchange: provider.exchange, on: req.client, logger: req.logger)
            if result != .revoked && result != .alreadyRevoked {
                req.logger.error("Apple web credential capture failed; immediate revocation was not confirmed")
            }
            throw AppleWebIdentityService.exchangeUnavailable()
        }
        let session: (token: String, principal: BrowserPrincipal)
        do {
            let proof = try await AppleWebIdentityService.verify(tokens.idToken, context: context, configuration: provider, req: req)
            session = try await req.db.transaction { db in
                // Front-channel user/name JSON is not identity proof and is ignored.
                let user = try await AppleWebIdentityService.resolve(proof, name: nil, on: db)
                if proof.emailVerified, let email = proof.email {
                    _ = try await VerifiedIdentityService.adoptProviderVerifiedEmail(email, to: user.requireID(), on: db)
                }
                try await AppleWebCredentialEscrowService.adopt(held, userID: user.requireID(), app: req.application, on: db)
                return try await BrowserSessionService.create(for: user, config: platform, on: db)
            }
        } catch {
            // If this update fails, the existing durable hold expires and the
            // maintenance worker still discovers and revokes the credential.
            try? await AppleWebCredentialEscrowService.abandon(held, on: req.db)
            throw error
        }
        // Fixed relative destination: no callback/query-supplied redirect target.
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: "/")
        response.cookies[BrowserSessionService.cookieName] = BrowserSessionService.cookie(session.token, maxAge: Int(BrowserSessionService.lifetime))
        response.cookies[Self.bindingCookie(for: input.state)] = Self.challengeCookie("", maxAge: 0)
        return response
    }
    private func settings(_ req: Request) throws -> (PlatformConfiguration, AppleWebConfiguration) {
        let platform = try PlatformConfiguration.load(on: req.application)
        return (platform, try AppleWebConfiguration.load(platform: platform, app: req.application))
    }
    private func limit(_ req: Request, platform: PlatformConfiguration) async throws {
        let key = "apple-web:" + SHA256Hasher.hash(token: platform.environment + ":" + platform.origin + ":" + IPAddressExtractor.extract(from: req))
        try await req.db.transaction { db in
            try await VerifiedIdentityService.lock("rate:" + key, on: db)
            try await RateLimitService.enforce(key: key, action: .tokenLookup, on: db)
        }
    }
}

private struct AppleWebPrivacyMiddleware: AsyncMiddleware {
    struct Failure: Content { let error: Bool; let reason: String; let identifier: String }
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        do { response = try await next.respond(to: request) }
        catch {
            let abort = error as? AbortError
            let status = abort?.status ?? .internalServerError
            let browserCallback = request.method == .POST && request.url.path == "/api/v2/auth/apple/callback" &&
                request.headers[.accept].contains { $0.lowercased().contains("text/html") }
            if browserCallback {
                // A fixed public status marker brings a browser back to a usable
                // sign-in screen. No code, state, identity or provider text enters
                // the redirect URL, and no supplied return destination is used.
                let identifier = (error as? Abort)?.identifier
                let marker = identifier == "identity_proof_required" ? "apple_existing_account" :
                    identifier == "apple_challenge_expired" ? "apple_expired" : "apple_failed"
                response = Response(status: .seeOther)
                response.headers.replaceOrAdd(name: .location, value: "/?signin=" + marker)
                if let input = try? request.content.decode(AppleWebCallback.self),
                   AppleWebChallengeService.validOpaque(input.state) {
                    response.cookies[AppleWebAuthController.bindingCookie(for: input.state)] = AppleWebAuthController.challengeCookie("", maxAge: 0)
                }
            } else {
                response = Response(status: status, headers: abort?.headers ?? [:])
                try response.content.encode(Failure(error: true,
                    reason: status.code < 500 ? (abort?.reason ?? "Apple sign-in could not be completed") : "Apple sign-in is temporarily unavailable. Start again shortly",
                    identifier: (error as? Abort)?.identifier ?? "apple_signin_failed"))
            }
        }
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return response
    }
}
