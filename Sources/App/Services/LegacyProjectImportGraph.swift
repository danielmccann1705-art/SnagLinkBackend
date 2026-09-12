import Foundation

enum LegacyImportRecordKind: String, CaseIterable, Codable, Sendable {
    case projects, snags, photos, drawings, contractors, trades, folders, tags, comments, statusHistory, deletionReceipts
}
enum LegacyImportFileRole: String, CaseIterable, Codable, Sendable {
    case projectCover, photoOriginal, photoThumbnail, photoAnnotation, drawingFile, drawingThumbnail, commentAttachment, deletedPhoto
}
struct LegacyImportIssue: Equatable, Sendable {
    let code: String
    let kind: LegacyImportRecordKind
    let recordID: UUID
    let field: String
}
struct LegacyImportEdge: Equatable, Sendable {
    let kind: LegacyImportRecordKind
    let recordID: UUID
    let field: String
    let targetKind: LegacyImportRecordKind
    let targetID: UUID
    let targetPresent: Bool
}
struct LegacyImportFileUse: Sendable {
    let kind: LegacyImportRecordKind
    let recordID: UUID
    let role: LegacyImportFileRole
    let position: Int
    let required: Bool
    let source: LegacyProjectImportSource.FileReference
}
struct LegacyImportDeclaredFile: Equatable, Sendable {
    /// Private retained-archive handle, never a destination key or log value.
    let archivePath: String
    let bytes: Int64
    let sha256: String
}
struct LegacyImportCapacity: Sendable {
    /// Must be supplied from current authorised server inventory by a future
    /// coordinator. This pure value API does not query or establish authority.
    let existingWorkspaceDirectoryRows: Int
}
struct LegacyImportProjectionBudget: Equatable, Sendable {
    let policy = "full-source-graph-upper-bound-v1"
    let journalEventUpperBound: Int
    let snapshotRowUpperBound: Int
    let maximumJournalEvents = 1000
    let maximumSnapshotRows = 10000
}
struct LegacyProjectImportGraph: Sendable {
    let decoded: LegacyProjectImportDecoded
    let sourceRecordIDs: [LegacyImportRecordKind: [UUID]]
    let edges: [LegacyImportEdge]
    let fileUses: [LegacyImportFileUse]
    let declaredFiles: [LegacyImportDeclaredFile]
    let totalDeclaredFileBytes: Int64
    let issues: [LegacyImportIssue]
    let sourceRecordCount: Int
    let fileRoleCounts: [LegacyImportFileRole: Int]
    let publicationBudget: LegacyImportProjectionBudget
    /// Source shape/inverse-graph completion ONLY. It is not actual media decode,
    /// verified ownership, current ACL, consent, an upload receipt or permission.
    var hasUnresolvedSourceFacts: Bool { !issues.isEmpty }
    let executionAuthority = "none"
    let mediaVerification = "source_declarations_only"
    let historicalAcceptance = "unverified_no_canonical_decisions_created"
    fileprivate init(decoded: LegacyProjectImportDecoded, sourceRecordIDs: [LegacyImportRecordKind: [UUID]],
                     edges: [LegacyImportEdge], fileUses: [LegacyImportFileUse], declaredFiles: [LegacyImportDeclaredFile],
                     totalDeclaredFileBytes: Int64, issues: [LegacyImportIssue], sourceRecordCount: Int,
                     fileRoleCounts: [LegacyImportFileRole: Int], publicationBudget: LegacyImportProjectionBudget) {
        self.decoded = decoded; self.sourceRecordIDs = sourceRecordIDs; self.edges = edges; self.fileUses = fileUses
        self.declaredFiles = declaredFiles; self.totalDeclaredFileBytes = totalDeclaredFileBytes; self.issues = issues
        self.sourceRecordCount = sourceRecordCount; self.fileRoleCounts = fileRoleCounts; self.publicationBudget = publicationBudget
    }
}

struct LegacyProjectImportGraphValidator {
    typealias Source = LegacyProjectImportSource
    typealias Kind = LegacyImportRecordKind
    static let maximumRecords = 10_000
    static let maximumEdges = 50_000
    static let maximumFileUses = 50_000
    static let maximumFiles = 20_000
    static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    static func validate(_ decoded: LegacyProjectImportDecoded, capacity: LegacyImportCapacity) throws -> LegacyProjectImportGraph {
        guard (0...10000).contains(capacity.existingWorkspaceDirectoryRows) else { throw LegacyProjectImportError.invalidCapacity }
        var audit = Audit(source: decoded.source)
        try audit.run()
        let s = decoded.source
        // A closed, conservative contract for this first bounded graph: one
        // canonical row + one source/provenance row per source record; one row
        // per declared edge; two per retained unique file plus two per file-role
        // use (including absent roles, so byte aliases cannot undercount bindings); four extra drawing
        // asset/page/version/page rows; three per pin; one final import receipt.
        // Downstream mapping MUST assert its actual writes fit this bound. It is
        // not a count of tables already implemented or of verified uploads.
        let pins = s.snags.filter { $0.drawingID != nil || $0.drawingPinX != nil || $0.drawingPinY != nil }.count
        let projected = audit.recordCount * 2 + audit.edges.count + audit.files.count * 2 + audit.uses.count * 2 + s.drawings.count * 4 + pins * 3 + 1
        let budget = LegacyImportProjectionBudget(journalEventUpperBound: projected,
            snapshotRowUpperBound: projected + capacity.existingWorkspaceDirectoryRows)
        guard budget.journalEventUpperBound <= budget.maximumJournalEvents,
              budget.snapshotRowUpperBound <= budget.maximumSnapshotRows else { throw LegacyProjectImportError.publicationLimit }
        try Task.checkCancellation()
        return .init(decoded: decoded, sourceRecordIDs: audit.ids.mapValues { $0.sorted(by: less) },
                     edges: audit.edges.sorted { edgeKey($0) < edgeKey($1) },
                     fileUses: audit.uses.sorted { useKey($0) < useKey($1) },
                     declaredFiles: audit.files.values.sorted { $0.archivePath < $1.archivePath },
                     totalDeclaredFileBytes: audit.totalBytes,
                     issues: audit.issues.sorted { issueKey($0) < issueKey($1) }, sourceRecordCount: audit.recordCount,
                     fileRoleCounts: Dictionary(uniqueKeysWithValues: LegacyImportFileRole.allCases.map { role in (role, audit.uses.filter { $0.role == role }.count) }), publicationBudget: budget)
    }
    private static func less(_ a: UUID, _ b: UUID) -> Bool { a.uuidString < b.uuidString }
    private static func edgeKey(_ e: LegacyImportEdge) -> String { "\(e.kind.rawValue)/\(e.recordID)/\(e.field)/\(e.targetKind.rawValue)/\(e.targetID)" }
    private static func useKey(_ f: LegacyImportFileUse) -> String { "\(f.kind.rawValue)/\(f.recordID)/\(f.role.rawValue)/\(String(format: "%06d", f.position))" }
    private static func issueKey(_ i: LegacyImportIssue) -> String { "\(i.kind.rawValue)/\(i.recordID)/\(i.field)/\(i.code)" }

    private struct Audit {
        let source: Source
        var ids: [Kind: [UUID]] = [:]
        var idSets: [Kind: Set<UUID>] = [:]
        var recordCount = 0
        var edges: [LegacyImportEdge] = []
        var uses: [LegacyImportFileUse] = []
        var files: [String: LegacyImportDeclaredFile] = [:]
        var totalBytes: Int64 = 0
        var issues: [LegacyImportIssue] = []
        mutating func issue(_ code: String, _ kind: Kind, _ id: UUID, _ field: String) {
            issues.append(.init(code: code, kind: kind, recordID: id, field: field))
        }
        mutating func records(_ kind: Kind, _ values: [UUID]) throws {
            recordCount += values.count
            guard recordCount <= maximumRecords else { throw LegacyProjectImportError.recordLimit }
            let set = Set(values); guard set.count == values.count else { throw LegacyProjectImportError.duplicateID }
            ids[kind] = values; idSets[kind] = set
        }
        mutating func edge(_ kind: Kind, _ id: UUID, _ field: String, _ target: Kind, _ values: [UUID]) throws {
            guard Set(values).count == values.count else { throw LegacyProjectImportError.duplicateID }
            guard edges.count + values.count <= maximumEdges else { throw LegacyProjectImportError.edgeLimit }
            for (index, value) in values.enumerated() {
                if index % 128 == 0 { try Task.checkCancellation() }
                let present = idSets[target]?.contains(value) == true
                edges.append(.init(kind: kind, recordID: id, field: field, targetKind: target, targetID: value, targetPresent: present))
                if !present { issue("missing_relationship", kind, id, field) }
            }
        }
        mutating func inverse(_ kind: Kind, _ id: UUID, _ field: String, _ actual: [UUID], _ expected: [UUID]) {
            if Set(actual) != Set(expected) { issue("inverse_relationship_mismatch", kind, id, field) }
        }
        mutating func run() throws {
            let s = source, p = s.project
            try records(.projects, [p.id]); try records(.snags, s.snags.map(\.id)); try records(.photos, s.photos.map(\.id))
            try records(.drawings, s.drawings.map(\.id)); try records(.contractors, s.contractors.map(\.id)); try records(.trades, s.trades.map(\.id))
            try records(.folders, s.folders.map(\.id)); try records(.tags, s.tags.map(\.id)); try records(.comments, s.comments.map(\.id))
            try records(.statusHistory, s.statusHistory.map(\.id)); try records(.deletionReceipts, s.deletionReceipts.map(\.deletedSnagID))
            // Reject an impossible publication before quadratic inverse review;
            // all source record counts were validated first, with no truncation.
            guard recordCount * 2 + 1 <= 1000 else { throw LegacyProjectImportError.publicationLimit }
            try counts(s.excludedArchiveRecordCounts); try counts(s.archiveRelationshipIssueCounts); try counts(s.findingCounts)
            guard s.findings.count <= 1000, s.omittedFindingCount >= 0, s.omittedFindingCount <= 100_000,
                  s.findings.count + s.omittedFindingCount == s.findingCounts.reduce(0, { $0 + $1.count }) else { throw LegacyProjectImportError.invalidRecord }
            let displayed = Dictionary(grouping: s.findings, by: \.code).mapValues(\.count)
            guard displayed.allSatisfy({ code, count in s.findingCounts.contains { $0.category == code && $0.count >= count } }) else { throw LegacyProjectImportError.invalidRecord }
            if s.omittedFindingCount > 0 { issue("source_findings_omitted", .projects, p.id, "omittedFindingCount") }
            if s.findingCounts.contains(where: { $0.count > 0 }) { issue("source_findings_require_review", .projects, p.id, "findingCounts") }
            if s.archiveRelationshipIssueCounts.contains(where: { $0.count > 0 }) { issue("archive_relationship_findings_not_project_scoped", .projects, p.id, "archiveRelationshipIssueCounts") }
            if s.source.inventoryComparison != "matches_recorded_inventory" { issue("source_inventory_unavailable", .projects, p.id, "inventoryComparison") }
            try edge(.projects, p.id, "sourceSnagIDs", .snags, p.sourceSnagIDs)
            try edge(.projects, p.id, "sourceDrawingIDs", .drawings, p.sourceDrawingIDs)
            try edge(.projects, p.id, "folderID", .folders, p.folderID.map { [$0] } ?? [])
            try edge(.projects, p.id, "tagIDs", .tags, p.tagIDs)
            inverse(.projects, p.id, "sourceSnagIDs", p.sourceSnagIDs, s.snags.map(\.id))
            inverse(.projects, p.id, "sourceDrawingIDs", p.sourceDrawingIDs, s.drawings.map(\.id))
            inverse(.projects, p.id, "tagIDs", p.tagIDs, s.tags.map(\.id))
            try file(p.cover, kind: .projects, id: p.id, role: .projectCover)
            for snag in s.snags {
                try Task.checkCancellation()
                guard snag.projectID == p.id else { throw LegacyProjectImportError.invalidRecord }
                try edge(.snags, snag.id, "projectID", .projects, [p.id])
                try edge(.snags, snag.id, "contractorID", .contractors, snag.contractorID.map { [$0] } ?? [])
                try edge(.snags, snag.id, "tradeID", .trades, snag.tradeID.map { [$0] } ?? [])
                try edge(.snags, snag.id, "drawingID", .drawings, snag.drawingID.map { [$0] } ?? [])
                try edge(.snags, snag.id, "sourcePhotoIDs", .photos, snag.sourcePhotoIDs)
                try edge(.snags, snag.id, "sourceCommentIDs", .comments, snag.sourceCommentIDs)
                try edge(.snags, snag.id, "sourceStatusChangeIDs", .statusHistory, snag.sourceStatusChangeIDs)
                inverse(.snags, snag.id, "sourcePhotoIDs", snag.sourcePhotoIDs, s.photos.filter { $0.snagID == snag.id }.map(\.id))
                inverse(.snags, snag.id, "sourceCommentIDs", snag.sourceCommentIDs, s.comments.filter { $0.snagID == snag.id }.map(\.id))
                inverse(.snags, snag.id, "sourceStatusChangeIDs", snag.sourceStatusChangeIDs, s.statusHistory.filter { $0.snagID == snag.id }.map(\.id))
                if snag.drawingPinX != nil || snag.drawingPinY != nil {
                    if let x = snag.drawingPinX, let y = snag.drawingPinY, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), snag.drawingID != nil {} else { issue("invalid_pin", .snags, snag.id, "drawingPin") }
                }
                if snag.localStatus != "open" || snag.unverifiedClosedAt != nil { issue("historical_workflow_requires_reconciliation", .snags, snag.id, "localStatus") }
                if idSets[.deletionReceipts]?.contains(snag.id) == true { issue("deletion_and_live_snag_share_id", .snags, snag.id, "id") }
                guard snag.tags.count <= 1000 else { throw LegacyProjectImportError.structureLimit }
            }
            for photo in s.photos {
                guard let snag = photo.snagID, idSets[.snags]?.contains(snag) == true else { throw LegacyProjectImportError.invalidRecord }
                try edge(.photos, photo.id, "snagID", .snags, [snag])
                try file(photo.original, kind: .photos, id: photo.id, role: .photoOriginal, required: true)
                try file(photo.thumbnail, kind: .photos, id: photo.id, role: .photoThumbnail)
                try file(photo.annotation, kind: .photos, id: photo.id, role: .photoAnnotation)
                guard photo.labelResolution == labelResolution(photo.sourceLabelJSON, legacy: photo.sourceLegacyLabelJSON) else { throw LegacyProjectImportError.invalidRecord }
                if ["not_recorded", "unreadable_or_unknown_json_needs_review"].contains(photo.labelResolution) { issue("photo_label_requires_review", .photos, photo.id, "labelResolution") }
            }
            for drawing in s.drawings {
                guard drawing.projectID == p.id else { throw LegacyProjectImportError.invalidRecord }
                try edge(.drawings, drawing.id, "projectID", .projects, [p.id])
                try edge(.drawings, drawing.id, "sourceSnagIDs", .snags, drawing.sourceSnagIDs)
                inverse(.drawings, drawing.id, "sourceSnagIDs", drawing.sourceSnagIDs, s.snags.filter { $0.drawingID == drawing.id }.map(\.id))
                try file(drawing.file, kind: .drawings, id: drawing.id, role: .drawingFile, required: true)
                try file(drawing.thumbnail, kind: .drawings, id: drawing.id, role: .drawingThumbnail)
                issue("drawing_source_revision_unverified", .drawings, drawing.id, "provenance")
            }
            for contractor in s.contractors {
                try edge(.contractors, contractor.id, "tradeIDs", .trades, contractor.tradeIDs)
                try edge(.contractors, contractor.id, "selectedSnagIDs", .snags, contractor.selectedSnagIDs)
                inverse(.contractors, contractor.id, "selectedSnagIDs", contractor.selectedSnagIDs, s.snags.filter { $0.contractorID == contractor.id }.map(\.id))
            }
            for trade in s.trades {
                try edge(.trades, trade.id, "selectedContractorIDs", .contractors, trade.selectedContractorIDs)
                try edge(.trades, trade.id, "selectedSnagIDs", .snags, trade.selectedSnagIDs)
                inverse(.trades, trade.id, "selectedContractorIDs", trade.selectedContractorIDs, s.contractors.filter { $0.tradeIDs.contains(trade.id) }.map(\.id))
                inverse(.trades, trade.id, "selectedSnagIDs", trade.selectedSnagIDs, s.snags.filter { $0.tradeID == trade.id }.map(\.id))
            }
            for folder in s.folders {
                try edge(.folders, folder.id, "parentID", .folders, folder.parentID.map { [$0] } ?? [])
                try edge(.folders, folder.id, "selectedChildIDs", .folders, folder.selectedChildIDs)
                try edge(.folders, folder.id, "selectedProjectIDs", .projects, folder.selectedProjectIDs)
                inverse(.folders, folder.id, "selectedChildIDs", folder.selectedChildIDs, s.folders.filter { $0.parentID == folder.id }.map(\.id))
                inverse(.folders, folder.id, "selectedProjectIDs", folder.selectedProjectIDs, p.folderID == folder.id ? [p.id] : [])
            }
            for tag in s.tags {
                try edge(.tags, tag.id, "selectedProjectIDs", .projects, tag.selectedProjectIDs)
                inverse(.tags, tag.id, "selectedProjectIDs", tag.selectedProjectIDs, p.tagIDs.contains(tag.id) ? [p.id] : [])
            }
            for comment in s.comments {
                guard let snag = comment.snagID, idSets[.snags]?.contains(snag) == true else { throw LegacyProjectImportError.invalidRecord }
                try edge(.comments, comment.id, "snagID", .snags, [snag])
                try edge(.comments, comment.id, "parentCommentID", .comments, comment.parentCommentID.map { [$0] } ?? [])
                if let parent = comment.parentCommentID, s.comments.first(where: { $0.id == parent })?.snagID != snag { issue("comment_parent_not_same_snag", .comments, comment.id, "parentCommentID") }
                try list(comment.mentions); try list(comment.attachmentPaths)
                guard comment.mentions.state != .decodedWithExcludedUnsafePaths,
                      comment.attachmentPaths.values != nil || comment.attachments.isEmpty else { throw LegacyProjectImportError.invalidRecord }
                if comment.mentions.state == .unreadable { issue("unreadable_mentions_retained_in_archive", .comments, comment.id, "mentions") }
                if [.unreadable, .decodedWithExcludedUnsafePaths].contains(comment.attachmentPaths.state) { issue("incomplete_attachment_list", .comments, comment.id, "attachmentPaths") }
                for (position, attachment) in comment.attachments.enumerated() { try file(attachment, kind: .comments, id: comment.id, role: .commentAttachment, position: position) }
                let safePaths = comment.attachments.compactMap(\.sourcePath).filter(Self.validPath)
                if comment.attachmentPaths.values != nil && comment.attachmentPaths.values != safePaths { issue("attachment_role_list_mismatch", .comments, comment.id, "attachments") }
            }
            for event in s.statusHistory {
                guard let snag = event.snagID, idSets[.snags]?.contains(snag) == true else { throw LegacyProjectImportError.invalidRecord }
                try edge(.statusHistory, event.id, "snagID", .snags, [snag])
            }
            for deletion in s.deletionReceipts {
                guard deletion.projectID == p.id else { throw LegacyProjectImportError.invalidRecord }
                try edge(.deletionReceipts, deletion.deletedSnagID, "projectID", .projects, [p.id])
                for (position, attachment) in deletion.photoFiles.enumerated() { try file(attachment, kind: .deletionReceipts, id: deletion.deletedSnagID, role: .deletedPhoto, position: position) }
            }
            cycles(s.folders.map { ($0.id, $0.parentID) }, kind: .folders, field: "parentID")
            cycles(s.comments.map { ($0.id, $0.parentCommentID) }, kind: .comments, field: "parentCommentID")
        }
        mutating func cycles(_ pairs: [(UUID, UUID?)], kind: Kind, field: String) {
            let parents = Dictionary(uniqueKeysWithValues: pairs), known = Set(pairs.map { $0.0 })
            var complete = Set<UUID>()
            for start in known.sorted(by: less) where !complete.contains(start) {
                var seen = Set<UUID>(), id: UUID? = start
                while let current = id, known.contains(current), !complete.contains(current) {
                    if !seen.insert(current).inserted { issue("relationship_cycle", kind, current, field); break }
                    id = parents[current] ?? nil
                }
                complete.formUnion(seen)
            }
        }
        func labelResolution(_ json: String?, legacy: String?) -> String {
            guard let json else { return legacy == nil ? "not_recorded" : "legacy_attribute" }
            guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = value["type"] as? String, ["before", "during", "after", "custom"].contains(type),
                  type != "custom" || value["customValue"] is String else { return "unreadable_or_unknown_json_needs_review" }
            return "stored_json"
        }
        func counts(_ values: [Source.Count]) throws {
            guard values.count <= 100, Set(values.map(\.category)).count == values.count,
                  values.allSatisfy({ !$0.category.isEmpty && $0.category.utf8.count <= 128 && (0...100_000).contains($0.count) }) else { throw LegacyProjectImportError.invalidRecord }
        }
        func list(_ list: Source.StringList) throws {
            guard (0...(256 * 1024)).contains(list.sourceBytes), (list.values?.count ?? 0) <= 1000 else { throw LegacyProjectImportError.structureLimit }
            switch list.state {
            case .notRecorded:
                guard list.values == nil, list.sourceBytes == 0, list.sourceSHA256 == nil else { throw LegacyProjectImportError.invalidRecord }
            case .decoded, .decodedWithExcludedUnsafePaths:
                guard list.values != nil, list.sourceSHA256.map(LegacyProjectImportDecoder.validDigest) == true else { throw LegacyProjectImportError.invalidRecord }
            case .unreadable:
                guard list.values == nil, list.sourceSHA256.map(LegacyProjectImportDecoder.validDigest) == true else { throw LegacyProjectImportError.invalidRecord }
            }
        }
        static func validPath(_ path: String) -> Bool {
            guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("%"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
        mutating func file(_ f: Source.FileReference, kind: Kind, id: UUID, role: LegacyImportFileRole, position: Int = 0, required: Bool = false) throws {
            try Task.checkCancellation()
            guard uses.count < maximumFileUses else { throw LegacyProjectImportError.fileLimit }
            uses.append(.init(kind: kind, recordID: id, role: role, position: position, required: required, source: f))
            if let path = f.sourcePath {
                guard LegacyProjectImportDecoder.digest(Data(path.utf8)) == f.sourcePathSHA256 else { throw LegacyProjectImportError.invalidFile }
            } else if let digest = f.sourcePathSHA256, !LegacyProjectImportDecoder.validDigest(digest) { throw LegacyProjectImportError.invalidFile }
            let drawing = [.drawingFile, .drawingThumbnail].contains(role)
            switch f.availability {
            case .verifiedBytes:
                guard let path = f.sourcePath, Self.validPath(path), let archive = f.archivePath, Self.validPath(archive),
                      let bytes = f.bytes, (0...maximumFileBytes).contains(bytes), let sha = f.sha256, LegacyProjectImportDecoder.validDigest(sha),
                      !f.usedLegacyDrawingLocation || drawing else { throw LegacyProjectImportError.invalidFile }
                let prefix = drawing && !f.usedLegacyDrawingLocation ? "Documents/FloorPlans/" : "Documents/Photos/"
                guard archive == prefix + path else { throw LegacyProjectImportError.invalidFile }
                let file = LegacyImportDeclaredFile(archivePath: archive, bytes: bytes, sha256: sha)
                if let old = files[archive] { guard old == file else { throw LegacyProjectImportError.invalidFile } }
                else {
                    guard files.count < maximumFiles else { throw LegacyProjectImportError.fileLimit }
                    let sum = totalBytes.addingReportingOverflow(bytes)
                    guard !sum.overflow, sum.partialValue <= maximumFileBytes else { throw LegacyProjectImportError.byteLimit }
                    totalBytes = sum.partialValue; files[archive] = file
                }
                if bytes == 0 { issue("empty_declared_file", kind, id, role.rawValue) }
            case .missing, .notRecorded:
                guard f.archivePath == nil, f.bytes == nil, f.sha256 == nil, !f.usedLegacyDrawingLocation,
                      (f.sourcePath != nil || f.sourcePathSHA256 == nil),
                      f.sourcePath == nil || f.sourcePath == "" || Self.validPath(f.sourcePath!) else { throw LegacyProjectImportError.invalidFile }
                if f.availability == .notRecorded {
                    guard f.sourcePath == nil || f.sourcePath == "" else { throw LegacyProjectImportError.invalidFile }
                }
                if f.availability == .missing || required { issue("missing_source_file", kind, id, role.rawValue) }
            case .unsafePath:
                guard f.sourcePath == nil, f.sourcePathSHA256.map(LegacyProjectImportDecoder.validDigest) == true,
                      f.archivePath == nil, f.bytes == nil, f.sha256 == nil, !f.usedLegacyDrawingLocation else { throw LegacyProjectImportError.invalidFile }
                issue("unsafe_source_path_retained_in_archive", kind, id, role.rawValue)
            }
        }
    }
}
