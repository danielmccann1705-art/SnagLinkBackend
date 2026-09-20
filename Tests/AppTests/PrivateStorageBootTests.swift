import XCTVapor
@testable import App

/// D1. The switch, and what a boot does when it is wrong.
///
/// Every case here drives the exact call `configure` makes —
/// `PrivateStorageBoot.install` — with an injected lookup instead of a process
/// environment, so the refusals are tested where they actually happen rather
/// than in a copy of the rule.
///
/// Nothing in this file turns anything on. The values below are synthetic, they
/// are handed to one function inside one test process, and no environment
/// variable is set anywhere.
final class PrivateStorageBootTests: XCTestCase {

    /// A complete, entirely synthetic private-storage configuration. Shaped to
    /// pass every particular the loader checks and to name nothing real.
    private var complete: [String: String] { [
        "R2_PRIVATE_NAMESPACE": "private-v1/",
        "R2_ACCOUNT_ID": String(repeating: "a", count: 32),
        "R2_PRIVATE_BUCKET_NAME": "synthetic-private",
        "R2_BUCKET_NAME": "synthetic-public",
        "R2_ACCESS_KEY_ID": "synthetic-key",
        "R2_SECRET_ACCESS_KEY": "synthetic-secret",
    ] }

    private let environments: [Environment] = [.production, .development, .testing]

    /// Boots one throwaway application against one lookup and returns what the
    /// boot refused with, or nil when it was accepted.
    private func boot(_ environment: Environment, _ values: [String: String]) async throws -> (any Error)? {
        let app = try await Application.make(environment)
        var refusal: (any Error)?
        do { try PrivateStorageBoot.install(app: app, lookup: { values[$0] }) }
        catch { refusal = error }
        try await app.asyncShutdown()
        return refusal
    }

    private func refusal(_ error: (any Error)?) -> PrivateStorageBoot.Refusal? { error as? PrivateStorageBoot.Refusal }

    // MARK: - accepted boots

    /// The gate D1 lifted, from the other side: a namespace that is configured
    /// installs in every environment, so activation is one act by one person and
    /// not a code change that has to accompany it.
    func testACompleteNamespaceBootsInEveryEnvironment() async throws {
        for environment in environments {
            let outcome = try await boot(environment, complete)
            XCTAssertNil(outcome, "a complete configuration is not a boot refusal in \(environment.name)")
        }
    }

    /// Development and testing run without private storage on purpose: a
    /// developer has no bucket and a test injects its own store.
    func testAnAbsentNamespaceIsAcceptedOutsideProduction() async throws {
        var off = complete
        off["R2_PRIVATE_NAMESPACE"] = nil
        for environment in [Environment.development, .testing] {
            let outcome = try await boot(environment, off)
            XCTAssertNil(outcome, environment.name)
        }
    }

    // MARK: - refusal 1: the namespace is set and unusable

    /// The switch is on and something behind it is wrong. Every particular the
    /// loader refuses is one boot refusal, in every environment — including
    /// testing, because a half-configured switch is a mistake wherever it is
    /// made, and allocation would refuse every upload anyway.
    func testANamespaceThatIsSetAndUnusableRefusesTheBootInEveryEnvironment() async throws {
        var missingAccount = complete; missingAccount["R2_ACCOUNT_ID"] = nil
        var notAPrefix = complete; notAPrefix["R2_PRIVATE_NAMESPACE"] = "not-a-prefix"
        var reserved = complete; reserved["R2_PRIVATE_NAMESPACE"] = "uploads/"
        var publicBucket = complete; publicBucket["R2_PRIVATE_BUCKET_NAME"] = complete["R2_BUCKET_NAME"]
        var noCredential = complete; noCredential["R2_SECRET_ACCESS_KEY"] = ""
        for (label, values) in [("no account", missingAccount), ("namespace is not a prefix", notAPrefix),
                                ("namespace is a legacy family", reserved),
                                ("the private bucket is the public one", publicBucket),
                                ("no credential", noCredential)] {
            for environment in environments {
                let outcome = refusal(try await boot(environment, values))
                XCTAssertEqual(outcome, .namespaceUnusable, "\(label) in \(environment.name)")
            }
        }
    }

    /// An unusable namespace is reported as an unusable namespace even when the
    /// deletion switch is also on: the namespace is the thing to fix, and the
    /// deletion switch is downstream of it.
    func testAnUnusableNamespaceIsNamedAheadOfTheDeletionSwitch() async throws {
        var both = complete
        both["R2_PRIVATE_NAMESPACE"] = "not-a-prefix"
        both["ACCOUNT_DELETION_ENABLED"] = "true"
        let outcome = refusal(try await boot(.production, both))
        XCTAssertEqual(outcome, .namespaceUnusable)
    }

    // MARK: - refusal 2: deletion is on with nothing to fence into

    /// A deletion makes a private object permanently unreadable by writing an
    /// erasure fence into the namespace. With no namespace it cannot fence, and a
    /// deletion that cannot fence never finishes — it blocks on a backoff curve
    /// indefinitely, which looks from outside exactly like work that is slow.
    func testAccountDeletionWithoutANamespaceRefusesTheBootInEveryEnvironment() async throws {
        var enabled = complete
        enabled["R2_PRIVATE_NAMESPACE"] = nil
        enabled["ACCOUNT_DELETION_ENABLED"] = "true"
        for environment in environments {
            let outcome = refusal(try await boot(environment, enabled))
            XCTAssertEqual(outcome, .accountDeletionWithoutNamespace, environment.name)
        }
    }

    /// And beside an installed namespace the same switch boots. Nothing here sets
    /// it; this is the shape of the day somebody does.
    func testAccountDeletionBootsBesideAnInstalledNamespace() async throws {
        var enabled = complete
        enabled["ACCOUNT_DELETION_ENABLED"] = "true"
        for environment in environments {
            let outcome = try await boot(environment, enabled)
            XCTAssertNil(outcome, environment.name)
        }
    }

    /// Only the exact literal turns it on, so a boot cannot be refused — or a
    /// deletion enabled — by a spelling nobody meant.
    func testAnythingButTheExactLiteralLeavesDeletionOff() async throws {
        var off = complete
        off["R2_PRIVATE_NAMESPACE"] = nil
        for spelling in ["TRUE", "True", "1", "yes", "false", ""] {
            var values = off; values["ACCOUNT_DELETION_ENABLED"] = spelling
            let outcome = try await boot(.development, values)
            XCTAssertNil(outcome, spelling)
            XCTAssertFalse(AccountDeletionService.isEnabledByConfiguration(lookup: { _ in spelling }), spelling)
        }
        XCTAssertTrue(AccountDeletionService.isEnabledByConfiguration(lookup: { _ in "true" }))
        XCTAssertFalse(AccountDeletionService.isEnabledByConfiguration(lookup: { _ in nil }))
    }

    /// The deployed switch is the only way in outside `.testing`, and the test
    /// activation is still the only way in under it. Neither has learned to
    /// stand in for the other.
    func testTheDeployedSwitchAndTheTestActivationStayTwoDifferentThings() async throws {
        let deployed = try await Application.make(.development)
        deployed.storage[AccountDeletionTestActivation.self] = true
        XCTAssertThrowsError(try AccountDeletionService.requireAvailable(deployed, lookup: { _ in nil }),
                             "a test activation is not a deployment fact")
        XCTAssertNoThrow(try AccountDeletionService.requireAvailable(deployed, lookup: { _ in "true" }))
        try await deployed.asyncShutdown()

        let testing = try await Application.make(.testing)
        XCTAssertThrowsError(try AccountDeletionService.requireAvailable(testing, lookup: { _ in nil }),
                             "an unactivated test process is still refused")
        testing.storage[AccountDeletionTestActivation.self] = true
        XCTAssertNoThrow(try AccountDeletionService.requireAvailable(testing, lookup: { _ in nil }))
        try await testing.asyncShutdown()
    }

    // MARK: - refusal 3: production without a namespace

    /// This build writes a private photograph only into the namespace. A
    /// production process without one refuses every upload, one request at a
    /// time, while looking healthy — so it is refused at boot instead, which is
    /// what makes the activation step impossible to forget silently.
    func testAProductionBootWithoutANamespaceIsRefused() async throws {
        var off = complete
        off["R2_PRIVATE_NAMESPACE"] = nil
        let production = refusal(try await boot(.production, off))
        XCTAssertEqual(production, .namespaceAbsentInProduction)
        let development = try await boot(.development, off)
        XCTAssertNil(development)
        let testing = try await boot(.testing, off)
        XCTAssertNil(testing)
    }

    // MARK: - what a refusal may say

    /// An operator reading the log must learn what to fix. Anyone else who ever
    /// reads it must learn nothing at all — not a bucket, not an account, not a
    /// namespace, not a credential.
    func testEveryRefusalNamesItsVariablesAndCarriesNoValue() {
        let refusals: [PrivateStorageBoot.Refusal] = [.namespaceUnusable, .accountDeletionWithoutNamespace,
                                                      .namespaceAbsentInProduction]
        let values = complete.values.sorted()
        for refusal in refusals {
            XCTAssertTrue(refusal.description.contains("R2_PRIVATE_NAMESPACE"), refusal.code)
            for value in values {
                XCTAssertFalse(refusal.description.contains(value), "\(refusal.code) must not print a configured value")
                XCTAssertFalse(refusal.code.contains(value), refusal.code)
            }
            XCTAssertEqual(refusal.errorDescription, refusal.description)
        }
        XCTAssertTrue(PrivateStorageBoot.Refusal.namespaceUnusable.description.contains("R2_ACCESS_KEY_ID"),
                      "the unusable case names every variable it could be")
        XCTAssertTrue(PrivateStorageBoot.Refusal.accountDeletionWithoutNamespace.description
                        .contains("ACCOUNT_DELETION_ENABLED"))
        XCTAssertEqual(Set(refusals.map(\.code)).count, refusals.count, "one code per refusal")
    }

    /// The three states are read off the installation and nothing else is carried
    /// out of it: there is no configuration in hand here to print by accident.
    func testTheBootStateIsTheInstallationWithItsConfigurationDropped() throws {
        XCTAssertEqual(PrivateStorageBoot.State(.absent), .absent)
        XCTAssertEqual(PrivateStorageBoot.State(.unusable), .unusable)
        let configuration = try TestPrivateContentStore.syntheticConfiguration()
        XCTAssertEqual(PrivateStorageBoot.State(.installed(configuration)), .installed)
        XCTAssertEqual(Set(PrivateStorageBoot.State.allCases.map(\.rawValue)), ["installed", "absent", "unusable"])
    }
}
