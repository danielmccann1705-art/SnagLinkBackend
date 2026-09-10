import Foundation

/// V2 permission matrix from the unified-platform brief. Context must be loaded
/// from server records in the operation's transaction, never decoded from a request.
/// Route integration is intentionally separate: legacy routes still use v1 ownership.
struct ProjectAccessPolicy {
    enum WorkspaceKind: String { case personal, company }
    enum WorkspaceRole: String { case owner, admin, member }
    enum ProjectRole: String { case manager, member, viewer }
    enum Action: String, CaseIterable, Hashable {
        case read, edit, assign, share, submitCompletion, review, archive
        case addProjectMember, manageProjectGrants
        case createCompanyProject, manageCompanyMembers, manageBilling, transferOwnership, closeCompany
    }

    struct Workspace {
        let id: UUID
        let kind: WorkspaceKind
        let ownerID: UUID
        let active: Bool
    }
    struct ProjectScope {
        let id: UUID
        let workspaceID: UUID
        // Creator is attribution only. It must not confer perpetual company access.
        let creatorID: UUID
    }
    struct Membership {
        let workspaceID: UUID
        let userID: UUID
        let role: WorkspaceRole
        let active: Bool
    }
    struct Grant {
        let workspaceID: UUID
        let projectID: UUID
        let userID: UUID
        let role: ProjectRole
    }

    static func allowedActions(actorID: UUID, workspace: Workspace, project: ProjectScope,
                               membership: Membership?, grant: Grant?) -> Set<Action> {
        guard workspace.active, project.workspaceID == workspace.id else { return [] }

        if workspace.kind == .personal {
            guard actorID == workspace.ownerID else { return [] }
            // Personal projects cannot acquire colleague access through a stray grant.
            return [.read, .edit, .assign, .share, .submitCompletion, .review, .archive]
        }

        guard let membership, membership.active,
              membership.userID == actorID, membership.workspaceID == workspace.id else { return [] }
        switch membership.role {
        case .owner:
            guard workspace.ownerID == actorID else { return [] }
            return Set(Action.allCases)
        case .admin:
            return Set(Action.allCases).subtracting([.transferOwnership, .closeCompany])
        case .member:
            guard let grant, grant.workspaceID == workspace.id, grant.projectID == project.id,
                  grant.userID == actorID else { return [] }
            switch grant.role {
            case .manager:
                // Manager can add existing company members as project Members only.
                return [.read, .edit, .assign, .share, .submitCompletion, .review, .archive, .addProjectMember]
            case .member:
                return [.read, .edit, .submitCompletion]
            case .viewer:
                return [.read]
            }
        }
    }

    /// A contributor may discard only their own unpublished draft. Published snags
    /// need the separate archive permission and an audited reason in the command layer.
    static func mayDiscardDraft(actorID: UUID, draftCreatorID: UUID, isPublished: Bool,
                                actions: Set<Action>) -> Bool {
        !isPublished && actorID == draftCreatorID && actions.contains(.edit)
    }
}
