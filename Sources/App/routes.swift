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
        SnagLink Backend API v1

        Endpoints:
        - GET /health - Health check

        Magic Links:
        - GET /api/v1/magic-links/:token/validate - Validate a magic link token
        - POST /api/v1/magic-links/:token/verify-pin - Verify PIN for magic link
        - POST /api/v1/magic-links - Create a new magic link (auth required)
        - GET /api/v1/magic-links - List your magic links (auth required)
        - DELETE /api/v1/magic-links/:id - Revoke a magic link (auth required)
        - GET /api/v1/magic-links/:id/analytics - Get magic link analytics (auth required)

        Team Invites:
        - GET /api/v1/team-invites/:token/validate - Validate a team invite token
        - POST /api/v1/team-invites - Create a new team invite (auth required)
        - GET /api/v1/team-invites/pending - List pending invites (auth required)
        - POST /api/v1/team-invites/:token/accept - Accept a team invite (auth required)
        - POST /api/v1/team-invites/:token/decline - Decline a team invite (auth required)
        - DELETE /api/v1/team-invites/:id - Revoke a team invite (auth required)
        """
    }

    // MARK: - Register Controllers
    try app.register(collection: MagicLinkController())
    try app.register(collection: TeamInviteController())
}

// MARK: - Response Models

struct HealthResponse: Content {
    let status: String
    let version: String
    let timestamp: Date
}
