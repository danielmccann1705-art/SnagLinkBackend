@testable import App
import XCTVapor
import Fluent
import JWT

final class SnagDeletionJSONTests: XCTestCase {
    func testRemovesOnlyTargetAndPreservesUnknownFieldsAndCounts() throws {
        let id = UUID(), retained = UUID(), drawing = UUID()
        let original = """
        {"custom":{"future":true},"project":{"snagCount":2,"closedSnagCount":1,"completionPercentage":50,"custom":"keep"},"drawings":[{"id":"\(drawing)","snagPinCount":2}],"snags":[{"id":"\(id)","status":"closed","drawingId":"\(drawing)","photos":[{"private":"removed"}]},{"id":"\(retained)","status":"open","custom":"keep"}]}
        """
        let json = try SnagDeletionService.removing([id], from: original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let snags = try XCTUnwrap(object["snags"] as? [[String: Any]])
        XCTAssertEqual(snags.count, 1)
        XCTAssertEqual(snags[0]["id"] as? String, retained.uuidString)
        XCTAssertEqual(snags[0]["custom"] as? String, "keep")
        XCTAssertNotNil(object["custom"])
        let project = try XCTUnwrap(object["project"] as? [String: Any])
        XCTAssertEqual(project["snagCount"] as? Int, 1)
        XCTAssertEqual(project["closedSnagCount"] as? Int, 0)
        XCTAssertEqual(project["completionPercentage"] as? Double, 0)
        XCTAssertEqual(project["custom"] as? String, "keep")
        XCTAssertEqual((object["drawings"] as? [[String: Any]])?.first?["snagPinCount"] as? Int, 1)
        XCTAssertFalse(json.contains("removed"))
        XCTAssertEqual(try SnagDeletionService.removing([id], from: json), json, "Repeated filtering must not reduce counts twice")
    }

    func testLastSnagProducesEmptyReportAndFinitePercentage() throws {
        let id = UUID()
        let input = "{\"project\":{\"snagCount\":1,\"closedSnagCount\":0},\"snags\":[{\"id\":\"\(id)\"}]}"
        let result = try SnagDeletionService.removing([id], from: input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual((object["snags"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((object["project"] as? [String: Any])?["completionPercentage"] as? Double, 0)
    }

    func testUnrelatedDeleteDoesNotRewriteSnapshot() throws {
        let input = "{\"snags\":[],\"unknown\":17}"
        XCTAssertEqual(try SnagDeletionService.removing([UUID()], from: input), input)
        XCTAssertEqual(try SnagDeletionService.removing([], from: input), input)
    }
}

/// Uses a disposable DATABASE_URL in development/CI; never supplies production settings.
final class SnagDeletionEndpointTests: XCTestCase {
    private enum ForcedRollback: Error { case expectedGuard, unexpectedDelete }
    var app: Application!
    override func setUp() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil, "Requires isolated PostgreSQL DATABASE_URL")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        app = nil
    }

    private func owner() async throws -> (UUID, UUID, String) {
        let user = User(appleUserId: nil, email: "delete-\(UUID())@example.test", name: "Owner", authProvider: .magicLink)
        try await user.save(on: app.db)
        let id = try user.requireID()
        let project = Project(name: "Deletion test", reference: "D", ownerId: id)
        try await project.save(on: app.db)
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString),
            expiration: .init(value: Date().addingTimeInterval(600)), userId: id))
        return (id, try project.requireID(), jwt)
    }

    private func remove(id: UUID, project: UUID, jwt: String?, expect status: HTTPResponseStatus) async throws {
        try await app.test(.POST, "api/v1/snags/\(id)/deletion", beforeRequest: { req in
            if let jwt { req.headers.bearerAuthorization = .init(token: jwt) }
            try req.content.encode(["projectId": project.uuidString])
        }, afterResponse: { res async in XCTAssertEqual(res.status, status) })
    }

    func testDeletionRequiresOwnerAndIsIdempotent() async throws {
        let (ownerId, projectId, jwt) = try await owner()
        let (_, _, otherJWT) = try await owner()
        let snag = Snag(reference: "D-001", title: "Door", projectId: projectId, ownerId: ownerId)
        try await snag.save(on: app.db)
        let id = try snag.requireID()
        try await remove(id: id, project: projectId, jwt: nil, expect: .unauthorized)
        try await remove(id: id, project: projectId, jwt: otherJWT, expect: .notFound)
        let retainedSnag = try await Snag.find(id, on: app.db)
        XCTAssertNotNil(retainedSnag)
        try await remove(id: id, project: projectId, jwt: jwt, expect: .noContent)
        try await remove(id: id, project: projectId, jwt: jwt, expect: .noContent)
        let removedSnag = try await Snag.find(id, on: app.db)
        XCTAssertNil(removedSnag)
        let receipt = try await SnagDeletionService.receipt(id: id, ownerId: ownerId, projectId: projectId, on: app.db)
        XCTAssertNotNil(receipt)
        try await remove(id: id, project: projectId, jwt: otherJWT, expect: .notFound)
    }

    func testReportOnlySnagDeletedFromEveryOwnedSnapshotWithoutBroadeningLinks() async throws {
        let (ownerId, projectId, jwt) = try await owner()
        let id = UUID(), other = UUID()
        let reportJSON = "{\"snags\":[{\"id\":\"\(id)\",\"title\":\"Delete\"},{\"id\":\"\(other)\",\"title\":\"Keep\"}]}"
        var links: [MagicLink] = []
        for _ in 0..<2 {
            let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
                expiresAt: Date().addingTimeInterval(600), snagIds: [id], projectId: projectId, createdById: ownerId)
            try await link.save(on: app.db); links.append(link)
            try await SyncedReport(magicLinkToken: link.token, reportJSON: reportJSON).save(on: app.db)
            let completion = Completion(snagId: id, magicLinkId: try link.requireID(), contractorName: "Demo")
            try await completion.save(on: app.db)
            try await HistoricalCompletionPhotoFixture.insert(completionID:try completion.requireID(),url:"https://example.test/external.jpg",on:app.db)
        }
        try await remove(id: id, project: projectId, jwt: jwt, expect: .noContent)
        for link in links {
            let fetchedReport = try await SyncedReport.query(on: app.db).filter(\.$magicLinkToken == link.token).first()
        let report = try XCTUnwrap(fetchedReport)
            XCTAssertFalse(report.reportJSON.contains(id.uuidString))
            XCTAssertTrue(report.reportJSON.contains(other.uuidString))
            let fetchedLink = try await MagicLink.find(link.id, on: app.db)
            let reloaded = try XCTUnwrap(fetchedLink)
            XCTAssertEqual(reloaded.snagIds, [id])
        }
        let completionCount = try await Completion.query(on: app.db).filter(\.$snagId == id).count()
        XCTAssertEqual(completionCount, 0)
        // Simulate a stale upload that raced deletion. Read filtering still removes it.
        let visible = try await SnagDeletionService.visibleReportJSON(reportJSON, ownerId: ownerId, projectId: projectId, on: app.db)
        XCTAssertFalse(visible.contains(id.uuidString))
        try await app.test(.PATCH, "api/v1/magic-links/\(links[0].token)/snags/\(id)/status", beforeRequest: { req in
            try req.content.encode(["status": "in_progress"])
        }, afterResponse: { res async in XCTAssertEqual(res.status, .gone) })
    }

    func testStaleCreateAndReportUploadsCannotResurrectDeletedSnag() async throws {
        let (ownerId, projectId, jwt) = try await owner()
        let id = UUID()
        try await remove(id: id, project: projectId, jwt: jwt, expect: .noContent)
        struct CreateBody: Content { let id: UUID; let title: String; let reference: String; let projectId: UUID }
        try await app.test(.POST, "api/v1/snags", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            try req.content.encode(CreateBody(id: id, title: "Stale", reference: "D-001", projectId: projectId))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .gone) })
        let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
            expiresAt: Date().addingTimeInterval(600), snagIds: [id], projectId: projectId, createdById: ownerId)
        try await link.save(on: app.db)
        try await app.test(.POST, "api/v1/magic-links/\(link.token)/report", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: "{\"snags\":[{\"id\":\"\(id)\",\"title\":\"Stale\"}]}")
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })
        let fetchedReport = try await SyncedReport.query(on: app.db).filter(\.$magicLinkToken == link.token).first()
        let report = try XCTUnwrap(fetchedReport)
        XCTAssertFalse(report.reportJSON.contains(id.uuidString))
    }

    func testDeletionCannotHideAnotherOwnerOrProjectsReportWithSameUUID() async throws {
        let (ownerA, projectA, jwtA) = try await owner()
        let (ownerB, projectB, jwtB) = try await owner()
        let projectA2 = Project(name: "Other project", reference: "OTHER", ownerId: ownerA)
        try await projectA2.save(on: app.db)
        let projectA2Id = try projectA2.requireID()
        let id = UUID()
        let json = "{\"snags\":[{\"id\":\"\(id)\",\"title\":\"Keep in this scope\"}]}"
        for (account, project) in [(ownerA, projectA), (ownerB, projectB), (ownerA, projectA2Id)] {
            let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
                expiresAt: Date().addingTimeInterval(600), snagIds: [id], projectId: project, createdById: account)
            try await link.save(on: app.db)
            try await SyncedReport(magicLinkToken: link.token, reportJSON: json).save(on: app.db)
            try await Completion(snagId: id, magicLinkId: try link.requireID(), contractorName: "Scope test").save(on: app.db)
        }
        // A report may contain a copied/forged UUID: that must never affect a different scope.
        try await remove(id: id, project: projectA, jwt: jwtA, expect: .noContent)
        let visibleA = try await SnagDeletionService.visibleReportJSON(json, ownerId: ownerA, projectId: projectA, on: app.db)
        let visibleB = try await SnagDeletionService.visibleReportJSON(json, ownerId: ownerB, projectId: projectB, on: app.db)
        let visibleA2 = try await SnagDeletionService.visibleReportJSON(json, ownerId: ownerA, projectId: projectA2Id, on: app.db)
        XCTAssertFalse(visibleA.contains(id.uuidString))
        for visible in [visibleB, visibleA2] {
            let object = try JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any]
            let snags = try XCTUnwrap(object?["snags"] as? [[String: Any]])
            XCTAssertEqual(snags.count, 1)
            XCTAssertEqual(snags.first?["id"] as? String, id.uuidString)
            XCTAssertEqual(snags.first?["title"] as? String, "Keep in this scope")
            // Each unaffected scope has its own pending completion. Its status
            // survives even though the uploaded snapshot omitted that field.
            XCTAssertEqual(snags.first?["status"] as? String, "submitted")
        }
        try await SnagDeletionService.requireActive(id, ownerId: ownerB, projectId: projectB, on: app.db)
        try await SnagDeletionService.requireActive(id, ownerId: ownerA, projectId: projectA2Id, on: app.db)
        try await app.test(.GET, "api/v1/completions/pending", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwtA)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(PendingCompletionsResponse.self)
            XCTAssertEqual(body?.totalCount, 1, "Another project with the same UUID remains visible")
        })
        try await app.test(.GET, "api/v1/snags/\(id)/completions", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwtA)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagCompletionsResponse.self)
            XCTAssertEqual(body?.completions.count, 1, "Only owned active project links may return evidence")
        })
        let canonical = Snag(id: id, reference: "OTHER-001", title: "Keep canonical", projectId: projectA2Id, ownerId: ownerA)
        try await canonical.save(on: app.db)
        try await app.test(.GET, "api/v1/snags/\(id)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwtA)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })
        try await app.test(.GET, "api/v1/snags?projectId=\(projectA2Id)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwtA)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = try? res.content.decode(SnagListSyncResponse.self)
            XCTAssertEqual(body?.totalCount, 1)
        })
        // A's receipt must not prevent the real owner from independently deleting their copy.
        try await remove(id: id, project: projectB, jwt: jwtB, expect: .noContent)
        let receipts = try await SnagDeletion.query(on: app.db).filter(\.$snagId == id).all()
        XCTAssertEqual(receipts.count, 2)
    }

    func testLegacyReceiptGuardUsesExactOwnedLinkWithoutCanonicalParent() async throws {
        let (ownerId, projectId, _) = try await owner()
        let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
            expiresAt: Date().addingTimeInterval(600), snagIds: [], projectId: projectId, createdById: ownerId)
        try await link.save(on: app.db)
        try await Project.query(on: app.db).filter(\.$id == projectId).delete()

        let deletedSnag = UUID()
        try await SnagDeletionService.delete(id: deletedSnag, projectId: projectId, ownerId: ownerId, on: app.db)
        let loadedReceipt = try await SnagDeletionService.receipt(
            id: deletedSnag, ownerId: ownerId, projectId: projectId, on: app.db)
        let receipt = try XCTUnwrap(loadedReceipt)

        try await link.delete(on: app.db)
        receipt.filePaths = ["/uploads/synced-photos/already-authorised.jpg"]
        try await receipt.save(on: app.db)
        let updatedReceipt = try await SnagDeletion.find(receipt.id, on: app.db)
        XCTAssertEqual(updatedReceipt?.filePaths,
                       ["/uploads/synced-photos/already-authorised.jpg"])

        let (otherOwner, otherProject, _) = try await owner()
        let otherLink = MagicLink(token: UUID().uuidString, accessLevel: .update,
            expiresAt: Date().addingTimeInterval(600), snagIds: [], projectId: otherProject, createdById: otherOwner)
        try await otherLink.save(on: app.db)
        try await Project.query(on: app.db).filter(\.$id == otherProject).delete()
        let forged = SnagDeletion(snagId: UUID(), ownerId: ownerId, projectId: otherProject)
        do {
            try await forged.save(on: app.db)
            XCTFail("Another owner's legacy link must not authorise a deletion receipt")
        } catch { }
        let forgedReceipt = try await SnagDeletionService.receipt(
            id: forged.snagId, ownerId: ownerId, projectId: otherProject, on: app.db)
        XCTAssertNil(forgedReceipt)
    }

    func testDirectOrphanCompletionPhotoDeleteIsRejectedOutsideCascade() async throws {
        let (ownerId, projectId, _) = try await owner()
        let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
            expiresAt: Date().addingTimeInterval(600), snagIds: [], projectId: projectId, createdById: ownerId)
        try await link.save(on: app.db)
        let completion = Completion(snagId: UUID(), magicLinkId: try link.requireID(), contractorName: "Synthetic")
        try await completion.save(on: app.db)
        let completionID = try completion.requireID()
        try await HistoricalCompletionPhotoFixture.insert(
            completionID: completionID, url: "https://example.test/historical.jpg", on: app.db)
        let inserted = try await CompletionPhoto.query(on: app.db)
            .filter(\.$completion.$id == completionID).first()
        let exactPhotoID = try XCTUnwrap(inserted?.id)

        do {
            try await app.db.transaction { db in
                let sql = try VerifiedIdentityService.sql(db)
                try await sql.raw("ALTER TABLE completion_photos DROP CONSTRAINT completion_photos_completion_id_fkey").run()
                try await sql.raw("DELETE FROM completions WHERE id=\(bind:completionID)").run()
                do {
                    try await sql.raw("DELETE FROM completion_photos WHERE id=\(bind:exactPhotoID)").run()
                    throw ForcedRollback.unexpectedDelete
                } catch is ForcedRollback { throw ForcedRollback.unexpectedDelete }
                catch { throw ForcedRollback.expectedGuard }
            }
            XCTFail("The synthetic transaction must roll back")
        } catch ForcedRollback.expectedGuard { }
        catch { XCTFail("Unexpected direct-orphan result: \(error)") }
    }

    func testMigrationIsAdditiveAndCanRunTwice() async throws {
        let (ownerId, projectId, _) = try await owner()
        let snag = Snag(reference: "D-001", title: "Keep evidence", projectId: projectId, ownerId: ownerId)
        try await snag.save(on: app.db)
        try await CreateSnagDeletion().prepare(on: app.db)
        try await CreateSnagDeletion().prepare(on: app.db)
        let retained = try await Snag.find(snag.id, on: app.db)
        XCTAssertEqual(retained?.title, "Keep evidence")
    }

    func testDeletionCleansOwnedPhotoFilesAndKeepsUnrelatedEvidence() async throws {
        let (ownerId, projectId, jwt) = try await owner()
        let id = UUID(), other = UUID()
        let link = MagicLink(token: UUID().uuidString, accessLevel: .update,
            expiresAt: Date().addingTimeInterval(600), snagIds: [id, other], projectId: projectId, createdById: ownerId)
        try await link.save(on: app.db)
        let path = "/uploads/synced-photos/\(UUID()).jpg"
        let retainedPath = "/uploads/synced-photos/\(UUID()).jpg"
        let base = URL(fileURLWithPath: app.directory.publicDirectory)
        let deletedURL = base.appendingPathComponent(String(path.dropFirst()))
        let keptURL = base.appendingPathComponent(String(retainedPath.dropFirst()))
        try FileManager.default.createDirectory(at: deletedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deleted fixture".utf8).write(to: deletedURL)
        try Data("retained fixture".utf8).write(to: keptURL)
        defer { try? FileManager.default.removeItem(at: deletedURL); try? FileManager.default.removeItem(at: keptURL) }
        try await SyncedPhoto(magicLinkToken: link.token, snagId: id, label: "before", filePath: path, sortOrder: 0).save(on: app.db)
        try await SyncedPhoto(magicLinkToken: link.token, snagId: other, label: "before", filePath: retainedPath, sortOrder: 0).save(on: app.db)
        try await remove(id: id, project: projectId, jwt: jwt, expect: .noContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
        let count = try await SyncedPhoto.query(on: app.db).filter(\.$snagId == id).count()
        XCTAssertEqual(count, 0)
    }
}
