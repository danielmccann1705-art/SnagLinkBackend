import Vapor
import Fluent
import FluentSQL

struct VerifiedIdentityService {
    /// Authority comes from the branch that inserted the account, never timestamps.
    /// Use only the result returned by a successfully committed identity transaction.
    struct Resolution: Sendable {
        let user: User
        let insertedNewAccount: Bool
    }

    static func sql(_ db: Database) throws -> SQLDatabase {
        guard let sql = db as? SQLDatabase else { throw Abort(.serviceUnavailable) }
        return sql
    }

    static func lock(_ key: String, on db: Database) async throws {
        try await sql(db).raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    static func activeUser(_ id: UUID, on db: Database) async throws -> User {
        guard let user = try await User.find(id, on: db), user.lifecycleState == "active" else {
            throw Abort(.unauthorized, reason: "Account is no longer available")
        }
        return user
    }

    /// Called only after a one-use email challenge proves control, inside the
    /// challenge transaction. A mutable legacy profile is not an identity claim.
    static func resolveEmail(_ value: String, name: String?, on db: Database) async throws -> User {
        try await resolveEmailOutcome(value, name: name, on: db).user
    }

    static func resolveEmailOutcome(_ value: String, name: String?, on db: Database) async throws -> Resolution {
        let email = EmailValidator.normalize(value)
        try await lock("identity-email:" + email, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)").first() {
            return .init(user: try await activeUser(row.decode(column: "user_id", as: UUID.self), on: db), insertedNewAccount: false)
        }
        let legacy = try await sql(db).raw("SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) LIMIT 1").first()
        guard legacy == nil else {
            throw Abort(.conflict, reason: "This email already belongs to a Snaglist account. Sign in the way you first did — with Apple, with Google, or with a link to the address shown in the app's Settings. An existing account cannot be claimed by email alone", identifier: "identity_proof_required")
        }
        let user = User(appleUserId: nil, email: email, name: name, authProvider: .magicLink)
        try await user.save(on: db)
        try await addIdentity(provider: "email", subject: email, userID: user.requireID(), on: db)
        return .init(user: user, insertedNewAccount: true)
    }

    /// Apple subject is supplied only by the verified Apple JWT handler. Never
    /// merge by Apple display name, relay address or client-provided email.
    ///
    /// Native and web Apple both come through here (audit F21), so a first sign-in whose
    /// address already belongs to another account gets the same refusal on both.
    /// Concurrency does not rest on the checks alone: the account, its Apple identity
    /// and (when Apple verified it) its email identity are written in the caller's one
    /// transaction, and `users.apple_user_id` and `user_identities (provider, subject)`
    /// are unique. A racing twin that got past a check fails on those constraints, its
    /// whole transaction rolls back (no orphan identity row survives), and
    /// `transactionRetryingIdentityRace` runs it once more against the winner's rows.
    static func resolveApple(subject: String, email: String?, emailVerified: Bool = false, name: String?, on db: Database) async throws -> User {
        try await resolveAppleOutcome(subject: subject, email: email, emailVerified: emailVerified, name: name, on: db).user
    }

    static func resolveAppleOutcome(subject: String, email: String?, emailVerified: Bool = false, name: String?, on db: Database) async throws -> Resolution {
        try await lock("identity-apple:" + subject, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'apple' AND subject = \(bind: subject)").first() {
            return .init(user: try await activeUser(row.decode(column: "user_id", as: UUID.self), on: db), insertedNewAccount: false)
        }
        if let existing = try await User.query(on: db).filter(\.$appleUserId == subject).first() {
            let user = try await activeUser(existing.requireID(), on: db)
            try await addIdentity(provider: "apple", subject: subject, userID: user.requireID(), on: db)
            return .init(user: user, insertedNewAccount: false)
        }
        let address = email.map(EmailValidator.normalize).flatMap { $0.isEmpty ? nil : $0 }
        try await refuseAddressHeldElsewhere(address, verified: emailVerified, on: db)
        let user = User(appleUserId: subject, email: email, name: name)
        try await user.save(on: db)
        let userID = try user.requireID()
        try await addIdentity(provider: "apple", subject: subject, userID: userID, on: db)
        // A verified address is claimed in the same transaction. The unique identity row is
        // the arbiter: if another account claimed it after the check above, nothing of this
        // account survives the refusal.
        if emailVerified, let address, EmailValidator.isValidFormat(address), address.count <= 254 {
            guard try await claimIdentity(provider: "email", subject: address, userID: userID, on: db) else {
                throw ExistingAccountRecovery.refusal(try await ExistingAccountRecovery.methods(holding: address, excluding: userID, on: db))
            }
        }
        return .init(user: user, insertedNewAccount: true)
    }

    /// First sign-in for an Apple subject (audit F21, D1 §7 "F2"): an address that
    /// already belongs to another account — a verified email identity or a legacy
    /// profile email — is refused before anything is created, so native and web Apple
    /// follow the same rule as email links and Google. Nothing is merged: the person
    /// signs in the way the existing account does, which the refusal names when the
    /// provider verified the address. A Hide My Email relay address is an address like
    /// any other. Deleted accounts hold no email, so they never block. A known subject
    /// never reaches this check, and a sign-in without an email creates the account.
    static func refuseAddressHeldElsewhere(_ value: String?, verified: Bool = false, on db: Database) async throws {
        guard let value else { return }
        let email = EmailValidator.normalize(value)
        guard !email.isEmpty else { return }
        try await lock("identity-email:" + email, on: db)
        let held = try await sql(db).raw("""
            SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email)
            UNION SELECT user_id AS id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)
            LIMIT 1
            """).first()
        guard held == nil else {
            throw ExistingAccountRecovery.refusal(verified ? try await ExistingAccountRecovery.methods(holding: email, on: db) : [])
        }
    }

    /// Runs an identity-creating transaction. When a concurrent sign-in won a race that
    /// only the database's unique constraints caught, the losing transaction has already
    /// rolled back whole; the one retry sees the winner's committed rows and signs in to
    /// that account or refuses, instead of surfacing a 500.
    static func transactionRetryingIdentityRace<T: Sendable>(on db: Database, _ body: @escaping @Sendable (any Database) async throws -> T) async throws -> T {
        do {
            return try await db.transaction(body)
        } catch let error as DatabaseError where error.isConstraintFailure {
            return try await db.transaction(body)
        }
    }

    /// Requires both authenticated account control and a challenge sent to the
    /// exact address. A verified identity owned elsewhere is never transferred.
    static func linkEmail(_ value: String, to userID: UUID, on db: Database) async throws {
        let email = EmailValidator.normalize(value)
        try await lock("identity-email:" + email, on: db)
        _ = try await activeUser(userID, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)").first() {
            guard try row.decode(column: "user_id", as: UUID.self) == userID else {
                throw Abort(.conflict, reason: "This verified email belongs to another account. Sign in to that account or request account recovery", identifier: "identity_already_linked")
            }
            return
        }
        // Competing legacy claims must be reconciled, not silently overridden.
        guard try await sql(db).raw("SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) AND id <> \(bind: userID) LIMIT 1").first() == nil else {
            throw Abort(.conflict, reason: "This address has an existing account claim that needs recovery", identifier: "identity_proof_required")
        }
        try await addIdentity(provider: "email", subject: email, userID: userID, on: db)
    }

    /// Adopts an address the identity provider has itself verified. Proof of the
    /// address is not proof of control of an account that already holds it, so an
    /// address claimed elsewhere is left exactly as it is and this reports false
    /// instead of throwing: a sign-in must not fail because someone else got there
    /// first.
    @discardableResult
    static func adoptProviderVerifiedEmail(_ value: String, to userID: UUID, on db: Database) async throws -> Bool {
        let email = EmailValidator.normalize(value)
        guard EmailValidator.isValidFormat(email), email.count <= 254 else { return false }
        try await lock("identity-email:" + email, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)").first() {
            return try row.decode(column: "user_id", as: UUID.self) == userID
        }
        guard try await sql(db).raw("SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) AND id <> \(bind: userID) LIMIT 1").first() == nil else { return false }
        try await addIdentity(provider: "email", subject: email, userID: userID, on: db)
        return true
    }

    static func verifiedEmails(for userID: UUID, on db: Database) async throws -> [String] {
        try await sql(db).raw("SELECT subject FROM user_identities WHERE user_id = \(bind: userID) AND provider = 'email' ORDER BY subject")
            .all().map { try $0.decode(column: "subject", as: String.self) }
    }

    /// Inserts the identity unless `(provider, subject)` is already taken; reports which.
    static func claimIdentity(provider: String, subject: String, userID: UUID, on db: Database) async throws -> Bool {
        try await sql(db).raw("""
            INSERT INTO user_identities (id, user_id, provider, subject, verified_at)
            VALUES (\(bind: UUID()), \(bind: userID), \(bind: provider), \(bind: subject), \(bind: Date()))
            ON CONFLICT (provider, subject) DO NOTHING RETURNING id
            """).first() != nil
    }

    private static func addIdentity(provider: String, subject: String, userID: UUID, on db: Database) async throws {
        try await sql(db).raw("INSERT INTO user_identities (id, user_id, provider, subject, verified_at) VALUES (\(bind: UUID()), \(bind: userID), \(bind: provider), \(bind: subject), \(bind: Date()))").run()
    }
}
