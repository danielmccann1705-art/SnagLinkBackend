import XCTVapor
@testable import App
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// D5. The fail-closed boot, and the two ways it did not close.
///
/// D1 gave the boot three refusals and they all fire. What the migration
/// rehearsal found is that firing was all they did: the refusal was thrown out of
/// an async `main`, where it is a trap rather than an exit, and it was thrown
/// after `autoMigrate()` had already written to the database. A deployment that
/// was never allowed to start migrated the schema and then stayed up.
///
/// Nothing here turns anything on. Every value below is synthetic, handed to one
/// function or one short-lived child process, and no environment variable is set
/// in this process or left behind by it.
final class BootGateOrderingTests: XCTestCase {

    /// A private-storage configuration whose account id is not an account id.
    /// Complete in every other particular, so the refusal it produces is
    /// `namespaceUnusable` and not a missing variable — and so it refuses in
    /// every environment, including `.testing`.
    private var unusable: [String: String] { [
        "R2_PRIVATE_NAMESPACE": "private-v1/",
        "R2_ACCOUNT_ID": "not-hex",
        "R2_PRIVATE_BUCKET_NAME": "synthetic-private",
        "R2_ACCESS_KEY_ID": "synthetic-key",
        "R2_SECRET_ACCESS_KEY": "synthetic-secret",
    ] }

    // MARK: - D5-2: a refused boot changes no schema

    /// The gate is the first thing `configure` does, and this is the assertion
    /// that holds it there. A boot that refused has not registered a database at
    /// all, so there is nothing `autoMigrate()` could have been called on: not a
    /// migration it chose to skip, but no database to migrate.
    ///
    /// Put the two calls back in their old order and this fails immediately —
    /// `configure` reaches `app.databases.use(...)` and `autoMigrate()` long
    /// before it reaches the refusal, and `ids()` comes back with `.psql` in it.
    func testARefusedBootRegistersNoDatabaseAndSoRunsNoMigration() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil,
                          "Requires a DATABASE_URL: with none, configure registers no database either way")
        let values = unusable
        let app = try await Application.make(.testing)
        var refused: (any Error)?
        do { try await configure(app, privateStorageLookup: { values[$0] }) } catch { refused = error }
        XCTAssertEqual(refused as? PrivateStorageBoot.Refusal, .namespaceUnusable,
                       "the boot must refuse before anything else it does can matter")
        XCTAssertTrue(app.databases.ids().isEmpty,
                      "a refused boot reached the database; a migration is the next line after that")
        try await app.asyncShutdown()
    }

    /// And the same boot with a usable namespace does reach the database, so the
    /// assertion above is measuring the refusal and not measuring nothing.
    func testAnAcceptedBootStillReachesTheDatabase() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil, "Requires an isolated PostgreSQL DATABASE_URL")
        var values = unusable
        values["R2_ACCOUNT_ID"] = String(repeating: "a", count: 32)
        let app = try await Application.make(.testing)
        do { try await configure(app, privateStorageLookup: { values[$0] }) }
        catch { try await app.asyncShutdown(); throw error }
        XCTAssertFalse(app.databases.ids().isEmpty, "an accepted boot configures the database as it always did")
        try await app.asyncShutdown()
    }

    // MARK: - D5-1: a refused boot leaves

    /// Observed in the rehearsal: the refusal logged, the process trapped at
    /// `Fatal error: Error raised at top level`, and the container was still
    /// running at forty-five seconds. So run the built server the way a container
    /// runs it and require that it goes — by its own exit, with a non-zero
    /// status, which is the only ending a deploy can read as a failure.
    ///
    /// Restore `throw error` in `Entrypoint` and this fails whichever shape the
    /// platform gives it: a trap is `uncaughtSignal` and not an exit, and a trap
    /// that a backtrace handler catches never ends at all.
    func testARefusedBootExitsNonZeroInsteadOfStayingUp() throws {
        guard let server = Self.builtServer else {
            throw XCTSkip("Requires the App product built beside the test bundle (swift build --product App)")
        }
        let process = Process()
        process.executableURL = server
        process.arguments = ["serve", "--env", "production"]
        // A deliberately unusable namespace and nothing else: no DATABASE_URL, so
        // this child has no database to reach even if it wanted one.
        var environment = unusable
        environment["PATH"] = "/usr/bin:/bin"
        environment["TMPDIR"] = NSTemporaryDirectory()
        environment["JWT_SECRET"] = "synthetic-test-only-never-a-deployed-key"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = NSMutableData()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); collected.append(data); lock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let stillRunning = process.isRunning
        if stillRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < hardDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let output = String(decoding: collected as Data, as: UTF8.self); lock.unlock()

        XCTAssertFalse(stillRunning, "a refused boot was still running after thirty seconds")
        guard !stillRunning else { return }
        XCTAssertEqual(process.terminationReason, .exit,
                       "a refusal must end by exiting; a signal is a crash, which is not a boot decision")
        XCTAssertNotEqual(process.terminationStatus, 0, "a refused boot must leave a non-zero status behind")
        XCTAssertTrue(output.contains("Boot refused:"), "the refusal must still be logged before the exit")
        XCTAssertTrue(output.contains("private_namespace_unusable"), "the refusal must still carry its code")
        XCTAssertFalse(output.contains("Error raised at top level"),
                       "the refusal reached the top level as an error instead of exiting")
        for value in unusable.values {
            XCTAssertFalse(output.contains(value), "a refusal names variables and never a configured value")
        }
    }

    // MARK: - D5.1: the second refusal, the one D5 left

    /// D5 fixed the private-storage refusals and reported that `JWT_SECRET` still
    /// had both defects: it stood after `autoMigrate()`, and it refused with
    /// `fatalError`, which traps — and, because `fatalError` never returns, the
    /// `exit(1)` D5 put in `Entrypoint` was never reached by it at all. A
    /// production boot with a namespace and no signing secret migrated the whole
    /// database and then hung, exactly as the private-storage case had.
    ///
    /// This is the schema half. A namespace lookup that finds nothing is accepted
    /// in `.testing`, so the first gate passes and the one under test is what
    /// refuses; a boot that refuses there has registered no database, so there is
    /// nothing `autoMigrate()` could have been called on.
    ///
    /// Put `SigningSecretBoot.install` back below `autoMigrate()` and this fails
    /// immediately — `configure` reaches `app.databases.use(...)` and the whole
    /// migration list long before it reaches the refusal, and `ids()` comes back
    /// with `.psql` in it.
    func testAMissingSigningSecretRegistersNoDatabaseAndSoRunsNoMigration() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil,
                          "Requires a DATABASE_URL: with none, configure registers no database either way")
        let app = try await Application.make(.testing)
        var refused: (any Error)?
        do {
            try await configure(app, privateStorageLookup: { _ in nil }, signingSecretLookup: { _ in nil })
        } catch { refused = error }
        XCTAssertEqual(refused as? SigningSecretBoot.Refusal, .jwtSecretAbsent,
                       "a boot with no signing secret must refuse, and refuse by that name")
        XCTAssertTrue(app.databases.ids().isEmpty,
                      "a refused boot reached the database; a migration is the next line after that")
        try await app.asyncShutdown()
    }

    /// And the same boot with a secret does reach the database, so the assertion
    /// above is measuring the refusal and not measuring nothing. The value is
    /// handed to one function in this process and never to an environment.
    func testABootWithASigningSecretStillReachesTheDatabase() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil, "Requires an isolated PostgreSQL DATABASE_URL")
        let app = try await Application.make(.testing)
        do {
            try await configure(app, privateStorageLookup: { _ in nil },
                                signingSecretLookup: { $0 == "JWT_SECRET" ? "synthetic-test-only-never-deployed" : nil })
        } catch { try await app.asyncShutdown(); throw error }
        XCTAssertFalse(app.databases.ids().isEmpty, "an accepted boot configures the database as it always did")
        try await app.asyncShutdown()
    }

    /// The exit half, run the way a container runs it. Before the fix this logged
    /// `JWT_SECRET environment variable is required` and then died on
    /// `Fatal error: JWT_SECRET must be set` — a trap, which is a signal and not
    /// an exit, and which the backtrace handler can leave running indefinitely.
    ///
    /// Development is the cheapest environment that reaches this gate: an absent
    /// namespace is accepted outside production, so the first gate passes and no
    /// private-storage variable has to be set in this child at all. Restore the
    /// `fatalError` and this fails whichever shape the platform gives it.
    func testAMissingSigningSecretExitsNonZeroInsteadOfTrapping() throws {
        guard let server = Self.builtServer else {
            throw XCTSkip("Requires the App product built beside the test bundle (swift build --product App)")
        }
        let process = Process()
        process.executableURL = server
        process.arguments = ["serve", "--env", "development"]
        // No JWT_SECRET, no namespace and no DATABASE_URL: nothing this child
        // could migrate even if the gate let it through.
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = NSMutableData()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); collected.append(data); lock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let stillRunning = process.isRunning
        if stillRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < hardDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let output = String(decoding: collected as Data, as: UTF8.self); lock.unlock()

        XCTAssertFalse(stillRunning, "a boot with no signing secret was still running after thirty seconds")
        guard !stillRunning else { return }
        XCTAssertEqual(process.terminationReason, .exit,
                       "a refusal must end by exiting; a trap is a signal, which is not a boot decision")
        XCTAssertNotEqual(process.terminationStatus, 0, "a refused boot must leave a non-zero status behind")
        XCTAssertTrue(output.contains("Boot refused:"), "the refusal must be logged in the shape D5 established")
        XCTAssertTrue(output.contains("JWT_SECRET"), "the refusal must name the variable an operator has to set")
        XCTAssertTrue(output.contains("jwt_secret_absent"), "the refusal must carry its code")
        XCTAssertFalse(output.contains("Fatal error"), "a trap is not an exit")
        XCTAssertFalse(output.contains("Error raised at top level"),
                       "the refusal reached the top level as an error instead of exiting")
    }

    /// What the refusal may say: the variable, and nothing that could be a value.
    /// The sibling of `PrivateStorageBootTests`' own wording test, kept here
    /// because this refusal guards the one secret in the system whose appearance
    /// in a log would be worst.
    func testTheSigningSecretRefusalNamesTheVariableAndCarriesNoValue() {
        let refusal = SigningSecretBoot.Refusal.jwtSecretAbsent
        XCTAssertTrue(refusal.description.contains("JWT_SECRET"), "an operator must learn what to set")
        XCTAssertEqual(refusal.code, "jwt_secret_absent", "the code is what a runbook keys on")
        XCTAssertEqual(refusal.errorDescription, refusal.description)
        for value in unusable.values {
            XCTAssertFalse(refusal.description.contains(value), "a refusal names variables and never a value")
        }
    }

    /// The App executable, in the build directory this test bundle was built
    /// into. Absent when only the test target was built, which is a skip and not
    /// a pass: the assertions above are the point of the test.
    private static var builtServer: URL? {
        var directories: [URL] = [Bundle(for: BootGateOrderingTests.self).bundleURL.deletingLastPathComponent()]
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directories.append(package.appendingPathComponent(".build/debug"))
        for directory in directories {
            let candidate = directory.appendingPathComponent("App")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
