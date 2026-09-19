import Vapor

/// Server-installed bridge to the reviewed private object store and one-job
/// DRA-02 processor. It is never decoded from HTTP and owns no database access.
/// The processor must store and byte-verify every page object described by its
/// returned manifest before returning. The controller rechecks lease authority
/// and commits readiness afterward.
protocol CanonicalDrawingRuntime: DrawingOriginalObjectReading {
    var identity: DrawingProcessorRuntimeIdentity { get }
    func putOriginal(_ binding: DrawingUploadBinding, bytes: Data) async throws
    func process(_ identity: DrawingProcessingIdentity) async throws -> DrawingProcessingManifest
    func readPage(_ target: CanonicalDrawingPageReadTarget) async throws -> Data
}

struct CanonicalDrawingPageReadTarget: Sendable, Equatable {
    enum Kind: String, Sendable { case rendition, thumbnail }
    let workspaceId: UUID
    let projectId: UUID
    let assetId: UUID
    let assetPageId: UUID
    let kind: Kind
    let sha256: String
    let byteCount: Int
    let mimeType: String
}

struct CanonicalDrawingRuntimeKey: StorageKey {
    typealias Value = any CanonicalDrawingRuntime
}

enum CanonicalDrawingRuntimeAccess {
    static func require(_ application: Application) throws -> any CanonicalDrawingRuntime {
        guard let runtime = application.storage[CanonicalDrawingRuntimeKey.self] else {
            throw Abort(.serviceUnavailable, reason: "Drawing processing is not available on this service",
                        identifier: "drawing_processor_unavailable")
        }
        return runtime
    }
}
