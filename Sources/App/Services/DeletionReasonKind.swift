import Foundation
import FluentSQL

/// Every reason an account deletion, or one object inside one, can be stopped
/// for — as one closed vocabulary instead of seventeen quoted strings spread
/// across four services.
///
/// **These are durable words, not labels.** `account_deletion_jobs.last_error_kind`
/// and `account_deletion_objects.last_error_kind` are columns. A row written
/// today is read weeks later by the operator runbook that decides whether a
/// blocked deletion needs a person, and by the next pass that has to recognise
/// its own earlier verdict. Renaming one is a breaking change to a written
/// procedure, not a tidy-up, so every raw value below is exactly the literal it
/// replaced and a test pins each one to its string.
///
/// **They are internal.** A deletion receipt carries a reference, a state and two
/// timestamps and nothing else (`AccountDeletionReceipt`); no reason kind has
/// ever reached a person and none may start to. That is precisely what lets these
/// words be about mechanism — `object_write_uncertain`, `fence_not_eligible` —
/// rather than about reassurance, and it is why collecting them changes no
/// user-facing shape.
///
/// **Why a type at all.** The set was already spread far enough that one branch
/// had been written twice inside a single `CASE`, where the second copy could
/// never be reached. A closed set is checkable — every value has one spelling,
/// one definition, and one place to look when a runbook asks what a row means.
enum DeletionReasonKind: String, Sendable, Equatable, CaseIterable {

    // MARK: - The pass itself could not finish

    /// The pass threw something that is not a scope refusal. It names no step
    /// deliberately: a provider's own error text can carry a key, a bucket or a
    /// credential, and none of those may reach a durable row. Retried on the
    /// backoff curve.
    case workerUnavailable = "worker_unavailable"

    /// Two accounts' writes are entangled: an intent this job must capture also
    /// names a workspace, a live project, a live import session or a live
    /// Contractor link outside this deletion's scope. The graph transaction
    /// refuses to capture a partial set, and it will refuse again on every pass —
    /// so this is a durable block with its own reason rather than an unavailable
    /// worker, which would hide the one condition that means a person must look.
    case objectWriteScopeAmbiguous = "object_write_scope_ambiguous"

    // MARK: - The database side has not finished

    /// The personal and import graph has not been erased yet. Every job is created
    /// in this state, before its first pass.
    case databaseErasurePending = "database_erasure_pending"

    /// An explicit company closure this deletion depends on is still running. The
    /// graph cannot be erased under it until the closure completes.
    case companyClosurePending = "company_closure_pending"

    // MARK: - Apple

    /// A stored Apple credential could not be decrypted or used, so the grant
    /// cannot be revoked. Durable: it will not resolve by waiting.
    case appleCredentialUnavailable = "apple_credential_unavailable"

    /// This deployment's Apple configuration cannot perform a revocation at all.
    case appleConfiguration = "apple_configuration"

    /// Apple answered, and not in a way that completes the revocation. Retried.
    case appleUnavailable = "apple_unavailable"

    // MARK: - Objects: the manifest has not finished

    /// Objects remain in the manifest and nothing above explains why. The ordinary
    /// "still working" reason.
    case objectCleanupPending = "object_cleanup_pending"

    /// A legacy completion photograph is named only by a URL, and this job cannot
    /// establish that the deleted account owns the object behind it. Durable
    /// evidence is retained instead of a manifest built from the URL alone.
    case unresolvedLegacyObjectOwnership = "unresolved_legacy_object_ownership"

    /// The graph still references this object from outside the deletion's scope,
    /// so it is not this job's to destroy. Written on the object row, and read
    /// back by the job's own `CASE` to decide that the job is blocked.
    case objectStillReferenced = "object_still_referenced"

    /// A captured write intent for one of this job's keys is still `active`: a
    /// writer may be in flight. Waiting is correct, and deleting would not be.
    case objectWritePending = "object_write_pending"

    /// A captured write intent is `uncertain` and no attested fence has resolved
    /// it. The bytes may or may not be at the address, so neither the delete
    /// branch nor completion may act.
    case objectWriteUncertain = "object_write_uncertain"

    /// A key that can be neither fenced nor deleted. Its captured intents
    /// disagree about the target, or one of them has no target, or the intent
    /// naming the address was never captured by this job — so the fence pass will
    /// never offer it and the delete branch will never touch it. Without this
    /// reason such a job returns to `ready` for ever and looks, to an operator,
    /// exactly like work that is merely slow.
    case objectTargetAmbiguous = "object_target_ambiguous"

    /// A physical delete was attempted and storage refused or did not answer. The
    /// storage error's own words are deliberately discarded.
    case storageUnavailable = "storage_unavailable"

    // MARK: - Objects: the fence pass refused one key

    /// The fence row exists and the database's own eligibility rule refuses it, so
    /// nothing was written to storage. Decided before any byte leaves the process.
    case fenceNotEligible = "fence_not_eligible"

    /// There is no fence store for this key's target — the namespace is not
    /// installed, or is installed and unusable, or the target is not this
    /// process's. A deployment fact, not a fact about the object.
    case fenceConfiguration = "fence_configuration"

    /// The fence store was reached and the fence did not complete. Retried.
    case fenceUnavailable = "fence_unavailable"
}

extension DeletionReasonKind {
    /// The kind as a SQL string literal, for the `CASE` expressions that decide a
    /// job's state inside one statement.
    ///
    /// A literal rather than a bind: these appear as `THEN` results and in
    /// comparisons where an untyped parameter has nothing to be inferred from, and
    /// the emitted text is byte-identical to the quoted literal it replaced —
    /// every raw value here is lowercase `[a-z_]` with nothing to escape.
    var sql: SQLQueryString { "\(literal: rawValue)" }
}
