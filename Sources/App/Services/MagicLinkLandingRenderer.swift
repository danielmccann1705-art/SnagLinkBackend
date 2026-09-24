import Foundation

/// Renders the fallback landing page for `https://snaglist.dev/auth/{token}` (B1).
///
/// Reached only when the universal link did NOT open the Snaglist app directly (app not
/// installed, the link opened in a browser, or on a computer). Never verifies the token
/// and never receives it: nothing on this page can sign anyone in, so the page says so
/// and names the two things that do work: tapping the link in Mail on the iPhone where
/// Snaglist is installed, or requesting a new link from the app.
///
/// There used to be an "Open Snaglist" button to `snaglist://auth/<token>`. It opened the
/// app, which then could not sign in: the app accepts sign-in links only as https links
/// on api.snaglist.dev and snaglist.dev. It also put the token into the page. Neither is
/// here any more, and the renderer takes no token, so it cannot echo one.
enum MagicLinkLandingRenderer {
    static let expiryNote = "Each sign-in link works once and expires 15 minutes after it was sent."

    static func render(isIOS: Bool) -> String {
        let body: String

        if isIOS {
            body = """
                <h1>Open this link in the Snaglist app</h1>
                <p>This sign-in link opened in a browser, so it can’t sign you in here. Snaglist sign-in finishes in the app.</p>
                <p>On the iPhone where Snaglist is installed, open the email in Mail and tap the sign-in link there.</p>
                <p>Or open Snaglist and request a new sign-in link.</p>
                <p class="muted">\(expiryNote)</p>
                """
        } else {
            body = """
                <h1>Open this link on your iPhone</h1>
                <p>Snaglist sign-in finishes in the iPhone app, so this link can’t sign you in on this device.</p>
                <p>On the iPhone where Snaglist is installed, open the email in Mail and tap the sign-in link there.</p>
                <p>Or open Snaglist on that iPhone and request a new sign-in link.</p>
                <p class="muted">\(expiryNote)</p>
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
