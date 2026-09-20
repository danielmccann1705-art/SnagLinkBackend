import Vapor
import Fluent
import FluentSQL

struct VerifiedIdentityService {
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
        let email = EmailValidator.normalize(value)
        try await lock("identity-email:" + email, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)").first() {
            return try await activeUser(row.decode(column: "user_id", as: UUID.self), on: db)
        }
        let legacy = try await sql(db).raw("SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email) LIMIT 1").first()
        guard legacy == nil else {
            throw Abort(.conflict, reason: "This email already belongs to a Snaglist account. Sign in the way you first did — with Apple, with Google, or with a link to the address shown in the app's Settings. An existing account cannot be claimed by email alone", identifier: "identity_proof_required")
        }
        let user = User(appleUserId: nil, email: email, name: name, authProvider: .magicLink)
        try await user.save(on: db)
        try await addIdentity(provider: "email", subject: email, userID: user.requireID(), on: db)
        return user
    }

    /// Apple subject is supplied only by the verified Apple JWT handler. Never
    /// merge by Apple display name, relay address or client-provided email.
    static func resolveApple(subject: String, email: String?, name: String?, on db: Database) async throws -> User {
        try await lock("identity-apple:" + subject, on: db)
        if let row = try await sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'apple' AND subject = \(bind: subject)").first() {
            return try await activeUser(row.decode(column: "user_id", as: UUID.self), on: db)
        }
        let user: User
        if let existing = try await User.query(on: db).filter(\.$appleUserId == subject).first() {
            user = try await activeUser(existing.requireID(), on: db)
        } else {
            user = User(appleUserId: subject, email: email, name: name)
            try await user.save(on: db)
        }
        try await addIdentity(provider: "apple", subject: subject, userID: user.requireID(), on: db)
        return user
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

    private static func addIdentity(provider: String, subject: String, userID: UUID, on db: Database) async throws {
        try await sql(db).raw("INSERT INTO user_identities (id, user_id, provider, subject, verified_at) VALUES (\(bind: UUID()), \(bind: userID), \(bind: provider), \(bind: subject), \(bind: Date()))").run()
    }
}
