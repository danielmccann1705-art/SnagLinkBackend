import Fluent
import Vapor

func routes(_ app: Application) throws {
    // MARK: - Health Check
    app.get("health") { req async -> HealthResponse in
        // The request half of the log-stream probe. A no-op in every deployment
        // that did not ask for one. Health is the right place for it: it is
        // reached on a schedule and on demand, it takes no argument, and it
        // carries nothing of anybody's, so driving the probe cannot put a path,
        // a token or an identifier anywhere near a log line.
        LogStreamProbe.emitRequest(req)
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
        - POST /api/v1/auth/logout - Sign out this app session only (auth required)
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
    // universal-link paths. `/auth/*` is the magic-link sign-in path (B1) and is the only
    // one: a manager tapping their own sign-in link should land in the app.
    //
    // `/m/*` is deliberately absent. That is the Contractor link, and a contractor opens
    // it in a browser with no account and no app. A manager who happens to have Snaglist
    // installed and taps the same link must reach the same browser page rather than a
    // screen the app has no session for, so this path must not claim the app.
    //
    // `appclips` is deliberately absent too: v2 ships no App Clip, and Apple caches this
    // file, so naming a target that does not exist outlives the mistake.
    // TEAMID 52ZZHYHM62 — confirm with the iOS team before deploy.
    app.get(".well-known", "apple-app-site-association") { req -> Response in
        let json = """
        {
          "applinks": {
            "details": [{
              "appIDs": ["52ZZHYHM62.com.snaglist.app"],
              "components": [
                { "/": "/auth/*" }
              ]
            }]
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
    // iOS app verifies via POST /api/v1/auth/magic-link/verify — and never reads it: the page
    // cannot sign anyone in, says so, and carries no copy of the token. The URL itself holds
    // the token, so the page is never cached and sends no referrer.
    app.get("auth", ":token") { req -> Response in
        let userAgent = IPAddressExtractor.extractUserAgent(from: req) ?? ""
        let isIOS = userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod")
        let html = MagicLinkLandingRenderer.render(isIOS: isIOS)
        return Response(
            status: .ok,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
            ],
            body: .init(string: html)
        )
    }

    // MARK: - Legal pages
    //
    // There is one privacy policy and one set of terms, and they are published on
    // the customer website. This host used to render a second copy of both, which
    // nothing linked to and which drifted: it named a hosting provider we do not
    // use, an unmonitored address, and analytics nobody collects, while the page
    // Apple is given said something else. Two policies that have to be kept in step
    // is a promise nobody can keep, so these redirect to the one that is published
    // rather than restating it. Permanent, and straight to the destination: adding
    // a hop through snaglist.dev would leave a second redirector to maintain.
    app.get("privacy") { _ async -> Response in LegalPageRedirect.privacy }
    app.get("terms") { _ async -> Response in LegalPageRedirect.terms }

    // MARK: - Controllers
    try app.register(collection: WebReportController())
    try app.register(collection: MagicLinkController())
    try app.register(collection: TeamInviteController())
    try app.register(collection: CompletionController())
    try app.register(collection: ContentReportController())
    try app.register(collection: UploadController())
    try app.register(collection: AuthController())
    try app.register(collection: AccountDeletionController())
    try app.register(collection: MaintenanceController())
    try app.register(collection: BrowserAuthController())
    try app.register(collection: GoogleAuthController())
    try app.register(collection: AppleWebAuthController())
    try app.register(collection: WorkspaceController())
    try app.register(collection: CompanyAdministrationController())
    try app.register(collection: LegacyImportPreviewController())
    try app.register(collection: StagedLegacyImportController())
    try app.register(collection: StagedImportFileController())
    try app.register(collection: LegacyImportCommitController())
    try app.register(collection: ImportedProjectController())
    try app.register(collection: PlatformProjectController())
    try app.register(collection: PlatformSnagController())
    try app.register(collection: PrivateMediaController())
    try app.register(collection: CanonicalWorkflowController())
    try app.register(collection: LinkGrantController())
    try app.register(collection: ContractorGrantController())
    try app.register(collection: RegisterSyncController())
    try app.register(collection: ProjectDiscoveryController())
    try app.register(collection: ProjectCommentController())
    try app.register(collection: CanonicalDrawingController())
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
