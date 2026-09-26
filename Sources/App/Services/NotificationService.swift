import Vapor
import Logging
import Foundation

/// Service for sending email notifications via Resend API
struct NotificationService {

    private static let logger = Logger(label: "notification-service")

    // MARK: - Configuration

    private static var resendAPIKey: String? {
        Environment.get("RESEND_API_KEY")
    }

    private static let resendBaseURL = "https://api.resend.com"
    private static var fromEmail: String {
        Environment.get("EMAIL_FROM") ?? "Snaglist <notifications@snaglist.app>"
    }

    // MARK: - Email Types

    enum EmailError: Error, AbortError {
        case apiKeyNotConfigured
        case sendFailed(String)
        case invalidResponse
        case recipientNotAllowed

        var status: HTTPResponseStatus {
            switch self {
            case .apiKeyNotConfigured:
                return .serviceUnavailable
            case .sendFailed:
                return .internalServerError
            case .invalidResponse:
                return .internalServerError
            case .recipientNotAllowed:
                return .forbidden
            }
        }

        var reason: String {
            switch self {
            case .apiKeyNotConfigured:
                return "Email service not configured"
            case .sendFailed(let message):
                return "Failed to send email: \(message)"
            case .invalidResponse:
                return "Invalid response from email service"
            case .recipientNotAllowed:
                return "Email delivery is restricted in this environment"
            }
        }
    }

    // MARK: - Resend API Request/Response

    private struct ResendEmailRequest: Content {
        let from: String
        let to: [String]
        let subject: String
        let html: String
        let text: String
    }

    private struct ResendEmailResponse: Content {
        let id: String?
        let error: ResendError?

        struct ResendError: Content {
            let message: String
        }
    }

    // MARK: - Public Methods

    /// Sends the Contractor link email when a link is created and shared with a contractor.
    /// - Parameters:
    ///   - email: Contractor's email address
    ///   - contractorName: Name of the contractor
    ///   - projectName: Name of the project
    ///   - projectAddress: Address of the project (optional)
    ///   - snagCount: Number of snags shared
    ///   - magicLinkURL: The full Contractor link URL
    ///   - createdByName: Name of the person who created the link
    ///   - client: HTTP client for making requests
    static func sendMagicLinkEmail(
        to email: String,
        contractorName: String,
        projectName: String,
        projectAddress: String?,
        snagCount: Int,
        magicLinkURL: String,
        createdByName: String,
        client: Client
    ) async throws {
        guard let apiKey = resendAPIKey else {
            logger.info("RESEND_API_KEY not configured, skipping email notification")
            return
        }

        let rendered = contractorLinkEmail(
            contractorName: contractorName,
            projectName: projectName,
            projectAddress: projectAddress,
            snagCount: snagCount,
            magicLinkURL: magicLinkURL,
            createdByName: createdByName
        )

        try await sendEmail(to: email, rendered: rendered, apiKey: apiKey, client: client)
    }

    /// Sends an email notification when a contractor submits work on a snag for review
    /// - Parameters:
    ///   - email: Project manager's email address
    ///   - pmName: Name of the project manager
    ///   - contractorName: Name of the contractor who submitted the work
    ///   - snagTitle: Title of the snag
    ///   - projectName: Name of the project
    ///   - completionNotes: Optional notes from the contractor
    ///   - hasPhotos: Whether completion photos were uploaded
    ///   - reviewURL: URL to review the submission (optional)
    ///   - client: HTTP client for making requests
    static func sendCompletionEmail(
        to email: String,
        pmName: String,
        contractorName: String,
        snagTitle: String,
        projectName: String,
        completionNotes: String?,
        hasPhotos: Bool,
        reviewURL: String?,
        client: Client
    ) async throws {
        guard let apiKey = resendAPIKey else {
            logger.info("RESEND_API_KEY not configured, skipping email notification")
            return
        }

        let rendered = completionEmail(
            pmName: pmName,
            contractorName: contractorName,
            snagTitle: snagTitle,
            projectName: projectName,
            completionNotes: completionNotes,
            hasPhotos: hasPhotos,
            reviewURL: reviewURL
        )

        try await sendEmail(to: email, rendered: rendered, apiKey: apiKey, client: client)
    }

    /// Sends a passwordless sign-in email to a Project Manager (B1).
    /// No-ops (logs and returns) when `RESEND_API_KEY` is unconfigured, matching the
    /// other senders — keeps staging/dev functional without transactional-email creds.
    /// - Parameters:
    ///   - email: Recipient email address.
    ///   - name: Optional display name for the greeting.
    ///   - magicLinkURL: The full sign-in URL (`…/auth/{token}` or a browser `#token=` URL).
    ///   - client: HTTP client for making requests.
    static func sendMagicSignInEmail(
        to email: String,
        name: String?,
        magicLinkURL: String,
        client: Client
    ) async throws {
        guard let apiKey = resendAPIKey else {
            logger.info("RESEND_API_KEY not configured, skipping magic sign-in email")
            return
        }

        let rendered = signInEmail(name: name, magicLinkURL: magicLinkURL)

        try await sendEmail(to: email, rendered: rendered, apiKey: apiKey, client: client)
    }

    /// Notifies a contractor of a PM's approval decision (B5). No-ops without `RESEND_API_KEY`.
    /// - Parameters:
    ///   - email: Contractor email.
    ///   - contractorName: Contractor display name.
    ///   - snagTitle: The snag that was decided.
    ///   - approved: true = approved, false = sent back.
    ///   - note: Optional PM note (shown for send-backs).
    ///   - client: HTTP client.
    static func sendApprovalDecisionEmail(
        to email: String,
        contractorName: String,
        snagTitle: String,
        approved: Bool,
        note: String?,
        client: Client
    ) async throws {
        guard let apiKey = resendAPIKey else {
            logger.info("RESEND_API_KEY not configured, skipping approval decision email")
            return
        }

        let rendered = approvalDecisionEmail(
            contractorName: contractorName,
            snagTitle: snagTitle,
            approved: approved,
            note: note
        )

        try await sendEmail(to: email, rendered: rendered, apiKey: apiKey, client: client)
    }

    // MARK: - Rendering

    // Pure functions: subject, HTML and plain text for each email, all through the
    // shared `EmailLayout`, which escapes every interpolated value. Links, expiry
    // wording and subjects are exactly what the senders used before the rebrand.

    static func contractorLinkEmail(
        contractorName: String,
        projectName: String,
        projectAddress: String?,
        snagCount: Int,
        magicLinkURL: String,
        createdByName: String
    ) -> EmailLayout.Rendered {
        let snags = "\(snagCount) snag\(snagCount == 1 ? "" : "s")"
        let subject = "You have \(snagCount) snag\(snagCount == 1 ? "" : "s") to review - \(projectName)"
        let address = projectAddress.flatMap { $0.isEmpty ? nil : $0 }
        return EmailLayout.render(subject: subject, EmailLayout.Message(
            preheader: "\(createdByName) has shared \(snags) with you on \(projectName).",
            heading: "You have \(snags) to review",
            blocks: [
                .greeting(contractorName),
                .paragraph([.strong(createdByName), .text(" has shared "), .strong(snags), .text(" with you that need attention.")]),
                .summary(title: projectName, detail: address),
                .button(label: "View snags", url: magicLinkURL),
                .small("Open the Contractor link to see each snag, add photos and submit your work for review."),
            ],
            closing: "This email was sent by Snaglist. If you weren't expecting it, you can safely ignore it."
        ))
    }

    static func completionEmail(
        pmName: String,
        contractorName: String,
        snagTitle: String,
        projectName: String,
        completionNotes: String?,
        hasPhotos: Bool,
        reviewURL: String?
    ) -> EmailLayout.Rendered {
        var blocks: [EmailLayout.Block] = [
            .greeting(pmName),
            .paragraph([.strong(contractorName), .text(" has submitted work on this snag. It is awaiting your review.")]),
            .summary(title: snagTitle, detail: projectName),
        ]
        if let notes = completionNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.note(label: "Contractor notes", text: notes))
        }
        if hasPhotos {
            blocks.append(.status("Completion photos attached", tone: .success))
        }
        if let url = reviewURL {
            blocks.append(.button(label: "Review submission", url: url))
        }
        return EmailLayout.render(subject: "Snag completed: \(snagTitle) - \(projectName)", EmailLayout.Message(
            preheader: "\(contractorName) submitted work on \(snagTitle) for your review.",
            heading: "Work submitted for review",
            blocks: blocks,
            closing: "This notification was sent by Snaglist."
        ))
    }

    static func signInEmail(name: String?, magicLinkURL: String) -> EmailLayout.Rendered {
        let greetingName = (name?.isEmpty == false) ? name! : "there"
        return EmailLayout.render(subject: "Sign in to Snaglist — one-tap link", EmailLayout.Message(
            preheader: "Your Snaglist sign-in link. It expires in 15 minutes.",
            heading: "Sign in to Snaglist",
            blocks: [
                .greeting(greetingName),
                .paragraph([.text("Use the button below to sign in to Snaglist. No password needed.")]),
                .button(label: "Sign in to Snaglist", url: magicLinkURL),
                .small("This link expires in 15 minutes and can only be used once."),
            ],
            closing: "If you didn't request this, you can safely ignore this email. No one can sign in without the link above."
        ))
    }

    static func approvalDecisionEmail(
        contractorName: String,
        snagTitle: String,
        approved: Bool,
        note: String?
    ) -> EmailLayout.Rendered {
        let decision: [EmailLayout.Inline]
        if approved {
            decision = [.text("Your work on "), .strong(snagTitle), .text(" has been approved. Nothing more to do — thanks!")]
        } else {
            decision = [.text("Your submission for "), .strong(snagTitle), .text(" was sent back. Please review and re-submit.")]
        }
        var blocks: [EmailLayout.Block] = [.greeting(contractorName), .paragraph(decision)]
        if let note, !note.isEmpty {
            blocks.append(.note(label: "Note", text: note))
        }
        return EmailLayout.render(subject: approved ? "Approved: \(snagTitle)" : "Sent back: \(snagTitle)", EmailLayout.Message(
            preheader: approved ? "Your work on \(snagTitle) has been approved." : "Your submission for \(snagTitle) was sent back.",
            heading: approved ? "Work approved" : "Changes needed",
            blocks: blocks,
            closing: "This notification was sent by Snaglist."
        ))
    }

    // MARK: - Private Methods

    private static func sendEmail(
        to email: String,
        rendered: EmailLayout.Rendered,
        apiKey: String,
        client: Client
    ) async throws {
        guard EmailDeliveryPolicy.allows(email, configuredRecipients: Environment.get("EMAIL_ALLOWED_RECIPIENTS")) else {
            throw EmailError.recipientNotAllowed
        }
        let request = ResendEmailRequest(
            from: fromEmail,
            to: [email],
            subject: rendered.subject,
            html: rendered.html,
            text: rendered.text
        )

        let response = try await client.post(URI(string: "\(resendBaseURL)/emails")) { req in
            req.headers.add(name: .authorization, value: "Bearer \(apiKey)")
            req.headers.add(name: .contentType, value: "application/json")
            try req.content.encode(request)
        }

        // Check response status
        guard response.status == .ok || response.status == .created else {
            if let body = response.body,
               let errorResponse = try? JSONDecoder().decode(ResendEmailResponse.self, from: body) {
                throw EmailError.sendFailed(errorResponse.error?.message ?? "Unknown error")
            }
            throw EmailError.sendFailed("HTTP \(response.status.code)")
        }

        // Decode response to verify success
        guard let body = response.body,
              let emailResponse = try? JSONDecoder().decode(ResendEmailResponse.self, from: body),
              emailResponse.id != nil else {
            throw EmailError.invalidResponse
        }

        logger.info("Email sent successfully")
    }
}
