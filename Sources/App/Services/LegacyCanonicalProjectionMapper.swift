import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum LegacyCanonicalProjectionError: Error, Equatable {
    case binding, allocation, unsupportedPolicy, changedDirectory, projectionChanged, capacity
}

/// Pure typed mapper. Does not query permissions, publish rows, infer MIME from a
/// filename, create verified historical activity, or resolve missing source facts.
enum LegacyCanonicalProjectionMapper {
    typealias P = LegacyCanonicalProjection
    struct Declaration: Sendable { let archivePath: String; let id: UUID; let sha256: String; let bytes: Int64 }
    struct Use: Sendable { let key: String; let id: UUID }
    static func useKey(_ kind: LegacyImportRecordKind, _ id: UUID, _ role: LegacyImportFileRole, _ position: Int = 0) -> String {
        "\(kind.rawValue)/\(id.uuidString.lowercased())/\(role.rawValue)/\(position)"
    }
    static func recordKey(_ kind: LegacyImportRecordKind, _ id: UUID) -> String { "\(kind.rawValue)/\(id.uuidString.lowercased())" }
    static func stableID(_ namespace: UUID, _ label: String) -> UUID {
        var data = Data("snaglist-canonical-projection-id-v1\n".utf8)
        data.append(contentsOf: namespace.uuidString.lowercased().utf8); data.append(0); data.append(contentsOf: label.utf8)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128; bytes[8] = (bytes[8] & 63) | 128 // UUIDv8, specified application hash.
        let h = bytes.map { String(format: "%02x", $0) }.joined(), a = Array(h)
        return UUID(uuidString: String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32]))!
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Default seconds since 2001 preserves source subsecond values, unlike the
        // whole-second ISO date formatter used by unrelated HTTP receipts.
        return try encoder.encode(value)
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { LegacyProjectImportDecoder.digest(try encode(value)) }
    static func handleDigest(_ path: String) -> String {
        LegacyProjectImportDecoder.digest(Data(("snaglist-projection-archive-handle-v1\n" + path).utf8))
    }
    static func workflow(_ source: LegacyProjectImportSource.Snag) -> P.Workflow {
        let display: String?
        switch source.localStatus {
        case "open", "draft", "sent", "opened", "cold", "overdue": display = "open"
        case "in_progress", "inProgress", "in-progress", "workStarted": display = "in_progress"
        case "submitted", "awaitingApproval", "readyForInspection", "awaiting_review": display = "awaiting_review"
        case "rejected", "sentBack", "changes_requested": display = "changes_requested"
        case "closed", "completed", "approved": display = "closed"
        default: display = nil
        }
        return .init(sourceStatus: source.localStatus, displayStatus: display,
            qualification: "legacy_unverified", requiresReconciliation: source.localStatus != "open" || source.unverifiedClosedAt != nil,
            unverifiedClosedAt: source.unverifiedClosedAt, actionableReview: false, verifiedAcceptance: false)
    }

    /// Digest of intrinsic directory fields, not project-selected inverse edges.
    /// Full exact source rows remain independently retained and hashed.
    static func directoryDigest<T: Encodable>(_ value: T, kind: LegacyImportRecordKind) throws -> String {
        let excluded: Set<String>
        switch kind {
        case .contractors: excluded = ["selectedSnagIDs"]
        case .trades: excluded = ["selectedSnagIDs", "selectedContractorIDs"]
        case .folders: excluded = ["selectedProjectIDs", "selectedChildIDs"]
        case .tags: excluded = ["selectedProjectIDs"]
        default: throw LegacyCanonicalProjectionError.allocation
        }
        guard var object = try JSONSerialization.jsonObject(with: encode(value)) as? [String: Any] else { throw LegacyCanonicalProjectionError.allocation }
        excluded.forEach { object.removeValue(forKey: $0) }
        // Trade membership is intrinsic; list order is not. Other selected edges
        // remain in the typed source graph, never discarded from the source.
        if let ids = object["tradeIDs"] as? [String] { object["tradeIDs"] = ids.sorted() }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return LegacyProjectImportDecoder.digest(Data(("directory-intrinsic-v1/" + kind.rawValue + "\n").utf8) + data)
    }

    static func sourceDigests(_ source: LegacyProjectImportSource) throws -> [String: String] {
        var result: [String: String] = [:]
        func add<T: Encodable>(_ value: T, _ kind: LegacyImportRecordKind, _ id: UUID) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            result[recordKey(kind,id)] = LegacyProjectImportDecoder.digest(try encoder.encode(value))
        }
        try add(source.project,.projects,source.project.id)
        for value in source.snags { try add(value,.snags,value.id) }
        for value in source.photos { try add(value,.photos,value.id) }
        for value in source.drawings { try add(value,.drawings,value.id) }
        for value in source.contractors { try add(value,.contractors,value.id) }
        for value in source.trades { try add(value,.trades,value.id) }
        for value in source.folders { try add(value,.folders,value.id) }
        for value in source.tags { try add(value,.tags,value.id) }
        for value in source.comments { try add(value,.comments,value.id) }
        for value in source.statusHistory { try add(value,.statusHistory,value.id) }
        for value in source.deletionReceipts { try add(value,.deletionReceipts,value.deletedSnagID) }
        return result
    }

    static func map(graph: LegacyProjectImportGraph, receipt: StagedLegacyImportReceipt, projectionID: UUID,
                    records: [P.SourceRecord], declarations: [Declaration], uses: [Use]) throws -> P {
        try Task.checkCancellation()
        let source = graph.decoded.source, project = source.project
        guard receipt.state == "staged_incomplete", receipt.revision == 1,
              receipt.exportSHA256 == graph.decoded.sha256, receipt.exportByteCount == graph.decoded.bytes.count,
              receipt.sourceFingerprint == source.source.sourceFingerprint, receipt.selectedProjectId == project.id else { throw LegacyCanonicalProjectionError.binding }
        let expectedDigests = try sourceDigests(source)
        let recordSet = Set(records.map { recordKey($0.kind, $0.sourceId) })
        let expected = Set(graph.sourceRecordIDs.flatMap { kind, ids in ids.map { recordKey(kind, $0) } })
        guard records.count == expected.count, recordSet == expected,
              Set(records.map(\.mappingId)).count == records.count,
              records.allSatisfy({ expectedDigests[recordKey($0.kind,$0.sourceId)] == $0.sourceSHA256 }),
              Set(declarations.map(\.archivePath)).count == declarations.count,
              Set(declarations.map(\.id)).count == declarations.count,
              Set(uses.map(\.key)).count == uses.count, Set(uses.map(\.id)).count == uses.count else { throw LegacyCanonicalProjectionError.allocation }
        let declarationsByPath = Dictionary(uniqueKeysWithValues: declarations.map { ($0.archivePath, $0) })
        guard declarations.count == graph.declaredFiles.count,
              graph.declaredFiles.allSatisfy({ file in declarationsByPath[file.archivePath].map { $0.sha256 == file.sha256 && $0.bytes == file.bytes } == true }) else { throw LegacyCanonicalProjectionError.allocation }
        let useIDs = Dictionary(uniqueKeysWithValues: uses.map { ($0.key, $0.id) })
        guard Set(useIDs.keys) == Set(graph.fileUses.map { useKey($0.kind, $0.recordID, $0.role, $0.position) }) else { throw LegacyCanonicalProjectionError.allocation }
        func use(_ kind: LegacyImportRecordKind, _ id: UUID, _ role: LegacyImportFileRole, _ position: Int = 0) -> UUID {
            useIDs[useKey(kind, id, role, position)]! // exhaustive equality checked above.
        }
        var allocations = records.map { P.Allocation(key: recordKey($0.kind, $0.sourceId), targetId: $0.sourceId) }
        func allocate(_ key: String) -> UUID {
            let id = stableID(projectionID, key); allocations.append(.init(key: key, targetId: id)); return id
        }
        let files = declarations.sorted { $0.id.uuidString < $1.id.uuidString }.map { d in
            P.FileObject(id: allocate("fileObject/\(d.id.uuidString.lowercased())"), declarationId: d.id,
                declaredSHA256: d.sha256, declaredBytes: d.bytes, requiredFact: "persisted_original_bytes_v1")
        }
        let fileIDs = Dictionary(uniqueKeysWithValues: files.map { ($0.declarationId, $0.id) })
        let fileUses = graph.fileUses.map { f in
            P.FileUse(id: use(f.kind, f.recordID, f.role, f.position), kind: f.kind, sourceId: f.recordID,
                role: f.role, position: f.position, required: f.required,
                fileObjectId: f.source.archivePath.flatMap { declarationsByPath[$0] }.flatMap { fileIDs[$0.id] },
                availability: f.source.availability, usedLegacyDrawingLocation: f.source.usedLegacyDrawingLocation,
                sourcePathSHA256: f.source.sourcePathSHA256, archiveHandleSHA256: f.source.archivePath.map(handleDigest))
        }
        var findings: [P.Finding] = graph.issues.map { issue in
            let qualified: Bool
            switch issue.code {
            case "historical_workflow_requires_reconciliation", "drawing_source_revision_unverified", "archive_relationship_findings_not_project_scoped": qualified = true
            case "source_findings_require_review":
                qualified = source.findingCounts.allSatisfy { ["drawing_provenance_unverified", "local_closure_unverified"].contains($0.category) }
            default: qualified = false
            }
            return .init(code: issue.code, kind: issue.kind, sourceId: issue.recordID, field: issue.field, disposition: qualified ? .qualification : .blocker)
        }
        func block(_ code: String, _ kind: LegacyImportRecordKind, _ id: UUID, _ field: String) {
            findings.append(.init(code: code, kind: kind, sourceId: id, field: field, disposition: .blocker))
        }
        func text(_ value: String?, maximum: Int, required: Bool = false) -> Bool {
            guard let value else { return !required }; return value.unicodeScalars.count <= maximum && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let projectTexts: [(String,String?,Int,Bool)] = [("name",project.name,200,true),("reference",project.reference,200,true),
            ("clientName",project.clientName,500,false),("clientEmail",project.clientEmail,500,false),("clientPhone",project.clientPhone,100,false),
            ("address",project.address,2000,false),("notes",project.notes,10000,false),("projectType",project.projectType,200,false),("customProjectType",project.customProjectType,200,false)]
        for (field,value,max,required) in projectTexts where !text(value,maximum:max,required:required) { block("canonical_value_requires_repair",.projects,project.id,field) }
        if project.latitude.map({ !(-90...90).contains($0) }) == true || project.longitude.map({ !(-180...180).contains($0) }) == true { block("canonical_value_requires_repair",.projects,project.id,"coordinates") }
        func decimal(_ value: Double?, id: UUID, field: String) -> String? {
            guard let value else { return nil }
            let raw = String(value)
            guard let number = Decimal(string: raw, locale: CanonicalValueService.decimalLocale) else { block("canonical_value_requires_repair",.snags,id,field); return nil }
            let encoded = NSDecimalNumber(decimal: number).stringValue
            guard (try? CanonicalValueService.decimal(.string(encoded))) != nil else { block("canonical_value_requires_repair",.snags,id,field); return nil }
            return encoded
        }
        let snags = source.snags.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }.enumerated().map { index,s in
            if !text(s.title,maximum:500,required:true) || s.title != s.title.trimmingCharacters(in:.whitespacesAndNewlines) { block("canonical_value_requires_repair",.snags,s.id,"title") }
            if !text(s.description,maximum:10000) || !text(s.location,maximum:500) { block("canonical_value_requires_repair",.snags,s.id,"descriptionOrLocation") }
            if !["low","medium","high","critical"].contains(s.priority) || s.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) == nil { block("canonical_value_requires_repair",.snags,s.id,"priorityOrCurrency") }
            if s.tags.count > 50 || Set(s.tags).count != s.tags.count || !s.tags.allSatisfy({ text($0,maximum:80,required:true) }) { block("canonical_value_requires_repair",.snags,s.id,"tags") }
            let state = workflow(s)
            if state.displayStatus == nil { block("unknown_workflow_requires_reconciliation",.snags,s.id,"localStatus") }
            return P.Snag(values:s,reference:s.reference,displayNumber:Int64(index + 1),initialVisibility:s.localStatus == "draft" ? "draft" : state.displayStatus == nil ? "unresolved" : "logged",costEstimateDecimal:decimal(s.costEstimate,id:s.id,field:"costEstimate"),actualCostDecimal:decimal(s.actualCost,id:s.id,field:"actualCost"),workflow:workflow(s),initialEntityRevision:1,initialWorkflowRevision:1)
        }
        let photos = source.photos.sorted { $0.id.uuidString < $1.id.uuidString }.map { p in
            P.Photo(id:p.id,snagId:p.snagID!,originalUseId:use(.photos,p.id,.photoOriginal),thumbnailUseId:use(.photos,p.id,.photoThumbnail),annotationUseId:use(.photos,p.id,.photoAnnotation),sourceLabelJSON:p.sourceLabelJSON,sourceLegacyLabelJSON:p.sourceLegacyLabelJSON,labelResolution:p.labelResolution,capturedAt:p.capturedAt,latitude:p.latitude,longitude:p.longitude,sortOrder:p.sortOrder,sourceCreatedAt:p.createdAt,renditionId:allocate("photoRendition/\(p.id.uuidString.lowercased())"),requiredFact:"decoded_source_image_and_safe_rendition_v1")
        }
        let drawings = source.drawings.sorted { $0.id.uuidString < $1.id.uuidString }.map { d in
            let assetId = allocate("drawingAsset/\(d.id.uuidString.lowercased())")
            let pageId = CanonicalDrawingService.pageID(assetID:assetId,index:0)
            allocations.append(.init(key:"drawingAssetPage/\(d.id.uuidString.lowercased())",targetId:pageId))
            if !text(d.name,maximum:200,required:true) || Int32(exactly:d.sortOrder) == nil { block("canonical_value_requires_repair",.drawings,d.id,"nameOrSortOrder") }
            return P.Drawing(id:d.id,name:d.name,projectId:project.id,fileUseId:use(.drawings,d.id,.drawingFile),thumbnailUseId:use(.drawings,d.id,.drawingThumbnail),sourcePageNumber:d.pageNumber,sortOrder:d.sortOrder,sourceCreatedAt:d.createdAt,sourceUpdatedAt:d.updatedAt,snagIds:d.sourceSnagIDs,provenance:d.provenance,assetId:assetId,assetPageId:pageId,versionId:allocate("drawingVersion/\(d.id.uuidString.lowercased())"),versionPageId:allocate("drawingVersionPage/\(d.id.uuidString.lowercased())"),requiredFact:"verified_single_legacy_coordinate_surface_v1")
        }
        let drawingIDs = Dictionary(uniqueKeysWithValues: drawings.map { ($0.id,$0) })
        let pins = source.snags.filter { $0.drawingID != nil || $0.drawingPinX != nil || $0.drawingPinY != nil }.sorted { $0.id.uuidString < $1.id.uuidString }.map { s in
            P.Pin(snagId:s.id,drawingId:s.drawingID,versionId:s.drawingID.flatMap { drawingIDs[$0]?.versionId },versionPageId:s.drawingID.flatMap { drawingIDs[$0]?.versionPageId },x:s.drawingPinX,y:s.drawingPinY,eventId:allocate("pinProjectionEvent/\(s.id.uuidString.lowercased())"),sourceShape:s.drawingPinX == nil && s.drawingPinY == nil ? "drawing_association_only" : "source_point",qualification:"source_coordinates_unverified_until_surface_processed")
        }
        let comments = source.comments.sorted { $0.id.uuidString < $1.id.uuidString }.map { c in
            P.Comment(id:c.id,snagId:c.snagID!,content:c.content,unverifiedAuthorId:c.unverifiedAuthorID,unverifiedAuthorName:c.unverifiedAuthorName,unverifiedAuthorType:c.unverifiedAuthorType,createdAt:c.createdAt,updatedAt:c.updatedAt,parentCommentId:c.parentCommentID,mentions:c.mentions,isFromContractorLink:c.isFromContractorLink,attachmentListState:c.attachmentPaths.state,attachmentListSourceBytes:c.attachmentPaths.sourceBytes,attachmentListSourceSHA256:c.attachmentPaths.sourceSHA256,attachmentUseIds:c.attachments.indices.map { use(.comments,c.id,.commentAttachment,$0) },provenance:c.provenance)
        }
        let deletions = source.deletionReceipts.sorted { $0.deletedSnagID.uuidString < $1.deletedSnagID.uuidString }.map { d in
            P.Deletion(deletedSnagId:d.deletedSnagID,projectId:d.projectID,reference:d.reference,unverifiedSourceOwnerId:d.unverifiedSourceOwnerID,createdAt:d.createdAt,historicalNeedsRemoteDeletion:d.historicalNeedsRemoteDeletion,photoUseIds:d.photoFiles.indices.map { use(.deletionReceipts,d.deletedSnagID,.deletedPhoto,$0) },execution:d.execution)
        }
        var directory: [P.DirectoryIdentity] = []
        func directoryRecord<T: Encodable>(_ value:T,kind:LegacyImportRecordKind,id:UUID) throws {
            directory.append(.init(kind:kind,sourceId:id,targetId:id,intrinsicSHA256:try directoryDigest(value,kind:kind),policy:"directory-intrinsic-v1"))
        }
        for c in source.contractors {
            if !text(c.companyName,maximum:200,required:true) || !text(c.contactName,maximum:200) || !text(c.phone,maximum:80) || !text(c.notes,maximum:5000) || !text(c.email,maximum:254) || c.email.map({ !EmailValidator.isValidFormat($0) }) == true || c.tradeIDs.count > 50 {
                block("canonical_directory_requires_repair",.contractors,c.id,"directoryFields")
            }
            try directoryRecord(c,kind:.contractors,id:c.id)
        }
        for t in source.trades {
            if !text(t.name,maximum:200,required:true) || t.colorHex.range(of:"^[0-9A-Fa-f]{6}$",options:.regularExpression) == nil || !(0...100000).contains(t.sortOrder) { block("canonical_directory_requires_repair",.trades,t.id,"directoryFields") }
            try directoryRecord(t,kind:.trades,id:t.id)
        }
        for f in source.folders { try directoryRecord(f,kind:.folders,id:f.id) }
        for t in source.tags { try directoryRecord(t,kind:.tags,id:t.id) }
        guard allocations.count <= graph.publicationBudget.journalEventUpperBound,
              Set(allocations.map(\.key)).count == allocations.count else { throw LegacyCanonicalProjectionError.capacity }
        try Task.checkCancellation()
        return .init(formatVersion:1,projectionId:projectionID,binding:.init(sessionId:receipt.sessionId,actorId:receipt.actorId,workspaceId:receipt.workspaceId,deviceId:receipt.deviceId,destination:receipt.destination,sourceFingerprint:receipt.sourceFingerprint,archiveId:source.source.archiveID,exportSHA256:receipt.exportSHA256,projectId:project.id,sourceRevision:receipt.revision),source:source.source,
            project:.init(id:project.id,name:project.name,reference:project.reference,clientName:project.clientName,clientEmail:project.clientEmail,clientPhone:project.clientPhone,address:project.address,latitude:project.latitude,longitude:project.longitude,projectType:project.projectType,customProjectType:project.customProjectType,notes:project.notes,startDate:project.startDate,expectedEndDate:project.expectedEndDate,localStatus:project.localStatus,isFavorite:project.isFavorite,sourceCreatedAt:project.createdAt,sourceUpdatedAt:project.updatedAt,folderId:project.folderID,tagIds:project.tagIDs,snagIds:project.sourceSnagIDs,drawingIds:project.sourceDrawingIDs,unverifiedSourceTeamId:project.unverifiedSourceTeamID,coverUseId:use(.projects,project.id,.projectCover)),
            snags:snags,photos:photos,drawings:drawings,pins:pins,contractors:source.contractors.sorted { $0.id.uuidString < $1.id.uuidString },trades:source.trades.sorted { $0.id.uuidString < $1.id.uuidString },folders:source.folders.sorted { $0.id.uuidString < $1.id.uuidString },tags:source.tags.sorted { $0.id.uuidString < $1.id.uuidString },comments:comments,statusHistory:source.statusHistory.sorted { $0.id.uuidString < $1.id.uuidString },deletions:deletions,
            sourceRecords:records.sorted { recordKey($0.kind,$0.sourceId) < recordKey($1.kind,$1.sourceId) },edges:graph.edges.map { .init(kind:$0.kind,sourceId:$0.recordID,field:$0.field,targetKind:$0.targetKind,targetId:$0.targetID,targetPresent:$0.targetPresent) },files:files,fileUses:fileUses,allocations:allocations.sorted { $0.key < $1.key },directoryIdentities:directory.sorted { recordKey($0.kind,$0.sourceId) < recordKey($1.kind,$1.sourceId) },findings:findings.sorted { "\($0.kind)/\($0.sourceId)/\($0.field)/\($0.code)" < "\($1.kind)/\($1.sourceId)/\($1.field)/\($1.code)" },excludedArchiveRecordCounts:source.excludedArchiveRecordCounts,archiveRelationshipIssueCounts:source.archiveRelationshipIssueCounts,sourceFindingCounts:source.findingCounts,sourceFindings:source.findings,omittedFindingCount:source.omittedFindingCount,limitations:source.limitations,journalEventUpperBound:graph.publicationBudget.journalEventUpperBound,snapshotRowUpperBound:graph.publicationBudget.snapshotRowUpperBound,importExecutable:false,publicationAcknowledgement:"not_requested_not_granted")
    }
}
