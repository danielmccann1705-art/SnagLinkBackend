import Foundation
import Crypto
import SotoS3
import NIOCore

enum StagedImportOriginalError: Error {
    case invalidDeclaration, byteCountMismatch, checksumMismatch, oversizedChunk
    case deadlineExceeded, objectUnavailable, storageUnavailable
}

/// One total cooperative IO deadline, including input, SDK retries and GET readback.
/// Future HTTP adapters must provide back-pressure and cancellation-aware input.
struct StagedImportIOBudget: Sendable {
    let deadline: ContinuousClock.Instant
    init(duration: Duration = .seconds(120)) throws {
        guard duration > .zero, duration <= .seconds(120) else { throw StagedImportOriginalError.deadlineExceeded }
        deadline = ContinuousClock.now.advanced(by: duration)
    }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw StagedImportOriginalError.deadlineExceeded }
    }
    var timeout: TimeAmount {
        get throws {
            try check()
            let remaining = ContinuousClock.now.duration(to: deadline).components
            return .nanoseconds(max(1, remaining.seconds * 1_000_000_000 + remaining.attoseconds / 1_000_000_000))
        }
    }
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try check()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw StagedImportOriginalError.deadlineExceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

enum StagedImportOriginalBytes {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumChunkBytes = 1024 * 1024

    static func validate(_ declaration: StagedImportOriginalDeclaration) throws {
        guard declaration.bytes >= 0, declaration.bytes <= maximumBytes,
              declaration.sha256.utf8.count == 64,
              declaration.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StagedImportOriginalError.invalidDeclaration
        }
    }

    /// A zero-content-length HTTP client can skip iteration. Verify empty sources
    /// first; for nonempty uploads the final chunk is withheld until SHA/EOF match.
    static func uploadBody(_ source: AWSHTTPBody, declaration: StagedImportOriginalDeclaration,
                           budget: StagedImportIOBudget) async throws -> AWSHTTPBody {
        try validate(declaration)
        if declaration.bytes == 0 {
            try await measure(source, declaration: declaration, budget: budget)
            return .init(buffer: ByteBuffer())
        }
        return .init(asyncSequence: VerifiedSequence(source: source, declaration: declaration, budget: budget), length: Int(declaration.bytes))
    }

    /// Never trusts Content-Length, ETag or object metadata as byte verification.
    static func measure(_ source: AWSHTTPBody, declaration: StagedImportOriginalDeclaration,
                        budget: StagedImportIOBudget) async throws {
        try validate(declaration)
        var iterator = VerifiedSequence(source: source, declaration: declaration, budget: budget).makeAsyncIterator()
        while try await iterator.next() != nil {}
    }

    private struct VerifiedSequence: AsyncSequence, Sendable {
        typealias Element = ByteBuffer
        let source: AWSHTTPBody
        let declaration: StagedImportOriginalDeclaration
        let budget: StagedImportIOBudget
        func makeAsyncIterator() -> Iterator { .init(source: source.makeAsyncIterator(), declaration: declaration, budget: budget) }
        struct Iterator: AsyncIteratorProtocol {
            var source: AWSHTTPBody.AsyncIterator
            let declaration: StagedImportOriginalDeclaration
            let budget: StagedImportIOBudget
            var hasher = SHA256()
            var count: Int64 = 0
            var finished = false
            mutating func nextNonempty() async throws -> ByteBuffer? {
                while true {
                    try budget.check()
                    let chunk = try await source.next()
                    try budget.check()
                    guard let chunk else { return nil }
                    guard chunk.readableBytes <= StagedImportOriginalBytes.maximumChunkBytes else { throw StagedImportOriginalError.oversizedChunk }
                    if chunk.readableBytes > 0 { return chunk }
                }
            }
            mutating func next() async throws -> ByteBuffer? {
                try budget.check()
                guard !finished else { return nil }
                guard let chunk = try await nextNonempty() else {
                    try finish()
                    return nil
                }
                count += Int64(chunk.readableBytes)
                guard count <= declaration.bytes else { throw StagedImportOriginalError.byteCountMismatch }
                chunk.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                if count == declaration.bytes {
                    // Peek past the final declared byte BEFORE yielding it to PUT.
                    guard try await nextNonempty() == nil else { throw StagedImportOriginalError.byteCountMismatch }
                    try finish()
                }
                return chunk
            }
            mutating func finish() throws {
                guard count == declaration.bytes else { throw StagedImportOriginalError.byteCountMismatch }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == declaration.sha256 else { throw StagedImportOriginalError.checksumMismatch }
                finished = true
            }
        }
    }
}

enum StagedImportObjectWrite: Sendable { case created, alreadyExists }

/// Internal storage dependency; neither an HTTP route nor an access grant. No
/// method accepts an arbitrary key, archive path, public URL or contractor token.
protocol StagedImportOriginalStore: Sendable {
    func putIfAbsent(_ address: StagedImportOriginalAddress, body: AWSHTTPBody, bytes: Int64,
                     budget: StagedImportIOBudget) async throws -> StagedImportObjectWrite
    func read(_ address: StagedImportOriginalAddress, budget: StagedImportIOBudget) async throws -> AWSHTTPBody
    /// Derived private objects (image renditions, drawing pages) addressed only by
    /// server-computed keys. Content-addressed keys make repeated processing idempotent.
    func putDerived(_ key: ImportedObjectKey, data: Data, mime: String, budget: StagedImportIOBudget) async throws
    func readDerived(_ key: ImportedObjectKey, limit: Int, budget: StagedImportIOBudget) async throws -> Data
}

/// A closed private namespace for import objects. Never built from request input.
struct ImportedObjectKey: Hashable, Sendable {
    let value: String
    private init(_ value: String) { self.value = value }
    static func original(_ address: StagedImportOriginalAddress) -> ImportedObjectKey {
        .init("staged-import/\(address.workspaceId.uuidString.lowercased())/\(address.sessionId.uuidString.lowercased())/\(address.declarationId.uuidString.lowercased())/original")
    }
    static func derived(_ address: StagedImportOriginalAddress, purpose: String, sha256: String) throws -> ImportedObjectKey {
        guard ["rendition", "drawing-page", "drawing-thumb"].contains(purpose), CanonicalDrawingService.hashValid(sha256) else { throw StagedImportOriginalError.invalidDeclaration }
        return .init("staged-import/\(address.workspaceId.uuidString.lowercased())/\(address.sessionId.uuidString.lowercased())/\(address.declarationId.uuidString.lowercased())/\(purpose)-\(sha256).jpg")
    }
    /// Re-validates a stored key before any storage read.
    static func stored(_ key: String) throws -> ImportedObjectKey {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "staged-import", parts[1...3].allSatisfy({ UUID(uuidString: String($0)) != nil && String($0) == String($0).lowercased() }),
              parts[4] == "original" || String(parts[4]).range(of: "^(rendition|drawing-page|drawing-thumb)-[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil else { throw StagedImportOriginalError.invalidDeclaration }
        return .init(key)
    }
}

/// Uses StorageService's existing S3/AWSClient. Logger stays disabled; SDK error
/// bodies can contain object addresses and must never cross this boundary.
struct SotoStagedImportOriginalStore: StagedImportOriginalStore {
    private let s3: S3
    private let bucket: String
    init(s3: S3, privateBucket: String) { self.s3 = s3; self.bucket = privateBucket }
    private func key(_ address: StagedImportOriginalAddress) -> String { ImportedObjectKey.original(address).value }
    private func client(_ budget: StagedImportIOBudget) throws -> S3 {
        // R2 does not receive AWS-signed chunk framing. Soto 7 skips automatic
        // retries for streaming PUT bodies; callers retain the same operation ID.
        s3.with(timeout: try budget.timeout, options: s3.config.options.union(.s3DisableChunkedUploads))
    }
    func putIfAbsent(_ address: StagedImportOriginalAddress, body: AWSHTTPBody, bytes: Int64,
                     budget: StagedImportIOBudget) async throws -> StagedImportObjectWrite {
        do {
            _ = try await client(budget).putObject(.init(body: body, bucket: bucket, cacheControl: "private, no-store",
                contentLength: bytes, contentType: "application/octet-stream", ifNoneMatch: "*", key: key(address)))
            try budget.check()
            return .created
        } catch is CancellationError { throw CancellationError() }
        catch let error as StagedImportOriginalError { throw error }
        catch {
            try budget.check()
            if (error as? AWSErrorType)?.context?.responseCode.code == 412 { return .alreadyExists }
            throw StagedImportOriginalError.storageUnavailable
        }
    }
    func read(_ address: StagedImportOriginalAddress, budget: StagedImportIOBudget) async throws -> AWSHTTPBody {
        do {
            let response = try await client(budget).getObject(.init(bucket: bucket, key: key(address)))
            try budget.check()
            return response.body
        } catch is CancellationError { throw CancellationError() }
        catch let error as StagedImportOriginalError { throw error }
        catch { throw StagedImportOriginalError.objectUnavailable }
    }
    func putDerived(_ key: ImportedObjectKey, data: Data, mime: String, budget: StagedImportIOBudget) async throws {
        do {
            _ = try await client(budget).putObject(.init(body: .init(buffer: ByteBuffer(data: data)), bucket: bucket, cacheControl: "private, no-store",
                contentLength: Int64(data.count), contentType: mime, ifNoneMatch: "*", key: key.value))
            try budget.check()
        } catch is CancellationError { throw CancellationError() }
        catch let error as StagedImportOriginalError { throw error }
        catch {
            try budget.check()
            // Content-addressed: an existing object with this key already holds these bytes.
            if (error as? AWSErrorType)?.context?.responseCode.code == 412 { return }
            throw StagedImportOriginalError.storageUnavailable
        }
    }
    func readDerived(_ key: ImportedObjectKey, limit: Int, budget: StagedImportIOBudget) async throws -> Data {
        do {
            let response = try await client(budget).getObject(.init(bucket: bucket, key: key.value))
            let bytes = try await response.body.collect(upTo: limit)
            try budget.check()
            return Data(buffer: bytes)
        } catch is CancellationError { throw CancellationError() }
        catch let error as StagedImportOriginalError { throw error }
        catch { throw StagedImportOriginalError.objectUnavailable }
    }
}
