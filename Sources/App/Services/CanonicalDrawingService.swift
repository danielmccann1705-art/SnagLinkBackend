import Vapor
import Fluent
import FluentSQL
import Crypto

/// Internal DRA-01 foundation; deliberately unregistered as an HTTP feature.
/// Before exposing mutations: implement private byte verification/processing,
/// complete graph journalling/bootstrap and Contractor page selection/revocation.
struct CanonicalDrawingService {
    static let processorProfile = "drawing-initial-v1"
    static let maxPages = 100
    static func invalid(_ reason: String = "Invalid drawing metadata") -> Abort { .init(.badRequest, reason: reason) }
    static func conflict(_ reason: String) -> Abort { .init(.conflict, reason: reason) }
    static func hashValid(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }
    static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= maximum && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func project(_ id: UUID, actorID: UUID, on db: Database) async throws -> Project {
        let result = try await ProjectAccessService.require(.edit, projectID: id, actorID: actorID, on: db).0
        try PlatformMutationService.requireManaged(result)
        return result
    }
    static func asset(_ id: UUID, projectID: UUID, on db: Database) async throws -> DrawingAssetRecord {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM drawing_assets WHERE id = \(bind: id) AND project_id = \(bind: projectID)").first() else { throw Abort(.notFound, reason: "Drawing source unavailable") }
        return try .init(row)
    }
    static func owned(_ value: DrawingAssetRecord, actorID: UUID) throws {
        guard value.uploaderId == actorID else { throw Abort(.notFound, reason: "Drawing source unavailable") }
    }
    static func allocate(_ command: DrawingAllocateCommand, projectID: UUID, actorID: UUID, on database: Database) async throws -> DrawingAssetRecord {
        try await allocateConfigured(command, projectID: projectID, actorID: actorID, expectedWorkspaceID: nil, runtime: nil, on: database)
    }
    /// Explicit internal opt-in, not a client field or runtime activation. The
    /// default allocate() contract keeps its historical placeholder profile.
    static func allocateWithExpectedRuntime(_ command: DrawingAllocateCommand, workspaceID: UUID, projectID: UUID,
                                            actorID: UUID, runtime: DrawingProcessorRuntimeIdentity,
                                            on database: Database) async throws -> DrawingAssetRecord {
        try await allocateConfigured(command, projectID: projectID, actorID: actorID,
                                     expectedWorkspaceID: workspaceID, runtime: runtime, on: database)
    }
    private static func allocateConfigured(_ command: DrawingAllocateCommand, projectID: UUID, actorID: UUID,
                                           expectedWorkspaceID: UUID?, runtime: DrawingProcessorRuntimeIdentity?,
                                           on database: Database) async throws -> DrawingAssetRecord {
        guard hashValid(command.sha256), validText(command.originalFilename, maximum: 255),
              !command.originalFilename.contains("/"), !command.originalFilename.contains("\\"),
              ["application/pdf", "image/jpeg", "image/png"].contains(command.mimeType), command.byteCount > 0,
              command.byteCount <= (command.mimeType == "application/pdf" ? 52428800 : 10485760) else { throw invalid() }
        let selectedProfile = runtime?.processorProfile ?? processorProfile
        let route: String
        if let runtime {
            guard let expectedWorkspaceID else { throw invalid() }
            route = "drawing.allocate.expected-runtime:\(expectedWorkspaceID):\(projectID):\(runtime.processorProfile):\(runtime.imageDigest)"
        } else { route = "drawing.allocate:\(projectID)" }
        let hash = try PlatformMutationService.requestHash(command, route: route)
        return try await database.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
            if let expectedWorkspaceID {
                try await WorkspaceAccessService.lock(expectedWorkspaceID, on: db)
                // No source/FK protects scope yet. Hold the project row through
                // the access helper and insert so a concurrent legacy write
                // cannot turn this explicit selection into implicit adoption.
                guard let candidate = try await VerifiedIdentityService.sql(db).raw("""
                    /* drawing-runtime-allocation-scope */
                    SELECT workspace_id, platform_managed FROM projects WHERE id = \(bind: projectID) FOR UPDATE
                    """).first(),
                      try candidate.decode(column: "workspace_id", as: UUID?.self) == expectedWorkspaceID,
                      try candidate.decode(column: "platform_managed", as: Bool.self) else {
                    throw Abort(.notFound, reason: "Drawing source unavailable")
                }
            }
            let project = try await project(projectID, actorID: actorID, on: db)
            if let expectedWorkspaceID, project.workspaceId != expectedWorkspaceID { throw conflict("Drawing project scope changed") }
            if let old = try await PlatformMutationService.replay(DrawingAssetRecord.self, actorID: actorID, mutation: command.mutation, hash: hash, on: db) {
                _ = try await asset(command.id, projectID: projectID, on: db)
                return old
            }
            try await VerifiedIdentityService.lock("entity:drawing-asset:" + command.id.uuidString, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            guard try await sql.raw("SELECT 1 FROM drawing_assets WHERE id = \(bind: command.id)").first() == nil else { throw conflict("Drawing source ID already exists") }
            let now = Date(), expires = now.addingTimeInterval(86400)
            let key = "drawings/\(project.workspaceId!)/\(projectID)/\(command.id)/original"
            try await sql.raw("""
                INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,original_mime,original_filename,original_key,processor_profile,state,revision,created_at,expires_at)
                VALUES(\(bind: command.id),\(bind: project.workspaceId!),\(bind: projectID),\(bind: actorID),'drawing_source',\(bind: command.sha256),\(bind: command.byteCount),\(bind: command.mimeType),\(bind: command.originalFilename),\(bind: key),\(bind: selectedProfile),'allocated',1,\(bind: now),\(bind: expires))
                """).run()
            let result = try await asset(command.id, projectID: projectID, on: db)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: command.mutation, hash: hash, on: db)
            return result
        }
    }
    /// A real worker must validate/store original bytes outside this transaction,
    /// then supply verified output to finishProcessing. Expired jobs may be reclaimed;
    /// an old lease can never finish after another worker has acquired the asset.
    static func beginProcessing(assetID: UUID, projectID: UUID, actorID: UUID, on database: Database) async throws -> DrawingProcessingLease {
        try await database.transaction { db in
            _ = try await project(projectID, actorID: actorID, on: db)
            let value = try await asset(assetID, projectID: projectID, on: db)
            try owned(value, actorID: actorID)
            let now = Date(), sql = try VerifiedIdentityService.sql(db)
            guard value.expiresAt > now, ["allocated", "processing"].contains(value.state) else { throw conflict("This drawing source cannot start processing") }
            if let existing = try await sql.raw("SELECT lease_expires_at FROM drawing_processing_jobs WHERE asset_id = \(bind: assetID)").first(), try existing.decode(column: "lease_expires_at", as: Date.self) > now {
                throw conflict("Drawing processing is already leased")
            }
            let token = UUID(), expires = now.addingTimeInterval(300)
            try await sql.raw("""
                INSERT INTO drawing_processing_jobs(asset_id,project_id,lease_token,lease_expires_at,attempt,state)
                VALUES(\(bind: assetID),\(bind: projectID),\(bind: token),\(bind: expires),1,'processing')
                ON CONFLICT(asset_id) DO UPDATE SET lease_token = EXCLUDED.lease_token, lease_expires_at = EXCLUDED.lease_expires_at, attempt = drawing_processing_jobs.attempt + 1
                """).run()
            try await sql.raw("UPDATE drawing_assets SET state = 'processing', revision = revision + 1 WHERE id = \(bind: assetID)").run()
            return .init(assetId: assetID, projectId: projectID, actorId: actorID, token: token, expiresAt: expires)
        }
    }
    static func validate(_ manifest: DrawingProcessingManifest, asset: DrawingAssetRecord) throws {
        guard manifest.sourceSHA256 == asset.sha256, manifest.sourceBytes == asset.byteCount,
              manifest.sourceMIME == asset.mimeType, manifest.processorProfile == asset.processorProfile,
              (1...maxPages).contains(manifest.pages.count), Set(manifest.pages.map(\.sourcePageIndex)) == Set(0..<manifest.pages.count),
              asset.mimeType == "application/pdf" || manifest.pages.count == 1 else { throw invalid("Processed source does not match its allocation") }
        var total = 0
        for page in manifest.pages {
            guard validText(page.sourcePageLabel, maximum: 100), hashValid(page.renditionSHA256), hashValid(page.thumbnailSHA256),
                  (1...10485760).contains(page.renditionBytes), (1...10485760).contains(page.thumbnailBytes) else { throw invalid("Invalid processed page manifest") }
            try DrawingGeometryValidation.validate(page.geometry, mime: asset.mimeType)
            total += page.renditionBytes + page.thumbnailBytes
        }
        guard total <= 268435456 else { throw invalid("Processed drawing exceeds the bounded output size") }
    }
    static func pageID(assetID: UUID, index: Int) -> UUID {
        // RFC 4122 UUIDv5: a fixed namespace and immutable asset/page identity.
        let namespace = UUID(uuidString: "266FB6C8-2B63-58A1-9A9D-5604571BB97D")!
        var input = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        input.append(Data("\(assetID.uuidString.lowercased()):\(index)".utf8))
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        let a = Array(h)
        return UUID(uuidString: String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32]))!
    }
    static func manifestHash(_ manifest: DrawingProcessingManifest) throws -> String {
        let ordered = DrawingProcessingManifest(sourceSHA256: manifest.sourceSHA256, sourceBytes: manifest.sourceBytes,
            sourceMIME: manifest.sourceMIME, processorProfile: manifest.processorProfile,
            pages: manifest.pages.sorted { $0.sourcePageIndex < $1.sourcePageIndex })
        return SHA256Hasher.hash(token: try PlatformMutationService.encode(ordered))
    }
    static func finishProcessing(_ lease: DrawingProcessingLease, manifest: DrawingProcessingManifest, on database: Database) async throws -> DrawingAssetRecord {
        try await database.transaction { db in
            let project = try await project(lease.projectId, actorID: lease.actorId, on: db)
            let value = try await asset(lease.assetId, projectID: lease.projectId, on: db)
            try owned(value, actorID: lease.actorId); try validate(manifest, asset: value)
            let resultHash = try manifestHash(manifest), sql = try VerifiedIdentityService.sql(db)
            guard let job = try await sql.raw("SELECT * FROM drawing_processing_jobs WHERE asset_id = \(bind: lease.assetId) AND project_id = \(bind: lease.projectId) AND lease_token = \(bind: lease.token)").first() else { throw conflict("Processing lease was replaced") }
            // Exact completed retries are safe even after the lease time; current ACL is still required.
            if value.state == "ready" {
                let stored = try await sql.raw("SELECT result_hash FROM drawing_assets WHERE id = \(bind: lease.assetId)").first()!.decode(column: "result_hash", as: String.self)
                guard stored == resultHash else { throw conflict("Processed output is immutable") }
                return value
            }
            guard value.state == "processing", value.expiresAt > Date(), try job.decode(column: "lease_expires_at", as: Date.self) > Date() else { throw conflict("Processing lease expired") }
            for page in manifest.pages.sorted(by: { $0.sourcePageIndex < $1.sourcePageIndex }) {
                let id = pageID(assetID: value.id, index: page.sourcePageIndex)
                let prefix = "drawings/\(project.workspaceId!)/\(lease.projectId)/\(value.id)/pages/\(id)"
                try await sql.raw("""
                    INSERT INTO drawing_asset_pages(id,asset_id,project_id,source_page_index,source_page_label,geometry_json,rendition_key,rendition_sha256,rendition_size,thumbnail_key,thumbnail_sha256,thumbnail_size)
                    VALUES(\(bind: id),\(bind: value.id),\(bind: lease.projectId),\(bind: page.sourcePageIndex),\(bind: page.sourcePageLabel),\(bind: PlatformMutationService.encode(page.geometry)),\(bind: prefix + "/" + page.renditionSHA256 + ".jpg"),\(bind: page.renditionSHA256),\(bind: page.renditionBytes),\(bind: prefix + "/thumb-" + page.thumbnailSHA256 + ".jpg"),\(bind: page.thumbnailSHA256),\(bind: page.thumbnailBytes))
                    """).run()
            }
            try await sql.raw("UPDATE drawing_assets SET state = 'ready', ready_at = \(bind: Date()), result_hash = \(bind: resultHash), revision = revision + 1 WHERE id = \(bind: value.id)").run()
            try await sql.raw("UPDATE drawing_processing_jobs SET state = 'complete' WHERE asset_id = \(bind: value.id)").run()
            return try await asset(value.id, projectID: lease.projectId, on: db)
        }
    }
    static func readAsset(_ id: UUID, projectID: UUID, actorID: UUID, on database: Database) async throws -> DrawingAssetRecord {
        try await database.transaction { db in
            let project = try await ProjectAccessService.require(.read, projectID: projectID, actorID: actorID, on: db).0
            try PlatformMutationService.requireManaged(project)
            let value = try await asset(id, projectID: projectID, on: db)
            guard value.publishedAt != nil || value.uploaderId == actorID else { throw Abort(.notFound, reason: "Drawing source unavailable") }
            return value
        }
    }
    static func publish(_ command: DrawingPublishCommand, projectID: UUID, actorID: UUID, on database: Database) async throws -> DrawingPublicationRecord {
        guard command.expectedAssetRevision > 0, command.acknowledgeInternalOriginalAccess,
              (1...maxPages).contains(command.sheets.count),
              Set(command.sheets.map(\.id)).count == command.sheets.count,
              Set(command.sheets.map(\.versionId)).count == command.sheets.count,
              Set(command.sheets.map(\.versionPageId)).count == command.sheets.count,
              Set(command.sheets.map(\.sourcePageIndex)).count == command.sheets.count,
              command.sheets.allSatisfy({ validText($0.name, maximum: 200) && Int32(exactly: $0.sortOrder) != nil && (0..<maxPages).contains($0.sourcePageIndex) }) else { throw invalid("Select valid sheets and acknowledge internal original-source access") }
        let hash = try PlatformMutationService.requestHash(command, route: "drawing.publish:\(projectID)")
        return try await database.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
            let project = try await project(projectID, actorID: actorID, on: db)
            let source = try await asset(command.assetId, projectID: projectID, on: db); try owned(source, actorID: actorID)
            if let old = try await PlatformMutationService.replay(DrawingPublicationRecord.self, actorID: actorID, mutation: command.mutation, hash: hash, on: db) { return old }
            guard source.state == "ready", source.revision == command.expectedAssetRevision,
                  source.publishedAt != nil || source.expiresAt > Date() else { throw conflict("Refresh the ready drawing source before publication") }
            let sql = try VerifiedIdentityService.sql(db), now = Date()
            // Global entity locks in deterministic order avoid cross-workspace ID races.
            let locks = command.sheets.flatMap { ["drawing:\($0.id)","drawing-version:\($0.versionId)","drawing-page:\($0.versionPageId)"] }.sorted()
            for key in locks { try await VerifiedIdentityService.lock("entity:" + key, on: db) }
            for sheet in command.sheets {
                guard try await sql.raw("SELECT 1 FROM drawings WHERE id = \(bind: sheet.id)").first() == nil,
                      try await sql.raw("SELECT 1 FROM drawing_versions WHERE id = \(bind: sheet.versionId)").first() == nil,
                      try await sql.raw("SELECT 1 FROM drawing_version_pages WHERE id = \(bind: sheet.versionPageId)").first() == nil else { throw conflict("A sheet/version ID already exists; replacement is not supported") }
                guard let page = try await sql.raw("SELECT id FROM drawing_asset_pages WHERE asset_id = \(bind: source.id) AND project_id = \(bind: projectID) AND source_page_index = \(bind: sheet.sourcePageIndex)").first() else { throw invalid("Selected page has not been processed") }
                let pageID = try page.decode(column: "id", as: UUID.self)
                try await sql.raw("""
                    INSERT INTO drawings(id,workspace_id,project_id,name,sort_order,revision,current_version_id,created_by,created_at,updated_at)
                    VALUES(\(bind: sheet.id),\(bind: project.workspaceId!),\(bind: projectID),\(bind: sheet.name),\(bind: sheet.sortOrder),1,\(bind: sheet.versionId),\(bind: actorID),\(bind: now),\(bind: now))
                    """).run()
                try await sql.raw("INSERT INTO drawing_versions(id,drawing_id,project_id,asset_id,version_number,published_by,published_at) VALUES(\(bind: sheet.versionId),\(bind: sheet.id),\(bind: projectID),\(bind: source.id),1,\(bind: actorID),\(bind: now))").run()
                try await sql.raw("INSERT INTO drawing_version_pages(id,version_id,drawing_id,asset_id,asset_page_id,project_id,page_index) VALUES(\(bind: sheet.versionPageId),\(bind: sheet.versionId),\(bind: sheet.id),\(bind: source.id),\(bind: pageID),\(bind: projectID),0)").run()
            }
            try await sql.raw("UPDATE drawing_assets SET published_at = COALESCE(published_at,\(bind: now)), revision = revision + 1 WHERE id = \(bind: source.id)").run()
            let result = DrawingPublicationRecord(projectId: projectID, assetId: source.id, sheets: command.sheets)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: command.mutation, hash: hash, on: db)
            return result
        }
    }
    static func setPin(_ command: DrawingPinCommand, snagID: UUID, projectID: UUID, actorID: UUID, on database: Database) async throws -> DrawingPinRecord {
        guard command.expectedSnagRevision > 0, command.expectedPinRevision >= 0 else { throw invalid() }
        if let pin = command.pin { guard pin.x.isFinite, pin.y.isFinite, (0...1).contains(pin.x), (0...1).contains(pin.y) else { throw invalid("Pin coordinates must be inside the displayed page") } }
        let hash = try PlatformMutationService.requestHash(command, route: "drawing.pin:\(projectID):\(snagID)")
        return try await database.transaction { db in
            try await PlatformMutationService.lock(actorID: actorID, mutation: command.mutation, on: db)
            let project = try await project(projectID, actorID: actorID, on: db)
            guard let snag = try await Snag.find(snagID, on: db), snag.projectId == projectID else { throw Abort(.notFound, reason: "Snag unavailable") }
            if let old = try await PlatformMutationService.replay(DrawingPinRecord.self, actorID: actorID, mutation: command.mutation, hash: hash, on: db) { return old }
            // Recover the exact committed result after later submission/archive.
            // Current project/snag scope and permission were checked above; no state is rewritten.
            guard snag.archivedAt == nil, !["closed", "awaiting_review"].contains(snag.status) else { throw conflict("Review or reopen this snag before changing its drawing pin") }
            try await PlatformMutationService.checkRevision(command.expectedSnagRevision, snag: snag, workspaceID: project.workspaceId!, on: db)
            let sql = try VerifiedIdentityService.sql(db)
            let current = try await sql.raw("SELECT * FROM snag_drawing_pins WHERE snag_id = \(bind: snagID) AND project_id = \(bind: projectID)").first()
            let previousRevision = try current?.decode(column: "revision", as: Int64.self) ?? 0
            guard previousRevision == command.expectedPinRevision else { throw conflict("Drawing pin changed; retain your draft and refresh") }
            if current == nil && (snag.drawingId != nil || snag.drawingPinX != nil || snag.drawingPinY != nil) { throw conflict("Import the existing drawing pin before changing it") }
            let previousPage = try current?.decode(column: "version_page_id", as: UUID?.self) ?? nil
            let previousX = try current?.decode(column: "x", as: Double?.self) ?? nil
            let previousY = try current?.decode(column: "y", as: Double?.self) ?? nil
            guard command.pin != nil || previousPage != nil else { throw conflict("There is no active pin to remove") }
            if let pin = command.pin {
                guard try await sql.raw("""
                    SELECT 1 FROM drawing_version_pages p JOIN drawings d ON d.id = p.drawing_id AND d.project_id = p.project_id
                    JOIN drawing_assets a ON a.id = p.asset_id AND a.project_id = p.project_id
                    WHERE p.id = \(bind: pin.versionPageId) AND p.version_id = \(bind: pin.versionId) AND p.drawing_id = \(bind: pin.drawingId) AND p.project_id = \(bind: projectID)
                    AND d.archived_at IS NULL AND a.state = 'ready' AND a.published_at IS NOT NULL
                    """).first() != nil else { throw Abort(.notFound, reason: "Drawing page unavailable") }
            }
            let pin = command.pin, revision = previousRevision + 1, now = Date(), deletedAt: Date? = pin == nil ? now : nil
            snag.drawingId = pin?.drawingId; snag.drawingPinX = pin?.x; snag.drawingPinY = pin?.y
            snag.revision += 1; try await snag.save(on: db)
            try await sql.raw("""
                INSERT INTO snag_drawing_pins(snag_id,project_id,drawing_id,version_id,version_page_id,x,y,revision,snag_revision,recorded_by,recorded_at,deleted_at)
                VALUES(\(bind: snagID),\(bind: projectID),\(bind: pin?.drawingId),\(bind: pin?.versionId),\(bind: pin?.versionPageId),\(bind: pin?.x),\(bind: pin?.y),\(bind: revision),\(bind: snag.revision),\(bind: actorID),\(bind: now),\(bind: deletedAt))
                ON CONFLICT(snag_id) DO UPDATE SET drawing_id=EXCLUDED.drawing_id,version_id=EXCLUDED.version_id,version_page_id=EXCLUDED.version_page_id,x=EXCLUDED.x,y=EXCLUDED.y,revision=EXCLUDED.revision,snag_revision=EXCLUDED.snag_revision,recorded_by=EXCLUDED.recorded_by,recorded_at=EXCLUDED.recorded_at,deleted_at=EXCLUDED.deleted_at
                """).run()
            let eventID = UUID(), action = pin == nil ? "removed" : (previousPage == nil ? "placed" : "moved")
            try await sql.raw("""
                INSERT INTO drawing_pin_events(id,snag_id,project_id,pin_revision,snag_revision,previous_page_id,previous_x,previous_y,next_page_id,next_x,next_y,action,actor_id,recorded_at)
                VALUES(\(bind: eventID),\(bind: snagID),\(bind: projectID),\(bind: revision),\(bind: snag.revision),\(bind: previousPage),\(bind: previousX),\(bind: previousY),\(bind: pin?.versionPageId),\(bind: pin?.x),\(bind: pin?.y),\(bind: action),\(bind: actorID),\(bind: now))
                """).run()
            let result = DrawingPinRecord(snagId: snagID, projectId: projectID, revision: revision, snagRevision: snag.revision, pin: pin, eventId: eventID, recordedBy: actorID)
            try await PlatformMutationService.record(result, actorID: actorID, workspaceID: project.workspaceId!, mutation: command.mutation, hash: hash, on: db)
            return result
        }
    }
}
