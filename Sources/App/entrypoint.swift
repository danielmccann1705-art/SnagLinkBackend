import Vapor
import Logging

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }

        app.logger.info("Starting server execution...")

        do {
            try await app.execute()
        } catch {
            app.logger.error("Server execution failed: \(error)")
            try? await app.asyncShutdown()
            // Exit gracefully instead of throwing, which can trigger SIGILL
            exit(1)
        }

        try await app.asyncShutdown()
    }
}
