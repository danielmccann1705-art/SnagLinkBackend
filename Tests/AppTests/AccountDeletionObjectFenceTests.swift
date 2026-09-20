@testable import App
import Fluent
import FluentSQL
import XCTVapor

/// The fence pass: the part of a deletion job that makes an object permanently
/// unreadable rather than deleting it.
///
/// What these hold is the property that matters when someone's photographs are at
/// stake — a key whose writers use the create-only protocol is never physically
/// deleted, whatever else happens, and a key whose captured intents disagree about
/// where it lives is never touched at all.
final class AccountDeletionObjectFenceTests: XCTestCase {
    var app: Application!

    /// Records every call so a test can assert that storage was never reached.
    actor Storage: ObjectErasureFenceStorage {
        nonisolated let target: ObjectStorageWriteTarget
        private var puts = 0
        init(target: ObjectStorageWriteTarget) { self.target = target }
        func replaceWithEmptyFence(key: String, contentType: String, metadata: [String: String]) async throws -> String {
            puts += 1
            return "synthetic-etag"
        }
        func readFence(key: String, maximumBytes: Int) async throws -> ObjectErasureFenceReadback {
            .init(target: target, key: key, body: Data(), byteCount: 0,
                  contentType: ObjectErasureFenceService.contentType,
                  metadata: ["snaglist-erasure": ObjectErasureFenceService.marker], etag: "synthetic-etag")
        }
        func putCount() -> Int { puts }
    }

    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        app = try await Application.make(.testing); try await configure(app)
        app.storage[AccountDeletionTestActivation.self] = true
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    // MARK: fixtures

    private func user() async throws -> UUID {
        try await app.db.transaction { db in
            try await VerifiedIdentityService.resolveEmail("fencepass-\(UUID())@example.test", name: "Synthetic member", on: db).requireID()
        }
    }
    private func target(identity: String = "synthetic-r2-account", bucket: String = "synthetic-private",
                        namespace: String = "fences-v1/") -> ObjectStorageWriteTarget {
        .init(backend: "r2", backendIdentity: identity, bucket: bucket, namespace: namespace, writeProtocol: .createOnlyV1)
    }
    /// What these cases are about is table contents the candidate query exists to
    /// refuse: two buckets on one physical key, a historical writer with no target
    /// beside a create-only one. `ObjectWriteIntentService.begin` takes an
    /// allocation now, and the policy will never produce one that says any of those
    /// things — which is exactly the protection — so the rows are written with
    /// `begin`'s own columns instead. The triggers still run on that insert; that
    /// is the point. The signature is unchanged, so every case below reads as it
    /// did.
    @discardableResult
    private func intent(userID: UUID, key: String, kind: String = "private_media",
                        target: ObjectStorageWriteTarget?) async throws -> UUID {
        try await app.db.transaction { db in
            try await ObjectWriteIntentRows.insert(userID: userID, key: key, kind: kind, target: target, on: db)
        }
    }
    private func endAndLease(_ id: UUID) async throws -> AccountDeletionWorker.Lease {
        _ = try await AccountDeletionService.request(userID: id, body: .init(confirmation: "DELETE", receiptReference: UUID().uuidString+UUID().uuidString), app: app)
        let token = UUID()
        let row = try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET state='leased',lease_token=\(bind:token),lease_expires_at=clock_timestamp()+INTERVAL '5 minutes' WHERE user_id=\(bind:id) RETURNING id").first()!
        return try .init(id: row.decode(column: "id", as: UUID.self), userID: id, token: token, attempt: 1)
    }
    /// Puts one manifest row in front of the pass without running graph erasure.
    private func manifest(_ lease: AccountDeletionWorker.Lease, kind: String = "private_media", key: String) async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO account_deletion_objects(job_id,storage_kind,object_key,attempts)
            VALUES(\(bind: lease.id),\(bind: kind),\(bind: key),0)
            ON CONFLICT DO NOTHING
            """).run()
    }

    // MARK: what the candidate query will and will not offer

    func testOneExactTargetIsACandidate() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertEqual(found.map(\.key), [key])
        XCTAssertEqual(found.first?.target, target())
    }

    /// Two writers that disagree about where the object lives cannot be fenced:
    /// one of them would be fencing somebody else's key.
    func testTwoDisagreeingTargetsAreNeverACandidate() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        try await intent(userID: id, key: key, target: target(bucket: "synthetic-private-other"))
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertTrue(found.isEmpty, "a key whose writers disagree about its target must be blocked without storage IO")
    }

    /// A historical row carries no target at all. It stays blocked and is never
    /// promoted into something fenceable.
    func testAnIntentWithNoTargetIsNeverACandidate() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: nil)
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertTrue(found.isEmpty, "a historical row with no target is never promoted into something fenceable")
    }

    /// One create-only writer is enough to keep the key out of the candidate set
    /// when another writer on the same key is a historical unknown.
    func testAMixOfKnownAndUnknownProtocolsIsNeverACandidate() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        try await intent(userID: id, key: key, target: nil)
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)

        let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertTrue(found.isEmpty, "one unknown writer on the key is enough to keep it out")
    }

    // MARK: the pass itself

    /// The whole point: request, verify, attest, and the manifest row completes
    /// without anything ever having been deleted.
    func testAnEligibleKeyIsFencedAndCompletes() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        let write = try await intent(userID: id, key: key, target: target())
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
        let storage = Storage(target: target())
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage

        let attested = try await AccountDeletionObjectFenceService.perform(lease, app: app, on: app.db)
        XCTAssertEqual(attested, 1)
        let puts = await storage.putCount()
        XCTAssertEqual(puts, 1)

        let row = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)
            """).first()
        XCTAssertNotNil(try row?.decode(column: "completed_at", as: Date?.self) ?? nil,
                        "attesting a fence completes the manifest row; nothing is deleted")
        let resolved = try await VerifiedIdentityService.sql(app.db).raw("SELECT object_write_is_resolved(\(bind: lease.id),\(bind: write)) AS resolved").first()!
        XCTAssertTrue(try resolved.decode(column: "resolved", as: Bool.self))
    }

    /// A second pass over an already-attested key does no storage work at all. A
    /// lost acknowledgement must not become a second fence attempt.
    func testAnAttestedKeyIsNotFencedTwice() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
        let storage = Storage(target: target())
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage

        _ = try await AccountDeletionObjectFenceService.perform(lease, app: app, on: app.db)
        _ = try await AccountDeletionObjectFenceService.perform(lease, app: app, on: app.db)
        let puts = await storage.putCount()
        XCTAssertEqual(puts, 1, "durable success is observed, not repeated")
    }

    /// The budget is time, so a pass that has already spent it starts nothing —
    /// and leaves the key for the next scheduled pass rather than failing it.
    func testAnExhaustedTimeBudgetStartsNothing() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)
        let storage = Storage(target: target())
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage

        let attested = try await AccountDeletionObjectFenceService.perform(
            lease, app: app, on: app.db, budget: .init(pass: 0, candidates: 16))
        XCTAssertEqual(attested, 0)
        let puts = await storage.putCount()
        XCTAssertEqual(puts, 0)
        let row = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT last_error_kind FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)
            """).first()
        XCTAssertNil(try row?.decode(column: "last_error_kind", as: String?.self) ?? nil,
                     "running out of time is not a failure of the key")
    }

    /// Ineligible means no storage call. The database decides — whether that is
    /// the fence insert's own constraints or the eligibility function — and it
    /// decides before anything is written.
    func testAnIneligibleKeyIsRecordedWithoutTouchingStorage() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)
        // Objects are fenced only after the graph erasure has finished. Set the
        // state explicitly rather than relying on whatever the request left.
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='pending' WHERE id=\(bind: lease.id)").run()
        let storage = Storage(target: target())
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage

        let attested = try await AccountDeletionObjectFenceService.perform(lease, app: app, on: app.db)
        XCTAssertEqual(attested, 0)
        let puts = await storage.putCount()
        XCTAssertEqual(puts, 0, "eligibility is decided before any storage call")
        let row = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT last_error_kind FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)
            """).first()
        XCTAssertEqual(try row?.decode(column: "last_error_kind", as: String?.self) ?? nil, "fence_not_eligible")
    }

    // MARK: one clock

    /// Makes every job that already existed undue, so the claim below can only
    /// return this test's own. `claim` selects by a global predicate, and a job
    /// another test left behind would otherwise be the one it picks up.
    private func parkExistingJobs() async throws {
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET available_at=clock_timestamp()+INTERVAL '1 day',
                lease_expires_at=CASE WHEN state='leased' THEN clock_timestamp()+INTERVAL '1 day' ELSE lease_expires_at END
            WHERE state IN ('ready','blocked','leased')
            """).run()
    }

    /// Every durable lease predicate in this flow is PostgreSQL's
    /// `clock_timestamp()`, so a lease the database considers expired is expired for
    /// everyone — whatever the application process believes the time to be.
    ///
    /// The provider here is the correct one throughout: it accepts the fence and
    /// reads back exactly what was written. The only thing that differs between the
    /// two halves is the lease, so the refusal can have come from nothing else.
    func testACorrectProviderCannotAttestUnderAStaleLease() async throws {
        let id = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: id, key: key, target: target())
        try await parkExistingJobs()
        let lease = try await endAndLease(id)
        try await manifest(lease, key: key)
        try await VerifiedIdentityService.sql(app.db).raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
        let storage = Storage(target: target())
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage

        // Expired by the database's own clock, which is the only clock any
        // predicate in this flow consults.
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET lease_expires_at=clock_timestamp()-INTERVAL '1 minute' WHERE id=\(bind: lease.id)
            """).run()

        let stale = try await AccountDeletionObjectFenceService.perform(lease, app: app, on: app.db)
        XCTAssertEqual(stale, 0, "an expired lease attests nothing, however willing the provider is")
        var puts = await storage.putCount()
        XCTAssertEqual(puts, 0, "the lease is checked before storage is reached")
        var row = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)
            """).first()
        XCTAssertNil(try row?.decode(column: "completed_at", as: Date?.self) ?? nil,
                     "nothing about the key changed; it is simply left for a worker that holds a lease")

        // The same key and the same provider, under a lease PostgreSQL issued itself.
        try await VerifiedIdentityService.sql(app.db).raw("""
            UPDATE account_deletion_jobs SET state='ready',lease_token=NULL,lease_expires_at=NULL,
                available_at=clock_timestamp()-INTERVAL '1 minute' WHERE id=\(bind: lease.id)
            """).run()
        let claimed = try await AccountDeletionWorker.claim(on: app.db)
        let fresh = try XCTUnwrap(claimed)
        XCTAssertEqual(fresh.id, lease.id, "the parked rows leave exactly this job claimable")
        let current = try await AccountDeletionObjectFenceService.perform(fresh, app: app, on: app.db)
        XCTAssertEqual(current, 1, "the same provider response attests once the lease is current")
        puts = await storage.putCount()
        XCTAssertEqual(puts, 1)
        row = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)
            """).first()
        XCTAssertNotNil(try row?.decode(column: "completed_at", as: Date?.self) ?? nil,
                        "a fresh claim fences the key the stale lease could not")
    }

    // MARK: the provider

    /// A store for one target may not serve another, and nothing falls back to a
    /// physical delete, the public bucket or local disk.
    func testTheProviderRefusesAnythingButItsOwnTarget() async throws {
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = Storage(target: target())
        XCTAssertNoThrow(try AccountDeletionFenceProvider.store(for: target(), app: app))
        XCTAssertThrowsError(try AccountDeletionFenceProvider.store(for: target(bucket: "synthetic-elsewhere"), app: app))
        XCTAssertThrowsError(try AccountDeletionFenceProvider.store(for: target(identity: "other-account"), app: app))
        XCTAssertThrowsError(try AccountDeletionFenceProvider.store(for: target(namespace: "other-v1/"), app: app))
    }

    /// With nothing configured and nothing injected there is no store, and the
    /// caller is told so rather than handed something that can delete.
    func testAnUnconfiguredProviderIsUnavailableRatherThanPermissive() async throws {
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = nil
        XCTAssertThrowsError(try AccountDeletionFenceProvider.store(for: target(), app: app)) { error in
            XCTAssertEqual(error as? AccountDeletionFenceProvider.Failure, .unavailable)
        }
    }

    /// A legacy target cannot be fenced at all, whatever is installed.
    func testALegacyProtocolTargetIsRefusedByTheProvider() async throws {
        let legacy = ObjectStorageWriteTarget(backend: "r2", backendIdentity: "synthetic-r2-account",
                                              bucket: "synthetic-private", namespace: "fences-v1/", writeProtocol: .legacyUnknown)
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = Storage(target: target())
        XCTAssertThrowsError(try AccountDeletionFenceProvider.store(for: legacy, app: app))
    }

    // MARK: - fixtures for the namespaced cases

    /// The private namespace as the real loader produces it, installed for this
    /// process only. `allocateMedia` is the one thing that decides a namespaced
    /// address, so a test that needs one asks the policy rather than writing a
    /// string that happens to look right.
    @discardableResult
    private func installedNamespace() throws -> PrivateStorageTargetConfiguration {
        let configuration = try TestPrivateContentStore.syntheticConfiguration(namespace: "fences-v1/")
        app.storage[PrivateObjectAllocationPolicy.InjectionKey.self] = configuration
        return configuration
    }

    private struct PersonalGraph { let userID: UUID; let workspaceID: UUID; let projectID: UUID; let snagID: UUID }

    private func personalGraph() async throws -> PersonalGraph {
        let userID = try await user()
        let workspace = try await app.db.transaction { try await WorkspaceAccessService.personal(for: userID, on: $0) }
        let project = Project(id: UUID(), name: "Private project", reference: UUID().uuidString.prefix(8).description, ownerId: userID)
        project.workspaceId = try workspace.requireID(); project.platformManaged = true
        try await project.save(on: app.db)
        let snag = Snag(id: UUID(), reference: "S-1", title: "Synthetic snag", projectId: try project.requireID(), ownerId: userID)
        snag.workspaceId = project.workspaceId; snag.displayNumber = 1; snag.publishedAt = Date()
        try await snag.save(on: app.db)
        return .init(userID: userID, workspaceID: try workspace.requireID(),
                     projectID: try project.requireID(), snagID: try snag.requireID())
    }

    /// One media row at exactly the two addresses the caller names. `ready` decides
    /// whether the rendition column holds the real address or the allocation-time
    /// placeholder's worth of nothing.
    private func mediaRow(_ graph: PersonalGraph, original: String, rendition: String, ready: Bool) async throws {
        let digest: String? = ready ? String(repeating: "b", count: 64) : nil
        let size: Int? = ready ? 90 : nil
        let edge: Int? = ready ? 10 : nil
        let moment: Date? = ready ? Date() : nil
        try await VerifiedIdentityService.sql(app.db).raw("""
            INSERT INTO media_assets(id,workspace_id,project_id,snag_id,creator_id,purpose,state,original_sha256,original_size,
                original_mime,original_key,rendition_key,rendition_sha256,rendition_size,width,height,revision,base_snag_revision,
                created_at,expires_at,ready_at,attached_at)
            VALUES(\(bind: UUID()),\(bind: graph.workspaceID),\(bind: graph.projectID),\(bind: graph.snagID),\(bind: graph.userID),
                'capture',\(bind: ready ? "ready" : "allocated"),\(bind: String(repeating: "a", count: 64)),100,'image/jpeg',
                \(bind: original),\(bind: rendition),\(bind: digest),\(bind: size),\(bind: edge),\(bind: edge),
                1,1,NOW(),NOW()+INTERVAL '1 day',\(bind: moment),\(bind: moment))
            """).run()
    }

    private func manifestKeys(_ lease: AccountDeletionWorker.Lease, kind: String = "private_media") async throws -> Set<String> {
        let rows = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT object_key FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND storage_kind=\(bind: kind)
            """).all()
        return try Set(rows.map { try $0.decode(column: "object_key", as: String.self) })
    }

    // MARK: - a key that can be neither fenced nor deleted

    /// Matrix #21 and #22. A key nothing will ever act on again has to say so.
    ///
    /// Two captured writers that disagree about where the object lives, or one
    /// create-only writer beside a historical unknown, leave a key the fence pass
    /// will not offer and the delete branch will not touch. Before this packet the
    /// job reported `object_cleanup_state='pending'`, went back to `ready` and
    /// climbed the backoff curve to hourly, for ever — indistinguishable from work
    /// that was merely slow. `pending` now means "will finish on its own", and this
    /// is `blocked`, with a reason an operator can act on.
    func testAKeyThatCanBeNeitherFencedNorDeletedBlocksTheJobWithItsOwnReason() async throws {
        for disagreement in ["two targets", "a historical writer"] {
            let id = try await user(), key = "fences-v1/\(UUID())"
            try await intent(userID: id, key: key, target: target())
            try await intent(userID: id, key: key,
                             target: disagreement == "two targets" ? target(bucket: "synthetic-private-other") : nil)
            let lease = try await endAndLease(id)
            try await manifest(lease, key: key)
            let sql = try VerifiedIdentityService.sql(app.db)
            try await sql.raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
            // Every writer has finished. Nothing is in flight, and still nothing can
            // act on the key: this is the state the reason exists to name.
            try await sql.raw("UPDATE object_write_intents SET state='settled',settled_at=NOW() WHERE object_key=\(bind: key)").run()
            let storage = Storage(target: target())
            app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage
            app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
                revokeApple: { _, _, _ in .revoked },
                deleteObject: { _, _ in XCTFail("A create-only address is never physically deleted, however its writers disagree") })

            try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
            let state = try await AccountDeletionWorker.finish(lease, on: app.db)
            let puts = await storage.putCount()
            XCTAssertEqual(puts, 0, "\(disagreement): refused by the candidate query, with no storage IO at all")
            XCTAssertEqual(state, "blocked", disagreement)
            let row = try await sql.raw("SELECT object_cleanup_state,last_error_kind FROM account_deletion_jobs WHERE id=\(bind: lease.id)").first()!
            XCTAssertEqual(try row.decode(column: "object_cleanup_state", as: String.self), "blocked", disagreement)
            XCTAssertEqual(try row.decode(column: "last_error_kind", as: String.self), "object_target_ambiguous", disagreement)
        }
    }

    /// Matrix #42. A create-only address is fenced or it is nothing. If one reaches
    /// the delete branch the capture was incomplete — another job's writer, or the
    /// same physical key recorded under another storage kind — and the answer to an
    /// incomplete capture is the blocked state, never a DELETE of an address some
    /// writer may still be creating. So the exclusion reads the physical key, not
    /// this job's captured rows and not this row's storage kind.
    func testACreateOnlyIntentFromAnotherJobOrKindKeepsTheKeyOutOfTheDeleteBranch() async throws {
        let owner = try await user(), stranger = try await user(), key = "fences-v1/\(UUID())"
        try await intent(userID: stranger, key: key, kind: "private_drawing", target: target())
        let lease = try await endAndLease(owner)
        try await manifest(lease, key: key)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = Storage(target: target())
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked },
            deleteObject: { _, _ in XCTFail("A create-only address is never deleted, whoever recorded the write") })

        try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
        let state = try await AccountDeletionWorker.finish(lease, on: app.db)
        XCTAssertEqual(state, "blocked")
        let job = try await sql.raw("SELECT last_error_kind FROM account_deletion_jobs WHERE id=\(bind: lease.id)").first()!
        XCTAssertEqual(try job.decode(column: "last_error_kind", as: String.self), "object_target_ambiguous",
                       "an uncaptured create-only writer is an incomplete capture, and it is visible rather than silent")
        let row = try await sql.raw("SELECT completed_at FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND object_key=\(bind: key)").first()
        XCTAssertNil(try row?.decode(column: "completed_at", as: Date?.self) ?? nil)
        let survivingWrite = try await sql.raw("SELECT 1 FROM object_write_intents i WHERE i.object_key=\(bind: key) AND i.storage_kind='private_drawing'").first()
        XCTAssertNotNil(survivingWrite, "the other account's evidence is untouched")
    }

    // MARK: - the namespace, as the policy allocates it

    /// Matrix #29. Why E7 exists at all.
    ///
    /// An asset that never became ready still carries the allocation-time rendition
    /// placeholder in its row, so that is the only rendition address the graph can
    /// name. If the real rendition was written before readiness failed, no surviving
    /// row names it — and without the captured write intent it would be an object no
    /// deletion could ever reach, at an address only the bytes themselves know.
    func testTheRealRenditionOfAnAssetThatNeverBecameReadyIsNamedOnlyByItsIntent() async throws {
        let configuration = try installedNamespace()
        let graph = try await personalGraph()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: graph.workspaceID, projectID: graph.projectID, app: app)
        let real = try PrivateObjectAllocationPolicy.rendition(of: allocation, sha256: String(repeating: "7", count: 64), app: app)
        let placeholder = String(allocation.key.dropLast("original".count)) + "view.jpg"
        try await mediaRow(graph, original: allocation.key, rendition: placeholder, ready: false)
        try await intent(userID: graph.userID, key: allocation.key, target: configuration.target)
        try await intent(userID: graph.userID, key: real.key, target: configuration.target)
        let namedByAnyRow = try await VerifiedIdentityService.sql(app.db).raw("""
            SELECT 1 FROM media_assets WHERE original_key=\(bind: real.key) OR rendition_key=\(bind: real.key)
            """).first()
        XCTAssertNil(namedByAnyRow, "no row names the real rendition; the recorded write is the only evidence it exists")

        let lease = try await endAndLease(graph.userID)
        let manifested = try await manifestKeys(lease)
        XCTAssertEqual(manifested, Set([allocation.key, placeholder, real.key]),
                       "the original and the placeholder come from the row; the real rendition comes from E7 alone")
        let candidates = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertEqual(Set(candidates.map(\.key)), Set([allocation.key, real.key]),
                       "both recorded writes are fenceable; the placeholder names an object that was never written")
        XCTAssertTrue(candidates.allSatisfy { $0.target == configuration.target })
    }

    /// Matrix #41. The whole point of the wave, end to end on one asset: a ready
    /// photograph's two namespaced addresses are one manifest row each, one fence
    /// candidate each, and both are made permanently unreadable rather than deleted.
    ///
    /// The manifest's spelling of each address is byte-identical to its intent's
    /// because both came from one allocation, which is what lets M1 hold by
    /// construction here instead of by normalisation.
    func testANamespacedOriginalAndRenditionAreOneManifestRowEachAndBothAreFenced() async throws {
        let configuration = try installedNamespace()
        let graph = try await personalGraph()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: graph.workspaceID, projectID: graph.projectID, app: app)
        let rendition = try PrivateObjectAllocationPolicy.rendition(of: allocation, sha256: String(repeating: "3", count: 64), app: app)
        try await mediaRow(graph, original: allocation.key, rendition: rendition.key, ready: true)
        try await intent(userID: graph.userID, key: allocation.key, target: configuration.target)
        try await intent(userID: graph.userID, key: rendition.key, target: configuration.target)

        let lease = try await endAndLease(graph.userID)
        let storage = Storage(target: configuration.target)
        app.storage[AccountDeletionFenceProvider.InjectionKey.self] = storage
        app.storage[AccountDeletionWorkerDependenciesKey.self] = .init(
            revokeApple: { _, _, _ in .revoked },
            deleteObject: { _, _ in XCTFail("A fenced photograph is never physically deleted") })

        let manifested = try await manifestKeys(lease)
        XCTAssertEqual(manifested, Set([allocation.key, rendition.key]),
                       "one asset, two addresses, two rows — the row and the intent agree on both strings")
        let candidates = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
        XCTAssertEqual(Set(candidates.map(\.key)), Set([allocation.key, rendition.key]))
        XCTAssertTrue(candidates.allSatisfy { $0.target == configuration.target })

        try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
        let state = try await AccountDeletionWorker.finish(lease, on: app.db)
        let puts = await storage.putCount()
        XCTAssertEqual(puts, 2, "one fence per address, and nothing else reached storage")
        XCTAssertEqual(state, "completed")
        let sql = try VerifiedIdentityService.sql(app.db)
        let pending = try await sql.raw("SELECT count(*) AS n FROM account_deletion_objects WHERE job_id=\(bind: lease.id) AND completed_at IS NULL").first()!
        XCTAssertEqual(try pending.decode(column: "n", as: Int.self), 0)
        let attested = try await sql.raw("""
            SELECT count(*) AS n FROM object_erasure_fence_attestations a
            JOIN object_erasure_fences f ON f.id=a.fence_id WHERE f.job_id=\(bind: lease.id)
            """).first()!
        XCTAssertEqual(try attested.decode(column: "n", as: Int.self), 2, "both addresses carry durable, verified evidence")
    }

    /// Matrix #39. A namespaced address is fenced or it is blocked; it is never
    /// physically deleted, and the physical-delete path is deliberately not taught
    /// its shape. The rule is the create-only exclusion in the delete branch. This
    /// is the backstop underneath the rule: if a namespaced key ever reached the
    /// branch with no recorded write at all, storage still refuses it by shape.
    func testANamespacedKeyIsRefusedByShapeAndIsNeverPhysicallyDeleted() async throws {
        try installedNamespace()
        let graph = try await personalGraph()
        let allocation = try PrivateObjectAllocationPolicy.allocateMedia(workspaceID: graph.workspaceID, projectID: graph.projectID, app: app)
        for kind in ["private_media", "private_drawing", "private_import", "legacy_photo", "legacy_drawing", "legacy_completion_photo"] {
            do {
                try await StorageService.deleteAccountObject(kind: kind, key: allocation.key, app: app)
                XCTFail("The physical-delete path must not accept a namespaced address under \(kind)")
            } catch { }
        }
        let lease = try await endAndLease(graph.userID)
        try await manifest(lease, key: allocation.key)
        let sql = try VerifiedIdentityService.sql(app.db)
        try await sql.raw("UPDATE account_deletion_jobs SET database_cleanup_state='completed' WHERE id=\(bind: lease.id)").run()
        // No injected double: the real path decides, which is the point of the case.
        app.storage[AccountDeletionWorkerDependenciesKey.self] = nil

        try await AccountDeletionWorker.perform(lease, app: app, on: app.db)
        let row = try await sql.raw("""
            SELECT completed_at,last_error_kind FROM account_deletion_objects
            WHERE job_id=\(bind: lease.id) AND object_key=\(bind: allocation.key)
            """).first()!
        XCTAssertNil(try row.decode(column: "completed_at", as: Date?.self) ?? nil)
        XCTAssertEqual(try row.decode(column: "last_error_kind", as: String?.self) ?? nil, "storage_unavailable",
                       "refused before any object could be removed, and recorded as a storage refusal")
    }

    /// Matrix #40, as amended. No writer outside the two private-media routes
    /// produces a fenceable key, and that is a property of what is recorded rather
    /// than of what the fence does.
    ///
    /// Every production call site that is not those two routes records an intent
    /// with no allocation, which is `legacy_unknown` with four null target columns,
    /// and the candidate query refuses such a key for every storage kind without
    /// touching storage. The other half of the same statement is that no other kind
    /// is placed in the namespace at all, so no other writer has a target it could
    /// record even if it wanted one.
    func testNoWriterOutsideThePrivateMediaRoutesProducesAFenceableKey() async throws {
        for kind in ["private_media", "private_drawing", "private_import", "legacy_photo", "legacy_drawing", "legacy_completion_photo"] {
            let id = try await user(), key = "uploads/\(kind)/\(UUID()).jpg"
            let write = try await intent(userID: id, key: key, kind: kind, target: nil)
            let lease = try await endAndLease(id)
            try await manifest(lease, kind: kind, key: key)
            let row = try await VerifiedIdentityService.sql(app.db).raw("""
                SELECT write_protocol,storage_backend,storage_backend_identity,storage_bucket,storage_namespace
                FROM object_write_intents WHERE id=\(bind: write)
                """).first()!
            XCTAssertEqual(try row.decode(column: "write_protocol", as: String.self), "legacy_unknown", kind)
            for column in ["storage_backend", "storage_backend_identity", "storage_bucket", "storage_namespace"] {
                XCTAssertNil(try row.decode(column: column, as: String?.self) ?? nil, "\(kind).\(column)")
            }
            let found = try await AccountDeletionObjectFenceService.candidates(lease, on: app.db, limit: 16)
            XCTAssertTrue(found.isEmpty, "\(kind): a writer with no recorded target produces nothing fenceable")
            if kind != "private_media" {
                XCTAssertEqual(try PrivateObjectAllocationPolicy.placement(ofKind: kind), .legacy,
                               "\(kind): nothing but private media is written into the namespace")
            }
        }
    }
}
