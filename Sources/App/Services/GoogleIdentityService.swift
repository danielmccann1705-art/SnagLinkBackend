import Vapor
import Fluent
import FluentSQL

struct GoogleIdentityService {
    /// Must be called inside the one-use challenge transaction after signature,
    /// audience, presenter and nonce verification. Never trusts a client email.
    static func resolve(_ proof: GoogleIdentityProof, on db: Database) async throws -> User {
        let contactEmail = proof.contactEmail.map(EmailValidator.normalize)
        try await VerifiedIdentityService.lock("identity-google:" + proof.subject, on: db)
        if let existing = try await identityOwner(proof.subject, on: db) {
            let user = try await VerifiedIdentityService.activeUser(existing, on: db)
            try await adoptVerifiedEmail(proof, for: user, on: db)
            return user
        }
        // A matching contact hint is not account-control evidence. Keep the
        // existing recovery/linking route instead of moving data or purchases.
        if let email = contactEmail {
            try await VerifiedIdentityService.lock("identity-email:" + email, on: db)
            let claimed = try await VerifiedIdentityService.sql(db).raw("""
                SELECT id FROM users WHERE lower(btrim(email)) = \(bind: email)
                UNION SELECT user_id AS id FROM user_identities WHERE provider = 'email' AND subject = \(bind: email)
                LIMIT 1
                """).first()
            guard claimed == nil else {
                throw Abort(.conflict, reason: "Sign in with your existing Snaglist account, then connect Google in Account settings", identifier: "identity_proof_required")
            }
        }
        let user = User(appleUserId: nil, email: contactEmail, name: proof.displayName, authProvider: .google)
        try await user.save(on: db)
        try await insert(proof.subject, for: user.requireID(), on: db)
        try await adoptVerifiedEmail(proof, for: user, on: db)
        return user
    }

    /// An address Google says it has verified is proof of that address, so a person
    /// invited at it can accept without a second round trip by email. It is still
    /// not account-control evidence: the subject above chose the account, and an
    /// address another account already holds is left where it is.
    private static func adoptVerifiedEmail(_ proof: GoogleIdentityProof, for user: User, on db: Database) async throws {
        guard proof.contactEmailIsVerified, let email = proof.contactEmail else { return }
        try await VerifiedIdentityService.adoptProviderVerifiedEmail(email, to: user.requireID(), on: db)
    }

    /// Both identities must be proven by the caller's account-bound challenge.
    /// A previously linked Google identity can never be transferred by this path.
    static func link(_ proof: GoogleIdentityProof, to userID: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.lock("identity-google:" + proof.subject, on: db)
        _ = try await VerifiedIdentityService.activeUser(userID, on: db)
        if let existing = try await identityOwner(proof.subject, on: db) {
            guard existing == userID else {
                throw Abort(.conflict, reason: "This Google account is connected to another Snaglist account. Sign in there or use account recovery", identifier: "identity_already_linked")
            }
            return
        }
        // One connected Google account per Snaglist user. The database index
        // protects simultaneous link attempts as well as this readable check.
        try await VerifiedIdentityService.lock("user-google:" + userID.uuidString, on: db)
        guard try await VerifiedIdentityService.sql(db).raw("SELECT id FROM user_identities WHERE user_id = \(bind: userID) AND provider = 'google'").first() == nil else {
            throw Abort(.conflict, reason: "Another Google account is already connected to this Snaglist account", identifier: "google_already_connected")
        }
        try await insert(proof.subject, for: userID, on: db)
        if proof.contactEmailIsVerified, let email = proof.contactEmail {
            try await VerifiedIdentityService.adoptProviderVerifiedEmail(email, to: userID, on: db)
        }
    }

    private static func identityOwner(_ subject: String, on db: Database) async throws -> UUID? {
        try await VerifiedIdentityService.sql(db).raw("SELECT user_id FROM user_identities WHERE provider = 'google' AND subject = \(bind: subject)").first()?.decode(column: "user_id", as: UUID.self)
    }

    private static func insert(_ subject: String, for userID: UUID, on db: Database) async throws {
        try await VerifiedIdentityService.sql(db).raw("INSERT INTO user_identities (id, user_id, provider, subject, verified_at) VALUES (\(bind: UUID()), \(bind: userID), 'google', \(bind: subject), \(bind: Date()))").run()
    }
}
