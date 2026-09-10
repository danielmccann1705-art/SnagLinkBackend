import Fluent
import Vapor

func routes(_ app: Application) throws {
    // MARK: - Health Check
    app.get("health") { req async -> HealthResponse in
        return HealthResponse(
            status: "ok",
            version: "1.0.0",
            timestamp: Date()
        )
    }

    // MARK: - API Documentation
    app.get { req async -> String in
        return """
        Snaglist Backend API v1

        Endpoints:
        - GET /health - Health check

        Authentication:
        - POST /api/v1/auth/apple - Sign in with Apple
        - POST /api/v1/auth/magic-link/request - Send a passwordless sign-in email (PM)
        - POST /api/v1/auth/magic-link/verify - Exchange a magic-link token for a JWT
        - GET /api/v1/auth/recognise?email= - Check if an email maps to a known account
        - GET /auth/:token - Magic-link universal-link landing/fallback page (web)

        Magic Links:
        - POST /api/v1/magic-links/preview - Create an unsent preview link (auth required)
        - GET /preview/:token - View an unsent preview link (submissions disabled)
        - GET /api/v1/magic-links/:linkId/validate - Validate a magic link token
        - POST /api/v1/magic-links/:linkId/verify-pin - Verify PIN for magic link
        - POST /api/v1/magic-links - Create a new magic link (auth required)
        - GET /api/v1/magic-links - List your magic links (auth required)
        - DELETE /api/v1/magic-links/:linkId - Revoke a magic link (auth required)
        - GET /api/v1/magic-links/:linkId/analytics - Get magic link analytics (auth required)
        - GET /api/v1/magic-links/:linkId/pdf - Download PDF report of snags
        - GET /api/v1/magic-links/:linkId/qr - Generate QR code image (PNG)
        - POST /api/v1/magic-links/:linkId/send - Record a send + enforce tier allowance (auth required)
        - GET /api/v1/users/me/usage - Magic-link allowance / tier counters (auth required)
        - POST /api/v1/magic-links/sync - Sync magic link from iOS app (auth required)
        - POST /api/v1/magic-links/:linkId/report - Sync report data (auth required)
        - POST /api/v1/magic-links/:linkId/photos - Upload synced photo (auth required)
        - POST /api/v1/magic-links/:linkId/drawings - Upload synced drawing (auth required)

        Team Invites:
        - GET /api/v1/team-invites/:inviteId/validate - Validate a team invite token
        - POST /api/v1/team-invites - Create a new team invite (auth required)
        - GET /api/v1/team-invites/pending - List pending invites (auth required)
        - POST /api/v1/team-invites/:inviteId/accept - Accept a team invite (auth required)
        - POST /api/v1/team-invites/:inviteId/decline - Decline a team invite (auth required)
        - DELETE /api/v1/team-invites/:inviteId - Revoke a team invite (auth required)

        Approvals:
        - GET /api/v1/approvals/pending - List snags awaiting approval (auth required)
        - POST /api/v1/approvals/:snagId/approve - Approve a submitted snag (auth required)
        - POST /api/v1/approvals/:snagId/send-back - Send a snag back with a reason (auth required)

        Completions:
        - POST /api/v1/magic-links/:linkId/snags/:snagId/complete - Submit completion (magic link)
        - GET /api/v1/completions/pending - List pending completions (auth required)
        - GET /api/v1/completions/:completionId - Get completion details (auth required)
        - POST /api/v1/completions/:completionId/approve - Approve completion (auth required)
        - POST /api/v1/completions/:completionId/reject - Reject completion (auth required)

        Snags:
        - GET /api/v1/magic-links/:linkId/snags - List snags for a magic link
        - GET /api/v1/snags/:snagId/completions - List all completions for a snag (auth required)

        Uploads:
        - POST /api/v1/uploads/photo - Upload a photo (multipart form data)

        Analytics:
        - POST /api/v1/events - Batch analytics events (auth optional; see ANALYTICS_EVENTS.md)
        - POST /api/v1/diagnostics - MetricKit diagnostic payloads (auth optional)

        Config:
        - GET /api/v1/config/feature-flags - Remote feature flags (auth optional)

        Devices:
        - POST /api/v1/devices/register - Register device for push notifications (auth required)
        - DELETE /api/v1/devices/unregister - Unregister device token (auth required)
        """
    }

    // MARK: - Apple App Site Association (B7)
    // Serves the AASA with no extension + application/json so iOS opens the app for our
    // universal-link paths. `/auth/*` is the magic-link sign-in path (B1); `/m/*` is the
    // contractor magic link. TEAMID 52ZZHYHM62 — confirm with the iOS team before deploy.
    app.get(".well-known", "apple-app-site-association") { req -> Response in
        let json = """
        {
          "applinks": {
            "details": [{
              "appIDs": ["52ZZHYHM62.com.snaglist.app"],
              "components": [
                { "/": "/auth/*" },
                { "/": "/m/*" }
              ]
            }]
          },
          "appclips": {
            "apps": ["52ZZHYHM62.com.snaglist.app.Clip"]
          }
        }
        """
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(string: json)
        )
    }

    // MARK: - Magic-link universal-link fallback (B1)
    // The OS opens the Snaglist app directly when this universal link is tapped on a device
    // with the app installed + AASA configured. This route is only hit as a fallback (app not
    // installed, or link opened in a browser). The server NEVER verifies the token here — the
    // iOS app verifies via POST /api/v1/auth/magic-link/verify.
    app.get("auth", ":token") { req -> Response in
        let token = req.parameters.get("token") ?? ""
        let userAgent = IPAddressExtractor.extractUserAgent(from: req) ?? ""
        let isIOS = userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod")
        let html = MagicLinkLandingRenderer.render(token: token, isIOS: isIOS)
        return Response(
            status: .ok,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: html)
        )
    }

    // MARK: - Legal Pages
    app.get("privacy") { req async -> Response in
        let html = LegalPageRenderer.privacyPolicy()
        return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(string: html))
    }

    app.get("terms") { req async -> Response in
        let html = LegalPageRenderer.termsOfService()
        return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(string: html))
    }

    // MARK: - Controllers
    try app.register(collection: WebReportController())
    try app.register(collection: MagicLinkController())
    try app.register(collection: TeamInviteController())
    try app.register(collection: CompletionController())
    try app.register(collection: ContentReportController())
    try app.register(collection: UploadController())
    try app.register(collection: AuthController())
    try app.register(collection: BrowserAuthController())
    try app.register(collection: WorkspaceController())
    try app.register(collection: PlatformProjectController())
    try app.register(collection: PlatformSnagController())
    try app.register(collection: RegisterSyncController())
    try app.register(collection: WorkspaceDirectoryController())
    try app.register(collection: DeviceController())
    try app.register(collection: ProjectController())
    try app.register(collection: SnagController())
    try app.register(collection: ContractorController())
    try app.register(collection: TradeController())
    try app.register(collection: TeamController())
    try app.register(collection: UserProfileController())
    try app.register(collection: AnalyticsController())
    try app.register(collection: ApprovalController())
    try app.register(collection: ConfigController())
}

// MARK: - Response Models

struct HealthResponse: Content {
    let status: String
    let version: String
    let timestamp: Date
}
