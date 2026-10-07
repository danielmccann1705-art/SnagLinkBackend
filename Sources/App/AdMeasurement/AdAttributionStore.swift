import Vapor
import Fluent
import FluentSQL

/// The `ad_attribution_records` table (`CreateAdAttributionRecords`) and every statement that reads or writes it.
/// Nothing in this file logs.
enum AdAttributionStore {

    // MARK: - Reference

    /// 128 random bits as 26 RFC 4648 base32 characters (upper case, no padding): unguessable, so it can stand as
    /// the only credential for an unauthenticated withdrawal, and short enough to read out to support.
    static func newReference() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base32(bytes)
    }

    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = "", buffer = 0, bits = 0
        for byte in bytes {
            buffer = ((buffer << 8) | Int(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    /// A reference as the withdrawal route accepts it: exactly 26 base32 characters (case-insensitive, as a person
    /// might type it to support). Anything else cannot name a record, so the route answers 404 without a query.
    static func normalisedReference(_ raw: String) -> String? {
        let upper = raw.uppercased()
        guard upper.utf8.count == 26, upper.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }) else { return nil }
        return upper
    }

    // MARK: - The app's upload

    /// `POST /api/v1/ad-measurement/apple` body, as the app sends it (`APIClient+AdMeasurement.swift`):
    /// `{"token": <AdServices token>, "rcAppUserID": <RevenueCat app user ID>, "appVersion": <CFBundleShortVersionString>}`.
    /// Any other key is ignored and never stored.
    struct Upload: Sendable, Equatable {
        let token: String
        let rcAppUserID: String
        let appVersion: String

        private struct Wire: Decodable { let token: String?; let rcAppUserID: String?; let appVersion: String? }

        /// Validates the three fields; `nil` for anything else. The caller answers 400 and never echoes a value.
        static func validated(_ data: Data) -> Upload? {
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
                  let token = wire.token, let id = wire.rcAppUserID, let version = wire.appVersion,
                  isToken(token), isRevenueCatAppUserID(id), isAppVersion(version) else { return nil }
            return Upload(token: token, rcAppUserID: id, appVersion: version)
        }

        /// Apple's token is a base64 string; the bound keeps the whole body under the route's 4 KB limit.
        static func isToken(_ value: String) -> Bool {
            (1...4000).contains(value.utf8.count) && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
                    $0 == 43 || $0 == 47 || $0 == 61 || $0 == 45 || $0 == 95   // + / = and the URL-safe - _
            }
        }

        /// The two shapes this app produces: RevenueCat's anonymous ID (`$RCAnonymousID:` + 32 lower-case hex or
        /// digits, the SDK's own pattern) or an account UUID as `UUID.uuidString` writes it (upper case).
        static func isRevenueCatAppUserID(_ value: String) -> Bool {
            let anonymous = "$RCAnonymousID:"
            if value.hasPrefix(anonymous) {
                let rest = value.utf8.dropFirst(anonymous.utf8.count)
                return rest.count == 32 && rest.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            }
            return value.utf8.count == 36 && UUID(uuidString: value)?.uuidString == value
        }

        /// `CFBundleShortVersionString`: one to four dot-separated numbers.
        static func isAppVersion(_ value: String) -> Bool {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return value.utf8.count <= 32 && (1...4).contains(parts.count) &&
                parts.allSatisfy { (1...6).contains($0.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }
        }
    }

    // MARK: - Statements

    /// One `pending` row; returns its reference. A clash on the unique reference (never expected at 128 bits) draws
    /// a new one.
    static func insert(_ upload: Upload, now: Date, on db: Database) async throws -> String {
        let sql = try VerifiedIdentityService.sql(db)
        for _ in 0..<3 {
            let reference = newReference()
            let inserted = try await sql.raw("""
                INSERT INTO ad_attribution_records
                    (id, reference, rc_app_user_id, app_version, token, exchange_state, exchange_attempts, created_at)
                VALUES (\(bind: UUID()), \(bind: reference), \(bind: upload.rcAppUserID), \(bind: upload.appVersion),
                        \(bind: upload.token), 'pending', 0, \(bind: now))
                ON CONFLICT (reference) DO NOTHING
                RETURNING reference
                """).first()
            if inserted != nil { return reference }
        }
        throw Abort(.internalServerError, reason: "No reference could be issued", identifier: "ad_measurement_reference_unavailable")
    }

    /// Reserves an authenticated, canonical request before the Apple call. The token is
    /// intentionally absent: a crash can leave only a token-free processing marker.
    static func insertCanonicalProcessing(accountID: UUID, installationID: UUID, consentRevision: UUID,
                                          appVersion: String, now: Date, on db: Database) async throws -> String {
        let sql = try VerifiedIdentityService.sql(db)
        for _ in 0..<3 {
            let reference = newReference()
            if try await sql.raw("""
                INSERT INTO ad_attribution_records
                    (id,reference,rc_app_user_id,app_version,token,exchange_state,exchange_attempts,created_at,
                     canonical_account_id,canonical_consent_revision,canonical_installation_id)
                VALUES (\(bind:UUID()),\(bind:reference),\(bind:accountID.uuidString),\(bind:appVersion),NULL,'processing',0,\(bind:now),
                        \(bind:accountID),\(bind:consentRevision),\(bind:installationID))
                ON CONFLICT DO NOTHING RETURNING reference
                """).first() != nil { return reference }
        }
        throw Abort(.conflict, reason: "Apple measurement is already processing", identifier: "ad_measurement_processing")
    }

    /// Withdrawal: erases the row whatever its state, including an unexchanged token. `true` when a row existed.
    /// An exchange in flight for it finds nothing to update and its result is discarded.
    static func delete(reference: String, on db: Database) async throws -> Bool {
        try await VerifiedIdentityService.sql(db).raw("""
            DELETE FROM ad_attribution_records WHERE reference = \(bind: reference) RETURNING id
            """).first() != nil
    }

    /// Account deletion (`AccountDeletionService.request`, inside its transaction): rows made while this account
    /// was signed in carry its UUID exactly as the app passes it to `Purchases.logIn` — `uuidString`, upper case.
    /// Rows made as a guest carry `$RCAnonymousID:…`, are linked to no account here, and end by withdrawal, by
    /// support with the reference, or at retention (PRIVACY-DELTA.md §A6).
    @discardableResult
    static func eraseAccount(_ userID: UUID, on db: Database) async throws -> Int {
        try await total(VerifiedIdentityService.sql(db), """
            WITH erased AS (DELETE FROM ad_attribution_records WHERE rc_app_user_id = \(bind: userID.uuidString) RETURNING 1)
            SELECT count(*) AS total FROM erased
            """)
    }

    /// Retention (D6, PROPOSED): rows created more than `AdMeasurementPolicy.retention` ago, oldest first, in
    /// batches.
    static func sweep(now: Date, on db: Database, limit: Int = AdMeasurementPolicy.sweepBatch) async throws -> Int {
        let cutoff = now.addingTimeInterval(-AdMeasurementPolicy.retention)
        return try await total(VerifiedIdentityService.sql(db), """
            WITH removed AS (
                DELETE FROM ad_attribution_records WHERE id IN (
                    SELECT id FROM ad_attribution_records WHERE created_at < \(bind: cutoff)
                    ORDER BY created_at LIMIT \(bind: max(0, limit)))
                RETURNING 1)
            SELECT count(*) AS total FROM removed
            """)
    }

    /// Rows whose token's 24-hour validity has run out before an exchange settled: `expired`, token dropped.
    static func expire(now: Date, on db: Database) async throws -> Int {
        let cutoff = now.addingTimeInterval(-AdMeasurementPolicy.tokenValidity)
        return try await total(VerifiedIdentityService.sql(db), """
            WITH expired AS (
                UPDATE ad_attribution_records SET exchange_state = 'expired', token = NULL
                WHERE exchange_state IN ('pending', 'failing') AND created_at <= \(bind: cutoff)
                RETURNING 1)
            SELECT count(*) AS total FROM expired
            """)
    }

    struct Due: Sendable { let id: UUID; let token: String }

    /// Rows still to exchange, oldest first: `pending` or `failing`, younger than the token's validity.
    static func due(now: Date, limit: Int, on db: Database) async throws -> (rows: [Due], total: Int) {
        let sql = try VerifiedIdentityService.sql(db)
        let cutoff = now.addingTimeInterval(-AdMeasurementPolicy.tokenValidity)
        let count = try await total(sql, """
            SELECT count(*) AS total FROM ad_attribution_records
            WHERE exchange_state IN ('pending', 'failing') AND created_at > \(bind: cutoff)
            """)
        let rows = try await sql.raw("""
            SELECT id, token FROM ad_attribution_records
            WHERE exchange_state IN ('pending', 'failing') AND created_at > \(bind: cutoff) AND token IS NOT NULL
            ORDER BY created_at LIMIT \(bind: max(0, limit))
            """).all()
        return (try rows.map { Due(id: try $0.decode(column: "id", as: UUID.self), token: try $0.decode(column: "token", as: String.self)) }, count)
    }

    /// Writes one exchange's outcome, only onto a row that still exists and is still due. `false` when the row was
    /// withdrawn (or expired) meanwhile: the result is discarded, never written anywhere.
    static func record(_ outcome: AppleAttributionExchangeService.Outcome, attempts: Int, id: UUID, now: Date,
                       on db: Database) async throws -> Bool {
        let sql = try VerifiedIdentityService.sql(db)
        let query: SQLQueryString
        switch outcome {
        case .attributed(let fields):
            query = """
                UPDATE ad_attribution_records SET exchange_state = 'done', token = NULL,
                    exchange_attempts = exchange_attempts + \(bind: attempts), exchanged_at = \(bind: now),
                    attribution = \(bind: fields.attribution), campaign_id = \(bind: fields.campaignId),
                    adgroup_id = \(bind: fields.adGroupId), keyword_id = \(bind: fields.keywordId), ad_id = \(bind: fields.adId),
                    claim_type = \(bind: fields.claimType), conversion_type = \(bind: fields.conversionType),
                    country_or_region = \(bind: fields.countryOrRegion)
                WHERE id = \(bind: id) AND exchange_state IN ('pending', 'failing')
                RETURNING id
                """
        case .invalid:
            query = """
                UPDATE ad_attribution_records SET exchange_state = 'invalid', token = NULL,
                    exchange_attempts = exchange_attempts + \(bind: attempts)
                WHERE id = \(bind: id) AND exchange_state IN ('pending', 'failing')
                RETURNING id
                """
        case .notYetAvailable:
            query = """
                UPDATE ad_attribution_records SET exchange_state = 'pending', exchange_attempts = exchange_attempts + \(bind: attempts)
                WHERE id = \(bind: id) AND exchange_state IN ('pending', 'failing')
                RETURNING id
                """
        case .failing:
            query = """
                UPDATE ad_attribution_records SET exchange_state = 'failing', exchange_attempts = exchange_attempts + \(bind: attempts)
                WHERE id = \(bind: id) AND exchange_state IN ('pending', 'failing')
                RETURNING id
                """
        }
        return try await sql.raw(query).first() != nil
    }

    /// Writes a synchronous authenticated exchange only to its token-free processing row.
    static func record(_ outcome: AppleAttributionExchangeService.Outcome, attempts: Int, reference: String,
                       now: Date, on db: Database) async throws -> Bool {
        let query: SQLQueryString
        switch outcome {
        case .attributed(let fields):
            query = """
                UPDATE ad_attribution_records SET exchange_state='done',exchange_attempts=\(bind:attempts),exchanged_at=\(bind:now),
                    attribution=\(bind:fields.attribution),campaign_id=\(bind:fields.campaignId),adgroup_id=\(bind:fields.adGroupId),
                    keyword_id=\(bind:fields.keywordId),ad_id=\(bind:fields.adId),claim_type=\(bind:fields.claimType),
                    conversion_type=\(bind:fields.conversionType),country_or_region=\(bind:fields.countryOrRegion)
                WHERE reference=\(bind:reference) AND exchange_state='processing' AND token IS NULL RETURNING id
                """
        case .invalid:
            query = """
                UPDATE ad_attribution_records SET exchange_state='invalid',exchange_attempts=\(bind:attempts)
                WHERE reference=\(bind:reference) AND exchange_state='processing' AND token IS NULL RETURNING id
                """
        case .notYetAvailable, .failing:
            return false
        }
        return try await VerifiedIdentityService.sql(db).raw(query).first() != nil
    }

    private static func total(_ sql: SQLDatabase, _ query: SQLQueryString) async throws -> Int {
        try await sql.raw(query).first()?.decode(column: "total", as: Int.self) ?? 0
    }
}
