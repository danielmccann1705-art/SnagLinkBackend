import Vapor
import Fluent
@preconcurrency import JWT
import Crypto

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("apple", use: appleSignIn)

        // B1: Magic-link (passwordless) Project Manager authentication.
        let magicLink = auth.grouped("magic-link")
        magicLink.post("request", use: requestMagicLink)
        magicLink.post("verify", use: verifyMagicLink)
        auth.get("recognise", use: recogniseEmail)
    }

    // MARK: - Sign in with Apple

    @Sendable
    func appleSignIn(req: Request) async throws -> AuthResponse {
        let input = try req.content.decode(AppleSignInRequest.self)

        // Verify Apple identity token using JWKS (signature + issuer + expiry)
        let appleToken: AppleIdentityToken
        do {
            appleToken = try await req.jwt.apple.verify(
                input.identityToken,
                applicationIdentifier: Environment.get("APPLE_APP_ID")
            ).get()
        } catch {
            throw Abort(.unauthorized, reason: "Invalid Apple identity token")
        }

        let appleUserId = appleToken.subject.value
        let email = appleToken.email

        // Find or create user
        let user: User
        if let existing = try await User.query(on: req.db).filter(\.$appleUserId == appleUserId).first() {
            user = existing
        } else {
            user = User(appleUserId: appleUserId, email: email, name: input.firstName)
            try await user.save(on: req.db)
        }

        return try issueAuthResponse(for: user, on: req)
    }

    // MARK: - Magic-link request

    /// `POST /api/v1/auth/magic-link/request`
    /// Sends a one-tap sign-in email. Always responds `204` for valid input regardless of
    /// whether an account exists — the account is created on verify, so this leaks nothing.
    @Sendable
    func requestMagicLink(req: Request) async throws -> Response {
        let input = try req.content.decode(MagicLinkRequestBody.self)
        let email = EmailValidator.normalize(input.email)

        guard EmailValidator.isValidFormat(email) else {
            throw Abort(.badRequest, reason: "Invalid email address")
        }
        guard !EmailValidator.isDisposable(email) else {
            throw Abort(.badRequest, reason: "Disposable email addresses are not allowed")
        }

        // Rate limit: 3 requests per email per hour. Keyed on email (not IP) so an attacker
        // can't burn through a victim's quota from many IPs, and a victim isn't flooded.
        try await RateLimitService.enforce(key: "magic_link:\(email)", action: .magicLinkRequest, on: req.db)

        let rawToken = try SecureTokenGenerator.generate(byteCount: 32)
        let tokenHash = SHA256Hasher.hash(token: rawToken)

        let authToken = MagicLinkAuthToken(
            tokenHash: tokenHash,
            email: email,
            expiresAt: Date().addingTimeInterval(15 * 60), // 15-minute TTL
            requestedName: input.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            requestingIP: IPAddressExtractor.extract(from: req)
        )
        try await authToken.save(on: req.db)

        let linkURL = "\(Self.magicLinkBaseURL)/auth/\(rawToken)"

        // Never log the email in plaintext — hash for log correlation only.
        req.logger.info("Magic sign-in link requested (email_hash=\(Self.emailHash(email)))")

        do {
            try await NotificationService.sendMagicSignInEmail(
                to: email,
                name: input.name,
                magicLinkURL: linkURL,
                client: req.client
            )
        } catch {
            // Don't surface delivery internals to the caller; log and still return 204 so the
            // endpoint can't be used to probe which addresses bounce.
            req.logger.error("Magic sign-in email send failed (email_hash=\(Self.emailHash(email))): \(error)")
        }

        return Response(status: .noContent)
    }

    // MARK: - Magic-link verify

    /// `POST /api/v1/auth/magic-link/verify`
    /// Exchanges a single-use token for a signed JWT. Same response shape as `/auth/apple`.
    @Sendable
    func verifyMagicLink(req: Request) async throws -> AuthResponse {
        let input = try req.content.decode(MagicLinkVerifyBody.self)
        let rawToken = input.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawToken.isEmpty else {
            throw Abort(.badRequest, reason: "Missing token")
        }

        let tokenHash = SHA256Hasher.hash(token: rawToken)
        guard let authToken = try await MagicLinkAuthToken.query(on: req.db)
            .filter(\.$tokenHash == tokenHash)
            .first()
        else {
            throw Abort(.gone, reason: "This sign-in link is invalid or has expired")
        }

        if authToken.isConsumed {
            throw Abort(.gone, reason: "This sign-in link has already been used", identifier: "consumed")
        }
        if authToken.isExpired {
            throw Abort(.gone, reason: "This sign-in link has expired", identifier: "expired")
        }

        // Single-use: mark consumed before issuing the session.
        authToken.consumedAt = Date()
        try await authToken.save(on: req.db)

        let email = authToken.email

        // Find an existing account by email (portable across providers — an email previously
        // used for Sign in with Apple resolves to the same account), else create one.
        let user: User
        if let existing = try await User.query(on: req.db)
            .filter(\.$email == email)
            .sort(\.$createdAt, .ascending)
            .first()
        {
            user = existing
        } else {
            user = User(
                appleUserId: nil,
                email: email,
                name: authToken.requestedName,
                authProvider: .magicLink
            )
            try await user.save(on: req.db)
        }

        return try issueAuthResponse(for: user, on: req)
    }

    // MARK: - Email recognition

    /// `GET /api/v1/auth/recognise?email=…`
    /// No auth. Returns whether the email maps to a known account, plus minimal display data.
    /// Privacy: the "not recognised" response shape is identical regardless of why (no such
    /// user, invalid input, etc.) so it can't be used to probe account state.
    @Sendable
    func recogniseEmail(req: Request) async throws -> EmailRecognitionResponse {
        // Rate limit: 10/min per IP to frustrate enumeration.
        let ip = IPAddressExtractor.extract(from: req)
        try await RateLimitService.enforce(key: "recognise:\(ip)", action: .emailRecognise, on: req.db)

        guard let rawEmail = try? req.query.get(String.self, at: "email") else {
            return EmailRecognitionResponse.notRecognised
        }
        let email = EmailValidator.normalize(rawEmail)
        guard EmailValidator.isValidFormat(email) else {
            return EmailRecognitionResponse.notRecognised
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .sort(\.$createdAt, .ascending)
            .first(),
            let userId = user.id
        else {
            return EmailRecognitionResponse.notRecognised
        }

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$ownerId == userId)
            .count()

        return EmailRecognitionResponse(
            recognised: true,
            displayName: user.name,
            projectCount: projectCount
        )
    }

    // MARK: - Helpers

    /// Public web origin used to build the universal-link sign-in URL.
    private static var magicLinkBaseURL: String {
        Environment.get("MAGIC_LINK_BASE_URL") ?? "https://snaglist.dev"
    }

    /// Short, non-reversible-in-practice correlation id for logs.
    private static func emailHash(_ email: String) -> String {
        String(SHA256Hasher.hash(token: email).prefix(12))
    }

    /// Builds the standard authenticated session response (30-day JWT), shared by all
    /// auth methods so they stay shape-compatible.
    private func issueAuthResponse(for user: User, on req: Request) throws -> AuthResponse {
        let jwtPayload = UserJWTPayload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(30 * 24 * 60 * 60)), // 30 days
            userId: user.id!
        )
        let token = try req.jwt.sign(jwtPayload)

        return AuthResponse(
            token: token,
            user: AuthUserResponse(
                id: user.id!,
                email: user.email,
                name: user.name,
                appleUserId: user.appleUserId,
                authProvider: user.authProvider
            ),
            isNewUser: user.createdAt == user.updatedAt
        )
    }
}

// MARK: - Request / Response models

struct AppleSignInRequest: Content {
    let identityToken: String
    let firstName: String?
    let lastName: String?
}

struct MagicLinkRequestBody: Content {
    let email: String
    let name: String?
}

struct MagicLinkVerifyBody: Content {
    let token: String
}

struct AuthResponse: Content {
    let token: String
    let user: AuthUserResponse
    let isNewUser: Bool
}

struct AuthUserResponse: Content {
    let id: UUID
    let email: String?
    let name: String?
    /// Nil for magic-link accounts.
    let appleUserId: String?
    let authProvider: String
}

struct EmailRecognitionResponse: Content {
    let recognised: Bool
    let displayName: String?
    let projectCount: Int?

    /// The single canonical "unknown" response — identical for every not-recognised reason.
    static let notRecognised = EmailRecognitionResponse(recognised: false, displayName: nil, projectCount: nil)
}
