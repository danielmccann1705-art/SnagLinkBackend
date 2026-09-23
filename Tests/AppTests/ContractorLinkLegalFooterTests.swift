@testable import App
import XCTVapor
import Foundation

/// M7 (website review, 23 September 2026): the 2.0 Contractor link page is where a
/// contractor with no Snaglist account uploads photographs and notes, so the page
/// itself must reach the privacy notice and the terms. The links sit in the static
/// footer, outside `#content`, so they show on the PIN gate and on the snag list alike.
final class ContractorLinkLegalFooterTests: XCTestCase {
    private static let privacy = "https://usesnaglist.com/privacy"
    private static let terms = "https://usesnaglist.com/terms"

    private func footer(_ html: String) -> String? {
        guard let start = html.range(of: "<footer class=\"page-footer\">"),
              let end = html.range(of: "</footer>", range: start.upperBound..<html.endIndex) else { return nil }
        return String(html[start.lowerBound..<end.upperBound])
    }

    /// No database: the shell embeds no project or snag data before the PIN check.
    func testTheContractorLinkPageLinksThePrivacyNoticeAndTheTerms() throws {
        let html = WebReportRenderer.renderCanonicalContractor()
        let element = try XCTUnwrap(footer(html), "The Contractor link page has no footer")
        XCTAssertTrue(element.contains("<a href=\"\(Self.privacy)\" target=\"_blank\" rel=\"noopener noreferrer\">Privacy</a>"), element)
        XCTAssertTrue(element.contains("<a href=\"\(Self.terms)\" target=\"_blank\" rel=\"noopener noreferrer\">Terms</a>"), element)
        // A new tab keeps a half-finished submission on screen, and noreferrer keeps the
        // capability URL out of the destination's Referer, beside the page's own
        // no-referrer policy.
        XCTAssertTrue(html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        // Both links, and only these, are the page's absolute addresses: navigation
        // targets, not loads, so the self-only Content-Security-Policy stands unchanged.
        XCTAssertEqual(html.components(separatedBy: "https://").count - 1, 2)
        XCTAssertTrue(html.contains("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'"))
    }

    /// The route that serves `/m/c2_…` answers with the same footer. Its legacy-token
    /// lookup needs the database, like the other route suites.
    func testTheServedContractorLinkShellCarriesTheLinks() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            let slug = "c2_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try await app.test(.GET, "m/\(slug)", afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("<a href=\"\(Self.privacy)\""), "privacy link missing from the served page")
                XCTAssertTrue(body.contains("<a href=\"\(Self.terms)\""), "terms link missing from the served page")
                XCTAssertTrue(res.headers.first(name: "Content-Security-Policy")?.contains("frame-ancestors 'self'") == true)
                XCTAssertEqual(res.headers.first(name: "X-Frame-Options"), "SAMEORIGIN")
            })
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
