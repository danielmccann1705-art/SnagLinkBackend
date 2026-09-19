@testable import App
import XCTVapor
import Fluent
import FluentSQL

final class AccountDeletionPropagationTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil,"Isolated synthetic PostgreSQL required")
        app=try await Application.make(.testing); try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testCompanyCommentDeltasUseBoundedAtomicGroups() async throws {
        let target=try await app.db.transaction { try await VerifiedIdentityService.resolveEmail("propagation-\(UUID())@example.test",name:"Erase this name",on:$0) }
        let owner=try await app.db.transaction { try await VerifiedIdentityService.resolveEmail("owner-\(UUID())@example.test",name:"Synthetic owner",on:$0) }
        let company=try await app.db.transaction { db in
            let team=try await WorkspaceAccessService.createCompany(id:UUID(),name:"Synthetic company",actorID:owner.requireID(),on:db)
            try await WorkspaceAccessService.putMembership(workspaceID:team.requireID(),userID:target.requireID(),role:"member",on:db)
            return team
        }
        let project=Project(id:UUID(),name:"Company evidence",reference:UUID().uuidString,ownerId:try owner.requireID())
        project.workspaceId=try company.requireID(); project.platformManaged=true; try await project.save(on:app.db)
        let snag=Snag(id:UUID(),reference:"S-1",title:"Synthetic snag",projectId:try project.requireID(),ownerId:try owner.requireID())
        snag.workspaceId=try company.requireID(); snag.displayNumber=1; snag.publishedAt=Date(); try await snag.save(on:app.db)
        let sql=try VerifiedIdentityService.sql(app.db)
        let targetID=try target.requireID(),workspaceID=try company.requireID(),projectID=try project.requireID(),snagID=try snag.requireID()
        try await sql.raw("""
            INSERT INTO project_comments(id,workspace_id,project_id,snag_id,author_user_id,author_name,body,created_at)
            SELECT gen_random_uuid(),\(bind:workspaceID),\(bind:projectID),\(bind:snagID),\(bind:targetID),'Erase this name','Synthetic retained comment '||n,NOW()
            FROM generate_series(1,1001) n
            """).run()
        try await app.db.transaction { try await AccountDeletionPropagationService.pseudonymiseCompanyAttribution(userID:targetID,on:$0) }
        let groups=try await sql.raw("""
            SELECT transaction_group,count(*) AS n FROM platform_changes
            WHERE workspace_id=\(bind:workspaceID) AND entity_type='comment' AND kind='updated'
            GROUP BY transaction_group ORDER BY transaction_group
            """).all()
        let sizes=try groups.map { try $0.decode(column:"n",as:Int.self) }.sorted()
        XCTAssertEqual(sizes,[1,1000])
        let names=try await sql.raw("SELECT count(*) AS n FROM project_comments WHERE workspace_id=\(bind:workspaceID) AND author_name='Former member'").first()!.decode(column:"n",as:Int.self)
        XCTAssertEqual(names,1001)
        let activity=try await sql.raw("SELECT detail FROM workspace_activity WHERE workspace_id=\(bind:workspaceID) AND action='member_removed' AND actor_user_id=\(bind:targetID) AND target_id=\(bind:targetID)").first()
        let activityDetail=try activity?.decode(column:"detail",as:String?.self)
        XCTAssertNotNil(activity); XCTAssertNil(activityDetail)
    }
}
