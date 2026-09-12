import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Errors contain codes/schema paths only. Never include private source strings or URLs.
enum LegacyProjectImportError: Error, Equatable {
    case sizeLimit, structureLimit, malformedJSON, duplicateKey, unknownField, missingField
    case unsupportedVersion, sourceMismatch, invalidMarker, invalidDigest, invalidRecord, invalidFile
    case duplicateID, recordLimit, edgeLimit, fileLimit, byteLimit, invalidCapacity, publicationLimit
}

struct LegacyProjectImportExpectedSource: Sendable {
    let exportSHA256: String
    let exportByteCount: Int
    let selectedProjectID: UUID
    let sourceFingerprint: String
}

/// Private immutable bytes and their source graph; not an import/account/consent receipt.
struct LegacyProjectImportDecoded: Sendable {
    let bytes: Data
    let sha256: String
    let source: LegacyProjectImportSource
    fileprivate init(bytes: Data, sha256: String, source: LegacyProjectImportSource) {
        self.bytes = bytes; self.sha256 = sha256; self.source = source
    }
}

struct LegacyProjectImportDecoder {
    static let maximumBytes = 8 * 1024 * 1024
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func validDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func decode(_ bytes: Data, expected: LegacyProjectImportExpectedSource) throws -> LegacyProjectImportDecoded {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw LegacyProjectImportError.sizeLimit }
        guard validDigest(expected.exportSHA256), validDigest(expected.sourceFingerprint) else { throw LegacyProjectImportError.invalidDigest }
        let checksum = digest(bytes)
        guard bytes.count == expected.exportByteCount, checksum == expected.exportSHA256 else { throw LegacyProjectImportError.sourceMismatch }
        var scanner = UniqueKeys(bytes: Array(bytes)); try scanner.validate()
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: bytes) }
        catch { throw LegacyProjectImportError.malformedJSON }
        try check(object, shape: .object("LegacyProjectImportSource"))
        let source: LegacyProjectImportSource
        do {
            // Native's hashed JSONEncoder uses its DEFAULT Date strategy: seconds
            // since 2001-01-01. ISO-8601/Unix milliseconds would reinterpret source.
            source = try JSONDecoder().decode(LegacyProjectImportSource.self, from: bytes)
        } catch { throw LegacyProjectImportError.malformedJSON }
        guard source.formatVersion == 1 else { throw LegacyProjectImportError.unsupportedVersion }
        guard source.project.id == expected.selectedProjectID,
              source.source.sourceFingerprint == expected.sourceFingerprint else { throw LegacyProjectImportError.sourceMismatch }
        guard [source.source.sourceFingerprint, source.source.databaseSHA256, source.source.inventorySHA256].allSatisfy(validDigest) else { throw LegacyProjectImportError.invalidDigest }
        guard source.purpose == "local_selected_project_preparation_only",
              source.ownership == "unverified_no_destination_account", source.canonicalAcceptance == "not_checked",
              source.mediaContentValidation == "hashes_only_not_decoded_or_rendered",
              source.limitations == limitations,
              ["matches_recorded_inventory", "not_recorded_in_legacy_copy"].contains(source.source.inventoryComparison),
              source.drawings.allSatisfy({ $0.provenance == "source_and_revision_unverified" }),
              source.comments.allSatisfy({ $0.provenance == "unverified_local_history" }),
              source.statusHistory.allSatisfy({ $0.provenance == "unverified_local_history_not_canonical_approval" }),
              source.deletionReceipts.allSatisfy({ $0.execution == "never_enqueue_from_this_descriptor" }) else { throw LegacyProjectImportError.invalidMarker }
        try Task.checkCancellation()
        return .init(bytes: bytes, sha256: checksum, source: source)
    }

    private indirect enum Shape: Sendable { case scalar, array(Shape), object(String) }
    private struct Field: Sendable { let shape: Shape; let required: Bool }
    private static func check(_ value: Any, shape: Shape) throws {
        try Task.checkCancellation()
        switch shape {
        case .scalar:
            if let text = value as? String, text.utf8.count > 256 * 1024 { throw LegacyProjectImportError.structureLimit }
        case .array(let element):
            guard let values = value as? [Any] else { throw LegacyProjectImportError.malformedJSON }
            guard values.count <= 50_000 else { throw LegacyProjectImportError.structureLimit }
            for value in values { try check(value, shape: element) }
        case .object(let name):
            guard let values = value as? [String: Any], let fields = shapes[name] else { throw LegacyProjectImportError.malformedJSON }
            guard Set(values.keys).isSubset(of: Set(fields.keys)) else { throw LegacyProjectImportError.unknownField }
            for (key, field) in fields {
                guard let value = values[key], !(value is NSNull) else {
                    if field.required { throw LegacyProjectImportError.missingField }
                    continue
                }
                try check(value, shape: field.shape)
            }
        }
    }

    /// Foundation chooses one duplicate object key. Reject it first, including
    /// escaped aliases; JSONDecoder still validates all strings/scalars/UTF-8.
    private struct UniqueKeys {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func validate() throws {
            try value(depth: 0); whitespace()
            guard index == bytes.count else { throw LegacyProjectImportError.malformedJSON }
        }
        mutating func value(depth: Int) throws {
            nodes += 1
            guard depth <= 8, nodes <= 300_000 else { throw LegacyProjectImportError.structureLimit }
            if nodes % 128 == 0 { try Task.checkCancellation() }
            whitespace(); guard index < bytes.count else { throw LegacyProjectImportError.malformedJSON }
            switch bytes[index] {
            case 123:
                index += 1; whitespace(); var keys = Set<String>()
                if take(125) { return }
                while true {
                    whitespace(); let range = try string()
                    let key: String
                    do { key = try JSONDecoder().decode(String.self, from: Data(bytes[range])) }
                    catch { throw LegacyProjectImportError.malformedJSON }
                    guard keys.insert(key).inserted else { throw LegacyProjectImportError.duplicateKey }
                    whitespace(); guard take(58) else { throw LegacyProjectImportError.malformedJSON }
                    try value(depth: depth + 1); whitespace()
                    if take(125) { return }
                    guard take(44) else { throw LegacyProjectImportError.malformedJSON }
                }
            case 91:
                index += 1; whitespace(); if take(93) { return }
                while true {
                    try value(depth: depth + 1); whitespace(); if take(93) { return }
                    guard take(44) else { throw LegacyProjectImportError.malformedJSON }
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw LegacyProjectImportError.malformedJSON }
            }
        }
        mutating func string() throws -> Range<Int> {
            let start = index; guard take(34) else { throw LegacyProjectImportError.malformedJSON }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return start..<index }
                if byte == 92 { index += 1 }
            }
            throw LegacyProjectImportError.malformedJSON
        }
        mutating func whitespace() { while index < bytes.count, [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
    }

    private static let limitations = [
        "Original media bytes and excluded records remain in the retained source archive.",
        "This descriptor has no destination account, membership, upload or queue authority.",
        "Local status, closure, authors and deletion owners are unverified historical values.",
        "Drawing source/revision provenance and canonical completion submissions are not established.",
        "Only the selected project, its child-owned records and directly relevant shared records are included.",
        "Shared contractor/trade/folder/tag relationships to other projects are deliberately omitted.",
        "Recorded child IDs may identify missing or excluded targets; findings must be resolved before import.",
        "Current-schema readback does not prove preservation of unknown older-schema attributes.",
        "Structured credentials and executable requests are excluded; ordinary user text remains private source data.",
        "Stored error diagnostics are excluded because they may contain token-bearing URLs; the source archive retains them."
]
    private static let shapes: [String: [String: Field]] = [
        "LegacyProjectImportSource": [
            "formatVersion": .init(shape: .scalar, required: true),
            "purpose": .init(shape: .scalar, required: true),
            "ownership": .init(shape: .scalar, required: true),
            "canonicalAcceptance": .init(shape: .scalar, required: true),
            "mediaContentValidation": .init(shape: .scalar, required: true),
            "source": .init(shape: .object("Source"), required: true),
            "project": .init(shape: .object("Project"), required: true),
            "snags": .init(shape: .array(.object("Snag")), required: true),
            "photos": .init(shape: .array(.object("Photo")), required: true),
            "drawings": .init(shape: .array(.object("Drawing")), required: true),
            "contractors": .init(shape: .array(.object("Contractor")), required: true),
            "trades": .init(shape: .array(.object("Trade")), required: true),
            "folders": .init(shape: .array(.object("Folder")), required: true),
            "tags": .init(shape: .array(.object("Tag")), required: true),
            "comments": .init(shape: .array(.object("Comment")), required: true),
            "statusHistory": .init(shape: .array(.object("StatusChange")), required: true),
            "deletionReceipts": .init(shape: .array(.object("DeletionReceipt")), required: true),
            "excludedArchiveRecordCounts": .init(shape: .array(.object("Count")), required: true),
            "archiveRelationshipIssueCounts": .init(shape: .array(.object("Count")), required: true),
            "findings": .init(shape: .array(.object("Finding")), required: true),
            "findingCounts": .init(shape: .array(.object("Count")), required: true),
            "omittedFindingCount": .init(shape: .scalar, required: true),
            "limitations": .init(shape: .array(.scalar), required: true)
        ],
        "Source": [
            "archiveID": .init(shape: .scalar, required: true),
            "capturedAt": .init(shape: .scalar, required: true),
            "appVersion": .init(shape: .scalar, required: true),
            "sourceFingerprint": .init(shape: .scalar, required: true),
            "databaseSHA256": .init(shape: .scalar, required: true),
            "inventorySHA256": .init(shape: .scalar, required: true),
            "inventoryComparison": .init(shape: .scalar, required: true)
        ],
        "Finding": [
            "code": .init(shape: .scalar, required: true),
            "recordID": .init(shape: .scalar, required: false),
            "field": .init(shape: .scalar, required: true)
        ],
        "Count": [
            "category": .init(shape: .scalar, required: true),
            "count": .init(shape: .scalar, required: true)
        ],
        "FileReference": [
            "sourcePath": .init(shape: .scalar, required: false),
            "sourcePathSHA256": .init(shape: .scalar, required: false),
            "archivePath": .init(shape: .scalar, required: false),
            "bytes": .init(shape: .scalar, required: false),
            "sha256": .init(shape: .scalar, required: false),
            "availability": .init(shape: .scalar, required: true),
            "usedLegacyDrawingLocation": .init(shape: .scalar, required: true)
        ],
        "StringList": [
            "values": .init(shape: .array(.scalar), required: false),
            "sourceBytes": .init(shape: .scalar, required: true),
            "sourceSHA256": .init(shape: .scalar, required: false),
            "state": .init(shape: .scalar, required: true)
        ],
        "Project": [
            "id": .init(shape: .scalar, required: true),
            "name": .init(shape: .scalar, required: true),
            "reference": .init(shape: .scalar, required: true),
            "clientName": .init(shape: .scalar, required: false),
            "clientEmail": .init(shape: .scalar, required: false),
            "clientPhone": .init(shape: .scalar, required: false),
            "address": .init(shape: .scalar, required: false),
            "latitude": .init(shape: .scalar, required: false),
            "longitude": .init(shape: .scalar, required: false),
            "projectType": .init(shape: .scalar, required: false),
            "customProjectType": .init(shape: .scalar, required: false),
            "startDate": .init(shape: .scalar, required: false),
            "expectedEndDate": .init(shape: .scalar, required: false),
            "cover": .init(shape: .object("FileReference"), required: true),
            "notes": .init(shape: .scalar, required: false),
            "localStatus": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "isFavorite": .init(shape: .scalar, required: true),
            "sourceSnagIDs": .init(shape: .array(.scalar), required: true),
            "sourceDrawingIDs": .init(shape: .array(.scalar), required: true),
            "folderID": .init(shape: .scalar, required: false),
            "tagIDs": .init(shape: .array(.scalar), required: true),
            "unverifiedSourceTeamID": .init(shape: .scalar, required: false)
        ],
        "Snag": [
            "id": .init(shape: .scalar, required: true),
            "reference": .init(shape: .scalar, required: true),
            "title": .init(shape: .scalar, required: true),
            "description": .init(shape: .scalar, required: false),
            "localStatus": .init(shape: .scalar, required: true),
            "priority": .init(shape: .scalar, required: true),
            "location": .init(shape: .scalar, required: false),
            "drawingPinX": .init(shape: .scalar, required: false),
            "drawingPinY": .init(shape: .scalar, required: false),
            "dueDate": .init(shape: .scalar, required: false),
            "costEstimate": .init(shape: .scalar, required: false),
            "actualCost": .init(shape: .scalar, required: false),
            "currency": .init(shape: .scalar, required: true),
            "tags": .init(shape: .array(.scalar), required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "unverifiedClosedAt": .init(shape: .scalar, required: false),
            "historicalContractorLinkSentAt": .init(shape: .scalar, required: false),
            "projectID": .init(shape: .scalar, required: false),
            "tradeID": .init(shape: .scalar, required: false),
            "contractorID": .init(shape: .scalar, required: false),
            "drawingID": .init(shape: .scalar, required: false),
            "sourcePhotoIDs": .init(shape: .array(.scalar), required: true),
            "sourceCommentIDs": .init(shape: .array(.scalar), required: true),
            "sourceStatusChangeIDs": .init(shape: .array(.scalar), required: true)
        ],
        "Photo": [
            "id": .init(shape: .scalar, required: true),
            "snagID": .init(shape: .scalar, required: false),
            "original": .init(shape: .object("FileReference"), required: true),
            "thumbnail": .init(shape: .object("FileReference"), required: true),
            "annotation": .init(shape: .object("FileReference"), required: true),
            "sourceLabelJSON": .init(shape: .scalar, required: false),
            "sourceLegacyLabelJSON": .init(shape: .scalar, required: false),
            "labelResolution": .init(shape: .scalar, required: true),
            "capturedAt": .init(shape: .scalar, required: true),
            "latitude": .init(shape: .scalar, required: false),
            "longitude": .init(shape: .scalar, required: false),
            "sortOrder": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true)
        ],
        "Drawing": [
            "id": .init(shape: .scalar, required: true),
            "name": .init(shape: .scalar, required: true),
            "file": .init(shape: .object("FileReference"), required: true),
            "thumbnail": .init(shape: .object("FileReference"), required: true),
            "pageNumber": .init(shape: .scalar, required: false),
            "sortOrder": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "projectID": .init(shape: .scalar, required: false),
            "sourceSnagIDs": .init(shape: .array(.scalar), required: true),
            "provenance": .init(shape: .scalar, required: true)
        ],
        "Contractor": [
            "id": .init(shape: .scalar, required: true),
            "companyName": .init(shape: .scalar, required: true),
            "contactName": .init(shape: .scalar, required: false),
            "email": .init(shape: .scalar, required: false),
            "phone": .init(shape: .scalar, required: false),
            "notes": .init(shape: .scalar, required: false),
            "isArchived": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "tradeIDs": .init(shape: .array(.scalar), required: true),
            "selectedSnagIDs": .init(shape: .array(.scalar), required: true)
        ],
        "Trade": [
            "id": .init(shape: .scalar, required: true),
            "name": .init(shape: .scalar, required: true),
            "colorHex": .init(shape: .scalar, required: true),
            "sortOrder": .init(shape: .scalar, required: true),
            "isArchived": .init(shape: .scalar, required: true),
            "isDefault": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "selectedContractorIDs": .init(shape: .array(.scalar), required: true),
            "selectedSnagIDs": .init(shape: .array(.scalar), required: true)
        ],
        "Folder": [
            "id": .init(shape: .scalar, required: true),
            "name": .init(shape: .scalar, required: true),
            "colorHex": .init(shape: .scalar, required: true),
            "sortOrder": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "parentID": .init(shape: .scalar, required: false),
            "selectedChildIDs": .init(shape: .array(.scalar), required: true),
            "selectedProjectIDs": .init(shape: .array(.scalar), required: true)
        ],
        "Tag": [
            "id": .init(shape: .scalar, required: true),
            "name": .init(shape: .scalar, required: true),
            "colorHex": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: true),
            "selectedProjectIDs": .init(shape: .array(.scalar), required: true)
        ],
        "Comment": [
            "id": .init(shape: .scalar, required: true),
            "snagID": .init(shape: .scalar, required: false),
            "content": .init(shape: .scalar, required: true),
            "unverifiedAuthorID": .init(shape: .scalar, required: false),
            "unverifiedAuthorName": .init(shape: .scalar, required: true),
            "unverifiedAuthorType": .init(shape: .scalar, required: true),
            "createdAt": .init(shape: .scalar, required: true),
            "updatedAt": .init(shape: .scalar, required: false),
            "parentCommentID": .init(shape: .scalar, required: false),
            "mentions": .init(shape: .object("StringList"), required: true),
            "isFromContractorLink": .init(shape: .scalar, required: true),
            "attachmentPaths": .init(shape: .object("StringList"), required: true),
            "attachments": .init(shape: .array(.object("FileReference")), required: true),
            "provenance": .init(shape: .scalar, required: true)
        ],
        "StatusChange": [
            "id": .init(shape: .scalar, required: true),
            "snagID": .init(shape: .scalar, required: false),
            "fromLocalStatus": .init(shape: .scalar, required: true),
            "toLocalStatus": .init(shape: .scalar, required: true),
            "unverifiedChangedByID": .init(shape: .scalar, required: false),
            "unverifiedChangedByName": .init(shape: .scalar, required: true),
            "unverifiedChangedByType": .init(shape: .scalar, required: true),
            "reason": .init(shape: .scalar, required: false),
            "createdAt": .init(shape: .scalar, required: true),
            "provenance": .init(shape: .scalar, required: true)
        ],
        "DeletionReceipt": [
            "deletedSnagID": .init(shape: .scalar, required: true),
            "projectID": .init(shape: .scalar, required: true),
            "reference": .init(shape: .scalar, required: true),
            "unverifiedSourceOwnerID": .init(shape: .scalar, required: false),
            "createdAt": .init(shape: .scalar, required: true),
            "historicalNeedsRemoteDeletion": .init(shape: .scalar, required: true),
            "photoFiles": .init(shape: .array(.object("FileReference")), required: true),
            "execution": .init(shape: .scalar, required: true)
        ]
    ]
}
