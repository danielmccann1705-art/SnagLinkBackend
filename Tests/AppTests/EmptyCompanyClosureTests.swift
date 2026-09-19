@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class EmptyCompanyClosureTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func fixture() async throws -> (UUID, UUID) {
        try await app.db.transaction { db in
            let owner = try await VerifiedIdentityService.resolveEmail("empty-company-\(UUID())@example.test", name: "Synthetic owner", on: db)
            let company = try await WorkspaceAccessService.createCompany(id: UUID(), name: "Empty synthetic company", actorID: owner.requireID(), on: db)
            return try (owner.requireID(), company.requireID())
        }
    }
    private func preparation(_ user: UUID) async throws -> CompanyDeletionPreparation {
        let result = try await app.db.transaction { db in try await CompanyDeletionPreparationService.prepare(userID: user, on: db) }
        return try XCTUnwrap(result.companies.first)
    }
    private func body(_ company: CompanyDeletionPreparation) -> AccountDeletionRequest {
        var body = AccountDeletionRequest(confirmation: "DELETE", receiptReference: UUID().uuidString + UUID().uuidString)
        body.emptyCompanies = [.init(workspaceID: company.workspaceID, expectedRevision: company.revision)]
        return body
    }
    func testDisclosedAndAcknowledgedEmptyCompanyClosesWithDurableReceipt() async throws {
        let (owner, company) = try await fixture()
        let prepared = try await preparation(owner)
        XCTAssertTrue(prepared.genuinelyEmpty); XCTAssertEqual(prepared.action, "closes_with_account")
        XCTAssertEqual(prepared.projectCount, 0); XCTAssertEqual(prepared.snagCount, 0); XCTAssertEqual(prepared.otherMemberCount, 0)
        let receipt = try await AccountDeletionService.request(userID: owner, body: body(prepared), app: app)
        XCTAssertEqual(receipt.state, "pending")
        let remaining = try await Team.find(company, on: app.db)
        XCTAssertNil(remaining)
        let row = try await VerifiedIdentityService.sql(app.db).raw("SELECT c.state,c.project_count,c.snag_count FROM company_closure_jobs c JOIN account_deletion_jobs j ON j.id=c.account_deletion_job_id WHERE c.workspace_id=\(bind: company) AND j.user_id=\(bind: owner)").first()
        XCTAssertEqual(try row?.decode(column: "state", as: String.self), "completed")
        XCTAssertEqual(try row?.decode(column: "project_count", as: Int64.self), 0)
        XCTAssertEqual(try row?.decode(column: "snag_count", as: Int64.self), 0)
    }
    func testEmptyCompanyIsNeverSilentlyClosedWithoutAcknowledgement() async throws {
        let (owner, company) = try await fixture()
        do {
            _ = try await AccountDeletionService.request(userID: owner, body: .init(confirmation: "DELETE", receiptReference: UUID().uuidString + UUID().uuidString), app: app)
            XCTFail("Closure must be disclosed and acknowledged")
        } catch let abort as Abort { XCTAssertEqual(abort.identifier, "company_owner_action_required") }
        let remaining = try await Team.find(company, on: app.db)
        XCTAssertNotNil(remaining)
        _ = try await VerifiedIdentityService.activeUser(owner, on: app.db)
    }
    func testNewHistoryAfterPreparationRequiresExplicitNonemptyClosure() async throws {
        let (owner, company) = try await fixture()
        let prepared = try await preparation(owner)
        try await WorkspaceAccessService.activity(workspaceID: company, actorID: owner, action: "synthetic_history", targetID: UUID(), on: app.db)
        do {
            _ = try await AccountDeletionService.request(userID: owner, body: body(prepared), app: app)
            XCTFail("An earlier zero count cannot authorize new content")
        } catch let abort as Abort { XCTAssertEqual(abort.identifier, "company_owner_action_required") }
        let updated = try await preparation(owner)
        XCTAssertFalse(updated.genuinelyEmpty)
        _ = try await VerifiedIdentityService.activeUser(owner, on: app.db)
    }
    func testArchivedProjectAndRemovedMemberAreNotEmpty() async throws {
        for mode in ["project", "member"] {
            let (owner, company) = try await fixture()
            if mode == "project" {
                let project = Project(name: "Archived work", reference: "OLD", ownerId: owner)
                project.workspaceId = company; project.archivedAt = Date()
                try await project.save(on: app.db)
            } else {
                try await app.db.transaction { db in
                    let member = try await VerifiedIdentityService.resolveEmail("removed-\(UUID())@example.test", name: "Former participant", on: db)
                    try await WorkspaceAccessService.putMembership(workspaceID: company, userID: member.requireID(), role: "member", on: db)
                    try await WorkspaceAccessService.changeMember(workspaceID: company, targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner, on: db)
                }
            }
            let prepared = try await preparation(owner)
            XCTAssertFalse(prepared.genuinelyEmpty)
            if mode == "project" { XCTAssertEqual(prepared.projectCount, 1) }
            else { XCTAssertEqual(prepared.otherMemberCount, 1) }
        }
    }
    func testExpiredFKLessLinkHistoryDoesNotCountAsEmpty() async throws {
        let (owner, _) = try await fixture()
        try await MagicLink(token: "historical-\(UUID())", accessLevel: .update, expiresAt: Date().addingTimeInterval(-3600), snagIds: [], projectId: UUID(), createdById: owner).save(on: app.db)
        let prepared = try await preparation(owner)
        XCTAssertFalse(prepared.genuinelyEmpty)
    }
    func testChangedCompanyRevisionCannotReuseEarlierAcknowledgement() async throws {
        let (owner, company) = try await fixture()
        let prepared = try await preparation(owner)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE teams SET revision=revision+1,name='Changed synthetic company' WHERE id=\(bind: company)").run()
        do {
            _ = try await AccountDeletionService.request(userID: owner, body: body(prepared), app: app)
            XCTFail("The user must review changed company details")
        } catch let abort as Abort { XCTAssertEqual(abort.identifier, "company_closure_confirmation_changed") }
    }
    func testPreparationRouteShowsOnlyAuthenticatedOwnersCompany() async throws {
        let (owner, company) = try await fixture()
        let (_, unrelated) = try await fixture()
        let user = try await VerifiedIdentityService.activeUser(owner, on: app.db)
        let token = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: owner.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: owner, authVersion: user.authVersion, authenticatedAt: Date()))
        try await app.test(.GET, "api/v2/account/deletion-preparation", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { response async throws in
            XCTAssertEqual(response.status, .ok)
            let result = try response.content.decode(AccountDeletionPreparation.self)
            XCTAssertEqual(result.companies.map(\.workspaceID), [company])
            XCTAssertFalse(result.companies.contains { $0.workspaceID == unrelated })
            XCTAssertEqual(response.headers.first(name: .cacheControl), "private, no-store")
        })
    }
}
