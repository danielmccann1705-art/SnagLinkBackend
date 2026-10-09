import Vapor
import Crypto

/// The optional-measurement notice (`outputs/measurement-2026-10-07/FINAL-PRIVACY-NOTICE-2.0.1.md`).
///
/// A version names one exact wording for every surface that presents the three optional choices
/// (the native sign-in screen, Settings > Privacy choices and the web portal) and therefore the
/// providers and data flows a grant recorded under it covers. Wording never changes under a
/// version: any change needs a new version here, in the app and in the portal, and
/// `MeasurementNoticeTests` pins each version's text hash. A grant is never broadened: what an
/// older version (or a revision recorded with no version) covers stays exactly what it covered.
enum MeasurementNotice {
    /// Replacement 2.0.1: PostHog EU (product analytics, the person's own actions in the app and the
    /// web portal), Apple through our server (Apple Ads) and LinkedIn server conversions (other
    /// adverts). Names neither Singular nor Meta: both are blocked in code in that binary.
    static let current = "measurement-notice-2026-10a"
    /// The alternative wording for a Singular-enabled candidate, to be used only if Dan unblocks
    /// Singular. Accepted by no route and wired to nothing.
    static let singularAlternative = "measurement-notice-2026-10b-singular"
    /// The unapproved pre-auth draft (`NATIVE-SIGNUP-OCT9.md`). Kept accepted on the issue route for
    /// historical revisions; app-only product coverage, never Singular.
    static let signupDraft = "signup-measurement-v1"

    /// Versions a pre-auth signup intent may be issued under.
    static let signupIssueAccepted: Set<String> = [signupDraft, current]
    /// Versions the settings consent route records. A request without a version is a historical
    /// client and is recorded with none (app-only coverage).
    static let settingsAccepted: Set<String> = [current]
    /// Versions whose product-analytics grant covers the person's own actions in the web portal.
    /// Counting them still needs `portalProductAnalyticsEnabled`.
    static let portalCovering: Set<String> = [current, singularAlternative]
    /// Versions whose cross-company grant covers Singular (and Meta through it). None is accepted:
    /// no grant recorded today can ever be treated as covering Singular.
    static let singularCovering: Set<String> = [singularAlternative]

    static func coversPortal(_ version: String?) -> Bool { version.map(portalCovering.contains) ?? false }
    static func coversSingular(_ version: String?) -> Bool { version.map(singularCovering.contains) ?? false }

    /// SQL predicate: the `measurement_permission_current` row aliased `alias` was recorded under a
    /// portal-covering version. Versions are compile-time constants (`[a-z0-9-]`, pinned by test).
    static func revisionCoversPortal(_ alias: String) -> String {
        let versions = portalCovering.sorted().map { "'\($0)'" }.joined(separator: ",")
        return "EXISTS(SELECT 1 FROM measurement_consent_events notice WHERE notice.account_id=\(alias).account_id " +
            "AND notice.id=\(alias).revision AND notice.notice_version IN (\(versions)))"
    }

    // MARK: - Exact wording

    struct Entry: Sendable, Equatable {
        let key: String
        let text: String
        init(_ key: String, _ text: String) { self.key = key; self.text = text }
    }

    /// `key<TAB>text<LF>` per entry, in order, UTF-8. The app builds the same document from the
    /// strings it actually displays; both pin the same SHA-256.
    static func canonical(_ entries: [Entry]) -> String {
        entries.map { "\($0.key)\t\($0.text)\n" }.joined()
    }

    static func textSHA256(_ version: String) -> String? {
        guard let entries = entries(version) else { return nil }
        return SHA256.hash(data: Data(canonical(entries).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func entries(_ version: String) -> [Entry]? {
        switch version {
        case current: return shared(crossCompany: currentCrossCompany) + surfaces
        case singularAlternative: return shared(crossCompany: singularCrossCompany) + surfaces
        case signupDraft: return draft
        default: return nil
        }
    }

    private static let currentCrossCompany = [
        "When you create your account or make a verified Pro subscription payment, our server tells LinkedIn, so we can see which LinkedIn adverts work.",
        "LinkedIn receives a hashed copy of your verified email address and, for a payment, its amount. Addresses from Apple’s Hide My Email are never sent.",
        "This also needs permission in Apple’s tracking settings. You can use Snaglist without allowing it."
    ]

    private static let singularCrossCompany = [
        "Use Singular to measure which adverts, including Meta adverts, led to your download. Singular uses this iPhone’s advertising identifier.",
        "When you create your account or make a verified Pro subscription payment, our server tells Singular, which can share it with Meta, and LinkedIn.",
        "LinkedIn receives a hashed copy of your verified email address and, for a payment, its amount. Addresses from Apple’s Hide My Email are never sent.",
        "This also needs permission in Apple’s tracking settings. You can use Snaglist without allowing it."
    ]

    private static func shared(crossCompany: [String]) -> [Entry] {
        var entries = [
            Entry("shared.intro.heading", "You decide what Snaglist measures."),
            Entry("shared.intro.body", "Your projects, photos, snag descriptions and contractor details are never included in optional analytics."),
            Entry("shared.intro.scope", "These choices are about you only. They never cover your company, team members or contractors."),
            Entry("purpose.productAnalytics.title", "Improve Snaglist"),
            Entry("purpose.productAnalytics.1", "Share selected actions, such as signing in, opening the Pro screen or issuing a report, with PostHog in the EU."),
            Entry("purpose.productAnalytics.2", "It covers only what you do while signed in to your account, in the Snaglist app and web portal, including your Pro subscription payments, refunds and cancellations."),
            Entry("purpose.productAnalytics.3", "This helps us see where people get stuck. No session recordings or screen contents are collected."),
            Entry("purpose.appleAds.title", "Measure Apple Ads"),
            Entry("purpose.appleAds.1", "Ask Apple, through our server, whether one of our App Store adverts led to your download."),
            Entry("purpose.appleAds.2", "We keep the campaign result with your account to understand which adverts lead to subscriptions."),
            Entry("purpose.appleAds.3", "This choice does not allow tracking across other companies’ apps or websites."),
            Entry("purpose.crossCompanyAds.title", "Measure other adverts")
        ]
        for (index, line) in crossCompany.enumerated() { entries.append(Entry("purpose.crossCompanyAds.\(index + 1)", line)) }
        return entries
    }

    /// State lines, then each surface's own wording. Shared by 10a and 10b.
    private static let surfaces = [
        Entry("state.crossCompany.trackingOff", "Chosen · not active because Apple’s tracking permission is off"),
        Entry("state.crossCompany.trackingRestricted", "Chosen · not active because tracking is restricted on this device"),
        Entry("state.crossCompany.trackingNotAsked", "Chosen · not active until you allow tracking on this device"),
        Entry("state.crossCompany.confirmationNeeded", "Chosen · not active · tracking was off when you made this choice"),
        Entry("state.crossCompany.openSettings", "Open Settings"),
        Entry("state.crossCompany.openSettingsHint", "Opens Snaglist in the Settings app, where you can allow tracking"),
        Entry("state.crossCompany.allowTracking", "Allow tracking"),
        Entry("state.crossCompany.allowTrackingHint", "Asks for Apple’s tracking permission for this choice"),
        Entry("state.crossCompany.turnOnAgain", "Turn on again"),
        Entry("state.crossCompany.turnOnAgainHint", "Makes this choice again now that tracking is allowed"),
        Entry("state.crossCompany.summaryInactive", "Measure other adverts is chosen but not active."),
        Entry("state.withdrawalPending", "Off on this device · withdrawal waiting to sync"),
        Entry("state.erasurePending", "Off · provider deletion pending"),
        Entry("state.inactive", "Choice saved · measurement is not active"),
        Entry("signin.heading", "Optional privacy choices"),
        Entry("signin.summaryOff", "All off. You can sign in without turning any on."),
        Entry("signin.summaryOn", "On for this sign-in: {titles}."),
        Entry("signin.review", "Review choices"),
        Entry("signin.hide", "Hide choices"),
        Entry("signin.scope", "These choices are off unless you turn them on. They are used only if this sign-in creates a new Snaglist account. If you already have an account, sign in and use Privacy choices in Settings instead."),
        Entry("signin.withdraw", "After you sign in, you can change or withdraw any choice at any time in Settings, under Privacy choices."),
        Entry("signin.skip", "Skip"),
        Entry("signin.skipHint", "Keeps every optional choice off"),
        Entry("settings.title", "Privacy choices"),
        Entry("settings.signedOut.1", "Sign in to manage these choices for your account."),
        Entry("settings.signedOut.2", "Activity while you are signed out is not sent to our analytics or advertising providers."),
        Entry("settings.refresh", "Refresh privacy choices"),
        Entry("settings.withdraw", "You can change or withdraw any choice at any time on this screen."),
        Entry("settings.deviceStop", "Turning a choice off stops that measurement on this device immediately."),
        Entry("settings.offline", "If you are offline, keep this account signed in so the withdrawal can reach the server."),
        Entry("settings.providerDeletion", "Provider deletion may take longer and is shown as pending until confirmed."),
        Entry("settings.policy", "Read our privacy policy"),
        Entry("portal.title", "Privacy choices"),
        Entry("portal.withdraw", "You can change or withdraw any choice at any time here, or in the Snaglist app in Settings, under Privacy choices."),
        Entry("portal.appOnly", "Measure Apple Ads and Measure other adverts can be turned on only in the Snaglist iPhone app. You can turn them off here."),
        Entry("portal.earlierNotice", "You made this choice under an earlier notice that covered only the app, so your actions in the web portal are not included. Turn it on again here to include them."),
        Entry("portal.crossCompanyState", "Chosen · active only on an iPhone where tracking is allowed for this choice")
    ]

    /// `signup-measurement-v1` as the app at `572154d` displayed it before sign-in. Historical only.
    private static let draft = [
        Entry("shared.intro.heading", "You decide what Snaglist measures."),
        Entry("shared.intro.body", "Your projects, photos, snag descriptions and contractor details are never included in optional analytics."),
        Entry("purpose.productAnalytics.title", "Improve Snaglist"),
        Entry("purpose.productAnalytics.1", "Share selected actions, such as opening the Pro screen, with PostHog in the EU."),
        Entry("purpose.productAnalytics.2", "This helps us see where people get stuck. No session recordings or screen contents are collected."),
        Entry("purpose.appleAds.title", "Measure Apple Ads"),
        Entry("purpose.appleAds.1", "Ask Apple whether one of our App Store adverts led to your download."),
        Entry("purpose.appleAds.2", "We use the campaign result to understand our advertising."),
        Entry("purpose.appleAds.3", "This choice does not allow tracking across other companies’ apps or websites."),
        Entry("purpose.crossCompanyAds.title", "Measure other adverts"),
        Entry("purpose.crossCompanyAds.1", "Use Singular to measure adverts, including Meta."),
        Entry("purpose.crossCompanyAds.2", "Share eligible sign-up and verified subscription events with advertising partners, including LinkedIn."),
        Entry("purpose.crossCompanyAds.3", "This also needs permission in Apple’s tracking settings. You can use Snaglist without allowing it."),
        Entry("signin.heading", "Optional privacy choices"),
        Entry("signin.summaryOff", "All off. You can sign in without turning any on."),
        Entry("signin.summaryOn", "On for this sign-in: {titles}."),
        Entry("signin.review", "Review choices"),
        Entry("signin.hide", "Hide choices"),
        Entry("signin.scope", "These choices are off unless you turn them on. They are used only if this sign-in creates a new Snaglist account. If you already have an account, sign in and use Privacy choices in Settings instead."),
        Entry("signin.skip", "Skip"),
        Entry("signin.skipHint", "Keeps every optional choice off")
    ]
}

/// Where an authenticated request came from: the native app's bearer session or the web portal's
/// cookie session. Portal-surface product events need a portal-covering notice and the portal switch.
enum MeasurementSurface: String, Sendable, Equatable {
    case app, web

    /// A bearer session is the app; a cookie session is the portal. Anything else is treated as the
    /// portal, the gated surface, so an unknown credential never escapes the portal rule.
    init(_ req: Request) {
        if req.auth.get(UserJWTPayload.self) != nil { self = .app }
        else { self = .web }
    }
}
