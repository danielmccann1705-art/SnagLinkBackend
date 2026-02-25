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
    private static let fromEmail = "Snaglist <notifications@snaglist.app>"

    // MARK: - Email Types

    enum EmailError: Error, AbortError {
        case apiKeyNotConfigured
        case sendFailed(String)
        case invalidResponse

        var status: HTTPResponseStatus {
            switch self {
            case .apiKeyNotConfigured:
                return .serviceUnavailable
            case .sendFailed:
                return .internalServerError
            case .invalidResponse:
                return .internalServerError
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
            }
        }
    }

    // MARK: - Resend API Request/Response

    private struct ResendEmailRequest: Content {
        let from: String
        let to: [String]
        let subject: String
        let html: String
    }

    private struct ResendEmailResponse: Content {
        let id: String?
        let error: ResendError?

        struct ResendError: Content {
            let message: String
        }
    }

    // MARK: - Public Methods

    /// Sends an email notification when a magic link is created and shared with a contractor
    /// - Parameters:
    ///   - email: Contractor's email address
    ///   - contractorName: Name of the contractor
    ///   - projectName: Name of the project
    ///   - projectAddress: Address of the project (optional)
    ///   - snagCount: Number of snags shared
    ///   - magicLinkURL: The full magic link URL
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

        let subject = "You have \(snagCount) snag\(snagCount == 1 ? "" : "s") to review - \(projectName)"

        let addressLine = projectAddress.map { "<p style=\"color: #6b7280; margin: 0;\">\($0)</p>" } ?? ""

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; line-height: 1.6; color: #1f2937; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="background: linear-gradient(135deg, #f97316 0%, #ea580c 100%); padding: 30px; border-radius: 12px 12px 0 0; text-align: center;">
                <h1 style="color: white; margin: 0; font-size: 24px;">Snaglist</h1>
            </div>

            <div style="background: #ffffff; padding: 30px; border: 1px solid #e5e7eb; border-top: none; border-radius: 0 0 12px 12px;">
                <p style="font-size: 18px; margin-top: 0;">Hi \(contractorName),</p>

                <p>\(createdByName) has shared <strong>\(snagCount) snag\(snagCount == 1 ? "" : "s")</strong> with you that need attention.</p>

                <div style="background: #f9fafb; border-radius: 8px; padding: 20px; margin: 20px 0;">
                    <p style="font-weight: 600; color: #111827; margin: 0 0 5px 0;">\(projectName)</p>
                    \(addressLine)
                </div>

                <div style="text-align: center; margin: 30px 0;">
                    <a href="\(magicLinkURL)" style="display: inline-block; background: #f97316; color: white; padding: 14px 28px; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 16px;">View Snags</a>
                </div>

                <p style="color: #6b7280; font-size: 14px;">You can view details, add photos, and mark items as complete directly from the link above.</p>

                <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 30px 0;">

                <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">This email was sent by Snaglist. If you weren't expecting this email, you can safely ignore it.</p>
            </div>
        </body>
        </html>
        """

        try await sendEmail(
            to: email,
            subject: subject,
            html: html,
            apiKey: apiKey,
            client: client
        )
    }

    /// Sends an email notification when a contractor marks a snag as complete
    /// - Parameters:
    ///   - email: Project manager's email address
    ///   - pmName: Name of the project manager
    ///   - contractorName: Name of the contractor who completed the work
    ///   - snagTitle: Title of the completed snag
    ///   - projectName: Name of the project
    ///   - completionNotes: Optional notes from the contractor
    ///   - hasPhotos: Whether completion photos were uploaded
    ///   - reviewURL: URL to review the completion (optional)
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

        let subject = "Snag completed: \(snagTitle) - \(projectName)"

        let notesSection = completionNotes.map { notes in
            """
            <div style="background: #f9fafb; border-radius: 8px; padding: 15px; margin: 15px 0;">
                <p style="font-weight: 600; color: #6b7280; margin: 0 0 5px 0; font-size: 12px; text-transform: uppercase;">Contractor Notes</p>
                <p style="color: #1f2937; margin: 0;">\(notes)</p>
            </div>
            """
        } ?? ""

        let photosIndicator = hasPhotos ? """
            <p style="color: #059669; font-size: 14px; margin: 10px 0;">
                <span style="display: inline-block; width: 8px; height: 8px; background: #059669; border-radius: 50%; margin-right: 6px;"></span>
                Completion photos attached
            </p>
        """ : ""

        let reviewButton = reviewURL.map { url in
            """
            <div style="text-align: center; margin: 25px 0;">
                <a href="\(url)" style="display: inline-block; background: #f97316; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600;">Review Completion</a>
            </div>
            """
        } ?? ""

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; line-height: 1.6; color: #1f2937; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="background: linear-gradient(135deg, #059669 0%, #047857 100%); padding: 30px; border-radius: 12px 12px 0 0; text-align: center;">
                <h1 style="color: white; margin: 0; font-size: 24px;">Completion Submitted</h1>
            </div>

            <div style="background: #ffffff; padding: 30px; border: 1px solid #e5e7eb; border-top: none; border-radius: 0 0 12px 12px;">
                <p style="font-size: 18px; margin-top: 0;">Hi \(pmName),</p>

                <p><strong>\(contractorName)</strong> has marked a snag as complete and is awaiting your review.</p>

                <div style="background: #ecfdf5; border: 1px solid #a7f3d0; border-radius: 8px; padding: 20px; margin: 20px 0;">
                    <p style="font-weight: 600; color: #065f46; margin: 0 0 5px 0;">\(snagTitle)</p>
                    <p style="color: #047857; margin: 0; font-size: 14px;">\(projectName)</p>
                </div>

                \(notesSection)
                \(photosIndicator)
                \(reviewButton)

                <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 30px 0;">

                <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">This notification was sent by Snaglist.</p>
            </div>
        </body>
        </html>
        """

        try await sendEmail(
            to: email,
            subject: subject,
            html: html,
            apiKey: apiKey,
            client: client
        )
    }

    // MARK: - Private Methods

    private static func sendEmail(
        to email: String,
        subject: String,
        html: String,
        apiKey: String,
        client: Client
    ) async throws {
        let request = ResendEmailRequest(
            from: fromEmail,
            to: [email],
            subject: subject,
            html: html
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
