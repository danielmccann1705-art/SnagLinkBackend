import Vapor

/// The published policy and terms, which live on the customer website.
///
/// Kept as one named place so the destinations cannot drift apart from the URLs
/// the app compiles in (`AppConfiguration.Web`) or from the Privacy Policy URL in
/// App Store Connect. `snaglist.dev/privacy` and `/terms` already redirect here;
/// these send people to the same destination without the extra hop.
enum LegalPageRedirect {
    static let privacyURL = "https://usesnaglist.com/privacy"
    static let termsURL = "https://usesnaglist.com/terms"

    static var privacy: Response { permanent(to: privacyURL) }
    static var terms: Response { permanent(to: termsURL) }

    private static func permanent(to location: String) -> Response {
        Response(status: .movedPermanently, headers: ["Location": location, "Cache-Control": "public, max-age=3600"])
    }
}
