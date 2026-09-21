import Vapor
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum Entrypoint {
    static func main() async throws {
        // Nothing here may throw out of `main`. An error thrown out of an async
        // `main` is not an exit: the runtime reports `Fatal error: Error raised
        // at top level` and traps, and a caught trap leaves the process alive —
        // a container that is up and never healthy, which is the failure D5 was
        // about. These first three steps run before `LoggingSystem.bootstrap`
        // has given us anywhere to log, so they say what happened on standard
        // error — the stream the console logger writes to once it exists — and
        // exit non-zero themselves.
        var env: Environment
        do { env = try Environment.detect() }
        catch { refuseBeforeLogging("the command line could not be read", error) }

        do { try LoggingSystem.bootstrap(from: &env) }
        catch { refuseBeforeLogging("logging could not be configured from the command line", error) }

        let app: Application
        do { app = try await Application.make(env) }
        catch { refuseBeforeLogging("the application could not be created", error) }

        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            // Exit gracefully instead of throwing, which can trigger SIGILL.
            // An error thrown out of an async `main` is not an exit: the runtime
            // reports `Fatal error: Error raised at top level` and traps on an
            // illegal instruction, and the crash handler that catches the trap
            // keeps the process alive rather than ending it. A refused boot that
            // never leaves is a container that is up and never healthy, and a
            // deploy poll that spins to its limit with no cause to read. The
            // refusal has already been logged, at critical, by whoever made it.
            //
            // Shut down what a partly-finished `configure` may have installed, in
            // the order `execute`'s catch below uses. Today a boot refusal
            // installs none of these, because both gates run before anything is
            // installed — but `configure` can also fail after them, at `routes`
            // or at anything added later, and by then the fence provider and the
            // content store are live and this catch was the one path that left
            // them running. The two catches are the same list for that reason:
            // which of them is a no-op is a fact about today's `configure`, not
            // something either catch should have to know.
            await AccountDeletionFenceProvider.shutdown(app: app)
            await PrivateContentStoreProvider.shutdown(app: app)
            try? await StorageService.shutdown()
            try? await app.asyncShutdown()
            exit(1)
        }

        app.logger.info("Starting server execution...")

        do {
            try await app.execute()
        } catch {
            app.logger.error("Server execution failed: \(error)")
            await AccountDeletionFenceProvider.shutdown(app: app)
            await PrivateContentStoreProvider.shutdown(app: app)
            try? await StorageService.shutdown()
            try? await app.asyncShutdown()
            // Exit gracefully instead of throwing, which can trigger SIGILL
            exit(1)
        }

        await AccountDeletionFenceProvider.shutdown(app: app)
        await PrivateContentStoreProvider.shutdown(app: app)
        try? await StorageService.shutdown()
        try await app.asyncShutdown()
    }

    /// A failure before `LoggingSystem.bootstrap` has nowhere to log: there is no
    /// `Logger` yet and no `Application` to carry one. Standard error is where the
    /// console logger will write once it exists, so write there, and end by
    /// exiting rather than by throwing — for exactly the reason the catch above
    /// exits.
    ///
    /// All three callers fail on the command line and nothing else:
    /// `Environment.detect` and `LoggingSystem.bootstrap(from:)` parse arguments,
    /// and `Application.make` fails on resources. None of them reads an
    /// environment variable, so the error's own description carries no configured
    /// value — and `what` is a fixed sentence chosen here, not interpolated from
    /// anything read.
    private static func refuseBeforeLogging(_ what: String, _ error: any Error) -> Never {
        fputs("Boot failed before logging was configured: \(what): \(error)\n", stderr)
        exit(1)
    }
}
