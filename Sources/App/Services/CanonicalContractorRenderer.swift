import Vapor

extension WebReportRenderer {
    /// The existing /m/:slug route dispatches the new canonical grant surface.
    /// No project or photo data is embedded before the live PIN/access check.
    static func renderCanonicalContractor() -> String {
        // Content-derived URLs prevent a cached stylesheet/script from surviving
        // an incremental deployment. Fonts retain stable, separately cached URLs.
        let bytes = ["tokens.css", "contractor.css", "contractor.js"].reduce(into: Data()) { data, name in
            if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Contractor"), let contents = try? Data(contentsOf: url) { data.append(contents) }
        }
        let version = String(PrivateImageProcessor.digest(bytes).prefix(16))
        return """
        <!doctype html><html lang="en-GB"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow">
        <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'">
        <title>Contractor link · Snaglist</title>
        <link rel="stylesheet" href="/assets/contractor/v2/tokens.css?v=\(version)"><link rel="stylesheet" href="/assets/contractor/v2/contractor.css?v=\(version)">
        <script src="/assets/contractor/v2/contractor.js?v=\(version)" defer></script></head><body>
        <header class="brand-bar"><img src="/assets/contractor/v2/wordmark-light.svg" alt="Snaglist" width="126" height="54"><span>Contractor link</span></header>
        <main id="content" tabindex="-1"><div class="loading" role="status">Loading your snag list…</div></main>
        <footer class="page-footer">Spot it. Fix it. Sign it off.</footer>
        <dialog id="photo-viewer" aria-label="Enlarged evidence photo"><button class="secondary close-photo" type="button">Close photo</button><img alt=""></dialog>
        <noscript><p>Enable JavaScript to view the current snag list and submit evidence.</p></noscript>
        </body></html>
        """
    }
}
