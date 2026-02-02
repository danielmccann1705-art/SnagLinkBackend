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

        Magic Links:
        - GET /api/v1/magic-links/:linkId/validate - Validate a magic link token
        - POST /api/v1/magic-links/:linkId/verify-pin - Verify PIN for magic link
        - POST /api/v1/magic-links - Create a new magic link (auth required)
        - GET /api/v1/magic-links - List your magic links (auth required)
        - DELETE /api/v1/magic-links/:linkId - Revoke a magic link (auth required)
        - GET /api/v1/magic-links/:linkId/analytics - Get magic link analytics (auth required)
        - GET /api/v1/magic-links/:linkId/pdf - Download PDF report of snags
        - GET /api/v1/magic-links/:linkId/qr - Generate QR code image (PNG)

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

        Uploads:
        - POST /api/v1/uploads/photo - Upload a photo (multipart form data)
        """
    }

    // MARK: - Controllers
    try app.register(collection: MagicLinkController())
    try app.register(collection: TeamInviteController())
    try app.register(collection: CompletionController())
    try app.register(collection: UploadController())
}

// MARK: - Response Models

struct HealthResponse: Content {
    let status: String
    let version: String
    let timestamp: Date
}
