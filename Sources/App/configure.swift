import Fluent
import FluentPostgresDriver
import Vapor
import JWT

public func configure(_ app: Application) async throws {
    // MARK: - Server Configuration
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // MARK: - Logging
    app.logger.logLevel = .info

    // MARK: - Database Configuration
    if let databaseURL = Environment.get("DATABASE_URL"),
       var config = try? SQLPostgresConfiguration(url: databaseURL) {
        // Disable TLS for local/same-VPS Postgres (e.g. Docker internal network).
        // Default: TLS enabled (for managed/external databases).
        if Environment.get("DATABASE_TLS_DISABLE") == "true" {
            config.coreConfiguration.tls = .disable
        }
        app.databases.use(.postgres(configuration: config), as: .psql)

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

        try await app.autoMigrate()
    } else {
        app.logger.warning("DATABASE_URL not set, database features disabled")
    }

    // MARK: - JWT Configuration
    guard let jwtSecret = Environment.get("JWT_SECRET") else {
        app.logger.critical("JWT_SECRET environment variable is required")
        fatalError("JWT_SECRET must be set")
    }
    app.jwt.signers.use(.hs256(key: jwtSecret))

    // MARK: - Apple Sign In (JWKS-based verification)
    if let appleAppId = Environment.get("APPLE_APP_ID") {
        app.jwt.apple.applicationIdentifier = appleAppId
    }

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
    // CORS must be added before other middleware
    app.middleware.use(cors, at: .beginning)
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // File middleware for serving uploaded photos (only needed when using local storage)
    if StorageService.backend == .local {
        app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    }

    // MARK: - Routes
    try routes(app)

    app.logger.info("Snaglist Backend configured successfully")
}
