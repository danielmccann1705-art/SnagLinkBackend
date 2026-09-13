import Vapor
import Fluent
import FluentSQL

/// One atomic publication of a prepared, processed projection into the canonical
/// graph, its change journal and an append-only commit receipt. Rollback leaves no
/// canonical row, journal event or receipt; retained source/original storage is untouched.
enum LegacyImportCommitService {
    static let coverage = ["importedFiles", "importedPhotos", "drawings", "drawingPins", "importedHistory", "projectOrganisation", "importReceipt"]
    private struct Processing {
        var files: [UUID: SQLRow] = [:]      // declaration_id → legacy_import_file_processing
        var drawings: [UUID: SQLRow] = [:]   // drawing source id → legacy_import_drawing_processing
    }
    private struct Journal { var count = 0 }

    static func blocked(_ reason: String, identifier: String = "import_publication_blocked") -> Abort { .init(.conflict, reason: reason, identifier: identifier) }

    /// Actor-private readiness view: projection receipt, processing summary, blockers.
    static func status(projectionID: UUID, scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                       on database: Database) async throws -> LegacyImportPreparationStatus {
        let projection = try await LegacyCanonicalProjectionService.read(projectionID: projectionID, scope: scope, actor: actor, binding: binding, on: database)
        return try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database, allowPublished: true) { session, db in
            let sql = try VerifiedIdentityService.sql(db)
            guard let row = try await sql.raw("SELECT receipt_json FROM legacy_canonical_projections WHERE id = \(bind: projectionID) AND session_id = \(bind: session.sessionId)").first() else { throw Abort(.notFound) }
            let receipt = try JSONDecoder().decode(LegacyCanonicalProjectionReceipt.self, from: Data(row.decode(column: "receipt_json", as: String.self).utf8))
            let summary = try await LegacyImportProcessingService.summary(projection, session: session, on: db)
            let commit = try await commitReceipt(sessionID: session.sessionId, on: db)
            let blockers = projection.findings.filter { $0.disposition == .blocker }
            return .init(projection: receipt, declaredFileCount: summary.declaredFileCount, receivedFileCount: summary.receivedFileCount,
                processedFileCount: summary.processedFileCount, decodedImageCount: summary.decodedImageCount, opaqueFileCount: summary.opaqueFileCount,
                renderedDrawingCount: summary.renderedDrawingCount, unsupportedDrawingCount: summary.unsupportedDrawingCount,
                missingRequiredFileCount: summary.missingRequiredFileCount, blockers: blockers,
                qualifications: projection.findings.filter { $0.disposition == .qualification },
                readyToPublish: commit == nil && blockers.isEmpty && summary.missingRequiredFileCount == 0 && summary.processedFileCount == summary.receivedFileCount, commit: commit)
        }
    }

    static func receipt(commitID: UUID, scope: StagedLegacyImportScope, actor: StagedLegacyImportActor, binding: ImportServerBinding, on database: Database) async throws -> LegacyImportCommitReceipt {
        try await StagedLegacyImportService.withActiveSession(scope, actor: actor, binding: binding, on: database, allowPublished: true) { session, db in
            guard let receipt = try await commitReceipt(sessionID: session.sessionId, on: db), receipt.commitId == commitID else { throw Abort(.notFound, reason: "No publication receipt exists for this preparation") }
            return receipt
        }
    }
    static func commitReceipt(sessionID: UUID, on db: Database) async throws -> LegacyImportCommitReceipt? {
        guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT receipt_json FROM legacy_import_commits WHERE session_id = \(bind: sessionID)").first() else { return nil }
        return try PlatformMutationService.decode(LegacyImportCommitReceipt.self, row.decode(column: "receipt_json", as: String.self))
    }

    static func commit(_ command: LegacyImportCommitCommand, actor: StagedLegacyImportActor, binding: ImportServerBinding,
                       on database: Database, now: Date = Date()) async throws -> LegacyImportCommitReceipt {
        guard command.acknowledgement.accepted, command.acknowledgement.version == LegacyImportCommitCommand.Acknowledgement.supportedVersion,
              command.acknowledgement.wording == LegacyImportCommitCommand.Acknowledgement.supportedWording else {
            throw Abort(.badRequest, reason: "Explicit acknowledgement of this publication is required", identifier: "import_publication_acknowledgement_required")
        }
        guard command.expectedSourceRevision == 1, CanonicalDrawingService.hashValid(command.expectedGraphSHA256),
              command.commitId != command.projectionId, command.commitId != command.scope.sessionId else { throw StagedLegacyImportService.bindingChanged() }
        let hash = try PlatformMutationService.requestHash(command, route: "PRIVATE:publish-legacy-import:\(command.scope.workspaceId)")
        // Rederived under current authority; immutable source bytes cannot change before the fenced transaction.
        let projection = try await LegacyCanonicalProjectionService.read(projectionID: command.projectionId, scope: command.scope, actor: actor, binding: binding, on: database)
        let graphSHA = try LegacyCanonicalProjectionMapper.digest(projection)
        guard graphSHA == command.expectedGraphSHA256 else { throw blocked("The prepared graph changed since it was reviewed. Refresh the preparation before publishing", identifier: "import_projection_changed") }
        return try await StagedLegacyImportService.withActiveSession(command.scope, actor: actor, binding: binding, on: database, allowPublished: true) { session, db in
            guard session.revision == command.expectedSourceRevision, session.deviceId == command.scope.deviceId else { throw StagedLegacyImportService.bindingChanged() }
            try await VerifiedIdentityService.lock("legacy-import-commit:\(actor.id):\(command.operationId)", on: db)
            let sql = try VerifiedIdentityService.sql(db)
            if let existing = try await sql.raw("SELECT * FROM legacy_import_commits WHERE session_id = \(bind: session.sessionId) OR id = \(bind: command.commitId) OR (actor_id = \(bind: actor.id) AND operation_id = \(bind: command.operationId))").first() {
                guard try existing.decode(column: "id", as: UUID.self) == command.commitId, try existing.decode(column: "session_id", as: UUID.self) == session.sessionId,
                      try existing.decode(column: "projection_id", as: UUID.self) == command.projectionId, try existing.decode(column: "operation_id", as: UUID.self) == command.operationId,
                      try existing.decode(column: "actor_id", as: UUID.self) == actor.id, try existing.decode(column: "request_hash", as: String.self) == hash,
                      try existing.decode(column: "graph_sha256", as: String.self) == graphSHA else {
                    throw Abort(.conflict, reason: "This preparation was already published by a different operation. Read its receipt", identifier: "import_publication_conflict")
                }
                return try PlatformMutationService.decode(LegacyImportCommitReceipt.self, existing.decode(column: "receipt_json", as: String.self))
            }
            guard let projectionRow = try await sql.raw("SELECT graph_sha256, state FROM legacy_canonical_projections WHERE id = \(bind: command.projectionId) AND session_id = \(bind: session.sessionId) AND actor_id = \(bind: actor.id)").first(),
                  try projectionRow.decode(column: "graph_sha256", as: String.self) == graphSHA, try projectionRow.decode(column: "state", as: String.self) == "prepared_non_executable" else {
                throw blocked("The prepared projection is unavailable or changed", identifier: "import_projection_changed")
            }
            let blockers = projection.findings.filter { $0.disposition == .blocker }
            guard blockers.isEmpty else { throw blocked("This source has \(blockers.count) blocking finding(s) that need repair before publication") }
            let processing = try await loadProcessing(projection, session: session, on: db)
            let summary = try await LegacyImportProcessingService.summary(projection, session: session, on: db)
            guard summary.missingRequiredFileCount == 0, summary.processedFileCount == summary.receivedFileCount else {
                throw blocked("Transfer and process every required original before publishing. \(summary.missingRequiredFileCount) required file(s) are not ready", identifier: "import_files_incomplete")
            }
            // Only declared-and-received files become canonical objects; absent optional roles stay absent.
            let receivedDeclarations = Set(processing.files.keys)
            let publishedFiles = projection.files.filter { receivedDeclarations.contains($0.declarationId) }
            try await Publication(command: command, projection: projection, session: session, actor: actor, processing: processing, files: publishedFiles, graphSHA: graphSHA, hash: hash, now: now, db: db).run()
            guard let receipt = try await commitReceipt(sessionID: session.sessionId, on: db) else { throw Abort(.internalServerError) }
            return receipt
        }
    }

    private static func loadProcessing(_ projection: LegacyCanonicalProjection, session: StagedLegacyImportReceipt, on db: Database) async throws -> Processing {
        let sql = try VerifiedIdentityService.sql(db)
        var result = Processing()
        for row in try await sql.raw("SELECT * FROM legacy_import_file_processing WHERE projection_id = \(bind: projection.projectionId)").all() {
            result.files[try row.decode(column: "declaration_id", as: UUID.self)] = row
        }
        for row in try await sql.raw("SELECT * FROM legacy_import_drawing_processing WHERE projection_id = \(bind: projection.projectionId)").all() {
            result.drawings[try row.decode(column: "drawing_source_id", as: UUID.self)] = row
        }
        // Every processing row must correspond to a current receipt for this exact session.
        let receipts = Set(try await sql.raw("SELECT declaration_id FROM staged_import_original_receipts WHERE session_id = \(bind: session.sessionId)").all().map { try $0.decode(column: "declaration_id", as: UUID.self) })
        guard Set(result.files.keys).isSubset(of: receipts) else { throw blocked("Processing facts do not match retained originals", identifier: "import_processing_diverged") }
        return result
    }

    /// Everything below runs inside the fenced source transaction. No network IO.
    private struct Publication {
        let command: LegacyImportCommitCommand; let projection: LegacyCanonicalProjection; let session: StagedLegacyImportReceipt
        let actor: StagedLegacyImportActor; let processing: Processing; let files: [LegacyCanonicalProjection.FileObject]
        let graphSHA: String; let hash: String; let now: Date; let db: Database
        var sql: SQLDatabase { get throws { try VerifiedIdentityService.sql(db) } }
        var workspaceID: UUID { projection.binding.workspaceId }
        var projectID: UUID { projection.project.id }
        typealias Kind = LegacyImportRecordKind

        func run() async throws {
            guard let workspace = try await Team.find(workspaceID, on: db), let timezone = TimeZone(identifier: workspace.timezone) else { throw Abort(.conflict, reason: "Confirm the workspace timezone before publishing", identifier: "timezone_required") }
            let sql = try sql
            var directory = try await reconcileDirectory()
            try await lockAndCheckCollisions(directory)
            try await checkCapacity(directory)
            var published: [(Kind, UUID, UUID, String)] = []
            var counts: [String: Int] = [:]
            func count(_ key: String) { counts[key, default: 0] += 1 }
            let sequenceBefore = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: workspaceID)").first()!.decode(column: "change_sequence", as: Int64.self)

            // 1. Project.
            let p = projection.project
            let project = Project(id: p.id, name: p.name, reference: p.reference, clientName: p.clientName, clientEmail: p.clientEmail, clientPhone: p.clientPhone,
                address: p.address, notes: p.notes, projectType: p.projectType, status: "active", isFavorite: p.isFavorite, latitude: p.latitude, longitude: p.longitude, ownerId: actor.id)
            project.customProjectType = p.customProjectType; project.startDate = p.startDate; project.expectedEndDate = p.expectedEndDate
            project.workspaceId = workspaceID; project.platformManaged = true; project.importedAt = now; project.importSessionId = session.sessionId
            project.sourceStatus = p.localStatus; project.sourceCreatedAt = p.sourceCreatedAt; project.sourceUpdatedAt = p.sourceUpdatedAt
            let coverUse = projection.fileUses.first { $0.id == p.coverUseId }
            project.coverFileId = coverUse?.fileObjectId.flatMap { id in files.contains { $0.id == id } ? id : nil }
            try await project.save(on: db)
            try await sql.raw("UPDATE projects SET next_snag_number = \(bind: Int64(projection.snags.count + 1)) WHERE id = \(bind: projectID)").run()
            try await WorkspaceAccessService.activity(workspaceID: workspaceID, actorID: actor.id, action: "project_imported", targetID: projectID, detail: session.sessionId.uuidString, on: db)
            published.append((.projects, p.id, p.id, "project")); count("projects")

            // 2. Workspace directory: folders, tags, trades, contractors (reused or created).
            for folder in projection.folders where directory.created.contains(LegacyCanonicalProjectionMapper.recordKey(.folders, folder.id)) {
                try await sql.raw("""
                    INSERT INTO workspace_folders (id,workspace_id,name,color_hex,sort_order,parent_id,revision,source_created_at,source_updated_at,created_at,updated_at)
                    VALUES (\(bind: folder.id),\(bind: workspaceID),\(bind: folder.name),\(bind: folder.colorHex),\(bind: folder.sortOrder),\(bind: folder.parentID),1,\(bind: folder.createdAt),\(bind: folder.updatedAt),\(bind: now),\(bind: now))
                    """).run()
                let response = try WorkspaceFolderResponse(await sql.raw("SELECT * FROM workspace_folders WHERE id = \(bind: folder.id)").first()!)
                try await change(projectID: nil, type: "folder", id: folder.id, revision: 1, kind: "created", fields: ["folder"], payload: response)
                published.append((.folders, folder.id, folder.id, "folder")); count("folders")
            }
            for tag in projection.tags where directory.created.contains(LegacyCanonicalProjectionMapper.recordKey(.tags, tag.id)) {
                try await sql.raw("""
                    INSERT INTO workspace_tags (id,workspace_id,name,color_hex,revision,source_created_at,source_updated_at,created_at,updated_at)
                    VALUES (\(bind: tag.id),\(bind: workspaceID),\(bind: tag.name),\(bind: tag.colorHex),1,\(bind: tag.createdAt),\(bind: tag.updatedAt),\(bind: now),\(bind: now))
                    """).run()
                let response = try WorkspaceTagResponse(await sql.raw("SELECT * FROM workspace_tags WHERE id = \(bind: tag.id)").first()!)
                try await change(projectID: nil, type: "tag", id: tag.id, revision: 1, kind: "created", fields: ["tag"], payload: response)
                published.append((.tags, tag.id, tag.id, "tag")); count("tags")
            }
            for t in projection.trades where directory.created.contains(LegacyCanonicalProjectionMapper.recordKey(.trades, t.id)) {
                let trade = Trade(id: t.id, name: t.name, colorHex: t.colorHex.uppercased(), ownerId: actor.id)
                trade.sortOrder = t.sortOrder; trade.isArchived = t.isArchived; trade.isDefault = t.isDefault
                trade.workspaceId = workspaceID; trade.platformManaged = true
                try await trade.save(on: db)
                let response = try WorkspaceDirectoryService.response(trade)
                try await change(projectID: nil, type: "trade", id: t.id, revision: 1, kind: "created", fields: ["name", "colorHex", "sortOrder", "isArchived", "isDefault"], payload: response)
                published.append((.trades, t.id, t.id, "trade")); count("trades")
            }
            let tradeIDs = Set(projection.trades.map(\.id))
            for c in projection.contractors where directory.created.contains(LegacyCanonicalProjectionMapper.recordKey(.contractors, c.id)) {
                let contractor = Contractor(id: c.id, companyName: c.companyName, ownerId: actor.id)
                contractor.contactName = c.contactName; contractor.email = c.email; contractor.phone = c.phone; contractor.notes = c.notes; contractor.isArchived = c.isArchived
                contractor.tradeIds = c.tradeIDs.filter { tradeIDs.contains($0) }
                contractor.workspaceId = workspaceID; contractor.platformManaged = true
                try await contractor.save(on: db)
                for id in contractor.tradeIds { try await sql.raw("INSERT INTO contractor_trades (contractor_id, trade_id, workspace_id) VALUES (\(bind: c.id), \(bind: id), \(bind: workspaceID)) ON CONFLICT DO NOTHING").run() }
                let response = try WorkspaceDirectoryService.response(contractor)
                try await change(projectID: nil, type: "contractor", id: c.id, revision: 1, kind: "created", fields: ["companyName", "contactName", "email", "phone", "notes", "isArchived", "tradeIds"], payload: response)
                published.append((.contractors, c.id, c.id, "contractor")); count("contractors")
            }
            try await finishDirectory(&directory)
            for (key, reused) in directory.reused { published.append((reused.kind, reused.sourceId, reused.targetId, "reused:" + key.split(separator: "/").first.map(String.init)!)) }
            if let folderID = p.folderId { try await sql.raw("INSERT INTO project_folder_links (project_id, workspace_id, folder_id) VALUES (\(bind: projectID), \(bind: workspaceID), \(bind: folderID))").run() }
            for tagID in p.tagIds { try await sql.raw("INSERT INTO project_tag_links (project_id, workspace_id, tag_id) VALUES (\(bind: projectID), \(bind: workspaceID), \(bind: tagID))").run() }
            try await change(projectID: projectID, type: "projectOrganisation", id: projectID, revision: 1, kind: "created", fields: ["folderId", "tagIds"], payload: ProjectOrganisationResponse(projectId: projectID, folderId: p.folderId, tagIds: p.tagIds))

            // 3. Snags with qualified workflow.
            let formatter = CanonicalValueService.dateFormatter(timezone: timezone)
            var snagRows: [UUID: Snag] = [:]
            for s in projection.snags {
                let v = s.values
                let snag = Snag(id: v.id, reference: v.reference, title: v.title, snagDescription: v.description, status: s.workflow.displayStatus ?? "open", priority: v.priority,
                    location: v.location, dueDate: v.dueDate, costEstimate: v.costEstimate, actualCost: v.actualCost, currency: v.currency,
                    drawingPinX: v.drawingPinX, drawingPinY: v.drawingPinY, projectId: projectID, contractorId: v.contractorID, tradeId: v.tradeID, drawingId: v.drawingID,
                    assignedAt: v.contractorID == nil ? nil : v.updatedAt, ownerId: actor.id, tags: v.tags)
                snag.workspaceId = workspaceID; snag.displayNumber = s.displayNumber
                snag.dueOn = v.dueDate.map { formatter.string(from: $0) }
                snag.costEstimateDecimal = s.costEstimateDecimal.flatMap { Decimal(string: $0, locale: CanonicalValueService.decimalLocale) }
                snag.actualCostDecimal = s.actualCostDecimal.flatMap { Decimal(string: $0, locale: CanonicalValueService.decimalLocale) }
                snag.publishedAt = s.initialVisibility == "draft" ? nil : now
                snag.importedAt = now; snag.sourceStatus = v.localStatus; snag.sourceCreatedAt = v.createdAt; snag.sourceUpdatedAt = v.updatedAt
                snag.sourceClosedAt = v.unverifiedClosedAt; snag.closedAt = nil
                snag.workflowQualification = s.workflow.requiresReconciliation ? "legacy_unverified" : nil
                try await snag.save(on: db)
                snagRows[v.id] = snag
                let response = PlatformSnagResponse(snag)
                try await change(projectID: projectID, type: "snag", id: v.id, revision: 1, kind: "imported", fields: ["reference", "status", "title", "workflow"], payload: response)
                published.append((.snags, v.id, v.id, "snag")); count("snags")
            }

            // 4. File objects and uses.
            let processed = processing.files
            var fileObjectIDs = Set<UUID>()
            for file in files.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let row = processed[file.declarationId]!
                let receiptID = try row.decode(column: "receipt_id", as: UUID.self), state = try row.decode(column: "state", as: String.self)
                let decoded = state == "decoded_image"
                let mime: String? = decoded ? try row.decode(column: "decoded_mime", as: String?.self) : nil
                let width: Int? = decoded ? try row.decode(column: "width", as: Int?.self) : nil
                let height: Int? = decoded ? try row.decode(column: "height", as: Int?.self) : nil
                let renditionKey: String? = decoded ? try row.decode(column: "rendition_key", as: String?.self) : nil
                let renditionSHA: String? = decoded ? try row.decode(column: "rendition_sha256", as: String?.self) : nil
                let renditionSize: Int? = decoded ? try row.decode(column: "rendition_size", as: Int?.self) : nil
                try await sql.raw("""
                    INSERT INTO imported_file_objects (id,workspace_id,project_id,session_id,declaration_id,receipt_id,sha256,bytes,storage,decoded_mime,width,height,rendition_key,rendition_sha256,rendition_size,revision,created_at)
                    VALUES (\(bind: file.id),\(bind: workspaceID),\(bind: projectID),\(bind: session.sessionId),\(bind: file.declarationId),\(bind: receiptID),\(bind: file.declaredSHA256),\(bind: file.declaredBytes),'staged_original_v1',
                        \(bind: mime),\(bind: width),\(bind: height),\(bind: renditionKey),\(bind: renditionSHA),\(bind: renditionSize),1,\(bind: now))
                    """).run()
                fileObjectIDs.insert(file.id)
                let response = try ImportedFileResponse(await sql.raw("SELECT * FROM imported_file_objects WHERE id = \(bind: file.id)").first()!)
                try await change(projectID: projectID, type: "importedFile", id: file.id, revision: 1, kind: "created", fields: ["sha256", "rendition"], payload: response)
                count("files"); if state == "decoded_image" { count("decodedFiles") } else { count("opaqueFiles") }
            }
            for use in projection.fileUses.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let objectID = use.fileObjectId.flatMap { fileObjectIDs.contains($0) ? $0 : nil }
                try await sql.raw("""
                    INSERT INTO imported_file_uses (id,project_id,kind,source_id,role,position,required,availability,file_object_id,source_path_sha256,used_legacy_drawing_location)
                    VALUES (\(bind: use.id),\(bind: projectID),\(bind: use.kind.rawValue),\(bind: use.sourceId),\(bind: use.role.rawValue),\(bind: use.position),\(bind: use.required),\(bind: use.availability.rawValue),\(bind: objectID),\(bind: use.sourcePathSHA256),\(bind: use.usedLegacyDrawingLocation))
                    """).run()
                let response = try ImportedFileUseResponse(await sql.raw("SELECT * FROM imported_file_uses WHERE id = \(bind: use.id)").first()!)
                try await change(projectID: projectID, type: "importedFileUse", id: use.id, revision: 1, kind: "created", fields: ["role", "fileId"], payload: response)
                count("fileUses")
            }

            // 5. Photos.
            for photo in projection.photos {
                try await sql.raw("""
                    INSERT INTO imported_photos (id,project_id,snag_id,original_use_id,thumbnail_use_id,annotation_use_id,source_label_json,source_legacy_label_json,label_resolution,captured_at,latitude,longitude,sort_order,source_created_at,revision,imported_at)
                    VALUES (\(bind: photo.id),\(bind: projectID),\(bind: photo.snagId),\(bind: photo.originalUseId),\(bind: photo.thumbnailUseId),\(bind: photo.annotationUseId),\(bind: photo.sourceLabelJSON),\(bind: photo.sourceLegacyLabelJSON),\(bind: photo.labelResolution),\(bind: photo.capturedAt),\(bind: photo.latitude),\(bind: photo.longitude),\(bind: photo.sortOrder),\(bind: photo.sourceCreatedAt),1,\(bind: now))
                    """).run()
                let response = try ImportedPhotoResponse(await sql.raw("SELECT * FROM imported_photos WHERE id = \(bind: photo.id)").first()!)
                try await change(projectID: projectID, type: "importedPhoto", id: photo.id, revision: 1, kind: "created", fields: ["photo"], payload: response)
                published.append((.photos, photo.id, photo.id, "importedPhoto")); count("photos")
            }

            // 6. Drawings: rendered sheets promote into canonical drawing tables; others stay opaque.
            var pagesByDrawing: [UUID: (version: UUID, page: UUID)] = [:]
            for d in projection.drawings {
                let rendered = try processing.drawings[d.id].flatMap { row -> SQLRow? in try row.decode(column: "state", as: String.self) == "rendered" ? row : nil }
                let fileUse = projection.fileUses.first { $0.id == d.fileUseId }
                let fileID = fileUse?.fileObjectId.flatMap { fileObjectIDs.contains($0) ? $0 : nil }
                if let row = rendered, let fileID, let file = files.first(where: { $0.id == fileID }) {
                    let mime = try row.decode(column: "source_mime", as: String.self), geometry = try row.decode(column: "geometry_json", as: String.self)
                    let resultHash = try row.decode(column: "result_hash", as: String.self)
                    let renditionKey = try row.decode(column: "rendition_key", as: String.self), renditionSHA = try row.decode(column: "rendition_sha256", as: String.self), renditionSize = try row.decode(column: "rendition_size", as: Int.self)
                    let thumbnailKey = try row.decode(column: "thumbnail_key", as: String.self), thumbnailSHA = try row.decode(column: "thumbnail_sha256", as: String.self), thumbnailSize = try row.decode(column: "thumbnail_size", as: Int.self)
                    let originalKey = ImportedObjectKey.original(.init(workspaceId: workspaceID, sessionId: session.sessionId, declarationId: file.declarationId)).value
                    try await sql.raw("""
                        INSERT INTO drawing_assets(id,workspace_id,project_id,uploader_id,purpose,original_sha256,original_size,original_mime,original_filename,original_key,processor_profile,state,revision,created_at,expires_at,ready_at,published_at,result_hash)
                        VALUES(\(bind: d.assetId),\(bind: workspaceID),\(bind: projectID),\(bind: actor.id),'drawing_source',\(bind: file.declaredSHA256),\(bind: Int(file.declaredBytes)),\(bind: mime),\(bind: d.name),\(bind: originalKey),\(bind: LegacyImportProcessingService.drawingProcessorProfile),'ready',1,\(bind: now),\(bind: now.addingTimeInterval(86400 * 3650)),\(bind: now),\(bind: now),\(bind: resultHash))
                        """).run()
                    try await sql.raw("""
                        INSERT INTO drawing_asset_pages(id,asset_id,project_id,source_page_index,source_page_label,geometry_json,rendition_key,rendition_sha256,rendition_size,thumbnail_key,thumbnail_sha256,thumbnail_size)
                        VALUES(\(bind: d.assetPageId),\(bind: d.assetId),\(bind: projectID),0,'1',\(bind: geometry),\(bind: renditionKey),\(bind: renditionSHA),\(bind: renditionSize),\(bind: thumbnailKey),\(bind: thumbnailSHA),\(bind: thumbnailSize))
                        """).run()
                    try await sql.raw("""
                        INSERT INTO drawings(id,workspace_id,project_id,name,sort_order,revision,current_version_id,created_by,created_at,updated_at)
                        VALUES(\(bind: d.id),\(bind: workspaceID),\(bind: projectID),\(bind: d.name),\(bind: d.sortOrder),1,\(bind: d.versionId),\(bind: actor.id),\(bind: now),\(bind: now))
                        """).run()
                    try await sql.raw("INSERT INTO drawing_versions(id,drawing_id,project_id,asset_id,version_number,published_by,published_at) VALUES(\(bind: d.versionId),\(bind: d.id),\(bind: projectID),\(bind: d.assetId),1,\(bind: actor.id),\(bind: now))").run()
                    try await sql.raw("INSERT INTO drawing_version_pages(id,version_id,drawing_id,asset_id,asset_page_id,project_id,page_index) VALUES(\(bind: d.versionPageId),\(bind: d.versionId),\(bind: d.id),\(bind: d.assetId),\(bind: d.assetPageId),\(bind: projectID),0)").run()
                    try await sql.raw("""
                        INSERT INTO imported_drawing_provenance (drawing_id,project_id,name,sort_order,file_use_id,thumbnail_use_id,source_page_number,source_created_at,source_updated_at,provenance,rendering,asset_id,imported_at)
                        VALUES (\(bind: d.id),\(bind: projectID),\(bind: d.name),\(bind: d.sortOrder),\(bind: d.fileUseId),\(bind: d.thumbnailUseId),\(bind: d.sourcePageNumber),\(bind: d.sourceCreatedAt),\(bind: d.sourceUpdatedAt),\(bind: d.provenance),'rendered_single_raster_v1',\(bind: d.assetId),\(bind: now))
                        """).run()
                    pagesByDrawing[d.id] = (d.versionId, d.versionPageId)
                    let sheet = try await LegacyImportReadService.sheet(d.id, projectID: projectID, on: db)
                    try await change(projectID: projectID, type: "drawing", id: d.id, revision: 1, kind: "imported", fields: ["name", "pages"], payload: sheet)
                    published.append((.drawings, d.id, d.id, "drawing")); count("renderedDrawings")
                } else {
                    try await sql.raw("""
                        INSERT INTO imported_drawing_provenance (drawing_id,project_id,name,sort_order,file_use_id,thumbnail_use_id,source_page_number,source_created_at,source_updated_at,provenance,rendering,asset_id,imported_at)
                        VALUES (\(bind: d.id),\(bind: projectID),\(bind: d.name),\(bind: d.sortOrder),\(bind: d.fileUseId),\(bind: d.thumbnailUseId),\(bind: d.sourcePageNumber),\(bind: d.sourceCreatedAt),\(bind: d.sourceUpdatedAt),\(bind: d.provenance),'opaque_unrendered',NULL,\(bind: now))
                        """).run()
                    let response = OpaqueImportedDrawingResponse(id: d.id, projectId: projectID, name: d.name, sortOrder: d.sortOrder,
                        imported: try ImportedDrawingProvenance(await sql.raw("SELECT * FROM imported_drawing_provenance WHERE drawing_id = \(bind: d.id) AND project_id = \(bind: projectID)").first()!))
                    try await change(projectID: projectID, type: "opaqueDrawing", id: d.id, revision: 1, kind: "imported", fields: ["name"], payload: response)
                    published.append((.drawings, d.id, d.id, "opaqueDrawing")); count("opaqueDrawings")
                }
            }
            // 7. Pins: canonical only where the sheet was rendered and coordinates exist.
            for pin in projection.pins {
                guard let drawingID = pin.drawingId, let target = pagesByDrawing[drawingID], let x = pin.x, let y = pin.y, let snag = snagRows[pin.snagId] else { continue }
                try await sql.raw("""
                    INSERT INTO snag_drawing_pins(snag_id,project_id,drawing_id,version_id,version_page_id,x,y,revision,snag_revision,recorded_by,recorded_at,deleted_at)
                    VALUES(\(bind: pin.snagId),\(bind: projectID),\(bind: drawingID),\(bind: target.version),\(bind: target.page),\(bind: x),\(bind: y),1,\(bind: snag.revision),\(bind: actor.id),\(bind: now),NULL)
                    """).run()
                try await sql.raw("""
                    INSERT INTO drawing_pin_events(id,snag_id,project_id,pin_revision,snag_revision,previous_page_id,previous_x,previous_y,next_page_id,next_x,next_y,action,actor_id,recorded_at)
                    VALUES(\(bind: pin.eventId),\(bind: pin.snagId),\(bind: projectID),1,\(bind: snag.revision),NULL,NULL,NULL,\(bind: target.page),\(bind: x),\(bind: y),'placed',\(bind: actor.id),\(bind: now))
                    """).run()
                let response = try DrawingPinResponse(await sql.raw("SELECT * FROM snag_drawing_pins WHERE snag_id = \(bind: pin.snagId) AND project_id = \(bind: projectID)").first()!)
                try await change(projectID: projectID, type: "drawingPin", id: pin.snagId, revision: 1, kind: "imported", fields: ["pin"], payload: response)
                count("pins")
            }

            // 8. Typed imported history.
            for c in projection.comments {
                try await sql.raw("""
                    INSERT INTO imported_snag_comments (id,project_id,snag_id,content,unverified_author_id,unverified_author_name,unverified_author_type,created_at,updated_at,parent_comment_id,mentions_json,is_from_contractor_link,attachment_list_state,attachment_list_source_bytes,attachment_list_source_sha256,provenance,revision,imported_at)
                    VALUES (\(bind: c.id),\(bind: projectID),\(bind: c.snagId),\(bind: c.content),\(bind: c.unverifiedAuthorId),\(bind: c.unverifiedAuthorName),\(bind: c.unverifiedAuthorType),\(bind: c.createdAt),\(bind: c.updatedAt),\(bind: c.parentCommentId),\(bind: PlatformMutationService.encode(c.mentions)),\(bind: c.isFromContractorLink),\(bind: c.attachmentListState.rawValue),\(bind: c.attachmentListSourceBytes),\(bind: c.attachmentListSourceSHA256),\(bind: c.provenance),1,\(bind: now))
                    """).run()
                let response = try ImportedCommentResponse(await sql.raw("SELECT * FROM imported_snag_comments WHERE id = \(bind: c.id)").first()!)
                try await change(projectID: projectID, type: "importedComment", id: c.id, revision: 1, kind: "created", fields: ["comment"], payload: response)
                published.append((.comments, c.id, c.id, "importedComment")); count("comments")
            }
            for h in projection.statusHistory {
                try await sql.raw("""
                    INSERT INTO imported_status_changes (id,project_id,snag_id,from_status,to_status,unverified_changed_by_id,unverified_changed_by_name,unverified_changed_by_type,reason,created_at,provenance,imported_at)
                    VALUES (\(bind: h.id),\(bind: projectID),\(bind: h.snagID!),\(bind: h.fromLocalStatus),\(bind: h.toLocalStatus),\(bind: h.unverifiedChangedByID),\(bind: h.unverifiedChangedByName),\(bind: h.unverifiedChangedByType),\(bind: h.reason),\(bind: h.createdAt),\(bind: h.provenance),\(bind: now))
                    """).run()
                let response = try ImportedStatusChangeResponse(await sql.raw("SELECT * FROM imported_status_changes WHERE id = \(bind: h.id)").first()!)
                try await change(projectID: projectID, type: "importedStatusChange", id: h.id, revision: 1, kind: "created", fields: ["status"], payload: response)
                published.append((.statusHistory, h.id, h.id, "importedStatusChange")); count("statusHistory")
            }
            for dl in projection.deletions {
                try await sql.raw("""
                    INSERT INTO imported_snag_deletions (deleted_snag_id,project_id,reference,unverified_source_owner_id,created_at,historical_needs_remote_deletion,execution,imported_at)
                    VALUES (\(bind: dl.deletedSnagId),\(bind: projectID),\(bind: dl.reference),\(bind: dl.unverifiedSourceOwnerId),\(bind: dl.createdAt),\(bind: dl.historicalNeedsRemoteDeletion),\(bind: dl.execution),\(bind: now))
                    """).run()
                let response = try ImportedDeletionResponse(await sql.raw("SELECT * FROM imported_snag_deletions WHERE deleted_snag_id = \(bind: dl.deletedSnagId) AND project_id = \(bind: projectID)").first()!)
                try await change(projectID: projectID, type: "importedDeletion", id: dl.deletedSnagId, revision: 1, kind: "created", fields: ["deletion"], payload: response)
                published.append((.deletionReceipts, dl.deletedSnagId, dl.deletedSnagId, "importedDeletion")); count("deletionReceipts")
            }

            // 9. Receipt, mappings and journal binding.
            let group = try await sql.raw("SELECT current_setting('snaglist.change_group', true) AS value").first()!.decode(column: "value", as: String?.self).flatMap(UUID.init(uuidString:))
            let sequenceAfter = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: workspaceID)").first()!.decode(column: "change_sequence", as: Int64.self)
            guard let group, sequenceAfter > sequenceBefore else { throw Abort(.internalServerError, reason: "Publication journal was not written") }
            let journalCount = Int(sequenceAfter - sequenceBefore) + 1
            guard journalCount <= projection.journalEventUpperBound, journalCount <= 1000 else { throw LegacyProjectImportError.publicationLimit }
            let commitID = command.commitId
            let receipt = LegacyImportCommitReceipt(formatVersion: 1, commitId: commitID, sessionId: session.sessionId, projectionId: projection.projectionId, operationId: command.operationId,
                deviceId: session.deviceId, actorId: actor.id, workspaceId: workspaceID, projectId: projectID, graphSHA256: graphSHA,
                acknowledgementVersion: command.acknowledgement.version, policyVersion: LegacyImportPublicationPolicy.version, state: "published", transactionGroup: group,
                firstSequence: sequenceBefore + 1, lastSequence: sequenceAfter + 1, journalEventCount: journalCount, publishedCounts: counts,
                reusedDirectoryCount: directory.reused.count, renderedDrawingCount: counts["renderedDrawings"] ?? 0, opaqueDrawingCount: counts["opaqueDrawings"] ?? 0,
                decodedFileCount: counts["decodedFiles"] ?? 0, opaqueFileCount: counts["opaqueFiles"] ?? 0,
                qualificationCounts: Dictionary(grouping: projection.findings.filter { $0.disposition == .qualification }, by: \.code).mapValues(\.count),
                coverage: RegisterSyncService.coverage, createdAt: now)
            try await sql.raw("""
                INSERT INTO legacy_import_commits (id,session_id,projection_id,actor_id,workspace_id,device_id,operation_id,request_hash,graph_sha256,acknowledgement_version,acknowledgement_wording,project_id,transaction_group,first_sequence,last_sequence,journal_event_count,state,receipt_json,created_at)
                VALUES (\(bind: commitID),\(bind: session.sessionId),\(bind: projection.projectionId),\(bind: actor.id),\(bind: workspaceID),\(bind: session.deviceId),\(bind: command.operationId),\(bind: hash),\(bind: graphSHA),\(bind: command.acknowledgement.version),\(bind: command.acknowledgement.wording),\(bind: projectID),\(bind: group),\(bind: sequenceBefore + 1),\(bind: sequenceAfter + 1),\(bind: journalCount),'published',\(bind: PlatformMutationService.encode(receipt)),\(bind: now))
                """).run()
            for (kind, sourceID, targetID, targetKind) in published {
                try await sql.raw("INSERT INTO legacy_import_published_records (commit_id,kind,source_id,target_id,target_kind) VALUES (\(bind: commitID),\(bind: kind.rawValue),\(bind: sourceID),\(bind: targetID),\(bind: targetKind))").run()
            }
            for (identityID, publication) in directory.publications {
                try await sql.raw("INSERT INTO legacy_import_directory_publications (identity_id,commit_id,kind,target_id,canonical_revision,content_sha256) VALUES (\(bind: identityID),\(bind: commitID),\(bind: publication.kind),\(bind: publication.targetId),\(bind: publication.revision),\(bind: publication.contentSHA256))").run()
            }
            try await change(projectID: projectID, type: "importReceipt", id: commitID, revision: 1, kind: "published", fields: ["receipt"], payload: receipt)
            // The receipt's own journal event is the final one in the group (lastSequence).
            let final = try await sql.raw("SELECT change_sequence FROM teams WHERE id = \(bind: workspaceID)").first()!.decode(column: "change_sequence", as: Int64.self)
            guard final == sequenceAfter + 1 else { throw Abort(.internalServerError, reason: "Publication journal sequence diverged") }
        }

        private func change<T: Encodable>(projectID: UUID?, type: String, id: UUID, revision: Int64, kind: String, fields: [String], payload: T) async throws {
            try await PlatformMutationService.change(workspaceID: workspaceID, projectID: projectID, type: type, entityID: id, revision: revision, kind: kind, fields: fields, payload: payload, actorID: actor.id, on: db)
        }

        struct Reused { let kind: Kind; let sourceId: UUID; let targetId: UUID }
        struct DirectoryPublication { let kind: String; let targetId: UUID; let revision: Int64; let contentSHA256: String }
        struct Directory { var created: Set<String> = []; var reused: [String: Reused] = [:]; var publications: [UUID: DirectoryPublication] = [:] }

        /// Same source lineage + unchanged intrinsic digest + unchanged published canonical
        /// content permits reuse. Anything else is a conflict, never a silent overwrite.
        private func reconcileDirectory() async throws -> Directory {
            let sql = try sql
            var directory = Directory()
            let b = projection.binding
            for identity in projection.directoryIdentities {
                let key = LegacyCanonicalProjectionMapper.recordKey(identity.kind, identity.sourceId)
                guard let row = try await sql.raw("""
                    SELECT id, intrinsic_sha256, target_id FROM legacy_canonical_directory_identities WHERE actor_id = \(bind: b.actorId) AND workspace_id = \(bind: b.workspaceId)
                    AND environment = \(bind: b.destination.environment) AND api_origin = \(bind: b.destination.apiOrigin) AND archive_id = \(bind: b.archiveId)
                    AND source_fingerprint = \(bind: b.sourceFingerprint) AND kind = \(bind: identity.kind.rawValue) AND source_id = \(bind: identity.sourceId)
                    """).first(), try row.decode(column: "intrinsic_sha256", as: String.self) == identity.intrinsicSHA256, try row.decode(column: "target_id", as: UUID.self) == identity.targetId else {
                    throw LegacyCanonicalProjectionError.changedDirectory
                }
                let identityID = try row.decode(column: "id", as: UUID.self)
                if let published = try await sql.raw("SELECT * FROM legacy_import_directory_publications WHERE identity_id = \(bind: identityID)").first() {
                    let targetID = try published.decode(column: "target_id", as: UUID.self)
                    guard let current = try await currentDirectoryContent(identity.kind, id: targetID),
                          current.revision == (try published.decode(column: "canonical_revision", as: Int64.self)),
                          current.sha256 == (try published.decode(column: "content_sha256", as: String.self)) else {
                        throw LegacyImportCommitService.blocked("A shared directory entry was edited after an earlier import. Reconcile it before importing another project from this source", identifier: "import_directory_changed")
                    }
                    directory.reused[key] = .init(kind: identity.kind, sourceId: identity.sourceId, targetId: targetID)
                } else {
                    directory.created.insert(key)
                    directory.publications[identityID] = .init(kind: identity.kind.rawValue, targetId: identity.targetId, revision: 1, contentSHA256: "")
                }
            }
            return directory
        }
        private func currentDirectoryContent(_ kind: Kind, id: UUID) async throws -> (revision: Int64, sha256: String)? {
            switch kind {
            case .contractors:
                guard let value = try await Contractor.find(id, on: db), value.workspaceId == workspaceID, value.platformManaged else { return nil }
                return (value.revision, SHA256Hasher.hash(token: try PlatformMutationService.encode(WorkspaceDirectoryService.response(value).data)))
            case .trades:
                guard let value = try await Trade.find(id, on: db), value.workspaceId == workspaceID, value.platformManaged else { return nil }
                return (value.revision, SHA256Hasher.hash(token: try PlatformMutationService.encode(WorkspaceDirectoryService.response(value).data)))
            case .folders:
                guard let row = try await sql.raw("SELECT * FROM workspace_folders WHERE id = \(bind: id) AND workspace_id = \(bind: workspaceID)").first() else { return nil }
                let value = try WorkspaceFolderResponse(row)
                return (value.revision, SHA256Hasher.hash(token: try PlatformMutationService.encode(value)))
            case .tags:
                guard let row = try await sql.raw("SELECT * FROM workspace_tags WHERE id = \(bind: id) AND workspace_id = \(bind: workspaceID)").first() else { return nil }
                let value = try WorkspaceTagResponse(row)
                return (value.revision, SHA256Hasher.hash(token: try PlatformMutationService.encode(value)))
            default: throw LegacyCanonicalProjectionError.allocation
            }
        }
        /// Records the exact published content digest for every newly created directory entry.
        private func finishDirectory(_ directory: inout Directory) async throws {
            for (identityID, publication) in directory.publications {
                guard let kind = Kind(rawValue: publication.kind), let current = try await currentDirectoryContent(kind, id: publication.targetId) else { throw LegacyCanonicalProjectionError.allocation }
                directory.publications[identityID] = .init(kind: publication.kind, targetId: publication.targetId, revision: current.revision, contentSHA256: current.sha256)
            }
        }

        private func lockAndCheckCollisions(_ directory: Directory) async throws {
            let sql = try sql
            var candidates: [(String, UUID)] = [("project", projectID)]
            candidates += projection.snags.map { ("snag", $0.values.id) }
            candidates += projection.deletions.map { ("snag", $0.deletedSnagId) }
            candidates += projection.photos.map { ("imported-photo", $0.id) }
            candidates += projection.comments.map { ("imported-comment", $0.id) }
            candidates += projection.statusHistory.map { ("imported-status", $0.id) }
            candidates += projection.drawings.flatMap { [("drawing", $0.id), ("drawing-asset", $0.assetId), ("drawing-version", $0.versionId), ("drawing-page", $0.versionPageId)] }
            candidates += files.map { ("imported-file", $0.id) }
            candidates += projection.fileUses.map { ("imported-file-use", $0.id) }
            for key in directory.created {
                let parts = key.split(separator: "/")
                let lockKind = ["contractors": "contractor", "trades": "trade", "folders": "folder", "tags": "tag"][String(parts[0])]!
                candidates.append((lockKind, UUID(uuidString: String(parts[1]))!))
            }
            for (kind, id) in candidates.sorted(by: { "\($0.0):\($0.1.uuidString)" < "\($1.0):\($1.1.uuidString)" }) {
                try await VerifiedIdentityService.lock("entity:\(kind):\(id.uuidString)", on: db)
            }
            func occupied(_ checks: [(String, String, UUID)]) async throws -> Bool {
                for (table, column, id) in checks {
                    if try await sql.raw("SELECT 1 FROM \(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: id) LIMIT 1").first() != nil { return true }
                }
                return false
            }
            func collision(_ what: String) -> Abort {
                LegacyImportCommitService.blocked("A \(what) with a source ID already exists in this workspace or was deleted. This import needs case-by-case reconciliation", identifier: "import_identity_collision")
            }
            if try await occupied([("projects", "id", projectID)]) { throw collision("project") }
            for s in projection.snags { if try await occupied([("snags", "id", s.values.id), ("snag_deletions", "snag_id", s.values.id)]) { throw collision("snag") } }
            for d in projection.deletions { if try await occupied([("snags", "id", d.deletedSnagId)]) { throw collision("deleted snag") } }
            for photo in projection.photos { if try await occupied([("imported_photos", "id", photo.id), ("media_assets", "id", photo.id)]) { throw collision("photo") } }
            for c in projection.comments { if try await occupied([("imported_snag_comments", "id", c.id), ("project_comments", "id", c.id)]) { throw collision("comment") } }
            for h in projection.statusHistory { if try await occupied([("imported_status_changes", "id", h.id)]) { throw collision("status change") } }
            for d in projection.drawings { if try await occupied([("drawings", "id", d.id), ("imported_drawing_provenance", "drawing_id", d.id), ("drawing_assets", "id", d.assetId),
                ("drawing_versions", "id", d.versionId), ("drawing_version_pages", "id", d.versionPageId), ("drawing_asset_pages", "id", d.assetPageId)]) { throw collision("drawing") } }
            for f in files { if try await occupied([("imported_file_objects", "id", f.id)]) { throw collision("file") } }
            for u in projection.fileUses { if try await occupied([("imported_file_uses", "id", u.id)]) { throw collision("file use") } }
            for key in directory.created {
                let parts = key.split(separator: "/"), id = UUID(uuidString: String(parts[1]))!
                let table = ["contractors": "contractors", "trades": "trades", "folders": "workspace_folders", "tags": "workspace_tags"][String(parts[0])]!
                if try await occupied([(table, "id", id)]) { throw collision("directory entry") }
            }
        }
        private func checkCapacity(_ directory: Directory) async throws {
            let sql = try sql
            let rows = try await sql.raw("SELECT (SELECT count(*) FROM contractors WHERE workspace_id = \(bind: workspaceID) AND platform_managed) + (SELECT count(*) FROM trades WHERE workspace_id = \(bind: workspaceID) AND platform_managed) AS n").first()!.decode(column: "n", as: Int.self)
            let folders = try await sql.raw("SELECT count(*) AS n FROM workspace_folders WHERE workspace_id = \(bind: workspaceID)").first()!.decode(column: "n", as: Int.self)
            let tags = try await sql.raw("SELECT count(*) AS n FROM workspace_tags WHERE workspace_id = \(bind: workspaceID)").first()!.decode(column: "n", as: Int.self)
            // Actual planned snapshot rows: every row a fresh register download would carry.
            let planned = 1 + projection.snags.count + rows + folders + tags + directory.created.count + files.count + projection.fileUses.count + projection.photos.count
                + projection.drawings.count + projection.pins.count + projection.comments.count + projection.statusHistory.count + projection.deletions.count + 2
            guard planned <= projection.snapshotRowUpperBound, planned <= 10000 else { throw LegacyProjectImportError.publicationLimit }
            let group = try await sql.raw("SELECT current_setting('snaglist.change_group', true) AS value").first()!.decode(column: "value", as: String?.self)
            guard group == nil || group == "" else { throw Abort(.conflict, reason: "Publication must own its transaction group") }
        }
    }
}
