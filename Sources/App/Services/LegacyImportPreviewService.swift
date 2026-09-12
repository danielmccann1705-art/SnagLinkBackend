import Vapor
import Fluent
import FluentSQL

struct LegacyImportPreviewService {
    static let contractVersion = "legacy-identity-preflight-v1-no-import"
    static let lifetime: TimeInterval = 30 * 60
    private struct Scan {
        let table: String
        let idColumn: String
        let scopeExpression: String
        let revisionExpression: String
    }
    // SQL fragments are internal constants, never derived from request strings.
    private static let scopes: [String: [Scan]] = [
        "projects": [.init(table: "projects", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(updated_at::text, '') || ':' || COALESCE(archived_at::text, '') || ':' || platform_managed::text")],
        "snags": [.init(table: "snags", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(updated_at::text, '')"),
                  .init(table: "snag_deletions", idColumn: "snag_id", scopeExpression: "NULL::uuid", revisionExpression: "id::text || ':' || COALESCE(created_at::text, '')")],
        "photos": [.init(table: "media_assets", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || state"),
                   .init(table: "synced_photos", idColumn: "id", scopeExpression: "NULL::uuid", revisionExpression: "id::text || ':' || COALESCE(created_at::text, '')")],
        "drawings": [.init(table: "drawings", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(archived_at::text, '')"),
                     .init(table: "synced_drawings", idColumn: "drawing_id", scopeExpression: "NULL::uuid", revisionExpression: "id::text || ':' || COALESCE(created_at::text, '')")],
        "contractors": [.init(table: "contractors", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(updated_at::text, '')")],
        "trades": [.init(table: "trades", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(updated_at::text, '')")],
        "comments": [.init(table: "project_comments", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text")],
        // Native deletionReceipts contain deleted snag UUIDs, not server receipt IDs.
        "deletionReceipts": [.init(table: "snags", idColumn: "id", scopeExpression: "workspace_id", revisionExpression: "revision::text || ':' || COALESCE(updated_at::text, '')"),
                             .init(table: "snag_deletions", idColumn: "snag_id", scopeExpression: "NULL::uuid", revisionExpression: "id::text || ':' || COALESCE(created_at::text, '')")]
    ]

    /// Caller supplies one DB transaction. This never calls ProjectAccessService.require
    /// or workspace discovery, which may attach legacy projects/create personal teams.
    /// The only durable write is the diagnostic mutation_receipt; no reservation occurs.
    static func preview(_ command: LegacyImportPreviewCommand, workspaceID: UUID, actorID: UUID,
                        binding: ImportServerBinding, on db: Database, now: Date = Date()) async throws -> LegacyImportPreviewResponse {
        try command.validate()
        guard command.expectedActorId == actorID, command.destination == binding.destination else {
            throw Abort(.conflict, reason: "The selected account or API environment changed. Prepare a new preview for the explicit destination", identifier: "import_preview_binding_changed")
        }
        let requestHash = try PlatformMutationService.requestHash(command, route: "POST:/api/v2/workspaces/\(workspaceID)/import-previews")
        try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
        try await WorkspaceAccessService.lock(workspaceID, on: db)
        guard let workspace = try await Team.find(workspaceID, on: db) else { throw Abort(.notFound, reason: "Workspace unavailable") }
        let role = try await WorkspaceAccessService.role(actorID: actorID, workspace: workspace, on: db)
        guard ["owner", "admin"].contains(role) else { throw Abort(.forbidden, reason: "Ask a workspace owner or admin to prepare this preview") }
        guard workspace.kind == command.expectedWorkspaceKind else {
            throw Abort(.conflict, reason: "The selected workspace kind changed", identifier: "import_preview_binding_changed")
        }
        let sql = try VerifiedIdentityService.sql(db)
        let member = try await sql.raw("SELECT role, state, revision FROM workspace_memberships WHERE workspace_id = \(bind: workspaceID) AND user_id = \(bind: actorID)").first()
        let user = try await VerifiedIdentityService.activeUser(actorID, on: db)
        var facts = [contractVersion, binding.environment, binding.apiOrigin, actorID.uuidString, String(user.authVersion), workspaceID.uuidString,
                     workspace.kind, workspace.ownerUserId.uuidString, workspace.lifecycleState, String(workspace.revision), role]
        if let member {
            facts += try [member.decode(column: "role", as: String.self), member.decode(column: "state", as: String.self), String(member.decode(column: "revision", as: Int64.self))]
        } else { facts.append("no-membership-row") }

        var collisions: [LegacyImportPreviewResponse.Collision] = [], identities: [LegacyImportPreviewResponse.IdentityCheck] = []
        var collisionKeys = Set<String>(), collisionFacts: [String] = []
        for kind in LegacyImportPreviewCommand.kinds.sorted() {
            let ids = command.recordIds[kind]!, scans = scopes[kind] ?? []
            identities.append(.init(kind: kind, sourceIds: ids, count: ids.count, namespacesChecked: scans.map(\.table),
                                    scope: scans.isEmpty ? "no_canonical_identity_namespace_checked" : "declared_ids_only_not_graph_validation"))
            for scan in scans {
                for offset in stride(from: 0, to: ids.count, by: 400) {
                    let batch = Array(ids[offset..<min(offset + 400, ids.count)])
                    let rows = try await sql.raw("""
                        SELECT \(unsafeRaw: scan.idColumn) AS source_id, \(unsafeRaw: scan.scopeExpression) AS workspace_id,
                               \(unsafeRaw: scan.revisionExpression) AS revision_fact
                        FROM \(unsafeRaw: scan.table) WHERE \(unsafeRaw: scan.idColumn) = ANY(\(bind: batch)) LIMIT 20001
                        """).all()
                    guard collisionFacts.count + rows.count <= 20_000 else { throw LegacyImportPreviewCommand.oversized() }
                    for row in rows {
                        let id = try row.decode(column: "source_id", as: UUID.self)
                        let scope = try row.decode(column: "workspace_id", as: UUID?.self)
                        let revision = try row.decode(column: "revision_fact", as: String.self)
                        // Internal fingerprint material only: never return another scope or owner.
                        collisionFacts.append(try PlatformMutationService.encode([kind, scan.table, id.uuidString, scope?.uuidString ?? "unscoped", revision]))
                        let code: String
                        if scope == workspaceID {
                            code = kind == "projects" ? "existing_project_reconciliation_required" : "existing_record_reconciliation_required"
                        } else { code = "identifier_unavailable" }
                        if collisionKeys.insert(kind + id.uuidString + code).inserted {
                            collisions.append(.init(kind: kind, sourceId: id, code: code))
                        }
                    }
                }
            }
        }
        facts += collisionFacts.sorted()
        let fingerprint = try PlatformMutationService.requestHash(facts, route: contractVersion)
        // Replays never bypass current actor, lifecycle, membership or collision checks.
        if let old = try await PlatformMutationService.replay(LegacyImportPreviewResponse.self, actorID: actorID, mutation: command.mutation, hash: requestHash, on: db) {
            guard old.actorId == actorID, old.workspaceId == workspaceID, old.destination == binding.destination,
                  old.expiresAt > now, old.previewFingerprint == fingerprint else {
                throw Abort(.conflict, reason: "This preview expired or its destination facts changed. Keep its receipt and request a new preview with a new operation ID", identifier: "import_preview_stale")
            }
            return old
        }
        var blockers: Set<String> = ["import_commit_not_implemented", "source_bytes_not_verified", "graph_content_not_validated", "ownership_consent_not_recorded"]
        if !collisions.isEmpty { blockers.insert("identifier_reconciliation_required") }
        if !command.recordIds["snags"]!.isEmpty || command.requirements["legacyReferenceCount"]! > 0 { blockers.insert("historical_reference_mapping_not_implemented") }
        if !command.recordIds["statusHistory"]!.isEmpty || command.requirements["localClosureCount"]! > 0 { blockers.insert("historical_status_is_not_canonical_acceptance") }
        if !command.recordIds["comments"]!.isEmpty { blockers.insert("historical_comment_provenance_not_implemented") }
        if !command.recordIds["photos"]!.isEmpty || command.requirements["coverCount"]! > 0 || command.requirements["attachmentCount"]! > 0 || command.requirements["deletionMediaCount"]! > 0 { blockers.insert("media_source_graph_import_not_implemented") }
        if !command.recordIds["drawings"]!.isEmpty || command.requirements["pinCount"]! > 0 || command.requirements["unresolvedDrawingAssociationCount"]! > 0 { blockers.insert("drawing_source_graph_import_not_implemented") }
        if !command.recordIds["folders"]!.isEmpty || !command.recordIds["tags"]!.isEmpty { blockers.insert("organisation_graph_import_not_implemented") }
        if !command.recordIds["contractors"]!.isEmpty || !command.recordIds["trades"]!.isEmpty { blockers.insert("directory_assignment_import_not_implemented") }
        if !command.recordIds["deletionReceipts"]!.isEmpty { blockers.insert("legacy_deletion_reconciliation_not_implemented") }
        if ["sourceFindingCount", "relationshipFindingCount", "missingMediaReferenceCount", "unsafeMediaReferenceCount"].contains(where: { command.requirements[$0]! > 0 }) { blockers.insert("source_findings_require_review") }
        if !Set(command.recordIds["snags"]!).isDisjoint(with: command.recordIds["deletionReceipts"]!) { blockers.insert("source_live_and_deleted_snag_conflict") }
        let result = LegacyImportPreviewResponse(formatVersion: 1, state: "preview_only", importExecutable: false,
            sourceBytesVerified: false, graphContentValidation: "not_performed", ownershipConsent: "not_recorded",
            operationId: command.mutation.operationId, deviceId: command.mutation.deviceId, actorId: actorID, workspaceId: workspaceID,
            workspaceKind: workspace.kind, workspaceRevision: workspace.revision, actorRole: role,
            destination: binding.destination, source: command.source, requestHash: requestHash, previewFingerprint: fingerprint,
            checks: ["bounded_identity_manifest", "current_actor_and_workspace_authority", "configured_api_binding", "declared_id_collisions", "known_import_capability_gaps"],
            identities: identities, collisions: collisions.sorted { ($0.kind, $0.sourceId.uuidString, $0.code) < ($1.kind, $1.sourceId.uuidString, $1.code) },
            blockers: blockers.sorted(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime))
        try await PlatformMutationService.record(result, actorID: actorID, workspaceID: workspaceID, mutation: command.mutation, hash: requestHash, on: db)
        return result
    }
}
