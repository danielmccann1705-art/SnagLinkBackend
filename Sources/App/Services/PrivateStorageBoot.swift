import Vapor
import Logging

/// What a boot does with the two switches that decide whether private
/// photographs can be written and whether an account deletion can finish.
///
/// **Fail closed means fail here.** A build that contains the private-media write
/// path serves an upload only through the installed namespace: there is no
/// unconditional writer left to fall back to, because an object written by one
/// would be an object no deletion could ever make permanently unreadable. So a
/// production process without a namespace is not a process with a missing
/// feature — it is a process that will refuse every photograph, one 503 at a
/// time, while looking healthy. And an account deletion without a namespace
/// cannot fence, and a deletion that cannot fence cannot finish; it blocks, on a
/// backoff curve, indefinitely.
///
/// Both of those are configuration mistakes that are cheap to make and expensive
/// to notice. Each one is therefore decided once, at boot, where it stops the
/// process with a line an operator can act on — never at the first request,
/// quietly, as a status code that reads like weather.
///
/// **What a refusal may say.** The variable that is wrong and the state it was
/// found in. Never a value: not a bucket, not an account, not a namespace, not a
/// credential, not a length or a prefix of one. An operator reading this log must
/// learn what to fix; anyone else who ever reads it must learn nothing at all.
enum PrivateStorageBoot {

    /// The three answers `PrivateObjectAllocationPolicy.install` can give, without
    /// the configuration one of them carries. The configuration is deliberately
    /// dropped on the way in: nothing here can print what it does not hold.
    enum State: String, Sendable, Equatable, CaseIterable {
        /// `R2_PRIVATE_NAMESPACE` is set and everything behind it loaded.
        case installed
        /// `R2_PRIVATE_NAMESPACE` is not set. The switch is off.
        case absent
        /// `R2_PRIVATE_NAMESPACE` is set and what is behind it did not load.
        case unusable

        init(_ installation: PrivateObjectAllocationPolicy.Installation) {
            switch installation {
            case .installed: self = .installed
            case .absent: self = .absent
            case .unusable: self = .unusable
            }
        }
    }

    /// The three boot refusals. Each carries a stable code for a runbook to key
    /// on and a sentence for the person reading the log, and neither contains a
    /// value read from the environment.
    enum Refusal: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// `R2_PRIVATE_NAMESPACE` is set and the configuration behind it is not
        /// usable. Refusing to start is the whole point: allocation would refuse
        /// every private upload anyway, and the alternative — starting and
        /// discovering it per request — hides a typo behind a storage outage.
        case namespaceUnusable
        /// `ACCOUNT_DELETION_ENABLED` is on and no namespace is installed.
        case accountDeletionWithoutNamespace
        /// A production boot with the switch off. This build has no other writer
        /// for a private photograph, so an absent namespace in production is a
        /// forgotten activation step, not a deployment that does without one.
        case namespaceAbsentInProduction

        /// The stable identifier a runbook keys on. Not a sentence, and not
        /// rewritten when the sentence is.
        var code: String {
            switch self {
            case .namespaceUnusable: return "private_namespace_unusable"
            case .accountDeletionWithoutNamespace: return "account_deletion_without_private_namespace"
            case .namespaceAbsentInProduction: return "private_namespace_absent_in_production"
            }
        }

        var description: String {
            switch self {
            case .namespaceUnusable:
                return """
                    R2_PRIVATE_NAMESPACE is set and the private storage configuration behind it could not be loaded. \
                    Check R2_PRIVATE_NAMESPACE, R2_ACCOUNT_ID, R2_PRIVATE_BUCKET_NAME, R2_ACCESS_KEY_ID and \
                    R2_SECRET_ACCESS_KEY. The server refuses to start rather than accept photographs it could not \
                    later make unreadable.
                    """
            case .accountDeletionWithoutNamespace:
                return """
                    ACCOUNT_DELETION_ENABLED is on and R2_PRIVATE_NAMESPACE is not set. Account deletion makes a \
                    private object permanently unreadable by writing an erasure fence into that namespace, so a \
                    deletion without one can never finish. Set R2_PRIVATE_NAMESPACE, or turn \
                    ACCOUNT_DELETION_ENABLED off.
                    """
            case .namespaceAbsentInProduction:
                return """
                    R2_PRIVATE_NAMESPACE is not set and this is a production boot. This build writes a private \
                    photograph only into the private namespace; with none installed every upload would be refused \
                    one request at a time. Set R2_PRIVATE_NAMESPACE.
                    """
            }
        }
        var errorDescription: String? { description }
    }

    /// Resolves both switches and either records what was found or stops the
    /// boot. The one call `configure` makes; the lookup is injectable so the
    /// refusals can be tested without a process environment.
    @discardableResult
    static func install(app: Application, lookup: (String) -> String? = Environment.get) throws -> State {
        let state = State(PrivateObjectAllocationPolicy.install(app: app, lookup: lookup))
        try verify(state: state, environment: app.environment,
                   accountDeletionEnabled: AccountDeletionService.isEnabledByConfiguration(lookup: lookup),
                   logger: app.logger)
        return state
    }

    /// The decision itself, over the two facts it needs and nothing else.
    ///
    /// Order matters once: an unusable namespace is reported as an unusable
    /// namespace even when the deletion switch is also on, because the namespace
    /// is the thing to fix and the deletion switch is downstream of it.
    static func verify(state: State, environment: Environment,
                       accountDeletionEnabled: Bool, logger: Logger) throws {
        switch state {
        case .unusable:
            throw refuse(.namespaceUnusable, logger: logger)
        case .absent:
            if accountDeletionEnabled { throw refuse(.accountDeletionWithoutNamespace, logger: logger) }
            if environment == .production { throw refuse(.namespaceAbsentInProduction, logger: logger) }
            // Development and testing run without private storage on purpose: a
            // developer has no bucket and a test injects its own store. Recorded,
            // because "uploads do not work here" should be readable in the log
            // rather than deduced from a 503.
            logger.info("Private object namespace is not installed",
                        metadata: ["state": .string(state.rawValue)])
        case .installed:
            logger.info("Private object namespace is installed",
                        metadata: ["state": .string(state.rawValue)])
        }
        logger.info("Account deletion switch read",
                    metadata: ["state": .string(accountDeletionEnabled ? "enabled" : "disabled")])
    }

    /// Logged before it is thrown, at `critical`, so the reason survives whatever
    /// the caller does with the error.
    private static func refuse(_ refusal: Refusal, logger: Logger) -> Refusal {
        logger.critical("Boot refused: \(refusal.description)", metadata: ["refusal": .string(refusal.code)])
        return refusal
    }
}
