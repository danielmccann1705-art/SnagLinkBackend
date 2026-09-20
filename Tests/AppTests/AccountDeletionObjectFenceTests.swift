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
    @discardableResult
    private func intent(userID: UUID, key: String, kind: String = "private_media",
                        target: ObjectStorageWriteTarget?) async throws -> UUID {
        try await app.db.transaction { db in
            try await ObjectWriteIntentService.begin(
                .init(storageKind: kind, key: key, data: Data("synthetic".utf8), contentType: "image/jpeg"),
                source: .init(kind: "media_asset", id: UUID()), scope: .init(userID: userID), target: target, on: db).id
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
}
