@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class OwnershipTransferTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture() async throws -> (Team, UUID, UUID, UUID) {
        try await app.db.transaction { db in
            let owner = try await VerifiedIdentityService.resolveEmail("transfer-owner-\(UUID())@example.test", name: "Owner", on: db)
            let member = try await VerifiedIdentityService.resolveEmail("transfer-target-\(UUID())@example.test", name: "Member", on: db)
            let outsider = try await VerifiedIdentityService.resolveEmail("transfer-other-\(UUID())@example.test", name: "Other", on: db)
            let company = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic company", actorID: owner.requireID(), on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: company.requireID(), userID: member.requireID(), role: "member", on: db)
            return try (company, owner.requireID(), member.requireID(), outsider.requireID())
        }
    }
    private func propose(_ company: Team, owner: UUID, target: UUID) async throws -> OwnershipTransferResponse {
        try await app.db.transaction { db in
            try await OwnershipTransferService.propose(workspaceID: company.requireID(), targetID: target, expectedRevision: company.revision, actorID: owner, on: db)
        }
    }
    private func currentOwner(_ company: Team) async throws -> UUID {
        let team = try await Team.find(company.requireID(), on: app.db)
        return try XCTUnwrap(team).ownerUserId
    }
    func testOfferDoesNotTransferAndDeletionRemainsBlockedUntilRecipientAccepts() async throws {
        let (company, owner, target, _) = try await fixture()
        let offer = try await propose(company, owner: owner, target: target)
        XCTAssertEqual(offer.state, "pending")
        let before = try await currentOwner(company)
        XCTAssertEqual(before, owner)
        do {
            _ = try await AccountDeletionService.request(userID: owner, body: .init(confirmation: "DELETE", receiptReference: String(repeating: "a", count: 43) + UUID().uuidString), app: app)
            XCTFail("A proposal cannot permit owner deletion")
        } catch let abort as Abort { XCTAssertEqual(abort.identifier, "company_owner_action_required") }
        let accepted = try await app.db.transaction { db in try await OwnershipTransferService.accept(id: offer.id, actorID: target, on: db) }
        XCTAssertEqual(accepted.state, "accepted")
        let after = try await currentOwner(company)
        XCTAssertEqual(after, target)
        let replay = try await app.db.transaction { db in try await OwnershipTransferService.accept(id: offer.id, actorID: target, on: db) }
        XCTAssertEqual(replay.id, offer.id); XCTAssertEqual(replay.resolvedAt, accepted.resolvedAt)
    }
    func testWrongRecipientAndOwnerCannotAccept() async throws {
        let (company, owner, target, outsider) = try await fixture()
        let offer = try await propose(company, owner: owner, target: target)
        for actor in [owner, outsider] {
            do {
                _ = try await app.db.transaction { db in try await OwnershipTransferService.accept(id: offer.id, actorID: actor, on: db) }
                XCTFail("Only the named recipient can accept")
            } catch let abort as Abort { XCTAssertEqual(abort.status, .notFound) }
        }
        let actual = try await currentOwner(company)
        XCTAssertEqual(actual, owner)
    }
    func testRemovedOrChangedRecipientCannotAcceptStaleOffer() async throws {
        let (company, owner, target, _) = try await fixture()
        let offer = try await propose(company, owner: owner, target: target)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.changeMember(workspaceID: company.requireID(), targetID: target, newRole: nil, expectedRevision: 1, actorID: owner, on: db)
        }
        do {
            _ = try await app.db.transaction { db in try await OwnershipTransferService.accept(id: offer.id, actorID: target, on: db) }
            XCTFail("Removed recipient cannot accept")
        } catch let abort as Abort { XCTAssertEqual(abort.status, .conflict) }
        let actual = try await currentOwner(company)
        XCTAssertEqual(actual, owner)
    }
    func testDeclineAndCancelKeepOwnershipAndCannotBeAccepted() async throws {
        for cancel in [false, true] {
            let (company, owner, target, _) = try await fixture()
            let offer = try await propose(company, owner: owner, target: target)
            let result = try await app.db.transaction { db in try await OwnershipTransferService.resolve(id: offer.id, actorID: cancel ? owner : target, cancel: cancel, on: db) }
            XCTAssertEqual(result.state, cancel ? "cancelled" : "declined")
            do {
                _ = try await app.db.transaction { db in try await OwnershipTransferService.accept(id: offer.id, actorID: target, on: db) }
                XCTFail("Resolved proposal must not accept")
            } catch let abort as Abort { XCTAssertEqual(abort.status, .conflict) }
            let actual = try await currentOwner(company)
            XCTAssertEqual(actual, owner)
        }
    }
    func testOriginalOwnerRouteRequiresRecipientAcceptance() async throws {
        let (company, owner, target, _) = try await fixture()
        func token(_ id: UUID) async throws -> String {
            let user = try await VerifiedIdentityService.activeUser(id, on: app.db)
            return try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id, authVersion: user.authVersion, authenticatedAt: Date()))
        }
        let ownerToken = try await token(owner), targetToken = try await token(target), companyID = try company.requireID()
        var offerID: UUID?
        try await app.test(.POST, "api/v2/workspaces/\(companyID)/owner", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: ownerToken)
            try request.content.encode(WorkspaceController.OwnerBody(userId: target, expectedRevision: 1))
        }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, .accepted)
            let offer = try response.content.decode(OwnershipTransferResponse.self)
            XCTAssertEqual(offer.state, "pending"); offerID = offer.id
        })
        let actualBefore = try await currentOwner(company)
        XCTAssertEqual(actualBefore, owner)
        let id = try XCTUnwrap(offerID)
        try await app.test(.POST, "api/v2/ownership-transfers/\(id)/accept", beforeRequest: { $0.headers.bearerAuthorization = .init(token: targetToken) }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode(OwnershipTransferResponse.self).state, "accepted")
        })
        let actualAfter = try await currentOwner(company)
        XCTAssertEqual(actualAfter, target)
    }
}
