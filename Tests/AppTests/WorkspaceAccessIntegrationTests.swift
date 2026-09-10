@testable import App
import XCTVapor
import Fluent
import FluentSQL
import JWT

final class WorkspaceAccessIntegrationTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://portal.example.test", environment: "local")
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }
    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("workspace-\(UUID())@example.test", name: "Synthetic manager", on: db) }
    }
    private func company(_ owner: User) async throws -> Team {
        try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Synthetic Construction", actorID: owner.requireID(), on: db) }
    }
    private func project(_ owner: User, workspace: Team) async throws -> Project {
        let project = Project(name: "Willow Court", reference: "WC", ownerId: try owner.requireID())
        project.workspaceId = try workspace.requireID()
        try await project.save(on: app.db)
        return project
    }
    private func join(_ user: User, company: Team, by owner: User, projects: [InvitationProjectGrant] = [], role: String = "member") async throws -> TeamInvite {
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: user.email!, role: role, projects: projects, actorID: owner.requireID(), on: db) }
        return try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: issued.1, actorID: user.requireID(), on: db) }
    }
    private func request(_ method: HTTPMethod, _ path: String, user: User, body: [String: String] = [:]) async throws -> XCTHTTPResponse {
        let id = try user.requireID()
        let jwt = try app.jwt.signers.sign(UserJWTPayload(subject: .init(value: id.uuidString), expiration: .init(value: Date().addingTimeInterval(3600)), userId: id))
        var result: XCTHTTPResponse!
        try await app.test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            if method != .GET { try req.content.encode(body) }
        }, afterResponse: { response async in result = response })
        return result
    }

    func testJoiningCompanyNeverExposesPersonalProjects() async throws {
        let owner = try await user(), colleague = try await user(), company = try await company(owner)
        let personal = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let privateProject = try await project(owner, workspace: personal)
        _ = try await join(colleague, company: company, by: owner)
        let response = try await request(.GET, "api/v2/projects/\(try privateProject.requireID())", user: colleague)
        XCTAssertEqual(response.status, .notFound)
        let list = try await request(.GET, "api/v2/workspaces", user: colleague)
        let workspaces = try list.content.decode([WorkspaceResponse].self)
        XCTAssertFalse(workspaces.contains { $0.id == personal.id })
        XCTAssertTrue(workspaces.contains { $0.id == company.id })
    }

    func testInviteCreatesMembershipAndSelectedManagerGrantAtomically() async throws {
        let owner = try await user(), manager = try await user(), company = try await company(owner)
        let assigned = try await project(owner, workspace: company), unassigned = try await project(owner, workspace: company)
        let invite = try await join(manager, company: company, by: owner, projects: [.init(projectId: try assigned.requireID(), role: "manager")])
        XCTAssertEqual(invite.acceptedUserId, manager.id)
        let response = try await request(.GET, "api/v2/projects/\(try assigned.requireID())", user: manager)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let body = try response.content.decode(PlatformProjectResponse.self)
        XCTAssertTrue(body.capabilities.contains("review")); XCTAssertFalse(body.capabilities.contains("manageBilling"))
        let hidden = try await request(.GET, "api/v2/projects/\(try unassigned.requireID())", user: manager)
        XCTAssertEqual(hidden.status, .notFound)
    }

    func testConcurrentInviteAcceptanceCreatesOneMembershipAndAuditEvent() async throws {
        let owner = try await user(), member = try await user(), company = try await company(owner)
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: member.email!, role: "member", projects: [], actorID: owner.requireID(), on: db) }
        let id = try member.requireID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await self.app.db.transaction { db in try await WorkspaceInvitationService.accept(token: issued.1, actorID: id, on: db) } } }
            try await group.waitForAll()
        }
        let sql = try VerifiedIdentityService.sql(app.db)
        let memberships = try await sql.raw("SELECT count(*) AS n FROM workspace_memberships WHERE workspace_id = \(bind: company.requireID()) AND user_id = \(bind: id)").first()!.decode(column: "n", as: Int.self)
        let events = try await sql.raw("SELECT count(*) AS n FROM workspace_activity WHERE target_id = \(bind: issued.0.requireID()) AND action = 'invitation_accepted'").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(memberships, 1); XCTAssertEqual(events, 1)
    }

    func testWrongVerifiedRecipientCannotAcceptLegacyOrV2Route() async throws {
        let owner = try await user(), recipient = try await user(), stranger = try await user(), company = try await company(owner)
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: recipient.email!, role: "member", projects: [], actorID: owner.requireID(), on: db) }
        // Even a mutable legacy display email matching the target confers no proof.
        stranger.email = recipient.email; try await stranger.save(on: app.db)
        let legacy = try await request(.POST, "api/v1/team-invites/\(issued.1)/accept", user: stranger)
        let v2 = try await request(.POST, "api/v2/invitations/accept", user: stranger, body: ["token": issued.1])
        XCTAssertEqual(legacy.status, .forbidden); XCTAssertEqual(v2.status, .forbidden)
        let stillPending = try await TeamInvite.find(issued.0.requireID(), on: app.db)
        XCTAssertEqual(stillPending?.status, "pending")
        let correct = try await request(.POST, "api/v1/team-invites/\(issued.1)/accept", user: recipient)
        XCTAssertEqual(correct.status, .ok, correct.body.string)
    }

    func testRemovedMemberLosesProjectAccessAndCannotReplayInviteToRejoin() async throws {
        let owner = try await user(), member = try await user(), company = try await company(owner), project = try await project(owner, workspace: company)
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: member.email!, role: "member", projects: [.init(projectId: try project.requireID(), role: "manager")], actorID: owner.requireID(), on: db) }
        _ = try await app.db.transaction { db in try await WorkspaceInvitationService.accept(token: issued.1, actorID: member.requireID(), on: db) }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: company.requireID(), targetID: member.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let get = try await request(.GET, "api/v2/projects/\(try project.requireID())", user: member)
        XCTAssertEqual(get.status, .notFound)
        let replay = try await request(.POST, "api/v2/invitations/accept", user: member, body: ["token": issued.1])
        XCTAssertEqual(replay.status, .notFound)
        let grants = try await VerifiedIdentityService.sql(app.db).raw("SELECT count(*) AS n FROM project_access WHERE state = 'active' AND user_id = \(bind: member.requireID()) AND workspace_id = \(bind: company.requireID())").first()!.decode(column: "n", as: Int.self)
        XCTAssertEqual(grants, 0)
    }

    func testUnassignedMemberCannotCreateCompanyProjectOrInviteOthers() async throws {
        let owner = try await user(), member = try await user(), company = try await company(owner)
        _ = try await join(member, company: company, by: owner)
        do {
            _ = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: "other@example.test", role: "admin", projects: [], actorID: member.requireID(), on: db) }
            XCTFail("Member must not invite")
        } catch let error as Abort { XCTAssertEqual(error.status, .forbidden) }
        let list = try await request(.GET, "api/v2/projects?workspaceId=\(try company.requireID())", user: member)
        XCTAssertEqual(list.status, .ok)
        XCTAssertEqual(try list.content.decode(PlatformProjectController.Page.self).items.count, 0)
    }

    func testCrossCompanyInvitationProjectIsRejectedWithoutPartialInvite() async throws {
        let owner = try await user(), companyA = try await company(owner), companyB = try await company(owner), otherProject = try await project(owner, workspace: companyB)
        let email = "cross-\(UUID())@example.test"
        do {
            _ = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: companyA.requireID(), email: email, role: "member", projects: [.init(projectId: try otherProject.requireID(), role: "manager")], actorID: owner.requireID(), on: db) }
            XCTFail("Cannot cross company boundary")
        } catch let error as Abort { XCTAssertEqual(error.status, .badRequest) }
        let count = try await TeamInvite.query(on: app.db).filter(\.$email == EmailValidator.normalize(email)).count()
        XCTAssertEqual(count, 0)
    }

    func testOwnerCannotBeRemovedOrDemotedAndTransferIsRevisionGuarded() async throws {
        let owner = try await user(), next = try await user(), company = try await company(owner)
        _ = try await join(next, company: company, by: owner)
        for role in [nil, "member"] {
            do {
                try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: company.requireID(), targetID: owner.requireID(), newRole: role, expectedRevision: 1, actorID: owner.requireID(), on: db) }
                XCTFail("Owner must transfer first")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
        }
        try await app.db.transaction { db in try await WorkspaceAccessService.transferOwnership(workspaceID: company.requireID(), targetID: next.requireID(), expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let fresh = try await Team.find(company.requireID(), on: app.db)
        XCTAssertEqual(fresh?.ownerUserId, next.id); XCTAssertEqual(fresh?.revision, 2)
        do {
            try await app.db.transaction { db in try await WorkspaceAccessService.transferOwnership(workspaceID: company.requireID(), targetID: owner.requireID(), expectedRevision: 1, actorID: next.requireID(), on: db) }
            XCTFail("Stale ownership transfer must conflict")
        } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
    }

    func testManagerMayAddMemberButCannotDemoteManagerOrPromoteMember() async throws {
        let owner = try await user(), manager = try await user(), member = try await user(), company = try await company(owner), project = try await project(owner, workspace: company)
        _ = try await join(manager, company: company, by: owner, projects: [.init(projectId: try project.requireID(), role: "manager")])
        _ = try await join(member, company: company, by: owner)
        try await app.db.transaction { db in try await ProjectAccessService.grant(projectID: project.requireID(), targetID: member.requireID(), role: "member", actorID: manager.requireID(), on: db) }
        for (target, role) in [(member, "manager"), (manager, "member")] {
            do {
                try await app.db.transaction { db in try await ProjectAccessService.grant(projectID: project.requireID(), targetID: target.requireID(), role: role, actorID: manager.requireID(), on: db) }
                XCTFail("Manager must not change privileged grants")
            } catch let error as Abort { XCTAssertEqual(error.status, .forbidden) }
        }
    }

    func testInviteFromRemovedAdminCannotBeAccepted() async throws {
        let owner = try await user(), admin = try await user(), recipient = try await user(), company = try await company(owner)
        _ = try await join(admin, company: company, by: owner, role: "admin")
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: recipient.email!, role: "member", projects: [], actorID: admin.requireID(), on: db) }
        try await app.db.transaction { db in try await WorkspaceAccessService.changeMember(workspaceID: company.requireID(), targetID: admin.requireID(), newRole: nil, expectedRevision: 1, actorID: owner.requireID(), on: db) }
        let response = try await request(.POST, "api/v2/invitations/accept", user: recipient, body: ["token": issued.1])
        XCTAssertEqual(response.status, .notFound)
    }
    func testInvitationPreviewRequiresVerifiedRecipientAndDoesNotCreateMembership() async throws {
        let owner = try await user(), recipient = try await user(), stranger = try await user(), company = try await company(owner), project = try await project(owner, workspace: company)
        let issued = try await app.db.transaction { db in try await WorkspaceInvitationService.issue(workspaceID: company.requireID(), email: recipient.email!, role: "member", projects: [.init(projectId: try project.requireID(), role: "manager")], actorID: owner.requireID(), on: db) }
        let hidden = try await request(.POST, "api/v2/invitations/preview", user: stranger, body: ["token": issued.1])
        XCTAssertEqual(hidden.status, .forbidden); XCTAssertFalse(hidden.body.string.contains(company.name))
        let preview = try await request(.POST, "api/v2/invitations/preview", user: recipient, body: ["token": issued.1])
        XCTAssertEqual(preview.status, .ok, preview.body.string)
        let body = try preview.content.decode(InvitationPreview.self)
        XCTAssertEqual(body.companyName, company.name); XCTAssertEqual(body.projects.first?.name, project.name)
        XCTAssertFalse(body.alreadyAccepted)
        let pending = try await TeamInvite.find(issued.0.requireID(), on: app.db); XCTAssertEqual(pending?.status, "pending")
        let member = try await VerifiedIdentityService.sql(app.db).raw("SELECT user_id FROM workspace_memberships WHERE workspace_id = \(bind: company.requireID()) AND user_id = \(bind: recipient.requireID())").first()
        XCTAssertNil(member)
    }

}
