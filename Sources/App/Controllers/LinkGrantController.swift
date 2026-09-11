import Vapor
import Fluent
import FluentSQL

struct LinkGrantController: RouteCollection {
    struct Page: Content { let items: [LinkGrantResponse]; let page: Int; let hasMore: Bool }
    func boot(routes: RoutesBuilder) throws {
        let links = routes.grouped("api", "v2", "projects", ":projectId", "links").grouped(PlatformAuthMiddleware())
        links.get(use: list)
        links.post("prepare", use: prepare)
        links.get(":grantId", use: get)
        links.post(":grantId", "activate", use: activate)
        links.post(":grantId", "revoke", use: revoke)
    }
    static func id(_ key: String, _ req: Request) throws -> UUID {
        guard let raw = req.parameters.get(key), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; return id
    }
    @Sendable func list(req: Request) async throws -> Page {
        let projectID = try Self.id("projectId", req), actor = try req.requireAuthenticatedUserId()
        let page = try req.query.get(Int?.self, at: "page") ?? 1
        guard (1...1000).contains(page) else { throw Abort(.badRequest) }
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.share, projectID: projectID, actorID: actor, on: db)
            try PlatformMutationService.requireManaged(project)
            let rows = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM link_grants WHERE project_id = \(bind: projectID) ORDER BY created_at DESC, id LIMIT 26 OFFSET \(bind: (page - 1) * 25)").all()
            var values: [LinkGrantResponse] = []
            for row in rows.prefix(25) { values.append(try await LinkGrantService.response(row, on: db)) }
            return .init(items: values, page: page, hasMore: rows.count > 25)
        }
    }
    @Sendable func get(req: Request) async throws -> LinkActivationResponse {
        let projectID = try Self.id("projectId", req), id = try Self.id("grantId", req), actor = try req.requireAuthenticatedUserId()
        return try await req.db.transaction { db in
            let (project, _) = try await ProjectAccessService.require(.share, projectID: projectID, actorID: actor, on: db)
            try PlatformMutationService.requireManaged(project)
            return try await self.activationResponse(id, projectID: projectID, app: req.application, on: db)
        }
    }
    @Sendable func prepare(req: Request) async throws -> LinkGrantResponse {
        let projectID = try Self.id("projectId", req), actor = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(LinkPrepareCommand.self)
        try LinkGrantService.validate(body)
        _ = try LinkGrantTokenService.keys(req.application)
        let hashes = try LinkGrantTokenService.requestHashes(body, route: "POST:\(req.url.path)", app: req.application), hash = hashes[0]
        // Keyed retry fingerprint: a leaked receipt cannot brute-force a short PIN.
        // The PIN-bearing body is never stored; bcrypt protects the grant PIN.
        let pinHash: String?
        if let pin = body.pin { pinHash = try await req.password.async.hash(pin) } else { pinHash = nil }
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            let (project, _) = try await ProjectAccessService.require(.share, projectID: projectID, actorID: actor, on: db)
            if let saved = try await VerifiedIdentityService.sql(db).raw("SELECT request_hash, result_json FROM mutation_receipts WHERE actor_id = \(bind: actor) AND operation_id = \(bind: body.mutation.operationId)").first() {
                guard hashes.contains(try saved.decode(column: "request_hash", as: String.self)) else { throw Abort(.conflict, reason: "Keep the original request when retrying this link", identifier: "operation_reused") }
                return try PlatformMutationService.decode(LinkGrantResponse.self, saved.decode(column: "result_json", as: String.self))
            }
            let result = try await LinkGrantService.prepare(body, pinHash: pinHash, project: project, actorID: actor, on: db)
            try await PlatformMutationService.record(result, actorID: actor, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    @Sendable func activate(req: Request) async throws -> LinkActivationResponse {
        let projectID = try Self.id("projectId", req), id = try Self.id("grantId", req), actor = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(LinkRevisionCommand.self), hash = try PlatformMutationService.requestHash(body, route: "POST:\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            let (project, _) = try await ProjectAccessService.require(.share, projectID: projectID, actorID: actor, on: db)
            try PlatformMutationService.requireManaged(project)
            if try await PlatformMutationService.replay(LinkGrantResponse.self, actorID: actor, mutation: body.mutation, hash: hash, on: db) == nil {
                let row = try await LinkGrantService.row(id, projectID: projectID, on: db)
                let result = try await LinkGrantService.activate(row, expectedRevision: body.expectedRevision, project: project, app: req.application, actorID: actor, on: db)
                try await PlatformMutationService.record(result, actorID: actor, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            }
            // Token never appears in mutation receipts or change feed; replay still
            // checks current permission, expiry and revocation before revealing it.
            return try await self.activationResponse(id, projectID: projectID, app: req.application, on: db)
        }
    }
    private func activationResponse(_ id: UUID, projectID: UUID, app: Application, on db: Database) async throws -> LinkActivationResponse {
        let row = try await LinkGrantService.row(id, projectID: projectID, on: db)
        let result = try await LinkGrantService.response(row, on: db)
        let path: String?
        if result.state == "active", result.expiresAt > Date(), let ciphertext = try row.decode(column: "token_ciphertext", as: String?.self) {
            path = "/m/" + (try LinkGrantTokenService.open(ciphertext, id: id, app: app))
        } else { path = nil }
        return .init(grant: result, contractorPath: path)
    }
    @Sendable func revoke(req: Request) async throws -> LinkGrantResponse {
        let projectID = try Self.id("projectId", req), id = try Self.id("grantId", req), actor = try req.requireAuthenticatedUserId()
        let body = try req.content.decode(LinkRevisionCommand.self), hash = try PlatformMutationService.requestHash(body, route: "POST:\(req.url.path)")
        return try await req.db.transaction { db in
            try await PlatformMutationService.lock(actorID: actor, mutation: body.mutation, on: db)
            let (project, _) = try await ProjectAccessService.require(.share, projectID: projectID, actorID: actor, on: db)
            if let old = try await PlatformMutationService.replay(LinkGrantResponse.self, actorID: actor, mutation: body.mutation, hash: hash, on: db) { return old }
            let row = try await LinkGrantService.row(id, projectID: projectID, on: db)
            if try row.decode(column: "state", as: String.self) != "revoked" {
                guard try row.decode(column: "revision", as: Int64.self) == body.expectedRevision else { throw Abort(.conflict, reason: "This Contractor link changed. Refresh before revoking") }
                try await Self.revoke(id, workspaceID: project.workspaceId!, actorID: actor, on: db)
            }
            let result = try await LinkGrantService.response(LinkGrantService.row(id, projectID: projectID, on: db), on: db)
            try await PlatformMutationService.record(result, actorID: actor, workspaceID: project.workspaceId!, mutation: body.mutation, hash: hash, on: db)
            return result
        }
    }
    static func revoke(_ id: UUID, workspaceID: UUID, actorID: UUID, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        try await sql.raw("UPDATE link_grants SET state = 'revoked', revoked_at = \(bind: Date()), revision = revision + 1, token_ciphertext = NULL WHERE id = \(bind: id) AND state != 'revoked'").run()
        try await sql.raw("DELETE FROM link_sessions WHERE grant_id = \(bind: id)").run()
        try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actorID, action: "contractor_link_revoked", targetID: id, on: db)
    }
    /// Existing native revoke queue sends the raw token; newer clients may use ID.
    /// Possessing that token alone never grants manager revocation authority.
    static func revokeLegacy(_ raw: String, actorID: UUID, on db: Database) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(db), found: SQLRow?
        if let id = UUID(uuidString: raw) { found = try await sql.raw("SELECT id, project_id FROM link_grants WHERE id = \(bind: id)").first() }
        else if raw.hasPrefix("c2_"), raw.count <= 100 { found = try await sql.raw("SELECT id, project_id FROM link_grants WHERE token_hash = \(bind: SHA256Hasher.hash(token: raw))").first() }
        else { return false }
        guard let found else { return false }
        let (project, _) = try await ProjectAccessService.require(.share, projectID: found.decode(column: "project_id", as: UUID.self), actorID: actorID, on: db)
        let row = try await LinkGrantService.row(found.decode(column: "id", as: UUID.self), projectID: project.requireID(), on: db)
        if try row.decode(column: "state", as: String.self) != "revoked" {
            try await revoke(row.decode(column: "id", as: UUID.self), workspaceID: project.workspaceId!, actorID: actorID, on: db)
        }
        return true
    }

}
