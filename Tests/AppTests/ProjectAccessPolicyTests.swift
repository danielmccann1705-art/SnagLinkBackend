@testable import App
import XCTest

final class ProjectAccessPolicyTests: XCTestCase {
    typealias Policy = ProjectAccessPolicy
    let workspaceID = UUID(), otherWorkspaceID = UUID(), projectID = UUID(), ownerID = UUID(), memberID = UUID()

    private func actions(kind: Policy.WorkspaceKind = .company, role: Policy.WorkspaceRole? = .member,
                         projectRole: Policy.ProjectRole? = .manager, active: Bool = true,
                         actorIsOwner: Bool = false, wrongMembershipScope: Bool = false,
                         wrongGrantScope: Bool = false, wrongProject: Bool = false,
                         wrongGrantUser: Bool = false, workspaceActive: Bool = true,
                         wrongProjectWorkspace: Bool = false) -> Set<Policy.Action> {
        let actor = actorIsOwner ? ownerID : memberID
        return Policy.allowedActions(actorID: actor,
            workspace: .init(id: workspaceID, kind: kind, ownerID: ownerID, active: workspaceActive),
            project: .init(id: projectID, workspaceID: wrongProjectWorkspace ? otherWorkspaceID : workspaceID, creatorID: actor),
            membership: role.map { .init(workspaceID: wrongMembershipScope ? otherWorkspaceID : workspaceID, userID: actor, role: $0, active: active) },
            grant: projectRole.map { .init(workspaceID: wrongGrantScope ? otherWorkspaceID : workspaceID,
                projectID: wrongProject ? UUID() : projectID, userID: wrongGrantUser ? UUID() : actor, role: $0) })
    }

    func testPersonalProjectNeverBecomesSharedThroughCompanyMembershipOrGrant() {
        XCTAssertTrue(actions(kind: .personal, role: .admin).isEmpty)
        XCTAssertTrue(actions(kind: .personal, role: .owner).isEmpty)
    }
    func testPersonalOwnerCanReviewButCannotInviteColleaguesIntoPersonalWorkspace() {
        let allowed = actions(kind: .personal, role: nil, projectRole: nil, actorIsOwner: true)
        XCTAssertTrue(allowed.contains(.review))
        XCTAssertTrue(allowed.contains(.share))
        XCTAssertFalse(allowed.contains(.addProjectMember))
        XCTAssertFalse(allowed.contains(.manageCompanyMembers))
    }
    func testRemovedCreatorHasNoCompanyAccessDespiteRetainedProjectGrant() {
        XCTAssertTrue(actions(active: false).isEmpty)
    }
    func testRemovedOwnerHasNoCompanyAccess() {
        XCTAssertTrue(actions(role: .owner, active: false, actorIsOwner: true).isEmpty)
    }
    func testOwnerRequiresMatchingOwnerRecordAndActiveMembership() {
        XCTAssertTrue(actions(role: .owner).isEmpty)
        XCTAssertTrue(actions(role: nil, actorIsOwner: true).isEmpty)
        XCTAssertEqual(actions(role: .owner, projectRole: nil, actorIsOwner: true), Set(Policy.Action.allCases))
    }
    func testAdminCanManageCompanyWorkButCannotTransferOrCloseCompany() {
        let allowed = actions(role: .admin, projectRole: nil)
        XCTAssertTrue(allowed.contains(.review))
        XCTAssertTrue(allowed.contains(.manageBilling))
        XCTAssertTrue(allowed.contains(.createCompanyProject))
        XCTAssertFalse(allowed.contains(.transferOwnership))
        XCTAssertFalse(allowed.contains(.closeCompany))
    }
    func testManagerGrantDoesNotCreateWorkspaceWidePowers() {
        let allowed = actions()
        XCTAssertTrue(allowed.contains(.review))
        XCTAssertTrue(allowed.contains(.addProjectMember))
        XCTAssertFalse(allowed.contains(.manageProjectGrants))
        XCTAssertFalse(allowed.contains(.manageCompanyMembers))
        XCTAssertFalse(allowed.contains(.manageBilling))
        XCTAssertFalse(allowed.contains(.createCompanyProject))
    }
    func testMemberCanCaptureAndSubmitButCannotShareApproveOrArchivePublishedWork() {
        XCTAssertEqual(actions(projectRole: .member), [.read, .edit, .submitCompletion])
    }
    func testViewerIsReadOnlyAndUnassignedMemberHasNoAccess() {
        XCTAssertEqual(actions(projectRole: .viewer), [.read])
        XCTAssertTrue(actions(projectRole: nil).isEmpty)
    }
    func testGrantCannotCrossWorkspaceProjectOrUser() {
        XCTAssertTrue(actions(wrongGrantScope: true).isEmpty)
        XCTAssertTrue(actions(wrongProject: true).isEmpty)
        XCTAssertTrue(actions(wrongGrantUser: true).isEmpty)
    }
    func testAdminFromAnotherWorkspaceHasNoAccess() {
        XCTAssertTrue(actions(role: .admin, wrongMembershipScope: true).isEmpty)
        XCTAssertTrue(actions(role: .admin, wrongProjectWorkspace: true).isEmpty)
    }
    func testInactiveWorkspaceDeniesOwnerAndAdmin() {
        XCTAssertTrue(actions(role: .owner, actorIsOwner: true, workspaceActive: false).isEmpty)
        XCTAssertTrue(actions(role: .admin, workspaceActive: false).isEmpty)
    }
    func testDraftExceptionDoesNotAllowDeletingPublishedOrSomeoneElsesWork() {
        let allowed = actions(projectRole: .member)
        XCTAssertTrue(Policy.mayDiscardDraft(actorID: memberID, draftCreatorID: memberID, isPublished: false, actions: allowed))
        XCTAssertFalse(Policy.mayDiscardDraft(actorID: memberID, draftCreatorID: memberID, isPublished: true, actions: allowed))
        XCTAssertFalse(Policy.mayDiscardDraft(actorID: memberID, draftCreatorID: ownerID, isPublished: false, actions: allowed))
        XCTAssertFalse(Policy.mayDiscardDraft(actorID: memberID, draftCreatorID: memberID, isPublished: false, actions: []))
    }
}
