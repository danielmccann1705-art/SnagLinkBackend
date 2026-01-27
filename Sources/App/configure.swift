import Fluent
import FluentPostgresDriver
import Vapor
import JWT

public func configure(_ app: Application) async throws {
    // MARK: - Server Configuration
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // MARK: - Database Configuration
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else {
        // Local development fallback
        let dbHost = Environment.get("DB_HOST") ?? "localhost"
        let dbPort = Environment.get("DB_PORT").flatMap(Int.init) ?? 5432
        let dbUser = Environment.get("DB_USER") ?? "postgres"
        let dbPass = Environment.get("DB_PASSWORD") ?? "password"
        let dbName = Environment.get("DB_NAME") ?? "snaglink"

        app.databases.use(
            .postgres(
                hostname: dbHost,
                port: dbPort,
                username: dbUser,
                password: dbPass,
                database: dbName
            ),
            as: .psql
        )
    }

    // MARK: - JWT Configuration
    let jwtSecret = Environment.get("JWT_SECRET") ?? "development-secret-key-change-me!!"
    if Environment.get("JWT_SECRET") == nil {
        app.logger.warning("JWT_SECRET not set, using default (NOT SECURE FOR PRODUCTION)")
    }
    app.jwt.signers.use(.hs256(key: jwtSecret))

    try await configureRest(app)
}

private func configureRest(_ app: Application) async throws {
    // MARK: - Migrations
    app.migrations.add(CreateMagicLink())
    app.migrations.add(CreateMagicLinkAccess())
    app.migrations.add(CreateTeamInvite())
    app.migrations.add(CreateAuditLog())
    app.migrations.add(CreateRateLimitEntry())

    // Auto-migrate database tables
    try await app.autoMigrate()

    // MARK: - Middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // CORS configuration
    let corsConfig = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
        allowedHeaders: [
            .accept,
            .authorization,
            .contentType,
            .origin,
            .xRequestedWith,
            .init("X-API-Key")
        ],
        allowCredentials: true
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfig))

    // MARK: - Logging
    app.logger.logLevel = Environment.get("LOG_LEVEL").flatMap { Logger.Level(rawValue: $0) } ?? .info

    // MARK: - Routes
    try routes(app)

    app.logger.info("SnagLink Backend configured successfully")
}
