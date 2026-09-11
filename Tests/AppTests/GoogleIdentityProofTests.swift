@testable import App
import XCTVapor
import JWT

/// Generated synthetic RSA fixture. No Google token, provider secret, customer
/// identity, network call or database is used by this cryptographic boundary test.
final class GoogleIdentityProofTests: XCTestCase {
    let config = GoogleIdentityConfiguration(webClientID: "12345-syntheticweb.apps.googleusercontent.com", iosClientID: "12345-syntheticios.apps.googleusercontent.com")
    let nonce = String(repeating: "synthetic-nonce-", count: 3)
    let created = Date()

    func signed(_ overrides: [String: Any] = [:], remove: [String] = []) throws -> String {
        var values: [String: Any] = ["iss": "https://accounts.google.com", "sub": "synthetic-subject-1",
            "aud": config.webClientID, "iat": created.timeIntervalSince1970,
            "exp": created.addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": nonce, "email": "  REVIEW@EXAMPLE.TEST  ", "name": "  Site Manager  "]
        values.merge(overrides) { _, new in new }
        remove.forEach { values.removeValue(forKey: $0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let claims = try decoder.decode(GoogleIdentityClaims.self, from: JSONSerialization.data(withJSONObject: values))
        let signers = JWTSigners()
        signers.use(.rs256(key: try .private(pem: Self.syntheticPrivate)), kid: "synthetic-rsa")
        return try signers.sign(claims, kid: "synthetic-rsa")
    }

    func verify(_ token: String, surface: GoogleIdentitySurface = .web, hash: String? = nil) throws -> GoogleIdentityProof {
        let signers = JWTSigners()
        signers.use(.rs256(key: try .public(pem: Self.syntheticPublic)), kid: "synthetic-rsa")
        return try GoogleIdentityVerifier.verify(token, signers: signers, surface: surface,
            nonceHash: hash ?? SHA256Hasher.hash(token: nonce), challengeCreatedAt: created, config: config)
    }

    func assertDenied(_ token: String, surface: GoogleIdentitySurface = .web, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try verify(token, surface: surface), file: file, line: line) { error in
            XCTAssertEqual((error as? Abort)?.status, .unauthorized, file: file, line: line)
            XCTAssertFalse(String(describing: error).contains("synthetic-subject"), file: file, line: line)
        }
    }

    func testValidSignedWebIdentityUsesStableSubjectAndOnlyContactHints() throws {
        for issuer in ["https://accounts.google.com", "accounts.google.com"] {
            let proof = try verify(signed(["iss": issuer]))
            XCTAssertEqual(proof.subject, "synthetic-subject-1")
            XCTAssertEqual(proof.contactEmail, "review@example.test")
            XCTAssertEqual(proof.displayName, "Site Manager")
        }
        XCTAssertEqual(try verify(signed(["azp": config.webClientID])).subject, "synthetic-subject-1")
        let absent = try verify(signed(remove: ["email", "name"]))
        XCTAssertNil(absent.contactEmail); XCTAssertNil(absent.displayName)
    }

    func testNativeRequiresExactIOSPresenterAndServerAudience() throws {
        let native = try signed(["azp": config.iosClientID])
        XCTAssertEqual(try verify(native, surface: .ios).subject, "synthetic-subject-1")
        assertDenied(native)
        assertDenied(try signed(), surface: .ios)
        assertDenied(try signed(["azp": config.webClientID]), surface: .ios)
        assertDenied(try signed(["azp": config.iosClientID, "aud": config.iosClientID]), surface: .ios)
    }

    func testWrongAudiencePresenterAndMultipleAudiencesAreRejected() throws {
        assertDenied(try signed(["aud": "12345-another.apps.googleusercontent.com"]))
        assertDenied(try signed(["aud": [config.webClientID, "another-client"]]))
        assertDenied(try signed(["azp": "another-client"]))
    }

    func testNonceMustMatchThisChallengeWithoutPublishingClaimValues() throws {
        assertDenied(try signed(remove: ["nonce"]))
        assertDenied(try signed(["nonce": "short"]))
        assertDenied(try signed(["nonce": String(repeating: "other-nonce", count: 4)]))
        XCTAssertThrowsError(try verify(signed(), hash: String(repeating: "0", count: 64)))
    }

    func testExpiryIssuedTimeAndChallengeAgeAreVerified() throws {
        assertDenied(try signed(["exp": created.addingTimeInterval(-1).timeIntervalSince1970]))
        assertDenied(try signed(["iat": created.addingTimeInterval(120).timeIntervalSince1970]))
        assertDenied(try signed(["iat": created.addingTimeInterval(-120).timeIntervalSince1970]))
    }

    func testInvalidIssuerAndSubjectAreRejected() throws {
        for issuer in ["https://accounts.google.com.evil.test", "https://example.test", ""] {
            assertDenied(try signed(["iss": issuer]))
        }
        for subject in ["", "invalid subject", "subject\n", "non-ascii-é", String(repeating: "x", count: 256)] {
            assertDenied(try signed(["sub": subject]))
        }
    }

    func testTamperedSignatureMalformedAndWrongAlgorithmCannotAuthenticate() throws {
        let token = try signed()
        var parts = token.split(separator: ".").map(String.init)
        parts[2] = (parts[2].hasPrefix("A") ? "B" : "A") + parts[2].dropFirst()
        assertDenied(parts.joined(separator: "."))
        for bad in ["", "not-a-jwt", "a.b.c", String(repeating: "x", count: 16_385)] { assertDenied(bad) }
        let header = Data(#"{"alg":"HS256","kid":"synthetic-rsa"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        parts = token.split(separator: ".").map(String.init); parts[0] = header
        assertDenied(parts.joined(separator: "."))
    }

    func testClientConfigurationNeverAcceptsPlaceholderOrArbitraryAudience() throws {
        for value in ["", "YOUR_CLIENT_ID", "123.apps.googleusercontent.com.evil.test", " https://google.com ", "12345-ABC.apps.googleusercontent.com"] {
            XCTAssertFalse(GoogleIdentityConfiguration.validClientID(value))
        }
        XCTAssertTrue(GoogleIdentityConfiguration.validClientID(config.webClientID))
    }

    // Generated solely for these tests; never a provider, signing or deployment key.
    static let syntheticPrivate = """
    -----BEGIN PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC4Zh122x+pQSyS
    cdCKC8qkquo2KgnMBE+MpZXLGoUwbFUplpPnGb707DFGkG0tCHw7Uwp0McNIIa7j
    ez95gxU06Bi98SkJ+nxaFP/+aggj1Ss/0ABYn269W83Tc0TD5uTI4UKGfV9Up644
    7xA9TUtTJa1A4pPHVoZmsUVi/PTyyA946lFwzTAiz3F+CKh1CMaExWM2yOZDs/TY
    2fnj5FEZq+NdAH6y4oZK4CUj1mzLs1vV8705u59RZLhGI5Pc7O3L6wl9i8E1H4eS
    IHppJZLv5VY52iC8B/xnVVxdVPudeS7roW8P660bm57MrF/aLDHUTiF8oy+4iP0s
    na/BEV8TAgMBAAECggEAVs9UDbFo/WB+YE8Okv6sHsuLyYYO6Koa3SbTFzPcAgju
    Ks8FwCVhvaI4LHUvwKSe/7q/UCZhPeMFl3hdUJJCeI7PnxQacuUmh64dOiOmw1/G
    pZsBnrcoBiNjCanZdLSNfnh1viTlrU/neEwrhACQdotlPges9IoqacwI02os0uJJ
    s6iXAytZVTiPXieh/UHy783KkQ1cpcuD+SrQWviPromyfeFlrzak9tQQ1RVOcHTZ
    cBQX8jgDdSvm3+06TbFQrlW7u4weRwgsdDwDlFuD9MLbcHkXSwTZJYb3Q5FsVbJS
    w5yO0Q1RapSVHDbKUsNwuRUlASpFgyEEZdWL306q2QKBgQDdK5CGIFg6fH1aTOnc
    RWNjV5sb9DvthdNGjnvM+s7fFzFRPgVnMbyWhFmPreNEzij1L+pGAAj4Ie6fwgP9
    4BWK/6VrI+6tcLfZFccjHlMcFXq1TriG9AK+TWq2hnT4Rs8YNncZ+CNn2bwaJIhr
    aPYpWgRbAf5L2X/KId2wC//7VQKBgQDVcB9u1VY/JtcTnBlLk8E7XhSk2QZZQYGk
    6sRSDS2eW8faRT/ZBzkrJdibRqdHxX09/esyUjNQvc8G6zFmBV/PEMFdliC5spQT
    tfQ69BroBw7h6MuXeUbhzDf9XUMzeqcyh4kE1dVX5wZYJrOg25o4ZjFllFBiOItD
    5TAmKsEAxwKBgGxgVpeC7fjq27oOCmKnlcYuPZF7IoqHkzn1w/Bzzj8/bCk1TQx+
    ML1I6WIggUdMBoHvEstuZPbCGd4rAi27SpMsJnDT0Lcojs5Pf59T0sHmPJTvmDh5
    BYcfBHWgeVzXxc9FkSMmlqLi7Ouaj0aizk0BETVPSr78O0RfR/RmTO9pAoGAOrCj
    JBHrrl/awlypI/wUJWQAXzgCI+b8ZEHeDAXtpl7sfJuQK/htguzcPA5Yj0bB4psA
    4oxx6eDXnbpskfYmW0TrNvXCN+3gA++DofZfs6/FKt+dpCBIGmzSdIwBn5U5ho54
    Yej+yjYPq4uw1ymrpZiMOrdmxytvOBM8gzI8ch8CgYANVLZm2xSojcSLktjrurrz
    eEM7OEFbtKLpLeiR+vsVFMbi4SzB2HBv2Z2ZaadFDmNswkV8xAzZS5t7Po81x9qU
    moRHRfORCoie/YyE/1o7Pvatg/EmhDiutajxSnFnuSAWXFnP0ygEyTlDxc/lsQLB
    M0+dy9/AJrVthCeZzRoLLQ==
    -----END PRIVATE KEY-----
    """
    static let syntheticPublic = """
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuGYddtsfqUEsknHQigvK
    pKrqNioJzARPjKWVyxqFMGxVKZaT5xm+9OwxRpBtLQh8O1MKdDHDSCGu43s/eYMV
    NOgYvfEpCfp8WhT//moII9UrP9AAWJ9uvVvN03NEw+bkyOFChn1fVKeuOO8QPU1L
    UyWtQOKTx1aGZrFFYvz08sgPeOpRcM0wIs9xfgiodQjGhMVjNsjmQ7P02Nn54+RR
    GavjXQB+suKGSuAlI9Zsy7Nb1fO9ObufUWS4RiOT3Ozty+sJfYvBNR+HkiB6aSWS
    7+VWOdogvAf8Z1VcXVT7nXku66FvD+utG5uezKxf2iwx1E4hfKMvuIj9LJ2vwRFf
    EwIDAQAB
    -----END PUBLIC KEY-----
    """
}
