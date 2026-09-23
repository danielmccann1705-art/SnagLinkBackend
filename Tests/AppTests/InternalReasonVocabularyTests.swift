import XCTVapor
import FluentSQL
@testable import App

/// A6. The two fixed internal vocabularies, pinned to the exact strings they
/// replaced.
///
/// `last_error_kind` is a durable column, read by an operator runbook weeks after
/// the pass that wrote it and by the next pass that has to recognise its own
/// earlier verdict. A renamed reason is a breaking change to a written procedure,
/// not a tidy-up — so every case is written out here by hand. A test that derived
/// the expected strings from the enum would pass whatever the enum said, which is
/// the one thing this must not do.
final class InternalReasonVocabularyTests: XCTestCase {

    /// Every durable reason, spelled out. The seventeen literals that stood in
    /// `AccountDeletionWorker`, `AccountDeletionGraphService`,
    /// `AccountDeletionObjectFenceService` and `AccountDeletionService` before
    /// they were collected, and the three the RevenueCat deletion step added.
    private let deletionReasons: [DeletionReasonKind: String] = [
        .workerUnavailable: "worker_unavailable",
        .objectWriteScopeAmbiguous: "object_write_scope_ambiguous",
        .databaseErasurePending: "database_erasure_pending",
        .companyClosurePending: "company_closure_pending",
        .appleCredentialUnavailable: "apple_credential_unavailable",
        .appleConfiguration: "apple_configuration",
        .appleUnavailable: "apple_unavailable",
        .objectCleanupPending: "object_cleanup_pending",
        .unresolvedLegacyObjectOwnership: "unresolved_legacy_object_ownership",
        .objectStillReferenced: "object_still_referenced",
        .objectWritePending: "object_write_pending",
        .objectWriteUncertain: "object_write_uncertain",
        .objectTargetAmbiguous: "object_target_ambiguous",
        .storageUnavailable: "storage_unavailable",
        .fenceNotEligible: "fence_not_eligible",
        .fenceConfiguration: "fence_configuration",
        .fenceUnavailable: "fence_unavailable",
        .revenueCatConfiguration: "revenuecat_configuration",
        .revenueCatUnavailable: "revenuecat_unavailable",
        .revenueCatPending: "revenuecat_pending",
    ]

    /// B2's four write kinds and B3's read kind, as one set.
    private let logKinds: [PrivateMediaLogKind: String] = [
        .absent: "absent",
        .existsThenAbsent: "exists_then_absent",
        .readbackUnavailable: "readback_unavailable",
        .notLanded: "not_landed",
        .storageUnreachable: "storage_unreachable",
    ]

    func testEveryDeletionReasonKeepsTheExactStringItReplaced() {
        for (kind, spelling) in deletionReasons { XCTAssertEqual(kind.rawValue, spelling) }
        XCTAssertEqual(deletionReasons.count, DeletionReasonKind.allCases.count,
                       "a reason was added or removed without being written down here")
        XCTAssertEqual(Set(DeletionReasonKind.allCases.map(\.rawValue)).count, DeletionReasonKind.allCases.count,
                       "one spelling per reason")
    }

    func testEveryPrivateMediaLogKindKeepsTheExactStringItReplaced() {
        for (kind, spelling) in logKinds { XCTAssertEqual(kind.rawValue, spelling) }
        XCTAssertEqual(logKinds.count, PrivateMediaLogKind.allCases.count)
        XCTAssertEqual(Set(PrivateMediaLogKind.allCases.map(\.rawValue)).count, PrivateMediaLogKind.allCases.count)
    }

    /// One vocabulary, two names. The read path and the write path do not keep
    /// separate lists that can drift apart.
    func testTheReadAndWriteServicesShareOneLogVocabulary() {
        XCTAssertTrue(PrivateMediaWriteService.LogKind.self == PrivateMediaLogKind.self)
        XCTAssertTrue(PrivateMediaReadService.LogKind.self == PrivateMediaLogKind.self)
    }

    /// The two vocabularies answer different questions and are kept apart: a log
    /// kind is a line an operator reads once, a reason kind is a row that
    /// survives the process that wrote it.
    func testTheTwoVocabulariesDoNotOverlap() {
        let reasons = Set(DeletionReasonKind.allCases.map(\.rawValue))
        let logs = Set(PrivateMediaLogKind.allCases.map(\.rawValue))
        XCTAssertTrue(reasons.isDisjoint(with: logs), "\(reasons.intersection(logs))")
    }

    /// And the one thing the enum is worth nothing without: the SQL each case
    /// produces is byte-for-byte the literal it replaced. PostgreSQL is asked
    /// directly, because a reason that changed spelling on the way into a `CASE`
    /// would be invisible everywhere else.
    func testEveryReasonsSQLLiteralIsExactlyItsDurableString() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Isolated synthetic PostgreSQL required")
        let app = try await Application.make(.testing)
        try await configure(app)
        let sql = try VerifiedIdentityService.sql(app.db)
        for kind in DeletionReasonKind.allCases {
            let row = try await sql.raw("SELECT (\(kind.sql))::TEXT AS value").first()
            XCTAssertEqual(try row?.decode(column: "value", as: String.self), kind.rawValue, kind.rawValue)
        }
        try await app.asyncShutdown()
    }
}
