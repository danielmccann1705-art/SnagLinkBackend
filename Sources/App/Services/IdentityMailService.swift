import Vapor

enum IdentityMailService {
    static func send(email: String, url: String, config: PlatformConfiguration, req: Request) async throws {
        #if DEBUG
        if let directory = Environment.get("SNAGLIST_LOCAL_MAILBOX") {
            // Developer mailbox is never compiled into the release binary. It
            // requires development mode, a loopback listener/origin/database,
            // an explicitly named disposable DB and a synthetic .test recipient.
            guard req.application.environment == .development, config.environment == "local",
                  req.application.http.server.configuration.hostname == "127.0.0.1",
                  let origin = URLComponents(string: config.origin), ["127.0.0.1", "localhost"].contains(origin.host ?? ""),
                  let database = Environment.get("DATABASE_URL").flatMap(URLComponents.init(string:)),
                  database.host == "127.0.0.1", database.path == "/snaglist_app_store_platform_browser",
                  email.lowercased().hasSuffix("@example.test"), directory.hasPrefix("/") else {
                throw Abort(.serviceUnavailable, reason: "The local development mailbox is not isolated")
            }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func escaped(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
            let html = """
                <!doctype html><html lang="en"><meta charset="utf-8"><title>Snaglist local test mailbox</title>
                <body><h1>Local test email</h1><p>Synthetic recipient: \(escaped(email)). No email was delivered.</p>
                <p><a href="\(escaped(url))">Open the Snaglist sign-in or verification link</a></p>
                <p>Development only. This link expires after 15 minutes and is bound to the requesting browser/account.</p></body></html>
                """
            let file = folder.appendingPathComponent("latest.html")
            try Data(html.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return
        }
        #endif
        guard let key = Environment.get("RESEND_API_KEY"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Verification email delivery is not configured")
        }
        try await NotificationService.sendMagicSignInEmail(to: email, name: nil, magicLinkURL: url, client: req.client)
    }
}
