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

        Magic Links:
        - GET /api/v1/magic-links/:linkId/validate - Validate a magic link token
        - POST /api/v1/magic-links/:linkId/verify-pin - Verify PIN for magic link
        - POST /api/v1/magic-links - Create a new magic link (auth required)
        - GET /api/v1/magic-links - List your magic links (auth required)
        - DELETE /api/v1/magic-links/:linkId - Revoke a magic link (auth required)
        - GET /api/v1/magic-links/:linkId/analytics - Get magic link analytics (auth required)
        - GET /api/v1/magic-links/:linkId/pdf - Download PDF report of snags
        - GET /api/v1/magic-links/:linkId/qr - Generate QR code image (PNG)
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

        Devices:
        - POST /api/v1/devices/register - Register device for push notifications (auth required)
        - DELETE /api/v1/devices/unregister - Unregister device token (auth required)
        """
    }

    // MARK: - Apple App Site Association
    app.get(".well-known", "apple-app-site-association") { req -> Response in
        let json = """
        {
          "applinks": {
            "details": [{
              "appIDs": ["52ZZHYHM62.com.snaglist.app"],
              "components": [{ "/": "/m/*" }]
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
    try app.register(collection: UploadController())
    try app.register(collection: AuthController())
    try app.register(collection: DeviceController())
    try app.register(collection: ProjectController())
    try app.register(collection: SnagController())
    try app.register(collection: ContractorController())
    try app.register(collection: TradeController())
    try app.register(collection: TeamController())
    try app.register(collection: UserProfileController())
}

// MARK: - Response Models

struct HealthResponse: Content {
    let status: String
    let version: String
    let timestamp: Date
}
