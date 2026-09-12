import Vapor
import Fluent
import FluentSQL

/// Deployment-selected expected runtime identity. Syntax validation is not proof
/// of image execution or sandbox acceptance. Never decode this from an HTTP body.
struct DrawingProcessorRuntimeIdentity: Sendable, Equatable {
    let processorProfile: String
    let imageDigest: String

    init(processorProfile: String, imageDigest: String) throws {
        let profilePrefix = "drawing-linux-byte-v1:", imagePrefix = "sha256:"
        guard processorProfile.hasPrefix(profilePrefix),
              CanonicalDrawingService.hashValid(String(processorProfile.dropFirst(profilePrefix.count))),
              imageDigest.hasPrefix(imagePrefix),
              CanonicalDrawingService.hashValid(String(imageDigest.dropFirst(imagePrefix.count))) else {
            throw Abort(.serviceUnavailable, reason: "Drawing processor profile is unavailable", identifier: "drawing_processor_unavailable")
        }
        self.processorProfile = processorProfile
        self.imageDigest = imageDigest
    }
}

/// Trusted coordinator context, not a public request or a renderer credential.
/// The lease token stays outside the parser and must never be logged.
struct DrawingProcessingIdentity: Sendable {
    let workspaceId: UUID
    let projectId: UUID
    let assetId: UUID
    let actorId: UUID
    let leaseToken: UUID
    let sourceSHA256: String
    let sourceBytes: Int
    let sourceMIME: String
    let processorProfile: String
}

/// A point-in-time authority result, not a durable storage receipt, signed grant,
/// observed runtime attestation, or permission to skip the final DB transaction.
struct DrawingProcessingStorageScope: Sendable {
    let workspaceId: UUID
    let projectId: UUID
    let assetId: UUID
    let actorId: UUID
    let purpose: DrawingSourcePurpose
    let sha256: String
    let byteCount: Int
    let mimeType: String
    let processorProfile: String
    let leaseExpiresAt: Date
    let attempt: Int
}

enum DrawingProcessingAuthority {
    /// For the private storage adapter's assertCurrent boundary. Re-evaluate
    /// before/after storage IO; never hold this DB transaction across network IO.
    /// Existing finishProcessing remains the final transaction/geometry gate.
    static func requireCurrent(_ expected: DrawingProcessingIdentity,
                               runtime: DrawingProcessorRuntimeIdentity,
                               on database: Database) async throws -> DrawingProcessingStorageScope {
        guard expected.processorProfile == runtime.processorProfile,
              CanonicalDrawingService.hashValid(expected.sourceSHA256),
              ["application/pdf", "image/jpeg", "image/png"].contains(expected.sourceMIME),
              expected.sourceBytes > 0,
              expected.sourceBytes <= (expected.sourceMIME == "application/pdf" ? 52428800 : 10485760) else {
            throw conflict()
        }
        return try await database.transaction { db in
            // Use the expected scope lock before any access-helper re-read.
            // Membership/grant/project services use this same transaction lock.
            try await WorkspaceAccessService.lock(expected.workspaceId, on: db)
            // Do not let the historical require() helper attach an unscoped
            // owner project to a personal workspace while checking authority.
            guard let candidate = try await Project.find(expected.projectId, on: db),
                  candidate.workspaceId == expected.workspaceId,
                  candidate.platformManaged else { throw unavailable() }
            let sql = try VerifiedIdentityService.sql(db)
            guard let row = try await sql.raw("""
                SELECT a.*, j.lease_token, j.lease_expires_at, j.attempt, j.state AS job_state
                FROM drawing_assets a LEFT JOIN drawing_processing_jobs j
                  ON j.asset_id = a.id AND j.project_id = a.project_id
                WHERE a.id = \(bind: expected.assetId) AND a.project_id = \(bind: expected.projectId)
                  AND a.workspace_id = \(bind: expected.workspaceId)
                """).first() else { throw unavailable() }
            // The existing source's non-cascading composite project/workspace
            // FK and source update/delete trigger prevent this scoped project
            // from moving or becoming unscoped before require() re-reads it.
            let project = try await ProjectAccessService.require(.edit, projectID: expected.projectId,
                                                                  actorID: expected.actorId, on: db).0
            try PlatformMutationService.requireManaged(project)
            guard project.workspaceId == expected.workspaceId else { throw unavailable() }
            let asset = try DrawingAssetRecord(row)
            guard asset.uploaderId == expected.actorId else { throw unavailable() }
            // Allocated assets may have no job. Current job columns themselves
            // are NOT NULL, but a LEFT JOIN can yield NULL; reject state first.
            guard try row.decode(column: "purpose", as: String.self) == DrawingSourcePurpose.drawingSource.rawValue,
                  asset.state == "processing", try row.decode(column: "job_state", as: String?.self) == "processing",
                  asset.processorProfile == runtime.processorProfile,
                  asset.sha256 == expected.sourceSHA256, asset.byteCount == expected.sourceBytes,
                  asset.mimeType == expected.sourceMIME else { throw conflict() }
            guard let token = try row.decode(column: "lease_token", as: UUID?.self),
                  let leaseExpiry = try row.decode(column: "lease_expires_at", as: Date?.self),
                  let attempt = try row.decode(column: "attempt", as: Int?.self) else { throw conflict() }
            let now = Date()
            guard token == expected.leaseToken, leaseExpiry > now, asset.expiresAt > now, attempt > 0 else { throw conflict() }
            return .init(workspaceId: expected.workspaceId, projectId: expected.projectId,
                         assetId: asset.id, actorId: expected.actorId, purpose: .drawingSource,
                         sha256: asset.sha256, byteCount: asset.byteCount, mimeType: asset.mimeType,
                         processorProfile: asset.processorProfile,
                         leaseExpiresAt: min(leaseExpiry, asset.expiresAt), attempt: attempt)
        }
    }

    private static func unavailable() -> Abort {
        .init(.notFound, reason: "Drawing processing is unavailable", identifier: "drawing_processing_unavailable")
    }
    private static func conflict() -> Abort {
        .init(.conflict, reason: "Drawing processing authority changed", identifier: "drawing_processing_authority_changed")
    }
}
