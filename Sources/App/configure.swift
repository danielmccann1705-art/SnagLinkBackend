import Fluent
import FluentPostgresDriver
import Vapor
import JWT

public func configure(_ app: Application) async throws {
    // MARK: - Server Configuration
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // MARK: - Database Configuration
    if let databaseURL = Environment.get("DATABASE_URL"),
       var config = try? SQLPostgresConfiguration(url: databaseURL) {
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config), as: .psql)

        // MARK: - Migrations
        app.migrations.add(CreateMagicLink())
        app.migrations.add(CreateMagicLinkAccess())
        app.migrations.add(CreateTeamInvite())
        app.migrations.add(CreateAuditLog())
        app.migrations.add(CreateRateLimitEntry())

        try await app.autoMigrate()
    } else {
        app.logger.warning("DATABASE_URL not set, database features disabled")
    }

    // MARK: - JWT Configuration
    let jwtSecret = Environment.get("JWT_SECRET") ?? "development-secret-key-change-me!!"
    app.jwt.signers.use(.hs256(key: jwtSecret))

    // MARK: - Middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // MARK: - Routes
    try routes(app)

    app.logger.info("Snaglist Backend configured successfully")
}
