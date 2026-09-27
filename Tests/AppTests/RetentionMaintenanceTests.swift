@testable import App
import XCTVapor
import Fluent
import FluentSQL

/// M1 retention packet (A4 §5, F17): each sweep removes or redacts exactly what the
/// accepted schedule says, keeps what it must keep, and records counts only.
final class RetentionMaintenanceTests: XCTestCase {
    var app: Application!
    var sql: SQLDatabase { app.db as! SQLDatabase }
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[CleanupLockKeyStorage.self] = Int64.random(in: 1_000_000...9_000_000)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func user() async throws -> User {
        try await app.db.transaction { db in try await VerifiedIdentityService.resolveEmail("retention-\(UUID())@example.test", name: "Synthetic owner", on: db) }
    }
    private func fixture() async throws -> (User, Team, Project, Snag) {
        let owner = try await user()
        let workspace = try await app.db.transaction { db in try await WorkspaceAccessService.personal(for: owner.requireID(), on: db) }
        let project = Project(id: UUID(), name: "Retention fixture", reference: String(UUID().uuidString.prefix(8)), ownerId: try owner.requireID())
        project.workspaceId = try workspace.requireID(); project.platformManaged = true
        try await project.save(on: app.db)
        let snag = Snag(id: UUID(), reference: "S-1", title: "Synthetic snag", projectId: try project.requireID(), ownerId: try owner.requireID())
        snag.workspaceId = project.workspaceId; snag.displayNumber = 1; snag.publishedAt = Date()
        try await snag.save(on: app.db)
        return (owner, workspace, project, snag)
    }
    private func days(_ n: Double) -> Date { Date().addingTimeInterval(n * 86_400) }
    private func grant(_ project: Project, creator: User, expires: Date, revoked: Date? = nil, pin: Bool = true) async throws -> UUID {
        let id = UUID()
        let state = revoked == nil ? "active" : "revoked"
        let sealed: String? = revoked == nil ? "sealed-synthetic" : nil
        let pinHash: String? = pin ? "synthetic-pin-hash" : nil
        try await sql.raw("""
            INSERT INTO link_grants (id, workspace_id, project_id, creator_id, contractor_id, mode, state, revision, token_hash, token_ciphertext,
                pin_hash, duration_days, created_at, activated_at, expires_at, revoked_at, issuance_json)
            VALUES (\(bind: id), \(bind: project.workspaceId!), \(bind: project.requireID()), \(bind: creator.requireID()), NULL, 'read_only',
                \(bind: state), 1, \(bind: UUID().uuidString), \(bind: sealed),
                \(bind: pinHash), 14, \(bind: days(-60)), \(bind: days(-59)), \(bind: expires), \(bind: revoked), '{"items":[]}')
            """).run()
        return id
    }
    private func count(_ query: SQLQueryString) async throws -> Int { try await sql.raw(query).first()!.decode(column: "n", as: Int.self) }

    func testExpiredCopiesSessionsAndInvitationsFollowTheAcceptedSchedule() async throws {
        let (owner, workspace, project, snag) = try await fixture()
        let ownerID = try owner.requireID(), workspaceID = try workspace.requireID(), projectID = try project.requireID()
        // Browser sessions: 25 h past expiry goes, 23 h stays.
        let oldSession = UUID(), recentSession = UUID()
        for (id, expiry) in [(oldSession, days(-25.0 / 24)), (recentSession, days(-23.0 / 24))] {
            try await sql.raw("""
                INSERT INTO browser_sessions (id, user_id, token_hash, csrf_hash, environment, origin, auth_version, authenticated_at, created_at, expires_at)
                VALUES (\(bind: id), \(bind: ownerID), \(bind: UUID().uuidString), 'csrf', 'staging', 'https://staging-app.usesnaglist.com', 1, \(bind: days(-8)), \(bind: days(-8)), \(bind: expiry))
                """).run()
        }
        // Download copies and cursors past expiry, with items.
        let snapshot = UUID(), freshSnapshot = UUID()
        for (id, expiry) in [(snapshot, days(-1)), (freshSnapshot, days(1))] {
            try await sql.raw("""
                INSERT INTO register_snapshots (id, token_hash, actor_id, workspace_id, project_id, access_fingerprint, high_watermark, item_count, created_at, expires_at)
                VALUES (\(bind: id), \(bind: UUID().uuidString), \(bind: ownerID), \(bind: workspaceID), \(bind: projectID), 'fp', 0, 1, \(bind: days(-2)), \(bind: expiry))
                """).run()
            try await sql.raw("INSERT INTO register_snapshot_items (snapshot_id, position, entity_type, entity_id, payload_json) VALUES (\(bind: id), 0, 'snag', \(bind: snag.requireID()), '{}')").run()
        }
        let cursor = UUID().uuidString
        try await sql.raw("""
            INSERT INTO project_change_cursors (token_hash, actor_id, workspace_id, project_id, sequence, expires_at)
            VALUES (\(bind: cursor), \(bind: ownerID), \(bind: workspaceID), \(bind: projectID), 0, \(bind: days(-1)))
            """).run()
        let discovery = UUID()
        try await sql.raw("""
            INSERT INTO project_discovery_snapshots (id, token_hash, actor_id, access_fingerprint, workspace_ids, item_count, created_at, expires_at)
            VALUES (\(bind: discovery), \(bind: UUID().uuidString), \(bind: ownerID), 'fp', ARRAY[\(bind: workspaceID)]::UUID[], 1, \(bind: days(-2)), \(bind: days(-1)))
            """).run()
        try await sql.raw("INSERT INTO project_discovery_items (snapshot_id, position, project_id, payload_json) VALUES (\(bind: discovery), 0, \(bind: projectID), '{}')").run()
        // Unlock sessions on a live link.
        let live = try await grant(project, creator: owner, expires: days(10))
        let expiredUnlock = UUID().uuidString, liveUnlock = UUID().uuidString
        try await sql.raw("INSERT INTO link_sessions (token_hash, grant_id, expires_at, created_at) VALUES (\(bind: expiredUnlock), \(bind: live), \(bind: days(-0.1)), \(bind: days(-0.2)))").run()
        try await sql.raw("INSERT INTO link_sessions (token_hash, grant_id, expires_at, created_at) VALUES (\(bind: liveUnlock), \(bind: live), \(bind: days(0.05)), \(bind: days(-0.01)))").run()
        // Invitations in a company.
        let company = try await app.db.transaction { db in try await WorkspaceAccessService.createCompany(id: UUID(), name: "Retention Co", actorID: ownerID, on: db) }
        let staleInvite = UUID(), recentInvite = UUID()
        for (id, expiry) in [(staleInvite, days(-31)), (recentInvite, days(-29))] {
            try await sql.raw("""
                INSERT INTO team_invites (id, email, role, status, token, team_id, expires_at, invited_by_user_id, invited_by_name, created_at, updated_at, token_hash)
                VALUES (\(bind: id), \(bind: "invitee-\(id)@example.test"), 'member', 'pending', \(bind: "sha256:" + id.uuidString), \(bind: company.requireID()),
                        \(bind: expiry), \(bind: ownerID), 'Synthetic owner', \(bind: days(-40)), \(bind: days(-40)), \(bind: id.uuidString))
                """).run()
        }
        // Housekeeping rows.
        let oldRun = UUID()
        try await sql.raw("INSERT INTO cleanup_runs (id, trigger, started_at, finished_at, state) VALUES (\(bind: oldRun), 'test', \(bind: days(-400)), \(bind: days(-400)), 'succeeded')").run()
        let oldOutbox = UUID()
        try await sql.raw("""
            INSERT INTO workflow_outbox (id, workspace_id, project_id, snag_id, actor_id, event_kind, payload_json, dedupe_key, state, attempts, available_at, created_at)
            VALUES (\(bind: oldOutbox), \(bind: workspaceID), \(bind: projectID), \(bind: snag.requireID()), \(bind: ownerID), 'submitted', '{}', \(bind: UUID().uuidString), 'ready', 0, \(bind: days(-31)), \(bind: days(-31)))
            """).run()

        let counts = try await RetentionMaintenanceService.run(on: app.db, receiptWindowDays: nil)
        XCTAssertEqual(counts.failed, [])
        XCTAssertNil(counts.receiptPurgeWindowDays, "the receipt purge is off unless configured")
        do { let n = try await count("SELECT count(*) AS n FROM browser_sessions WHERE id IN (\(bind: oldSession), \(bind: recentSession))"); XCTAssertEqual(n, 1) }
        do { let n = try await count("SELECT count(*) AS n FROM browser_sessions WHERE id = \(bind: recentSession)"); XCTAssertEqual(n, 1) }
        do { let n = try await count("SELECT count(*) AS n FROM register_snapshots WHERE id IN (\(bind: snapshot), \(bind: freshSnapshot))"); XCTAssertEqual(n, 1) }
        do { let n = try await count("SELECT count(*) AS n FROM register_snapshot_items WHERE snapshot_id = \(bind: freshSnapshot)"); XCTAssertEqual(n, 1) }
        do { let n = try await count("SELECT count(*) AS n FROM register_snapshot_items WHERE snapshot_id = \(bind: snapshot)"); XCTAssertEqual(n, 0) }
        do { let n = try await count("SELECT count(*) AS n FROM project_change_cursors WHERE token_hash = \(bind: cursor)"); XCTAssertEqual(n, 0) }
        do { let n = try await count("SELECT count(*) AS n FROM project_discovery_snapshots WHERE id = \(bind: discovery)"); XCTAssertEqual(n, 0) }
        do { let n = try await count("SELECT count(*) AS n FROM link_sessions WHERE token_hash IN (\(bind: expiredUnlock), \(bind: liveUnlock))"); XCTAssertEqual(n, 1) }
        do { let n = try await count("SELECT count(*) AS n FROM link_sessions WHERE token_hash = \(bind: liveUnlock)"); XCTAssertEqual(n, 1) }
        let stale = try await sql.raw("SELECT email, status, token, token_hash FROM team_invites WHERE id = \(bind: staleInvite)").first()!
        XCTAssertEqual(try stale.decode(column: "email", as: String.self), "expired-\(staleInvite.uuidString.lowercased())@invalid.invalid")
        XCTAssertEqual(try stale.decode(column: "status", as: String.self), "expired")
        XCTAssertEqual(try stale.decode(column: "token", as: String.self), "erased:\(staleInvite.uuidString.lowercased())")
        XCTAssertNil(try stale.decode(column: "token_hash", as: String?.self))
        let recent = try await sql.raw("SELECT email, status FROM team_invites WHERE id = \(bind: recentInvite)").first()!
        XCTAssertEqual(try recent.decode(column: "email", as: String.self), "invitee-\(recentInvite)@example.test")
        XCTAssertEqual(try recent.decode(column: "status", as: String.self), "pending")
        do { let n = try await count("SELECT count(*) AS n FROM cleanup_runs WHERE id = \(bind: oldRun)"); XCTAssertEqual(n, 0) }
        do { let n = try await count("SELECT count(*) AS n FROM workflow_outbox WHERE id = \(bind: oldOutbox)"); XCTAssertEqual(n, 0) }
        // A second pass finds nothing more of these.
        let again = try await RetentionMaintenanceService.run(on: app.db, receiptWindowDays: nil)
        XCTAssertEqual(again.failed, [])
        do { let n = try await count("SELECT count(*) AS n FROM team_invites WHERE id = \(bind: staleInvite) AND status = 'expired'"); XCTAssertEqual(n, 1) }
    }

    func testContractorLinkSecretsGoThirtyDaysAfterTheLinkEndedAndReadsStayRefused() async throws {
        let (owner, _, project, _) = try await fixture()
        let expired = try await grant(project, creator: owner, expires: days(-31))
        let revoked = try await grant(project, creator: owner, expires: days(20), revoked: days(-31))
        let recent = try await grant(project, creator: owner, expires: days(-29))
        let live = try await grant(project, creator: owner, expires: days(5))
        let receiptOperation = UUID()
        try await sql.raw("""
            INSERT INTO link_mutation_receipts (grant_id, operation_id, device_id, request_hash, result_json, created_at)
            VALUES (\(bind: expired), \(bind: receiptOperation), \(bind: UUID()), 'hash', '{}', \(bind: days(-40)))
            """).run()
        let counts = try await RetentionMaintenanceService.run(on: app.db, receiptWindowDays: nil)
        XCTAssertEqual(counts.failed, [])
        for id in [expired, revoked] {
            let row = try await sql.raw("SELECT state, token_hash, token_ciphertext, pin_hash, issuance_json, secrets_purged_at FROM link_grants WHERE id = \(bind: id)").first()!
            XCTAssertNil(try row.decode(column: "token_ciphertext", as: String?.self))
            XCTAssertNil(try row.decode(column: "pin_hash", as: String?.self))
            XCTAssertNil(try row.decode(column: "issuance_json", as: String?.self))
            XCTAssertNotNil(try row.decode(column: "secrets_purged_at", as: Date?.self))
            XCTAssertNotNil(try row.decode(column: "token_hash", as: String?.self), "the lookup hash stays so the link still answers 'expired'")
        }
        for id in [recent, live] {
            let row = try await sql.raw("SELECT token_ciphertext, pin_hash, secrets_purged_at FROM link_grants WHERE id = \(bind: id)").first()!
            XCTAssertNotNil(try row.decode(column: "token_ciphertext", as: String?.self))
            XCTAssertNotNil(try row.decode(column: "pin_hash", as: String?.self))
            XCTAssertNil(try row.decode(column: "secrets_purged_at", as: Date?.self))
        }
        do { let n = try await count("SELECT count(*) AS n FROM link_mutation_receipts WHERE grant_id = \(bind: expired)"); XCTAssertEqual(n, 0) }
        // The manager's view of an ended link still reads as ended.
        let listed = try await LinkGrantService.response(LinkGrantService.row(expired, projectID: project.requireID(), on: app.db), on: app.db)
        XCTAssertEqual(listed.state, "active"); XCTAssertLessThan(listed.expiresAt, Date())
        // The database refuses an active link that lost its material without a purge record.
        do {
            try await sql.raw("UPDATE link_grants SET token_ciphertext = NULL WHERE id = \(bind: live)").run()
            XCTFail("An active link without its sealed token must be refused unless purged")
        } catch {}
    }

    func testPurgedReceiptIsRecognisedAndNeverReplayed() async throws {
        let (owner, workspace, _, _) = try await fixture()
        let ownerID = try owner.requireID(), operation = UUID(), recentOperation = UUID()
        let hash = "synthetic-request-hash"
        for (id, created) in [(operation, days(-31)), (recentOperation, days(-1))] {
            try await sql.raw("""
                INSERT INTO mutation_receipts (actor_id, operation_id, device_id, workspace_id, request_hash, result_json, created_at)
                VALUES (\(bind: ownerID), \(bind: id), \(bind: UUID()), \(bind: workspace.requireID()), \(bind: hash), '{"value":"synthetic"}', \(bind: created))
                """).run()
        }
        XCTAssertNil(RetentionMaintenanceService.receiptWindowDays(lookup: { _ in nil }))
        XCTAssertNil(RetentionMaintenanceService.receiptWindowDays(lookup: { _ in "7" }), "shorter than a session is refused")
        XCTAssertEqual(RetentionMaintenanceService.receiptWindowDays(lookup: { _ in "30" }), 30)
        let counts = try await RetentionMaintenanceService.run(on: app.db, receiptWindowDays: 30)
        XCTAssertEqual(counts.failed, []); XCTAssertEqual(counts.receiptPurgeWindowDays, 30)
        let purged = try await sql.raw("SELECT result_json, result_purged_at, request_hash FROM mutation_receipts WHERE actor_id = \(bind: ownerID) AND operation_id = \(bind: operation)").first()!
        XCTAssertEqual(try purged.decode(column: "result_json", as: String.self), #"{"resultPurged":true}"#)
        XCTAssertNotNil(try purged.decode(column: "result_purged_at", as: Date?.self))
        XCTAssertEqual(try purged.decode(column: "request_hash", as: String.self), hash, "recognition is kept")
        struct Value: Codable { let value: String }
        let metadata = MutationMetadata(operationId: operation, deviceId: UUID())
        do {
            _ = try await PlatformMutationService.replay(Value.self, actorID: ownerID, mutation: metadata, hash: hash, on: app.db)
            XCTFail("A purged receipt must not replay")
        } catch let error as Abort {
            XCTAssertEqual(error.status, .conflict); XCTAssertEqual(error.identifier, "already_applied_refresh_required")
        }
        do {
            _ = try await PlatformMutationService.replay(Value.self, actorID: ownerID, mutation: metadata, hash: "different", on: app.db)
            XCTFail("A reused operation id must still be refused")
        } catch let error as Abort { XCTAssertEqual(error.identifier, "operation_reused") }
        let recent = try await PlatformMutationService.replay(Value.self, actorID: ownerID, mutation: .init(operationId: recentOperation, deviceId: UUID()), hash: hash, on: app.db)
        XCTAssertEqual(recent?.value, "synthetic")
    }

    func testTheHourlyPassRecordsRetentionCountsAndCountsOrphansWithoutErasingThem() async throws {
        let (owner, _, project, snag) = try await fixture()
        let orphan = UUID()
        try await sql.raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,original_sha256,original_size,
                original_mime,original_key,rendition_key,revision,base_snag_revision,created_at,expires_at)
            VALUES(\(bind: orphan),\(bind: project.workspaceId!),\(bind: project.requireID()),\(bind: snag.requireID()),\(bind: owner.requireID()),
                'capture','allocated',\(bind: String(repeating: "c", count: 64)),100,'image/jpeg',\(bind: "platform/retention/\(UUID())/original"),
                \(bind: "platform/retention/\(UUID())/rendition.jpg"),1,1,\(bind: days(-9)),\(bind: days(-8)))
            """).run()
        let removed = try await CleanupService.runCleanup(app: app, trigger: .test)
        let retention = try XCTUnwrap(removed?.retention)
        XCTAssertEqual(retention.failed, [])
        XCTAssertGreaterThanOrEqual(retention.orphanUploadsAwaitingFence, 1)
        do { let n = try await count("SELECT count(*) AS n FROM media_assets WHERE id = \(bind: orphan)"); XCTAssertEqual(n, 1, "orphans are counted, not erased, until the fence path exists") }
        let row = try await sql.raw("SELECT removed_json FROM cleanup_runs WHERE state = 'succeeded' ORDER BY started_at DESC LIMIT 1").first()!
        let json = try row.decode(column: "removed_json", as: String.self)
        XCTAssertTrue(json.contains("\"retention\""))
        XCTAssertFalse(json.contains("@"))
        let decoded = try JSONDecoder().decode(CleanupService.Removed.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.retention?.failed, [])
    }
}
