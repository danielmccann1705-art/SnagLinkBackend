import Vapor
import Fluent
import FluentSQL

struct AccountDeletionRequest: Content, Sendable {
    let confirmation: String
    let receiptReference: String
    var emptyCompanies: [EmptyCompanyAcknowledgement]? = nil
    var companyClosures: [CompanyClosureAcknowledgement]? = nil
}
struct AccountDeletionStatusRequest: Content { let receiptReference: String }
struct AccountDeletionReceipt: Content, Sendable {
    let receiptReference: String
    let state: String
    let requestedAt: Date
    let completedAt: Date?
}

/// Account deletion as a test turns it on, and only a test.
///
/// It is honoured under `.testing` and ignored entirely in every other
/// environment — its presence is not trusted, it is not read. A deployed process
/// has exactly one way to enable deletion, and it is the configuration switch
/// below; this key cannot reach one and a deployment cannot reach this key.
struct AccountDeletionTestActivation: StorageKey { typealias Value = Bool }

enum AccountDeletionService {

    /// The deployed switch, read from configuration alone.
    ///
    /// Accepted only as the exact literal `true`. Any other spelling leaves
    /// deletion off, which is the safe direction for a switch whose "on"
    /// destroys data — and the Cloudflare adapter refuses every other spelling
    /// upstream (`Infrastructure/cloudflare/src/config.mjs`), so a typo is caught
    /// before it reaches a container rather than silently read as "off".
    ///
    /// Turning it on is a deliberate act and not this code's to make: the switch
    /// is read here and set nowhere in this repository outside a test. A boot
    /// that finds it on without a private namespace refuses to start
    /// (`PrivateStorageBoot`), because a deletion that cannot fence cannot finish.
    static func isEnabledByConfiguration(lookup: (String) -> String? = Environment.get) -> Bool {
        lookup("ACCOUNT_DELETION_ENABLED") == "true"
    }

    /// Two ways in and no third: a test that activated it under `.testing`, or a
    /// deployment that set the switch. The reason and identifier are unchanged —
    /// a client that already handles this refusal keeps handling it.
    static func requireAvailable(_ app: Application, lookup: (String) -> String? = Environment.get) throws {
        if app.environment == .testing, app.storage[AccountDeletionTestActivation.self] == true { return }
        guard isEnabledByConfiguration(lookup: lookup) else {
            throw Abort(.serviceUnavailable, reason: "Account deletion is not available yet", identifier: "account_deletion_unavailable")
        }
    }
    static func receiptHash(_ reference: String) throws -> String {
        guard (43...128).contains(reference.utf8.count), reference.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Abort(.badRequest, reason: "A secure deletion reference is required", identifier: "invalid_deletion_reference") }
        return SHA256Hasher.hash(token: "account-deletion:" + reference)
    }
    static func status(reference: String, on db: Database) async throws -> AccountDeletionReceipt {
        let hash = try receiptHash(reference)
        guard let row = try await VerifiedIdentityService.sql(db).raw("""
            SELECT state, requested_at, completed_at FROM account_deletion_jobs WHERE receipt_hash = \(bind: hash)
            """).first() else { throw Abort(.notFound, reason: "Deletion reference not found") }
        let stored = try row.decode(column: "state", as: String.self)
        return try .init(receiptReference: reference, state: ["ready", "leased"].contains(stored) ? "pending" : stored,
                         requestedAt: row.decode(column: "requested_at", as: Date.self),
                         completedAt: row.decode(column: "completed_at", as: Date?.self))
    }

    /// Phase one of erasure. There is intentionally no success claim while the
    /// personal/import graph and copied payload disposition are incomplete.
    static func request(userID: UUID, body: AccountDeletionRequest, app: Application) async throws -> AccountDeletionReceipt {
        try requireAvailable(app)
        guard body.confirmation == "DELETE" else {
            throw Abort(.badRequest, reason: "Confirm account deletion", identifier: "deletion_confirmation_required")
        }
        let hash = try receiptHash(body.receiptReference)
        return try await app.db.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            // Match the canonical write boundary. Locked in stable order to avoid
            // deadlocks when a member belongs to more than one company.
            let scopes = try await sql.raw("""
                SELECT DISTINCT t.id FROM teams t LEFT JOIN workspace_memberships m ON m.workspace_id=t.id
                WHERE t.owner_user_id=\(bind: userID) OR m.user_id=\(bind: userID) ORDER BY t.id
                """).all()
            for scope in scopes { try await WorkspaceAccessService.lock(scope.decode(column: "id", as: UUID.self), on: db) }
            guard let row = try await sql.raw("SELECT lifecycle_state FROM users WHERE id = \(bind: userID) FOR UPDATE").first() else {
                throw Abort(.unauthorized)
            }
            if let previous = try await sql.raw("SELECT receipt_hash FROM account_deletion_jobs WHERE user_id = \(bind: userID)").first() {
                guard try previous.decode(column: "receipt_hash", as: String.self) == hash else {
                    throw Abort(.conflict, reason: "Use the saved deletion reference", identifier: "deletion_already_requested")
                }
                return try await status(reference: body.receiptReference, on: db)
            }
            guard try row.decode(column: "lifecycle_state", as: String.self) == "active" else { throw Abort(.unauthorized) }
            // Authority inserts lock the target user through database triggers.
            // Once this row is locked, a concurrent transfer or invitation cannot
            // attach this account to a scope which escaped the workspace locks.
            let currentScopes = try await sql.raw("""
                SELECT DISTINCT t.id FROM teams t LEFT JOIN workspace_memberships m ON m.workspace_id=t.id
                WHERE t.owner_user_id=\(bind: userID) OR m.user_id=\(bind: userID) ORDER BY t.id
                """).all()
            let lockedIDs = try scopes.map { try $0.decode(column: "id", as: UUID.self) }
            let currentIDs = try currentScopes.map { try $0.decode(column: "id", as: UUID.self) }
            guard lockedIDs == currentIDs else {
                throw Abort(.conflict, reason: "Your workspaces changed. Try deleting your account again", identifier: "account_scope_changed")
            }
            // Every empty-company closure must have been disclosed and explicitly
            // acknowledged. Nonempty companies still require accepted transfer or
            // the separate counted closure route; no implicit cascade is allowed.
            let companyClosures = try await CompanyClosureConfirmationService.consume(body.companyClosures ?? [], userID: userID, receiptHash: hash, on: db)
            let emptyCompanies = try await CompanyDeletionPreparationService.confirmedEmpty(userID: userID, acknowledgements: body.emptyCompanies ?? [], excluding: Set(companyClosures.map(\.workspaceID)), on: db)
            let user = try await VerifiedIdentityService.activeUser(userID, on: db)
            var addresses = Set(try await VerifiedIdentityService.verifiedEmails(for: userID, on: db))
            if let address = user.email { addresses.insert(EmailValidator.normalize(address)) }
            let appleIdentity = try await sql.raw("SELECT id FROM user_identities WHERE user_id=\(bind: userID) AND provider='apple' LIMIT 1").first()
            let hasApple = user.appleUserId != nil || appleIdentity != nil
            let credentialCount = try await sql.raw("SELECT count(*) AS total FROM apple_credentials WHERE user_id=\(bind: userID)").first()?.decode(column: "total", as: Int.self) ?? 0
            let appleState = credentialCount > 0 ? "pending" : (hasApple ? "unavailable" : "not_applicable")
            let jobID = UUID(), now = Date()
            try await sql.raw("""
                INSERT INTO account_deletion_jobs
                (id,user_id,receipt_hash,requested_at,state,available_at,database_cleanup_state,apple_revocation_state,
                 apple_credential_ciphertext,apple_client_id,object_cleanup_state,last_error_kind)
                VALUES (\(bind: jobID),\(bind: userID),\(bind: hash),\(bind: now),'ready',\(bind: now),'blocked',\(bind: appleState),
                        NULL,NULL,'blocked',\(DeletionReasonKind.databaseErasurePending.sql))
                """).run()
            try await CompanyDeletionPreparationService.closeEmpty(emptyCompanies, userID: userID, jobID: jobID, on: db)
            try await CompanyClosureLifecycleService.create(companyClosures, parentJobID: jobID, on: db)
            try await sql.raw("""
                INSERT INTO account_deletion_apple_credentials(id,job_id,client_id,credential_ciphertext,state)
                SELECT gen_random_uuid(),\(bind: jobID),client_id,refresh_token_ciphertext,'pending'
                FROM apple_credentials WHERE user_id=\(bind: userID)
                """).run()
            if hasApple && credentialCount == 0 {
                try await sql.raw("""
                    INSERT INTO account_deletion_apple_credentials(id,job_id,state) VALUES(gen_random_uuid(),\(bind: jobID),'unavailable')
                    """).run()
            }
            // Move encrypted credentials durably, never copy a plaintext provider token.
            try await AppleCredentialService.discard(userID: userID, on: db)
            try await sql.raw("UPDATE users SET lifecycle_state='deleted',auth_version=auth_version+1,email=NULL,name=NULL,apple_user_id=NULL,subscription_tier='free',subscription_verified_until=NULL,updated_at=\(bind: now) WHERE id=\(bind: userID)").run()
            try await sql.raw("UPDATE ownership_transfer_offers SET state='cancelled',resolved_at=NOW() WHERE state='pending' AND (owner_user_id=\(bind: userID) OR target_user_id=\(bind: userID))").run()
            try await sql.raw("DELETE FROM google_identity_challenges WHERE target_user_id=\(bind: userID)").run()
            for table in ["browser_sessions", "device_tokens", "magic_link_sends", "analytics_events", "user_identities"] {
                try await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE user_id=\(bind: userID)").run()
            }
            try await sql.raw("DELETE FROM identity_challenges WHERE target_user_id=\(bind: userID)").run()
            // Keep company invitation decisions and references, erase the deleted
            // recipient's address and make every outstanding capability unusable.
            try await sql.raw("""
                UPDATE team_invites SET email='deleted-' || id::text || '@invalid.invalid',
                    status=CASE WHEN status='pending' THEN 'revoked' ELSE status END,
                    token='erased:' || id::text,token_hash=NULL,updated_at=\(bind: now)
                WHERE accepted_user_id=\(bind: userID)
                """).run()
            for address in addresses {
                try await sql.raw("""
                    UPDATE team_invites SET email='deleted-' || id::text || '@invalid.invalid',
                        status=CASE WHEN status='pending' THEN 'revoked' ELSE status END,
                        token='erased:' || id::text,token_hash=NULL,updated_at=\(bind: now)
                    WHERE lower(btrim(email))=\(bind: address)
                    """).run()
                try await sql.raw("DELETE FROM identity_challenges WHERE lower(btrim(email))=\(bind: address)").run()
                try await sql.raw("DELETE FROM magic_link_auth_tokens WHERE lower(btrim(email))=\(bind: address)").run()
            }
            for table in ["project_change_cursors", "register_snapshots", "project_discovery_snapshots"] {
                try await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE actor_id=\(bind: userID)").run()
            }
            try await sql.raw("DELETE FROM link_sessions WHERE grant_id IN (SELECT id FROM link_grants WHERE creator_id=\(bind: userID))").run()
            try await sql.raw("UPDATE link_grants SET state='revoked',revoked_at=COALESCE(revoked_at,\(bind: now)),revision=revision+1,token_ciphertext=NULL,pin_hash=NULL,issuance_json=NULL WHERE creator_id=\(bind: userID)").run()
            try await sql.raw("UPDATE magic_links SET revoked_at=COALESCE(revoked_at,\(bind: now)),pin_hash=NULL,pin_salt=NULL WHERE created_by_id=\(bind: userID)").run()
            try await AccountDeletionPropagationService.pseudonymiseCompanyAttribution(userID:userID,on:db)
            try await sql.raw("DELETE FROM project_access WHERE user_id=\(bind: userID)").run()
            try await sql.raw("DELETE FROM workspace_memberships WHERE user_id=\(bind: userID)").run()
            try await sql.raw("UPDATE completions SET reviewed_by_name='Former member' WHERE reviewed_by_user_id=\(bind: userID)").run()
            try await sql.raw("UPDATE team_invites SET invited_by_name='Former member' WHERE invited_by_user_id=\(bind: userID)").run()
            if companyClosures.isEmpty {
                try await AccountDeletionGraphService.erase(userID: userID, jobID: jobID, on: db)
            } else {
                try await CompanyClosureLifecycleService.freezeAndSeal(companyClosures, parentJobID: jobID, on: db)
                try await sql.raw("UPDATE account_deletion_jobs SET object_cleanup_state='pending',last_error_kind=\(DeletionReasonKind.companyClosurePending.sql) WHERE id=\(bind: jobID)").run()
            }
            return try await status(reference: body.receiptReference, on: db)
        }
    }
}
