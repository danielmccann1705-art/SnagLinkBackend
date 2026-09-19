import Vapor
import Fluent
import FluentSQL

enum CompanyClosureLifecycleService {
    static func create(_ confirmations: [CompanyClosureConfirmationService.Confirmed], parentJobID: UUID, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        for confirmed in confirmations {
            try await sql.raw("""
                INSERT INTO company_closure_jobs(id,account_deletion_job_id,workspace_id,confirmed_revision,mode,
                    project_count,snag_count,other_member_count,state,requested_at,confirmation_id,inventory_hash)
                VALUES(\(bind: UUID()),\(bind: parentJobID),\(bind: confirmed.workspaceID),\(bind: confirmed.workspaceRevision),'explicit',
                    \(bind: confirmed.inventory.projectCount),\(bind: confirmed.inventory.snagCount),\(bind: confirmed.inventory.otherMemberCount),
                    'erasing',NOW(),\(bind: confirmed.confirmationID),\(bind: confirmed.inventory.fingerprint))
                """).run()
        }
    }
    /// Final acceptance still holds every workspace lock. Each closing scope is
    /// authorised by its own durable child; the post-revocation inventory becomes
    /// immutable erasure authority in the same transaction as account revocation.
    static func freezeAndSeal(_ confirmations: [CompanyClosureConfirmationService.Confirmed], parentJobID: UUID, on db: Database) async throws {
        let sql = try VerifiedIdentityService.sql(db)
        for confirmed in confirmations {
            let id = confirmed.workspaceID
            guard let row = try await sql.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: parentJobID) AND workspace_id=\(bind: id) AND mode='explicit' AND state='erasing' FOR UPDATE").first() else { throw CompanyClosureConfirmationService.changed() }
            let childID = try row.decode(column: "id", as: UUID.self)
            try await sql.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind: parentJobID.uuidString),true),set_config('snaglist.company_closure_job_id',\(bind: childID.uuidString),true)").run()
            guard try await sql.raw("UPDATE teams SET lifecycle_state='closing',revision=revision+1,updated_at=NOW() WHERE id=\(bind: id) AND lifecycle_state='active' RETURNING id").first() != nil else { throw CompanyClosureConfirmationService.changed() }
            try await sql.raw("DELETE FROM link_sessions WHERE grant_id IN (SELECT id FROM link_grants WHERE workspace_id=\(bind: id))").run()
            try await sql.raw("UPDATE link_grants SET state='revoked',revoked_at=COALESCE(revoked_at,NOW()),revision=revision+1,token_ciphertext=NULL,pin_hash=NULL,issuance_json=NULL WHERE workspace_id=\(bind: id)").run()
            try await sql.raw("UPDATE magic_links SET revoked_at=COALESCE(revoked_at,NOW()),pin_hash=NULL,pin_salt=NULL WHERE project_id IN (SELECT id FROM projects WHERE workspace_id=\(bind: id))").run()
            try await sql.raw("UPDATE team_invites SET status=CASE WHEN status='pending' THEN 'revoked' ELSE status END,token='erased:'||id::text,token_hash=NULL,updated_at=NOW() WHERE team_id=\(bind: id)").run()
            try await sql.raw("UPDATE project_access SET state='removed',revision=revision+1,updated_at=NOW() WHERE workspace_id=\(bind: id) AND state='active'").run()
            try await sql.raw("UPDATE workspace_memberships SET state='removed',revision=revision+1,updated_at=NOW() WHERE workspace_id=\(bind: id) AND state='active'").run()
            try await sql.raw("UPDATE ownership_transfer_offers SET state='cancelled',resolved_at=NOW() WHERE workspace_id=\(bind: id) AND state='pending'").run()
            let accepted = try await AccountDeletionGraphService.companyInventory(workspaceID: id, on: db)
            guard accepted.projectCount == confirmed.inventory.projectCount,
                  accepted.snagCount == confirmed.inventory.snagCount,
                  accepted.otherMemberCount == confirmed.inventory.otherMemberCount else { throw CompanyClosureConfirmationService.changed() }
            guard try await sql.raw("""
                UPDATE company_closure_jobs SET erasure_inventory_hash=\(bind: accepted.fingerprint)
                WHERE id=\(bind: childID) AND account_deletion_job_id=\(bind: parentJobID) AND state='erasing' AND erasure_inventory_hash IS NULL RETURNING id
                """).first() != nil else { throw CompanyClosureConfirmationService.changed() }
            try await sql.raw("SELECT set_config('snaglist.company_closure_job_id','',true),set_config('snaglist.account_deletion_job_id','',true)").run()
        }
    }
    /// Finish every confirmed company database graph before processing the shared
    /// parent manifest. Personal rows are then erased even if historical company
    /// objects have unresolved ownership and overall completion remains blocked.
    static func prepareObjects(_ lease: AccountDeletionWorker.Lease, on db: Database,
                               transactionMode: AccountDeletionWorker.TransactionMode) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(db)
        let children = try await sql.raw("SELECT id,workspace_id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state='erasing' ORDER BY workspace_id LIMIT 4").all()
        for child in children {
            let childID = try child.decode(column: "id", as: UUID.self), workspaceID = try child.decode(column: "workspace_id", as: UUID.self)
            guard try await AccountDeletionWorker.renew(lease, on: db) else { return false }
            let changed = try await AccountDeletionWorker.withCurrentLease(lease, on: db, transactionMode: transactionMode) { transaction in
                try await AccountDeletionGraphService.eraseCompany(workspaceID: workspaceID, closureJobID: childID, parentJobID: lease.id, on: transaction)
            }
            guard changed else { return false }
        }
        if try await sql.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state NOT IN ('awaiting_objects','completed') LIMIT 1").first() != nil { return false }
        let hasExplicit = try await sql.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' LIMIT 1").first() != nil
        if hasExplicit {
            guard try await AccountDeletionWorker.renew(lease, on: db) else { return false }
            _ = try await AccountDeletionWorker.withCurrentLease(lease, on: db, transactionMode: transactionMode) { transaction in
                let scoped = try VerifiedIdentityService.sql(transaction)
                let pending = try await scoped.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND database_cleanup_state<>'completed'").first() != nil
                if pending { try await AccountDeletionGraphService.erase(userID: lease.userID, jobID: lease.id, on: transaction) }
            }
        }
        return try await sql.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND database_cleanup_state='completed'").first() != nil
    }
    /// Children conservatively wait for all parent objects, including personal
    /// objects, because a shared key can belong to more than one closing scope.
    /// No unresolved reference is silently turned into successful deletion.
    static func completeObjectPhase(_ lease: AccountDeletionWorker.Lease, on db: Database,
                                    transactionMode: AccountDeletionWorker.TransactionMode) async throws {
        try await AccountDeletionWorker.withCurrentLease(lease, on: db, transactionMode: transactionMode) { transaction in
            let scoped = try VerifiedIdentityService.sql(transaction)
            guard try await scoped.raw("SELECT id FROM account_deletion_jobs WHERE id=\(bind: lease.id) AND database_cleanup_state='completed'").first() != nil,
                  try await scoped.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state NOT IN ('awaiting_objects','completed') LIMIT 1").first() == nil,
                  try await scoped.raw("SELECT object_key FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND completed_at IS NULL LIMIT 1").first() == nil,
                  try await scoped.raw("SELECT d.intent_id FROM account_deletion_write_intents d JOIN object_write_intents i ON i.id=d.intent_id WHERE d.job_id=\(bind:lease.id) AND NOT object_write_is_resolved(d.job_id,i.id) LIMIT 1").first() == nil,
                  try await scoped.raw("SELECT source_id FROM account_deletion_unresolved_objects WHERE job_id=\(bind: lease.id) LIMIT 1").first() == nil else { return }
            let children = try await scoped.raw("SELECT id FROM company_closure_jobs WHERE account_deletion_job_id=\(bind: lease.id) AND mode='explicit' AND state='awaiting_objects' ORDER BY id FOR UPDATE").all()
            for child in children {
                let id = try child.decode(column: "id", as: UUID.self)
                try await scoped.raw("SELECT set_config('snaglist.account_deletion_job_id',\(bind: lease.id.uuidString),true),set_config('snaglist.company_closure_job_id',\(bind: id.uuidString),true)").run()
                try await scoped.raw("UPDATE company_closure_jobs SET state='completed',completed_at=NOW() WHERE id=\(bind: id) AND state='awaiting_objects'").run()
            }
            try await scoped.raw("SELECT set_config('snaglist.company_closure_job_id','',true),set_config('snaglist.account_deletion_job_id','',true)").run()
        }
    }
}
