import XCTest
@testable import App

/// Every transactional email renders through `EmailLayout` in the current Snaglist brand,
/// escapes what users typed, and still carries its exact link, subject and expiry wording.
final class EmailBrandTests: XCTestCase {
    private let signInURL = "https://snaglist-api-unified-staging.example.test/auth/Zm9vYmFyLWJhei1xdXV4LTAxMjM0NTY3ODlhYmNkZWY"
    private let browserSignInURL = "https://staging-app.usesnaglist.com/sign-in/verify#token=Zm9vYmFyLWJhei1xdXV4LTAxMjM0NTY3ODk"
    private let contractorURL = "https://snaglist-api-unified-staging.example.test/m/c2_Synthetic-Slug_0123"
    private let reviewURL = "https://staging-app.usesnaglist.com/projects/0000/snags/0001/review"

    private func allEmails() -> [(name: String, email: EmailLayout.Rendered, links: [String])] {
        [
            ("contractor-link", NotificationService.contractorLinkEmail(
                contractorName: "Priya Contractor", projectName: "Plot 15, Riverside", projectAddress: "1 Example Street, Nuneaton CV10 0AA",
                snagCount: 3, magicLinkURL: contractorURL, createdByName: "Sam Manager"), [contractorURL]),
            ("contractor-link-single", NotificationService.contractorLinkEmail(
                contractorName: "Priya Contractor", projectName: "Plot 15, Riverside", projectAddress: nil,
                snagCount: 1, magicLinkURL: contractorURL, createdByName: "Sam Manager"), [contractorURL]),
            ("completion", NotificationService.completionEmail(
                pmName: "Project Manager", contractorName: "Priya Contractor", snagTitle: "S-012 — Skirting gap in hallway",
                projectName: "Plot 15, Riverside", completionNotes: "Filled and repainted.\nSecond coat tomorrow.", hasPhotos: true, reviewURL: reviewURL), [reviewURL]),
            ("completion-minimal", NotificationService.completionEmail(
                pmName: "Project Manager", contractorName: "Priya Contractor", snagTitle: "Snag #0A1B2C3D",
                projectName: "Project", completionNotes: nil, hasPhotos: false, reviewURL: nil), []),
            ("sign-in", NotificationService.signInEmail(name: "Sam", magicLinkURL: signInURL), [signInURL]),
            ("sign-in-browser", NotificationService.signInEmail(name: nil, magicLinkURL: browserSignInURL), [browserSignInURL]),
            ("approval-approved", NotificationService.approvalDecisionEmail(
                contractorName: "Priya Contractor", snagTitle: "S-012 — Skirting gap in hallway", approved: true, note: nil), []),
            ("approval-sent-back", NotificationService.approvalDecisionEmail(
                contractorName: "Priya Contractor", snagTitle: "S-012 — Skirting gap in hallway", approved: false,
                note: "The gap by the door frame is still visible. Please fill and send a new photo."), []),
        ]
    }

    func testNoOldBrandColoursRemainInAnyEmail() {
        let retired = ["#f97316", "#ea580c", "linear-gradient", "#059669", "#047857", "#168a45", "#d63b1f", "#065f46", "#ecfdf5"]
        for (name, email, _) in allEmails() {
            let html = email.html.lowercased()
            for colour in retired {
                XCTAssertFalse(html.contains(colour), "\(name) still contains \(colour)")
            }
            XCTAssertTrue(html.contains(EmailLayout.Brand.accent), name)
            XCTAssertTrue(html.contains(EmailLayout.Brand.ink), name)
            XCTAssertTrue(html.contains(EmailLayout.Brand.background), name)
        }
        XCTAssertEqual(EmailLayout.Brand.accent, "#d8321e")
        XCTAssertEqual(EmailLayout.Brand.ink, "#1a1d23")
        XCTAssertEqual(EmailLayout.Brand.muted, "#59616d")
        XCTAssertEqual(EmailLayout.Brand.background, "#f7f8fa")
        XCTAssertEqual(EmailLayout.Brand.rule, "#d9dce1")
        XCTAssertEqual(EmailLayout.Brand.radius, "6px")
    }

    func testEveryEmailUsesTheSharedLayoutWordmarkAndFooter() {
        for (name, email, _) in allEmails() {
            XCTAssertTrue(email.html.hasPrefix("<!DOCTYPE html>"), name)
            XCTAssertTrue(email.html.contains("Snagl<span style=\"color: #d8321e;\">i</span>st"), "\(name) wordmark")
            XCTAssertTrue(email.html.contains("max-width: 560px"), name)
            XCTAssertTrue(email.html.contains("role=\"presentation\""), name)
            XCTAssertTrue(email.html.contains("Snaglist &middot; <a href=\"https://usesnaglist.com\""), name)
            XCTAssertTrue(email.html.contains("support@usesnaglist.com</a>"), name)
            XCTAssertTrue(email.html.contains("Snaglist is provided by Reeve Technologies Ltd, 66 Paul Street, London EC2A 4NA."), name)
            XCTAssertFalse(email.html.lowercased().contains("<img"), "\(name) must not depend on remote images")
            XCTAssertFalse(email.html.lowercased().contains("<style"), "\(name) must use inline styles only")
            XCTAssertFalse(email.html.lowercased().contains("url("), name)
            XCTAssertTrue(email.text.hasPrefix("Snaglist\n"), name)
            XCTAssertTrue(email.text.hasSuffix("Snaglist · usesnaglist.com · support@usesnaglist.com\nSnaglist is provided by Reeve Technologies Ltd, 66 Paul Street, London EC2A 4NA.\n"), name)
            XCTAssertFalse(email.text.contains("<"), "\(name) plain text carries no markup")
        }
    }

    func testEachEmailStillCarriesItsExactLink() {
        for (name, email, links) in allEmails() {
            for link in links {
                XCTAssertTrue(email.html.contains("href=\"\(link)\""), "\(name) HTML lost \(link)")
                XCTAssertTrue(email.text.contains("\n\(link)\n"), "\(name) text lost \(link)")
            }
            if links.isEmpty {
                XCTAssertFalse(email.html.contains("If the button does not work"), name)
            }
        }
    }

    func testSubjectsAndExpiryWordingAreUnchanged() {
        let emails = Dictionary(uniqueKeysWithValues: allEmails().map { ($0.name, $0.email) })
        XCTAssertEqual(emails["contractor-link"]?.subject, "You have 3 snags to review - Plot 15, Riverside")
        XCTAssertEqual(emails["contractor-link-single"]?.subject, "You have 1 snag to review - Plot 15, Riverside")
        XCTAssertEqual(emails["completion"]?.subject, "Snag completed: S-012 — Skirting gap in hallway - Plot 15, Riverside")
        XCTAssertEqual(emails["sign-in"]?.subject, "Sign in to Snaglist — one-tap link")
        XCTAssertEqual(emails["approval-approved"]?.subject, "Approved: S-012 — Skirting gap in hallway")
        XCTAssertEqual(emails["approval-sent-back"]?.subject, "Sent back: S-012 — Skirting gap in hallway")
        for key in ["sign-in", "sign-in-browser"] {
            XCTAssertTrue(emails[key]!.html.contains("This link expires in 15 minutes and can only be used once."), key)
            XCTAssertTrue(emails[key]!.text.contains("This link expires in 15 minutes and can only be used once."), key)
        }
        XCTAssertTrue(emails["sign-in"]!.html.contains("Hi Sam,"))
        XCTAssertTrue(emails["sign-in-browser"]!.html.contains("Hi there,"))
        XCTAssertTrue(emails["completion"]!.html.contains("Filled and repainted.<br>Second coat tomorrow."))
        XCTAssertTrue(emails["completion"]!.html.contains("Completion photos attached"))
        XCTAssertFalse(emails["completion-minimal"]!.html.contains("Completion photos attached"))
        XCTAssertFalse(emails["contractor-link-single"]!.html.contains("Example Street"))
    }

    func testNoRetiredOrForbiddenWording() throws {
        let yet = try NSRegularExpression(pattern: "\\byet\\b", options: [.caseInsensitive])
        for (name, email, _) in allEmails() {
            for part in [email.subject, email.html, email.text] {
                let lower = part.lowercased()
                XCTAssertFalse(lower.contains("magic link"), name)
                XCTAssertFalse(lower.contains("magic-link"), name)
                XCTAssertFalse(lower.contains("coming soon"), name)
                XCTAssertNil(yet.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)), "\(name) says 'yet'")
            }
        }
        XCTAssertTrue(allEmails()[0].email.html.contains("Contractor link"))
    }

    func testTheLayoutEscapesEveryValueItIsGiven() {
        let hostile = "<script>alert(\"x\")</script> O'Brien & Sons"
        let escaped = "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; O&#39;Brien &amp; Sons"
        let rendered = EmailLayout.render(subject: "s", EmailLayout.Message(
            preheader: hostile,
            heading: hostile,
            blocks: [
                .greeting(hostile),
                .paragraph([.text(hostile), .strong(hostile)]),
                .summary(title: hostile, detail: hostile),
                .note(label: hostile, text: hostile),
                .status(hostile, tone: .attention),
                .button(label: hostile, url: "https://example.test/a\"onmouseover=\"alert(1)"),
                .small(hostile),
            ],
            closing: hostile
        ))
        XCTAssertFalse(rendered.html.contains("<script>"))
        XCTAssertFalse(rendered.html.contains("O'Brien"))
        XCTAssertFalse(rendered.html.contains("\"onmouseover=\""))
        XCTAssertTrue(rendered.html.contains("href=\"https://example.test/a&quot;onmouseover=&quot;alert(1)\""))
        // preheader, title, heading, greeting, 2 inline, summary x2, note x2, status, button label, small, closing
        XCTAssertEqual(rendered.html.components(separatedBy: escaped).count - 1, 14)
        // Plain text is never interpreted as HTML, so it keeps the characters as typed.
        XCTAssertTrue(rendered.text.contains("Hi \(hostile),"))
    }

    func testEverySenderEscapesUserSuppliedValues() {
        let hostile = "<b>Mallory</b> & \"Co\""
        let emails = [
            NotificationService.contractorLinkEmail(contractorName: hostile, projectName: hostile, projectAddress: hostile,
                                                    snagCount: 2, magicLinkURL: contractorURL, createdByName: hostile),
            NotificationService.completionEmail(pmName: hostile, contractorName: hostile, snagTitle: hostile, projectName: hostile,
                                                completionNotes: hostile, hasPhotos: false, reviewURL: reviewURL),
            NotificationService.signInEmail(name: hostile, magicLinkURL: signInURL),
            NotificationService.approvalDecisionEmail(contractorName: hostile, snagTitle: hostile, approved: false, note: hostile),
            NotificationService.approvalDecisionEmail(contractorName: hostile, snagTitle: hostile, approved: true, note: nil),
        ]
        for email in emails {
            XCTAssertFalse(email.html.contains("<b>Mallory</b>"))
            XCTAssertFalse(email.html.contains("&amp;lt;"), "double-escaped")
            XCTAssertTrue(email.html.contains("&lt;b&gt;Mallory&lt;/b&gt; &amp; &quot;Co&quot;"))
        }
    }

    /// Writes each email to disk for visual review only when asked (never in the normal suite).
    func testRenderedPreviewsAreWrittenOnRequest() throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAGLIST_EMAIL_PREVIEW_DIR"], directory.hasPrefix("/") else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index: [String] = []
        for (position, item) in allEmails().enumerated() {
            let stem = String(format: "%02d", position + 1) + "-" + item.name
            try Data(item.email.html.utf8).write(to: folder.appendingPathComponent(stem + ".html"))
            try Data(item.email.text.utf8).write(to: folder.appendingPathComponent(stem + ".txt"))
            index.append("\(stem)\t\(item.email.subject)")
        }
        try Data((index.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("subjects.tsv"))
    }
}
