@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CompanyClosureConfirmationTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture() async throws -> (User, UUID, UUID) {
        try await app.db.transaction { db in
            let user = try await VerifiedIdentityService.resolveEmail("company-confirm-\(UUID())@example.test", name: "Synthetic owner", on: db)
            let team = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Counted synthetic company", actorID: user.requireID(), on: db)
            let project = Project(name: "Company project", reference: "COUNT", ownerId: try user.requireID())
            project.workspaceId = try team.requireID()
            try await project.save(on: db)
            return try (user, team.requireID(), project.requireID())
        }
    }
    private func reference() -> String { UUID().uuidString + UUID().uuidString }
    private func issue(owner: User, workspace: UUID, receipt: String) async throws -> CompanyClosureConfirmationResponse {
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: owner.requireID().uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: owner.requireID(), authVersion: owner.authVersion, authenticatedAt: Date()))
        var result: CompanyClosureConfirmationResponse?
        try await app.test(.POST, "api/v2/account/company-closures/confirmation", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: token)
            try request.content.encode(CompanyClosureConfirmationRequest(workspaceID: workspace, receiptReference: receipt))
        }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
            result = try response.content.decode(CompanyClosureConfirmationResponse.self)
        })
        return try XCTUnwrap(result)
    }
    private func consume(_ result: CompanyClosureConfirmationResponse, actor: UUID, receipt: String, confirmation: String = "CLOSE COMPANY") async throws -> [CompanyClosureConfirmationService.Confirmed] {
        try await app.db.transaction { db in
            try await WorkspaceAccessService.lock(result.workspaceID, on: db)
            return try await CompanyClosureConfirmationService.consume([.init(workspaceID: result.workspaceID, confirmationReference: result.confirmationReference, confirmation: confirmation)], userID: actor, receiptHash: AccountDeletionService.receiptHash(receipt), on: db)
        }
    }
    func testRouteNamesExactCountsStoresOnlyReferenceHashAndDoesNotCloseCompany() async throws {
        let (owner, workspace, _) = try await fixture(), receipt = reference()
        let result = try await issue(owner: owner, workspace: workspace, receipt: receipt)
        XCTAssertEqual(result.name, "Counted synthetic company")
        XCTAssertEqual(result.projectCount, 1); XCTAssertEqual(result.snagCount, 0); XCTAssertEqual(result.otherMemberCount, 0)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT reference_hash,consumed_at FROM company_closure_confirmations WHERE workspace_id=\(bind: workspace)").first()
        XCTAssertEqual(try row?.decode(column: "reference_hash", as: String.self), CompanyClosureConfirmationService.referenceHash(result.confirmationReference))
        XCTAssertNotEqual(try row?.decode(column: "reference_hash", as: String.self), result.confirmationReference)
        XCTAssertNil(try row?.decode(column: "consumed_at", as: Date?.self))
        let team = try await Team.find(workspace, on: app.db)
        XCTAssertEqual(team?.lifecycleState, "active")
    }
    func testSameCountsButChangedProjectContentInvalidatesConfirmation() async throws {
        let (owner, workspace, project) = try await fixture(), receipt = reference()
        let result = try await issue(owner: owner, workspace: workspace, receipt: receipt)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE projects SET name='Changed after confirmation' WHERE id=\(bind: project)").run()
        do { _ = try await consume(result, actor: owner.requireID(), receipt: receipt); XCTFail("Equal counts do not prove equal inventory") }
        catch let error as Abort { XCTAssertEqual(error.identifier, "company_closure_confirmation_changed") }
    }
    func testReceiptActorAndExplicitAcknowledgementMustMatch() async throws {
        let (owner, workspace, _) = try await fixture(), receipt = reference()
        let (other, _, _) = try await fixture()
        let result = try await issue(owner: owner, workspace: workspace, receipt: receipt)
        for (actor, selectedReceipt, confirmation) in [(try owner.requireID(), reference(), "CLOSE COMPANY"), (try other.requireID(), receipt, "CLOSE COMPANY"), (try owner.requireID(), receipt, "DELETE")] {
            do { _ = try await consume(result, actor: actor, receipt: selectedReceipt, confirmation: confirmation); XCTFail("Unmatched confirmation must fail") }
            catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
        }
        let accepted = try await consume(result, actor: owner.requireID(), receipt: receipt)
        XCTAssertEqual(accepted.count, 1)
        do { _ = try await consume(result, actor: owner.requireID(), receipt: receipt); XCTFail("Consumed context must not replay") }
        catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }
    func testExpiredConfirmationCannotAuthorizeClosure() async throws {
        let (owner, workspace, _) = try await fixture(), receipt = reference()
        let result = try await issue(owner: owner, workspace: workspace, receipt: receipt)
        // Create an already-expired synthetic context. Existing evidence is
        // immutable, including its expiry; tests must not bypass that boundary.
        let expiredReference = reference()
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO company_closure_confirmations(id,actor_user_id,workspace_id,reference_hash,receipt_hash,workspace_revision,
                project_count,snag_count,other_member_count,inventory_hash,created_at,expires_at)
            SELECT \(bind: UUID()),actor_user_id,workspace_id,\(bind: CompanyClosureConfirmationService.referenceHash(expiredReference)),receipt_hash,workspace_revision,
                project_count,snag_count,other_member_count,inventory_hash,NOW()-INTERVAL '20 minutes',NOW()-INTERVAL '10 minutes'
            FROM company_closure_confirmations WHERE reference_hash=\(bind: CompanyClosureConfirmationService.referenceHash(result.confirmationReference))
            """).run()
        let expired = CompanyClosureConfirmationResponse(confirmationReference: expiredReference, workspaceID: workspace, name: result.name,
                                                        projectCount: result.projectCount, snagCount: result.snagCount, otherMemberCount: result.otherMemberCount, expiresIn: 0)
        do { _ = try await consume(expired, actor: owner.requireID(), receipt: receipt); XCTFail("Expired context must fail") }
        catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }
    func testConfirmationEvidenceCannotBeReboundOrExpiryExtended() async throws {
        let (owner, workspace, _) = try await fixture(), receipt = reference()
        let result = try await issue(owner: owner, workspace: workspace, receipt: receipt)
        let hash = CompanyClosureConfirmationService.referenceHash(result.confirmationReference)
        for query: SQLQueryString in [
            "UPDATE company_closure_confirmations SET receipt_hash='changed' WHERE reference_hash=\(bind: hash)",
            "UPDATE company_closure_confirmations SET expires_at=expires_at+INTERVAL '1 day' WHERE reference_hash=\(bind: hash)",
            "DELETE FROM company_closure_confirmations WHERE reference_hash=\(bind: hash)"
        ] {
            do { try await VerifiedIdentityService.sql(app.db).raw(query).run(); XCTFail("Confirmation evidence must remain immutable") }
            catch { }
        }
        let accepted = try await consume(result, actor: owner.requireID(), receipt: receipt)
        XCTAssertEqual(accepted.count, 1)
    }

}
