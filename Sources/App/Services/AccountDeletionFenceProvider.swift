import Vapor

/// The one place a deletion job obtains a fence store.
///
/// Two rules decide everything here. An intent row never chooses credentials or an
/// endpoint: one immutable server configuration produces one store for one exact
/// target, and a request for any other target is refused. And there is no fallback
/// — if the configured store is missing or does not match, the caller gets an
/// error, never a physical DELETE, never the public bucket, never local disk.
/// Falling back would turn "this object is permanently fenced" into "this object
/// was deleted from somewhere", which is the confusion the fence exists to remove.
enum AccountDeletionFenceProvider {

    /// A store injected by a test. Honoured only under `.testing`; in any other
    /// environment its presence is ignored entirely rather than trusted.
    struct InjectionKey: StorageKey { typealias Value = any ObjectErasureFenceStorage }

    private struct LiveKey: StorageKey { typealias Value = R2ObjectErasureFenceStore }

    enum Failure: Error, Equatable { case unavailable }

    /// Returns the store that owns `target`, or throws. Never returns a store for a
    /// different target, and never constructs one from anything the caller supplied.
    static func store(for target: ObjectStorageWriteTarget, app: Application) throws -> any ObjectErasureFenceStorage {
        guard target.writeProtocol == .createOnlyV1 else { throw Failure.unavailable }
        if app.environment == .testing, let injected = app.storage[InjectionKey.self] {
            guard injected.target == target else { throw Failure.unavailable }
            return injected
        }
        if let live = app.storage[LiveKey.self] {
            guard live.target == target else { throw Failure.unavailable }
            return live
        }
        guard let store = try? R2ObjectErasureFenceStore.makeIfEnabled(target: target, environment: app.environment),
              store.target == target else { throw Failure.unavailable }
        // One store per process for one target. Built once so a pass does not open
        // an HTTP client per key, and owned here so shutdown has somewhere to run.
        app.storage[LiveKey.self] = store
        return store
    }

    /// Called from the application's shutdown path, beside the other clients. A
    /// store that was never built has nothing to close.
    static func shutdown(app: Application) async {
        guard let live = app.storage[LiveKey.self] else { return }
        app.storage[LiveKey.self] = nil
        try? await live.shutdown()
    }
}
