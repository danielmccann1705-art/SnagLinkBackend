import Vapor
import JWT
import Logging

/// What a boot does with the secret every session it issues is signed with.
///
/// **A sibling of `PrivateStorageBoot`, not a fourth case inside it.** The shape
/// is deliberately identical — an error with a stable `code` for a runbook and a
/// sentence for the person reading the log, logged at `critical` before it is
/// thrown, and thrown so that `Entrypoint`'s catch shuts the application down and
/// exits non-zero. Only the subject differs, and it differs enough to keep apart:
/// `PrivateStorageBoot.Refusal` is documented as the refusals of the two private
/// storage switches, every one of its cases names `R2_PRIVATE_NAMESPACE`, and a
/// pre-existing test asserts exactly that of every refusal in it. A signing
/// secret has nothing to do with private object allocation, and filing it there
/// would have made that test's name false without making the test fail.
///
/// **What a refusal may say.** The variable that is missing. Never its value, and
/// never a length, a prefix or a hash of one — this is the secret that signs
/// every session in the system, and a log line is the last place it may appear.
/// There is exactly one thing an operator needs from this log and it is the name
/// `JWT_SECRET`.
///
/// This used to be a `guard` in `configure` with two defects, the same two the
/// private storage gate had. It stood after `autoMigrate()`, so a production boot
/// with no signing secret applied every pending migration to the live database
/// and only then refused. And it refused with `fatalError`, which traps rather
/// than exits — and, because `fatalError` never returns, the `exit(1)` in
/// `Entrypoint`'s catch was never reached at all. A deployment that was never
/// allowed to serve a request changed the schema and then stayed up.
enum SigningSecretBoot {

    /// The one refusal. An enum with a single case rather than a bare error, so
    /// that it carries a code and reads like its sibling, and so a second one can
    /// be added beside it without changing how any of this is thrown or caught.
    enum Refusal: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// `JWT_SECRET` is not set.
        case jwtSecretAbsent

        /// The stable identifier a runbook keys on. Not a sentence, and not
        /// rewritten when the sentence is.
        var code: String {
            switch self {
            case .jwtSecretAbsent: return "jwt_secret_absent"
            }
        }

        var description: String {
            switch self {
            case .jwtSecretAbsent:
                return """
                    JWT_SECRET is not set. Every session this process would issue and every session it would \
                    accept is signed with it, so a boot without one cannot tell its own tokens from anybody \
                    else's. Set JWT_SECRET. The server refuses to start rather than run unable to authenticate \
                    a single request.
                    """
            }
        }
        var errorDescription: String? { description }
    }

    /// Reads the secret and either installs the signer or stops the boot.
    ///
    /// The one call `configure` makes, and it makes it before it touches the
    /// database. The lookup is injectable for the same single reason
    /// `privateStorageLookup` is: a test has to be able to drive this into a
    /// refusal, and then check that no migration followed, without unsetting a
    /// process environment variable the rest of the suite depends on.
    ///
    /// The predicate is the one the `guard` in `configure` used, unchanged: set
    /// is set. An empty `JWT_SECRET` was accepted before this moved and is
    /// accepted after it, because tightening what is refused is a different
    /// decision from fixing how a refusal ends.
    static func install(app: Application, lookup: (String) -> String? = Environment.get) throws {
        guard let secret = lookup("JWT_SECRET") else {
            throw refuse(.jwtSecretAbsent, logger: app.logger)
        }
        app.jwt.signers.use(.hs256(key: secret))
    }

    /// Logged before it is thrown, at `critical`, so the reason survives whatever
    /// the caller does with the error. The same line shape, level and metadata
    /// key as `PrivateStorageBoot.refuse`, so one runbook reads both.
    private static func refuse(_ refusal: Refusal, logger: Logger) -> Refusal {
        logger.critical("Boot refused: \(refusal.description)", metadata: ["refusal": .string(refusal.code)])
        return refusal
    }
}
