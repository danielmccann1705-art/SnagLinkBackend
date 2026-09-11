@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class CompanyAdministrationTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user(_ name: String = "Synthetic manager") async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("admin-\(UUID())@example.test", name: name, on: db) }
    }
    private func company(_ owner: User) async throws -> Team {
        try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Construction", actorID: owner.requireID(), on: db) }
    }
    private func request(_ path: String, user: User) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        var response: XCTHTTPResponse!
        try await app.test(.GET, path, beforeRequest: { req in req.headers.bearerAuthorization = .init(token: jwt) }, afterResponse: { result async in response = result })
        return response
    }
    func testAllAdministrationReadsRequireCurrentCompanyAdminAndHidePersonalData() async throws {
        let owner = try await user(), admin = try await user(), member = try await user(), outsider = try await user(), team = try await company(owner)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: admin.requireID(), role: "admin", on: db)
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: member.requireID(), role: "member", on: db)
        }
        let personal = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        for suffix in ["administration/members", "invitations", "administration/activity"] {
            let path = "api/v2/workspaces/\(try team.requireID())/\(suffix)"
            for actor in [owner, admin] {
                let result = try await request(path, user: actor)
                XCTAssertEqual(result.status, .ok, result.body.string)
                XCTAssertEqual(result.headers.first(name: .cacheControl), "no-store")
            }
            let denied = try await request(path, user: member), hidden = try await request(path, user: outsider)
            XCTAssertEqual(denied.status, .forbidden); XCTAssertEqual(hidden.status, .notFound)
            XCTAssertFalse(hidden.body.string.contains(team.name))
            let privateRead = try await request("api/v2/workspaces/\(try personal.requireID())/\(suffix)", user: owner)
            XCTAssertEqual(privateRead.status, .notFound)
        }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: team.requireID(), targetID: admin.requireID(), newRole: "member", expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let revoked = try await request("api/v2/workspaces/\(try team.requireID())/administration/members", user: admin)
        XCTAssertEqual(revoked.status, .forbidden)
    }
    func testMembersAreBoundedSearchableAndRemovedRecordsAreExplicit() async throws {
        let owner = try await user("Owner"), team = try await company(owner)
        // One transaction, 51 additional real users; no invented authorization rows.
        try await app.db.transaction { db in
            for index in 0..<51 {
                let member = try await VerifiedIdentityService.resolveEmail("page-\(UUID())@example.test", name: "Builder \(index)", on: db)
                try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: member.requireID(), role: "member", on: db)
            }
        }
        let base = "api/v2/workspaces/\(try team.requireID())/administration/members"
        let first = try await request(base, user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        let next = try await request(base + "?page=2", user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertEqual(first.items.count, 50); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(next.items.count, 2); XCTAssertFalse(next.hasMore)
        XCTAssertTrue(Set(first.items.map(\.userId)).isDisjoint(with: next.items.map(\.userId)))
        let target = next.items[0]
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: team.requireID(), targetID: target.userId, newRole: nil, expectedRevision: target.revision, actorID: owner.requireID(), on: db) }
        let removed = try await request(base + "?state=removed", user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertEqual(removed.items.map(\.userId), [target.userId]); XCTAssertEqual(removed.items[0].revision, 2)
        let search = try await request(base + "?q=Owner", user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertEqual(search.items.map(\.userId), [try owner.requireID()])
        XCTAssertEqual(search.items[0].verifiedEmail, owner.email)
        let originalEmail = owner.email!
        owner.email = "mutable-not-verified@example.test"; try await owner.save(on: app.db)
        let verifiedSearch = try await request(base + "?q=" + originalEmail, user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertEqual(verifiedSearch.items.map(\.userId), [try owner.requireID()])
        let unverifiedSearch = try await request(base + "?q=mutable-not-verified", user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertTrue(unverifiedSearch.items.isEmpty)
        let literal = try await request(base + "?q=%25", user: owner).content.decode(CompanyAdministrationController.MemberPage.self)
        XCTAssertTrue(literal.items.isEmpty)
        for query in ["?page=0", "?page=no", "?page=10001", "?state=owner", "?q=" + String(repeating: "x", count: 121)] {
            let invalid = try await request(base + query, user: owner)
            XCTAssertEqual(invalid.status, .badRequest)
        }
    }
    func testInvitationListHasEffectiveExpiryAndNeverReturnsCapabilitiesOrHashes() async throws {
        let owner = try await user(), team = try await company(owner), recipient = try await user()
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: team.requireID(), email: recipient.email!, role: "member", projects: [], actorID: owner.requireID(), on: db) }
        let other = try await company(owner)
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: other.requireID(), email: "secret-other@example.test", role: "admin", projects: [], actorID: owner.requireID(), on: db) }
        let base = "api/v2/workspaces/\(try team.requireID())/invitations"
        let result = try await request(base, user: owner)
        let page = try result.content.decode(CompanyAdministrationController.InvitationPage.self)
        XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items[0].status, "pending"); XCTAssertTrue(page.items[0].canRevoke)
        XCTAssertFalse(result.body.string.contains(issued.1)); XCTAssertFalse(result.body.string.contains(issued.0.tokenHash!))
        XCTAssertFalse(result.body.string.contains("token")); XCTAssertFalse(result.body.string.contains("secret-other"))
        issued.0.expiresAt = Date().addingTimeInterval(-1); try await issued.0.save(on: app.db)
        let expired = try await request(base + "?state=expired", user: owner).content.decode(CompanyAdministrationController.InvitationPage.self)
        XCTAssertEqual(expired.items[0].status, "expired")
        let pending = try await request(base + "?state=pending", user: owner).content.decode(CompanyAdministrationController.InvitationPage.self)
        XCTAssertTrue(pending.items.isEmpty)
        try await app.db.transaction { db in try await WorkspaceInvitationService.revoke(invitationID: issued.0.requireID(), actorID: owner.requireID(), on: db) }
        let revoked = try await request(base + "?state=revoked", user: owner).content.decode(CompanyAdministrationController.InvitationPage.self)
        XCTAssertEqual(revoked.items.count, 1); XCTAssertFalse(revoked.items[0].canRevoke)
    }
    func testActivityAllowsOnlyAdministrationFieldsAndReflectsActualActors() async throws {
        let owner = try await user("Emma Hughes"), colleague = try await user("Jamie Taylor"), team = try await company(owner)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: colleague.requireID(), role: "member", on: db)
            try await WorkspaceAccessService.changeMember(workspaceID: team.requireID(), targetID: colleague.requireID(), newRole: "admin", expectedRevision: 1, actorID: owner.requireID(), on: db)
            try await WorkspaceAccessService.activity(workspaceID: team.requireID(), actorID: owner.requireID(), action: "internal_secret_action", targetID: nil, detail: "do-not-expose", on: db)
        }
        let result = try await request("api/v2/workspaces/\(try team.requireID())/administration/activity", user: owner)
        let page = try result.content.decode(CompanyAdministrationController.ActivityPage.self)
        XCTAssertEqual(page.items.count, 2)
        let change = try XCTUnwrap(page.items.first { $0.action == "member_role_changed" })
        XCTAssertEqual(change.actorName, "Emma Hughes"); XCTAssertEqual(change.targetName, "Jamie Taylor"); XCTAssertEqual(change.role, "admin")
        XCTAssertFalse(result.body.string.contains("do-not-expose")); XCTAssertFalse(result.body.string.contains("internal_secret_action"))
        XCTAssertFalse(result.body.string.contains("detail"))
    }
    func testMemberProjectAccessListsOnlyCompanyProjectsAndPreservesRemovedGrantRevision() async throws {
        let owner = try await user(), colleague = try await user(), outsider = try await user(), team = try await company(owner)
        let project = Project(name: "Willow Court", reference: "WC", ownerId: try owner.requireID())
        project.workspaceId = try team.requireID(); try await project.save(on: app.db)
        let other = try await company(owner), hidden = Project(name: "Other company private project", reference: "XX", ownerId: try owner.requireID())
        hidden.workspaceId = try other.requireID(); try await hidden.save(on: app.db)
        try await app.db.transaction { db in
            try await WorkspaceAccessService.putMembership(workspaceID: team.requireID(), userID: colleague.requireID(), role: "member", on: db)
            try await ProjectAccessService.grant(projectID: project.requireID(), targetID: colleague.requireID(), role: "manager", actorID: owner.requireID(), on: db)
        }
        let base = "api/v2/workspaces/\(try team.requireID())/administration/members/\(try colleague.requireID())/projects"
        let active = try await request(base, user: owner).content.decode(CompanyAdministrationController.MemberProjectPage.self)
        XCTAssertEqual(active.items.map(\.id), [try project.requireID()]); XCTAssertEqual(active.items[0].access.role, "manager")
        let response = try await request(base, user: colleague)
        XCTAssertEqual(response.status, .forbidden)
        let cross = try await request("api/v2/workspaces/\(try team.requireID())/administration/members/\(try outsider.requireID())/projects", user: owner)
        XCTAssertEqual(cross.status, .notFound)
        try await app.db.transaction { db in
            let (p, actions) = try await ProjectAccessService.require(.manageProjectGrants, projectID: project.requireID(), actorID: owner.requireID(), on: db)
            _ = try await ProjectGrantService.set(.init(mutation: .init(operationId: UUID(), deviceId: UUID()), userId: colleague.requireID(), role: nil, expectedRevision: active.items[0].access.revision), project: p, actorID: owner.requireID(), actions: actions, on: db)
        }
        let removed = try await request(base, user: owner).content.decode(CompanyAdministrationController.MemberProjectPage.self)
        XCTAssertEqual(removed.items[0].access.state, "removed"); XCTAssertNil(removed.items[0].access.role)
        XCTAssertEqual(removed.items[0].access.revision, active.items[0].access.revision + 1)
        let activity = try await request("api/v2/workspaces/\(try team.requireID())/administration/activity", user: owner).content.decode(CompanyAdministrationController.ActivityPage.self)
        let event = try XCTUnwrap(activity.items.first { $0.action == "project_access_removed" })
        XCTAssertEqual(event.projectName, "Willow Court")
        XCTAssertEqual(event.role, "none")
        XCTAssertEqual(activity.items.first { $0.action == "project_access_granted" }?.role, "manager")
        let filtered = try await request(base + "?q=no-match", user: owner).content.decode(CompanyAdministrationController.MemberProjectPage.self)
        XCTAssertTrue(filtered.items.isEmpty)
    }
}
