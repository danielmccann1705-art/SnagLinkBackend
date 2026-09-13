import Vapor
import Fluent

/// Shared only by authenticated selected-source staging routes.
enum StagedImportRequestBoundary {
    /// Refresh authentication after bounded body decoding; never upgrade a stale
    /// JWT/browser request into a new authVersion merely by loading today's user.
    static func actor(_ req: Request, on database: Database? = nil) async throws -> StagedLegacyImportActor {
        let db = database ?? req.db
        let id = try req.requireAuthenticatedUserId()
        let version: Int
        if let jwt = req.auth.get(UserJWTPayload.self) {
            let current = try await JWTAuthMiddleware.authenticate(req, on: db)
            guard current.userId == id, current.authVersion == jwt.authVersion else { throw Abort(.unauthorized) }
            version = current.authVersion ?? 0
        }
        else if let original = req.auth.get(BrowserPrincipal.self) {
            let current = try await BrowserSessionService.authenticate(req, config: PlatformConfiguration.load(on: req.application), on: db)
            guard current.userID == id, current.sessionID == original.sessionID,
                  let row = try await VerifiedIdentityService.sql(db).raw("SELECT auth_version FROM browser_sessions WHERE id = \(bind: current.sessionID) AND user_id = \(bind: id) AND revoked_at IS NULL AND expires_at > \(bind: Date())").first() else { throw Abort(.unauthorized) }
            version = try row.decode(column: "auth_version", as: Int.self)
        } else { throw Abort(.unauthorized) }
        let user = try await VerifiedIdentityService.activeUser(id, on: db)
        guard user.authVersion == version else { throw Abort(.unauthorized) }
        return .init(id: id, authVersion: version)
    }
    /// Called inside the current source workspace/user transaction after IO.
    /// Recheck the original credential, then lock browser revocation until commit.
    static func receiptAuthentication(_ req: Request, actor original: StagedLegacyImportActor, on db: Database) async throws {
        let current = try await actor(req, on: db)
        guard current.id == original.id, current.authVersion == original.authVersion else { throw Abort(.unauthorized) }
        if let principal = req.auth.get(BrowserPrincipal.self) {
            guard try await VerifiedIdentityService.sql(db).raw("SELECT id FROM browser_sessions WHERE id = \(bind: principal.sessionID) AND user_id = \(bind: original.id) AND auth_version = \(bind: original.authVersion) AND revoked_at IS NULL AND expires_at > \(bind: Date()) FOR SHARE").first() != nil else {
                throw Abort(.unauthorized, reason: "Sign in again before resuming this original transfer")
            }
        }
    }
}
