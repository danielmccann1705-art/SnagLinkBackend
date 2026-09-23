@testable import App
import XCTVapor
import Foundation

/// Astra §7: the no-account Contractor link notice sits next to the first photo
/// upload and the submit action, with accessible links to the Contractor link terms
/// and the privacy notice. No checkbox, no account, no change to what is submitted.
/// The script is read exactly as a contractor's browser receives it.
final class ContractorLinkTermsNoticeTests: XCTestCase {
    static let terms = "https://usesnaglist.com/terms#contractor-links"
    static let privacy = "https://usesnaglist.com/privacy"
    static let notice = "Your photos and notes will be shared with the project team and may appear in project reports. Upload only information you have permission to share. By submitting, you agree to the <a href=\"\(terms)\" target=\"_blank\" rel=\"noopener noreferrer\" aria-label=\"Contractor link terms (opens in a new tab)\">Contractor link terms</a>. Read our <a href=\"\(privacy)\" target=\"_blank\" rel=\"noopener noreferrer\" aria-label=\"privacy notice (opens in a new tab)\">privacy notice</a> to understand how your information is used."

    var app: Application!
    override func setUp() async throws {
        try XCTSkipIf(Environment.get("DATABASE_URL") == nil, "Disposable PostgreSQL required")
        app = try await Application.make(.testing)
        try await configure(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func served(_ name: String) async throws -> Data {
        let response = try await app.testable(method: .inMemory).sendRequest(.GET, "assets/contractor/v2/\(name)")
        XCTAssertEqual(response.status, .ok, name)
        return Data(buffer: response.body)
    }

    func testTheSubmissionFormCarriesTheNoticeBetweenUploadAndSubmit() async throws {
        let script = String(decoding: try await served("contractor.js"), as: UTF8.self)
        let form = try XCTUnwrap(script.range(of: "function submission(item,draft) {"))
        let formEnd = try XCTUnwrap(script.range(of: "function card(item) {", range: form.upperBound..<script.endIndex))
        let body = String(script[form.upperBound..<formEnd.lowerBound])

        XCTAssertEqual(script.components(separatedBy: Self.notice).count - 1, 1, "the notice appears exactly once")
        let notice = try XCTUnwrap(body.range(of: "<p class=\"help terms-notice\" id=\"terms-${item.id}\">" + Self.notice + "</p>"),
                                   "the notice is part of the submission form, with an id the actions refer to")
        let chooser = try XCTUnwrap(body.range(of: "<button type=\"button\" class=\"secondary\" data-choose=\"${item.id}\" aria-describedby=\"terms-${item.id}\""))
        let submit = try XCTUnwrap(body.range(of: "<button type=\"submit\" class=\"primary\" aria-describedby=\"terms-${item.id}\""))
        XCTAssertLessThan(chooser.lowerBound, notice.lowerBound, "after the first photo upload control")
        XCTAssertLessThan(notice.lowerBound, submit.lowerBound, "before the submit action")

        // Nothing to tick, nothing to sign in to.
        XCTAssertFalse(script.contains("checkbox"))
        XCTAssertFalse(script.lowercased().contains("sign in"))
        // What is submitted is unchanged: the request carries no acceptance field.
        XCTAssertTrue(script.contains("draft.request={mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)}"))
        XCTAssertFalse(script.contains("termsVersion") || script.contains("terms_version") || script.contains("acceptedTerms"))
        // The two addresses are navigations the page already allows (links, not loads).
        XCTAssertEqual(Set(script.components(separatedBy: "https://").dropFirst().map { String($0.prefix(while: { $0 != "\"" })) }),
                       ["usesnaglist.com/terms#contractor-links", "usesnaglist.com/privacy"])
    }

    /// The page names its script by content, so the new bytes reach a contractor's
    /// browser at once instead of an hour-cached older copy.
    func testTheScriptAddressChangesWithItsBytes() async throws {
        var bytes = Data()
        for name in ["tokens.css", "contractor.css", "contractor.js"] { bytes.append(try await served(name)) }
        let version = String(PrivateImageProcessor.digest(bytes).prefix(16))
        let html = WebReportRenderer.renderCanonicalContractor()
        XCTAssertTrue(html.contains("/assets/contractor/v2/contractor.js?v=\(version)"), "the page must reference the served script's own digest")
        XCTAssertTrue(html.contains("/assets/contractor/v2/contractor.css?v=\(version)"))
    }
}
