import Foundation

/// Renders the fallback landing page for `https://snaglist.dev/auth/{token}` (B1).
///
/// Reached only when the universal link did NOT open the Snaglist app directly (app not
/// installed, or opened in a desktop browser). Never verifies the token — purely informational,
/// with a best-effort custom-scheme button on iOS to hand the token to the app.
enum MagicLinkLandingRenderer {
    static func render(token: String, isIOS: Bool) -> String {
        let safeToken = token.htmlEscaped
        let body: String

        if isIOS {
            body = """
                <h1>Almost there</h1>
                <p>Tap the button below to finish signing in to Snaglist.</p>
                <a class="btn" href="snaglist://auth/\(safeToken)">Open Snaglist</a>
                <p class="muted">If nothing happens, make sure the Snaglist app is installed on this iPhone, then tap the sign-in link in your email again.</p>
                <p class="muted">This link expires 15 minutes after it was sent and can only be used once.</p>
                """
        } else {
            body = """
                <h1>Open Snaglist on your iPhone</h1>
                <p>This sign-in link recognised — but Snaglist sign-in completes on your iPhone.</p>
                <p class="muted">Open this email on the iPhone that has the Snaglist app installed, then tap the sign-in link again.</p>
                <p class="muted">This link expires 15 minutes after it was sent and can only be used once.</p>
                """
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="robots" content="noindex, nofollow">
            <title>Sign in to Snaglist</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; background: #f7f1de; color: #0b1833; margin: 0; padding: 40px 20px; display: flex; justify-content: center; }
                .card { background: #fff; border: 1px solid rgba(11,24,51,0.165); border-radius: 12px; padding: 32px; max-width: 420px; width: 100%; box-shadow: 2px 2px 0 #0b1833; }
                h1 { font-size: 22px; margin: 0 0 12px; }
                p { line-height: 1.55; margin: 0 0 14px; }
                .muted { color: #5a6378; font-size: 14px; }
                .btn { display: inline-block; background: #168aad; color: #fff; padding: 14px 28px; border-radius: 8px; text-decoration: none; font-weight: 600; margin: 8px 0 18px; }
            </style>
        </head>
        <body>
            <div class="card">
                \(body)
            </div>
        </body>
        </html>
        """
    }
}
