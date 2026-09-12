import Foundation
import XCTest
@testable import App

final class LegacyProjectImportContractTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-full-v1.json"))
    }
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private func expected(_ bytes: Data) -> LegacyProjectImportExpectedSource {
        .init(exportSHA256: LegacyProjectImportDecoder.digest(bytes), exportByteCount: bytes.count,
              selectedProjectID: id(1), sourceFingerprint: String(repeating: "a", count: 64))
    }
    private func decode(_ bytes: Data) throws -> LegacyProjectImportDecoded { try LegacyProjectImportDecoder.decode(bytes, expected: expected(bytes)) }
    private func graph(_ bytes: Data) throws -> LegacyProjectImportGraph {
        try LegacyProjectImportGraphValidator.validate(decode(bytes), capacity: .init(existingWorkspaceDirectoryRows: 0))
    }
    private func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any]); change(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func mutateRecord(_ value: inout [String: Any], _ key: String, _ change: (inout [String: Any]) -> Void) {
        var records = value[key] as! [[String: Any]]; change(&records[0]); value[key] = records
    }
    private func expect(_ error: LegacyProjectImportError, _ run: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try run(), file: file, line: line) { XCTAssertEqual($0 as? LegacyProjectImportError, error, file: file, line: line) }
    }
    func testActualNativeEncodedFixturePreservesEveryFieldAndExactBytes() throws {
        let bytes = try fixture(), decoded = try decode(bytes)
        XCTAssertEqual(decoded.bytes, bytes); XCTAssertEqual(decoded.sha256, expected(bytes).exportSHA256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(decoded.source), bytes, "All 187 source fields must survive without a narrower DTO round-trip")
        XCTAssertEqual(decoded.source.project.reference, "WC/P12/26")
        XCTAssertEqual(decoded.source.snags[0].reference, "P12-A/07")
        XCTAssertEqual(decoded.source.source.capturedAt.timeIntervalSinceReferenceDate, 810561600.125)
        XCTAssertEqual(decoded.source.snags[0].actualCost, 80.125)
        XCTAssertEqual(decoded.source.photos[1].sourceLegacyLabelJSON, "{\"type\":\"during\"}")
        XCTAssertEqual(decoded.source.drawings[0].pageNumber, 2)
        XCTAssertEqual(decoded.source.deletionReceipts[0].deletedSnagID, id(99))
        XCTAssertTrue(decoded.source.deletionReceipts[0].historicalNeedsRemoteDeletion)
        XCTAssertEqual(decoded.source.comments[1].unverifiedAuthorID, id(701))
    }
    func testCompleteCountsAllRolesAndEdgesAreDeterministicWithoutAuthority() throws {
        let g = try graph(fixture())
        XCTAssertEqual(g.sourceRecordCount, 16); XCTAssertEqual(g.sourceRecordIDs.count, 11)
        XCTAssertEqual(g.fileUses.count, 14); XCTAssertEqual(g.declaredFiles.count, 12)
        XCTAssertEqual(Set(g.fileUses.map(\.role)), Set(LegacyImportFileRole.allCases))
        XCTAssertEqual(g.edges.count, 40)
        XCTAssertEqual(g.publicationBudget.journalEventUpperBound, 135)
        XCTAssertTrue(g.edges.allSatisfy(\.targetPresent))
        XCTAssertFalse(g.issues.contains { $0.code.contains("mismatch") || $0.code == "missing_relationship" })
        XCTAssertTrue(g.issues.contains { $0.code == "historical_workflow_requires_reconciliation" && $0.recordID == id(3) })
        XCTAssertTrue(g.issues.contains { $0.code == "drawing_source_revision_unverified" })
        XCTAssertEqual(g.executionAuthority, "none"); XCTAssertEqual(g.mediaVerification, "source_declarations_only")
        XCTAssertEqual(g.historicalAcceptance, "unverified_no_canonical_decisions_created")
        let reversed = try changed { value in for key in ["snags", "photos", "folders", "comments"] { value[key] = (value[key] as! [Any]).reversed().map { $0 } } }
        let r = try graph(reversed)
        XCTAssertEqual(g.edges, r.edges); XCTAssertEqual(g.declaredFiles, r.declaredFiles)
        XCTAssertEqual(g.issues, r.issues); XCTAssertEqual(g.publicationBudget, r.publicationBudget)
    }
    func testWhitespaceChangesExactSourceFingerprintWithoutReencoding() throws {
        let bytes = try fixture(), spaced = Data(" \n".utf8) + bytes + Data("\n".utf8)
        let decoded = try decode(spaced); XCTAssertEqual(decoded.bytes, spaced)
        XCTAssertNotEqual(decoded.sha256, try decode(bytes).sha256)
        expect(.sourceMismatch) { _ = try LegacyProjectImportDecoder.decode(spaced, expected: self.expected(bytes)) }
    }
    func testBindingRejectsDifferentProjectFingerprintBytesOrLength() throws {
        let b = try fixture(), e = expected(b)
        for wrong in [LegacyProjectImportExpectedSource(exportSHA256: e.exportSHA256, exportByteCount: b.count, selectedProjectID: id(2), sourceFingerprint: e.sourceFingerprint),
                      .init(exportSHA256: e.exportSHA256, exportByteCount: b.count, selectedProjectID: id(1), sourceFingerprint: String(repeating: "b", count: 64)),
                      .init(exportSHA256: String(repeating: "c", count: 64), exportByteCount: b.count, selectedProjectID: id(1), sourceFingerprint: e.sourceFingerprint),
                      .init(exportSHA256: e.exportSHA256, exportByteCount: b.count + 1, selectedProjectID: id(1), sourceFingerprint: e.sourceFingerprint)] {
            expect(.sourceMismatch) { _ = try LegacyProjectImportDecoder.decode(b, expected: wrong) }
        }
    }
    func testRejectsDuplicateAndEscapedAliasKeysBeforeFoundationDropsOne() throws {
        for prefix in ["{\"formatVersion\":1,", "{\"format\\u0056ersion\":1,"] {
            let bytes = Data(prefix.utf8) + (try fixture()).dropFirst()
            expect(.duplicateKey) { _ = try self.decode(bytes) }
        }
    }
    func testClosedSchemaRejectsUnknownNestedFieldsAndMissingRequiredFields() throws {
        expect(.unknownField) { _ = try self.decode(self.changed { $0["credentials"] = "do-not-accept" }) }
        expect(.unknownField) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "photos") { $0["remoteURL"] = "https://example.invalid/private" } }) }
        expect(.missingField) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "comments") { $0.removeValue(forKey: "provenance") } }) }
        expect(.missingField) { _ = try self.decode(self.changed { $0["formatVersion"] = NSNull() }) }
    }
    func testWrongVersionMarkersDateFormatAndIntegerTypesAreRejected() throws {
        expect(.unsupportedVersion) { _ = try self.decode(self.changed { $0["formatVersion"] = 2 }) }
        expect(.invalidMarker) { _ = try self.decode(self.changed { $0["ownership"] = "account_owner" }) }
        expect(.invalidMarker) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "statusHistory") { $0["provenance"] = "verified_approval" } }) }
        expect(.invalidMarker) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "deletionReceipts") { $0["execution"] = "enqueue" } }) }
        expect(.malformedJSON) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "snags") { $0["createdAt"] = "2026-09-12T10:00:00Z" } }) }
        expect(.malformedJSON) { _ = try self.decode(self.changed { self.mutateRecord(&$0, "photos") { $0["sortOrder"] = 1.5 } }) }
        expect(.malformedJSON) { _ = try self.decode(self.changed { $0["formatVersion"] = true }) }
    }
    func testMalformedTruncatedDeepAndOversizeBytesAreBounded() throws {
        expect(.malformedJSON) { _ = try self.decode(Data((try self.fixture()).dropLast())) }
        let deep = Data((String(repeating: "[", count: 10)+"0"+String(repeating: "]", count: 10)).utf8)
        expect(.structureLimit) { _ = try self.decode(deep) }
        let huge = Data(repeating: 32, count: LegacyProjectImportDecoder.maximumBytes + 1)
        expect(.sizeLimit) { _ = try self.decode(huge) }
        expect(.structureLimit) { _ = try self.decode(self.changed { var p = $0["project"] as! [String: Any]; p["notes"] = String(repeating: "x", count: 256*1024+1); $0["project"] = p }) }
    }
    func testDuplicateRecordIDsAndDuplicateEdgesDoNotCollapseIntoSets() throws {
        expect(.duplicateID) { _ = try self.graph(self.changed { $0["snags"] = ($0["snags"] as! [Any]) + [($0["snags"] as! [Any])[0]] }) }
        expect(.duplicateID) { _ = try self.graph(self.changed { self.mutateRecord(&$0, "contractors") { $0["tradeIDs"] = [self.id(11).uuidString, self.id(11).uuidString] } }) }
    }
    func testForeignParentsRejectAndAsymmetricEdgesRemainExplicit() throws {
        expect(.invalidRecord) { _ = try self.graph(self.changed { self.mutateRecord(&$0, "photos") { $0["snagID"] = self.id(999).uuidString } }) }
        expect(.invalidRecord) { _ = try self.graph(self.changed { self.mutateRecord(&$0, "snags") { $0["projectID"] = self.id(888).uuidString } }) }
        let missing = try graph(changed { self.mutateRecord(&$0, "snags") { $0["sourcePhotoIDs"] = [self.id(404).uuidString] } })
        XCTAssertTrue(missing.edges.contains { !$0.targetPresent && $0.targetID == id(404) })
        XCTAssertTrue(missing.issues.contains { $0.code == "inverse_relationship_mismatch" })
        XCTAssertEqual(missing.decoded.source.photos.count, 3)
    }
    func testFolderAndCommentCyclesAreBoundedAndPreservedForRepair() throws {
        let g = try graph(changed { value in
            self.mutateRecord(&value, "folders") { $0["parentID"] = self.id(31).uuidString }
            self.mutateRecord(&value, "comments") { $0["parentCommentID"] = self.id(41).uuidString }
        })
        XCTAssertEqual(g.issues.filter { $0.code == "relationship_cycle" }.count, 2)
        XCTAssertEqual(g.decoded.source.folders[0].parentID, id(31))
    }
    func testInvalidPinsAndLiveDeletionConflictAreNotCanonicalCommands() throws {
        let g = try graph(changed { value in
            self.mutateRecord(&value, "snags") { $0["drawingPinX"] = -0.3 }
            self.mutateRecord(&value, "deletionReceipts") { $0["deletedSnagID"] = self.id(2).uuidString }
        })
        XCTAssertTrue(g.issues.contains { $0.code == "invalid_pin" })
        XCTAssertTrue(g.issues.contains { $0.code == "deletion_and_live_snag_share_id" })
        XCTAssertEqual(g.executionAuthority, "none")
    }
    func testMissingUnsafeAndAbsentFilesRetainDistinctRoles() throws {
        let g = try graph(changed { value in self.mutateRecord(&value, "photos") { photo in
            photo["original"] = ["availability":"missing", "usedLegacyDrawingLocation":false]
            photo["annotation"] = ["availability":"unsafePath", "usedLegacyDrawingLocation":false, "sourcePathSHA256":String(repeating:"d",count:64)]
        } })
        XCTAssertEqual(g.fileUses.count, 14); XCTAssertEqual(g.declaredFiles.count, 10)
        XCTAssertTrue(g.issues.contains { $0.code == "missing_source_file" && $0.field == "photoOriginal" })
        XCTAssertTrue(g.issues.contains { $0.code == "unsafe_source_path_retained_in_archive" })
        XCTAssertTrue(g.fileUses.contains { $0.source.availability == .notRecorded })
    }
    func testFileScopePathChecksumRoleAndConflictingDeclarationsAreRejected() throws {
        for key in ["archivePath", "sourcePathSHA256"] {
            let b = try changed { value in self.mutateRecord(&value, "photos") { photo in
                var f = photo["original"] as! [String: Any]; f[key] = key == "archivePath" ? "Documents/Photos/../escape" : String(repeating:"d",count:64); photo["original"] = f
            } }
            expect(.invalidFile) { _ = try self.graph(b) }
        }
        expect(.invalidFile) { _ = try self.graph(self.changed { value in self.mutateRecord(&value, "photos") { photo in var f = photo["original"] as! [String: Any]; f["usedLegacyDrawingLocation"] = true; photo["original"] = f } }) }
        expect(.invalidFile) { _ = try self.graph(self.changed { value in var photos = value["photos"] as! [[String: Any]]; var f = photos[0]["original"] as! [String: Any]; f["bytes"] = 9; photos[1]["original"] = f; value["photos"] = photos }) }
    }
    func testSharedBytesKeepAllRoleParentsAndCountStorageOnce() throws {
        let g = try graph(changed { value in self.mutateRecord(&value, "photos") { $0["thumbnail"] = $0["original"] } })
        XCTAssertEqual(g.fileUses.count, 14); XCTAssertEqual(g.declaredFiles.count, 11)
        XCTAssertEqual(g.fileRoleCounts[.photoOriginal], 3); XCTAssertEqual(g.fileRoleCounts[.photoThumbnail], 3)
    }
    func testZeroByteSourceAndLegacyDrawingFallbackAreHonestFacts() throws {
        let g = try graph(changed { value in self.mutateRecord(&value, "drawings") { drawing in
            var f = drawing["file"] as! [String: Any]; f["bytes"] = 0; f["sha256"] = LegacyProjectImportDecoder.digest(Data()); f["usedLegacyDrawingLocation"] = true
            f["archivePath"] = "Documents/Photos/" + (f["sourcePath"] as! String); drawing["file"] = f
        } })
        XCTAssertTrue(g.issues.contains { $0.code == "empty_declared_file" })
        XCTAssertTrue(g.fileUses.contains { $0.source.usedLegacyDrawingLocation })
    }
    func testUnreadableHistoricalListsRemainUnverifiedAndUnresolved() throws {
        let g = try graph(changed { value in self.mutateRecord(&value, "comments") { $0["mentions"] = ["sourceBytes":7,"sourceSHA256":String(repeating:"f",count:64),"state":"unreadable"] } })
        XCTAssertTrue(g.issues.contains { $0.code == "unreadable_mentions_retained_in_archive" })
        XCTAssertEqual(g.decoded.source.comments[0].mentions.sourceBytes, 7)
        expect(.invalidRecord) { _ = try self.graph(self.changed { value in self.mutateRecord(&value, "comments") { $0["mentions"] = ["sourceBytes":0,"state":"notRecorded","values":[]] } }) }
    }
    func testFindingCountsCannotPretendThatOmittedProblemsAreComplete() throws {
        expect(.invalidRecord) { _ = try self.graph(self.changed { $0["omittedFindingCount"] = 1 }) }
        let g = try graph(changed { $0["findings"] = []; $0["omittedFindingCount"] = 2 })
        XCTAssertTrue(g.issues.contains { $0.code == "source_findings_omitted" })
    }
    func testPublicationBudgetRejectsJournalAndWorkspaceSnapshotOverflow() throws {
        let d = try decode(fixture())
        let ordinary = try LegacyProjectImportGraphValidator.validate(d, capacity: .init(existingWorkspaceDirectoryRows: 0))
        let maximum = 10000 - ordinary.publicationBudget.journalEventUpperBound
        _ = try LegacyProjectImportGraphValidator.validate(d, capacity: .init(existingWorkspaceDirectoryRows: maximum))
        expect(.publicationLimit) { _ = try LegacyProjectImportGraphValidator.validate(d, capacity: .init(existingWorkspaceDirectoryRows: maximum + 1)) }
        expect(.invalidCapacity) { _ = try LegacyProjectImportGraphValidator.validate(d, capacity: .init(existingWorkspaceDirectoryRows: -1)) }
        let many = try changed { value in
            let template = (value["tags"] as! [[String:Any]])[0]
            value["tags"] = (1000..<1450).map { n -> [String:Any] in var r = template; r["id"] = self.id(n).uuidString; r["selectedProjectIDs"] = []; return r }
        }
        expect(.publicationLimit) { _ = try self.graph(many) }
    }
    func testTotalDeclaredBytesCannotExceedTwoGiB() throws {
        let b = try changed { value in self.mutateRecord(&value, "photos") { photo in var f = photo["original"] as! [String: Any]; f["bytes"] = 2*1024*1024*1024; photo["original"] = f } }
        expect(.byteLimit) { _ = try self.graph(b) }
    }
    func testCancellationDoesNotReturnPartiallyValidatedGraph() async throws {
        let bytes = try fixture(), binding = expected(bytes)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LegacyProjectImportDecoder.decode(bytes, expected: binding)
        }
        do { _ = try await task.value; XCTFail("Cancelled validation returned") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLabelResolutionCannotOverrideMissingOrUnreadableSource() throws {
        expect(.invalidRecord) { _ = try self.graph(self.changed { value in self.mutateRecord(&value, "photos") { $0.removeValue(forKey: "sourceLabelJSON") } }) }
        let preserved = try graph(changed { value in self.mutateRecord(&value, "photos") { $0["sourceLabelJSON"] = "unknown legacy syntax"; $0["labelResolution"] = "unreadable_or_unknown_json_needs_review" } })
        XCTAssertEqual(preserved.decoded.source.photos[0].sourceLabelJSON, "unknown legacy syntax")
        XCTAssertTrue(preserved.issues.contains { $0.code == "photo_label_requires_review" })
    }
    func testOmittedAttachmentListCannotCarryDetachedFilesAndUnselectedTagsAreQualified() throws {
        expect(.invalidRecord) { _ = try self.graph(self.changed { value in self.mutateRecord(&value, "comments") { $0["attachmentPaths"] = ["state":"notRecorded", "sourceBytes":0] } }) }
        let g = try graph(changed { value in var p = value["project"] as! [String:Any]; p["tagIDs"] = []; value["project"] = p })
        XCTAssertTrue(g.issues.contains { $0.field == "tagIDs" && $0.code == "inverse_relationship_mismatch" })
        XCTAssertEqual(g.decoded.source.tags.count, 1)
    }

    func testPortableFixtureContainsEveryDeclaredSourceByteWithExactHashes() throws {
        struct FixtureFile: Decodable { let path: String; let bytes: Int; let sha256: String; let base64: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-project-files-v1.json")
        let files = try JSONDecoder().decode([FixtureFile].self, from: Data(contentsOf: url))
        let g = try graph(fixture()), byPath = Dictionary(uniqueKeysWithValues: g.declaredFiles.map { ($0.archivePath, $0) })
        XCTAssertEqual(files.count, 12); XCTAssertEqual(Set(files.map(\.path)), Set(byPath.keys))
        var total: Int64 = 0
        for file in files {
            let data = try XCTUnwrap(Data(base64Encoded: file.base64)), declaration = try XCTUnwrap(byPath[file.path])
            XCTAssertEqual(data.count, file.bytes); XCTAssertEqual(Int64(file.bytes), declaration.bytes)
            XCTAssertEqual(LegacyProjectImportDecoder.digest(data), file.sha256); XCTAssertEqual(file.sha256, declaration.sha256)
            total += Int64(data.count)
        }
        XCTAssertEqual(total, g.totalDeclaredFileBytes)
    }

}
