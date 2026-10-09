import Fluent
import FluentPostgresDriver
import Vapor
import JWT

/// Everything this process decides before it serves anything.
///
/// The two lookups are injected for one reason: the boot gates are the first
/// things here, and a test has to be able to drive one into a refusal — and then
/// check that no migration followed — without setting or unsetting a process
/// environment variable the rest of the suite shares. Every other read below is
/// still the process environment's own.
public func configure(_ app: Application,
                      privateStorageLookup: (String) -> String? = Environment.get,
                      signingSecretLookup: (String) -> String? = Environment.get) async throws {
    // MARK: - Server Configuration
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // MARK: - Logging
    app.logger.logLevel = .info

    // MARK: - Private object allocation and the deletion switch
    // Resolve both switches once, here, so a half-configured one is visible at
    // boot rather than as a surprise inside an upload, and so the first request
    // does not pay to parse configuration. Three states are refused outright and
    // the process does not start: a namespace that is set and unusable, account
    // deletion enabled with no namespace to fence into, and a production boot
    // with no namespace at all in a build that has no other private writer. The
    // reasons name the variable to fix and the state it was found in, and carry
    // no value of any kind. See `PrivateStorageBoot`.
    //
    // This is the first thing a boot decides, ahead of the database and its
    // migrations, and the order is the whole of "fail closed": a deployment that
    // is not allowed to start must do nothing at all. The gate used to run after
    // `autoMigrate()`, so a production boot with a missing or unusable namespace
    // applied every pending migration to the live database and only then refused
    // — a schema change made by a process that was never permitted to serve a
    // request. Nothing here needs a schema, or a database, or the network: it
    // reads the environment, records what it found, and returns.
    try PrivateStorageBoot.install(app: app, lookup: privateStorageLookup)

    // MARK: - Token signing
    // The second thing a boot decides, and for the same reason as the first: a
    // process that cannot sign a session cannot serve one, so it must do nothing
    // at all rather than migrate a live schema on its way to refusing. This used
    // to sit below `autoMigrate()` and refuse with `fatalError`, which is a trap
    // and not an exit — and `fatalError` never returns, so the `exit(1)` in
    // `Entrypoint`'s catch never ran either. It is moved, not changed: it reads
    // the same variable and refuses on the same condition. Nothing between here
    // and where it used to stand reads a signer — the span is `databases.use`,
    // the migration list and `autoMigrate()`, and no migration reads any
    // configuration at all — and nothing it needs runs after this point: it reads
    // the environment, installs an HS256 signer into application storage, and
    // returns. It names the variable and never its value. See `SigningSecretBoot`.
    try SigningSecretBoot.install(app: app, lookup: signingSecretLookup)

    // MARK: - The log-stream probe
    // Inert unless `LOG_STREAM_PROBE` carries a marker, and it carries one only
    // in a deliberate diagnostic run. It sits after the two boot gates and not
    // before them: those two are the first things a boot decides, and a test
    // holds them there by requiring that a refused boot has registered no
    // database at all. Nothing here touches a database, a store or the network —
    // it reads one variable, keeps it, and writes three lines on two streams. See
    // `LogStreamProbe` for what the three lines are and why there are three.
    try LogStreamProbe.install(app: app)

    // MARK: - Database Configuration
    if let databaseURL = Environment.get("DATABASE_URL"),
       var config = try? SQLPostgresConfiguration(url: databaseURL) {
        // Disable TLS for local/same-VPS Postgres (e.g. Docker internal network).
        // Default: TLS enabled (for managed/external databases).
        if Environment.get("DATABASE_TLS_DISABLE") == "true" {
            config.coreConfiguration.tls = .disable
        }
        // Pool size (wave 3): `DATABASE_MAX_CONNECTIONS`, total across event loops, 1...16.
        // Absent, exactly the previous pool: one connection per event loop.
        let pool = DatabasePool.settings(requested: Environment.get(DatabasePool.variable),
                                         eventLoops: DatabasePool.eventLoopCount(app.eventLoopGroup))
        if pool.invalid {
            app.logger.warning("\(DatabasePool.variable) is not a whole number from 1 to \(DatabasePool.ceiling); using one connection per event loop")
        }
        app.storage[DatabasePool.Key.self] = pool
        app.storage[RuntimeDiagnostics.BootKey.self] = Date()
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: pool.perEventLoop), as: .psql)

        // MARK: - Migrations
        app.migrations.add(CreateMagicLink())
        app.migrations.add(CreateMagicLinkAccess())
        app.migrations.add(CreateTeamInvite())
        app.migrations.add(CreateAuditLog())
        app.migrations.add(CreateRateLimitEntry())
        app.migrations.add(CreateCompletion())
        app.migrations.add(CreateCompletionPhoto())
        app.migrations.add(CreateUser())
        app.migrations.add(AddSlugToMagicLink())
        app.migrations.add(CreateSyncedReport())
        app.migrations.add(CreateSyncedPhoto())
        app.migrations.add(CreateSyncedDrawing())
        app.migrations.add(CreateDeviceToken())
        app.migrations.add(CreateProject())
        app.migrations.add(CreateSnag())
        app.migrations.add(CreateContractor())
        app.migrations.add(CreateTrade())
        app.migrations.add(CreateTeam())
        app.migrations.add(AddForeignKeysAndIndexes())
        app.migrations.add(AddThumbnailToSyncedPhoto())
        app.migrations.add(CreateAnalyticsEvent())
        // B1: Magic-link Project Manager authentication.
        app.migrations.add(AddAuthProviderToUsers())
        app.migrations.add(CreateMagicLinkAuthTokens())
        // B2: preview magic links.
        app.migrations.add(AddPreviewModeToMagicLinks())
        // B5: approvals workflow.
        app.migrations.add(CreateSnagSendBacks())
        // B4: tier counter + onboarding link tracking.
        app.migrations.add(AddOnboardingLinkConsumedToUsers())
        app.migrations.add(CreateMagicLinkSends())
        // B6: remote feature flags.
        app.migrations.add(CreateFeatureFlags())
        app.migrations.add(CreateSnagDeletion())
        app.migrations.add(CreateContentReport())
        app.migrations.add(AddSubscriptionVerification())
        app.migrations.add(CreatePlatformIdentity())
        app.migrations.add(CreateWorkspaceAccess())
        app.migrations.add(CreateCanonicalMutations())
        app.migrations.add(CreateRegisterSnapshots())
        app.migrations.add(CreateWorkspaceDirectory())
        app.migrations.add(CreateAssignmentHistory())
        app.migrations.add(CreateCanonicalValues())
        app.migrations.add(VersionProjectGrants())
        app.migrations.add(VersionInvitationGrants())
        app.migrations.add(CreatePrivateMedia())
        app.migrations.add(AddMediaSnapshotCoverage())
        app.migrations.add(CreateCanonicalWorkflow())
        app.migrations.add(AddChangeTransactionGroups())
        app.migrations.add(CreateContractorGrants())
        app.migrations.add(CreateGoogleIdentity())
        app.migrations.add(CreateProjectDiscoveryAndComments())
        app.migrations.add(CreateProjectMetadataParity())
        app.migrations.add(CreateCanonicalDrawings())
        app.migrations.add(CreateDrawingOriginalReceipts())
        app.migrations.add(CreateStagedLegacyImports())
        app.migrations.add(CreateStagedImportOriginalReceipts())
        app.migrations.add(CreateLegacyCanonicalProjections())
        app.migrations.add(CreateLegacyImportPublication())
        app.migrations.add(RelaxStagedLegacyImportSourceUniqueness())
        app.migrations.add(CreateAppleCredentials())
        app.migrations.add(CreateCleanupRuns())
        app.migrations.add(CreateImportProcessingAttempts())
        app.migrations.add(AllowReprocessingOpaqueImports())
        app.migrations.add(AllowFallbackCleanupTrigger())
        app.migrations.add(CreateAccountDeletionJobs())
        app.migrations.add(CreateAppleMultiClientCredentials())
        app.migrations.add(CreateAppleWebChallenges())
        app.migrations.add(CreateAppleWebCredentialEscrow())
        app.migrations.add(CreateAccountDeletionGraphErasure())
        app.migrations.add(CreateCompletionUploadObjects())
        app.migrations.add(CreateOwnershipTransferOffers())
        app.migrations.add(CreateEmptyCompanyClosure())
        app.migrations.add(CreateCountedCompanyClosure())
        app.migrations.add(CreateCompanyClosureGraphErasure())
        app.migrations.add(CreateObjectWriteIntents())
        app.migrations.add(CreateObjectErasureFences())
        app.migrations.add(BindMediaAssetKeysAtUpload())
        app.migrations.add(AddRevenueCatCustomerDeletion())
        app.migrations.add(CreateAppSessionRevocations())
        app.migrations.add(CreateIssuedReports())
        app.migrations.add(AddRetentionMaintenanceM1())
        app.migrations.add(CreateDiagnosticRequestFailures())
        app.migrations.add(AddUploadRetirements())
        app.migrations.add(ReKeyUploadRetirements())
        // 2.0.2 Apple ads measurement: one new table, nothing else touched (Sources/App/AdMeasurement).
        app.migrations.add(CreateAdAttributionRecords())
        // Replacement 2.0.1 measurement privacy boundary: consent, per-purpose subjects,
        // per-installation ATT assertions and durable provider erasure manifests.
        app.migrations.add(CreateMeasurementPrivacyState())
        // Authenticated device observations, product-event outbox and canonical Apple binding.
        app.migrations.add(CreateMeasurementRelayState())
        // Authenticated RevenueCat lifecycle facts and provider transport metadata.
        app.migrations.add(AddMeasurementLifecycleTransport())
        // RevenueCat event generation and subscription period start are distinct.
        app.migrations.add(SeparateRevenueCatEventTimes())
        // Provider-event ledger and bounded latest-period refund reconciliation.
        app.migrations.add(CreateRevenueCatLifecycleLedger())
        app.migrations.add(HardenRevenueCatLifecycleConflicts())
        app.migrations.add(AllowRevenueCatEventDispatch())
        // Optional purchase-callback witness and immutable acquisition installation.
        app.migrations.add(CreateMeasurementPurchaseOrigins())
        // Apple-only purchase attribution remains independent of ATT and cross-company consent.
        app.migrations.add(ScopeMeasurementPurchaseOrigins())
        // Exact cross-company purchase joins may enqueue LinkedIn with the same
        // originating installation authority used by the dispatch-time gate.
        app.migrations.add(AllowLinkedInPurchaseInstallation())
        // Provider deletion receipts must exist before the PostHog erasure worker
        // can resume a submitted request across process restarts.
        app.migrations.add(CreatePostHogErasureReceipts())
        // Optional pre-auth signup intents, one canonical signup fact per inserted
        // account and the dedicated `signupFact` outbox source.
        app.migrations.add(CreateMeasurementSignupIntents())

        try await app.autoMigrate()
    } else {
        app.logger.warning("DATABASE_URL not set, database features disabled")
    }

    // MARK: - Apple Sign In (JWKS-based verification)
    app.jwt.apple.applicationIdentifier = AuthController.appleApplicationIdentifier

    // MARK: - JSON Date Encoding
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // MARK: - CORS Configuration
    let cors = CORSMiddleware(configuration: .init(
        allowedOrigin: .any(["https://snaglist.dev", "https://www.snaglist.dev", "http://localhost:5173"]),
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.contentType, .authorization, .init("X-Session-Token")]
    ))

    // MARK: - Middleware
    // Replace defaults that log raw paths and error URLs (legacy links carry tokens).
    app.middleware = .init()
    app.middleware.use(PrivateRequestLoggingMiddleware())
    // CORS must be added before other middleware
    app.middleware.use(cors, at: .beginning)

    // File middleware for serving uploaded photos (only needed when using local storage)
    if StorageService.backend == .local {
        app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    }

    // MARK: - Routes
    try routes(app)

    // MARK: - Scheduled Tasks
    CleanupService.scheduleCleanup(app: app)

    app.logger.info("Snaglist Backend configured successfully")
}
