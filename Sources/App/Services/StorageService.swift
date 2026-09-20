import Vapor
import SotoS3
import Foundation
import NIOCore

/// Abstraction over file storage backends (local disk for dev, Cloudflare R2 for prod).
/// Backend is auto-detected: if `R2_BUCKET_NAME` is set → R2, otherwise → local disk.
enum StorageService {

    // MARK: - Backend Detection

    enum Backend {
        case local
        case r2
    }

    static var backend: Backend {
        Environment.get("R2_BUCKET_NAME") != nil ? .r2 : .local
    }

    /// Base URL for constructing public file URLs.
    /// - R2: returns `R2_PUBLIC_URL` (e.g. `https://cdn.snaglist.dev`)
    /// - Local: returns `BASE_URL` (e.g. `https://snaglist.dev`)
    static var publicBaseURL: String {
        switch backend {
        case .r2:
            return Environment.get("R2_PUBLIC_URL") ?? Environment.get("BASE_URL") ?? "https://snaglist.dev"
        case .local:
            return Environment.get("BASE_URL") ?? "https://snaglist.dev"
        }
    }

    // MARK: - R2 / S3 Client (lazy singleton)

    private static let _awsClient: AWSClient = {
        AWSClient(
            credentialProvider: .static(
                accessKeyId: Environment.get("R2_ACCESS_KEY_ID") ?? "",
                secretAccessKey: Environment.get("R2_SECRET_ACCESS_KEY") ?? ""
            )
        )
    }()

    private static let _s3Client: S3 = {
        let accountId = Environment.get("R2_ACCOUNT_ID") ?? ""
        return S3(
            client: _awsClient,
            endpoint: "https://\(accountId).r2.cloudflarestorage.com",
            timeout: .minutes(2)
        )
    }()

    private static var bucketName: String {
        Environment.get("R2_BUCKET_NAME") ?? "snaglist-uploads"
    }

    // MARK: - The private namespace is never mutated from here

    /// Refuses, before any shape logic at all, a key inside the installed private
    /// namespace.
    ///
    /// Every entry in this file either writes unconditionally or physically
    /// deletes, and the private namespace is built on neither being possible. An
    /// object there is created once and never overwritten, and a deletion replaces
    /// its bytes with an erasure fence that must stay at that address for good. A
    /// single unconditional PUT through here would overwrite a fence back into
    /// content, and a single DELETE would remove one — turning "permanently
    /// unreadable" into "readable again" or into "deleted, and so re-creatable".
    ///
    /// Until now nothing but a coincidence of shapes kept them apart: `privatePath`
    /// happens to demand `platform/`, `deleteAccountObject` happens to demand each
    /// legacy family's prefix. A coincidence that four validators have to keep
    /// agreeing on is not a rule, and it is not what should stand between a
    /// customer's erased photograph and a writer that does not know about fences.
    /// This is the rule, and it is checked first so that no shape logic below can
    /// be the thing that decides.
    ///
    /// There is nothing to refuse where no namespace is installed: without one
    /// there is no address that could be inside it. The check is against the
    /// installation this process resolved at boot, never against a caller's idea of
    /// what a namespace is.
    ///
    /// The refusal is internal. No route can reach it with a caller-supplied key,
    /// so a client meeting it has met a server fault, and the identifier is for the
    /// operator rather than for the client.
    private static func refuseNamespaceMutation(_ key: String, app: Application) throws {
        guard case .installed(let configuration) = PrivateObjectAllocationPolicy.installation(app: app) else { return }
        let namespace = configuration.target.namespace
        // Both spellings. A namespace cannot itself contain a leading slash, but a
        // caller's key can carry one, and the two legacy entries below strip it
        // before they act — so a slashed namespaced key would otherwise reach
        // storage as its unslashed self.
        let normalized = key.hasPrefix("/") ? String(key.dropFirst()) : key
        guard !key.hasPrefix(namespace), !normalized.hasPrefix(namespace) else {
            throw Abort(.internalServerError, reason: "Private namespace objects are never written or deleted here",
                        identifier: "private_namespace_mutation_refused")
        }
    }

    // MARK: - Upload

    /// Uploads data to storage.
    /// - Parameters:
    ///   - data: The file data to upload.
    ///   - key: The storage key (e.g. `uploads/photos/uuid.jpg`). No leading slash.
    ///   - contentType: MIME type of the file.
    ///   - app: The Vapor Application (used for local disk path).
    static func upload(data: ByteBuffer, key: String, contentType: String, app: Application) async throws {
        try refuseNamespaceMutation(key, app: app)
        switch backend {
        case .r2:
            let putRequest = S3.PutObjectRequest(
                body: .init(buffer: data),
                bucket: bucketName,
                contentType: contentType,
                key: key
            )
            _ = try await _s3Client.putObject(putRequest)
            app.logger.info("StorageService: uploaded object to R2")

        case .local:
            let fullPath = app.directory.publicDirectory + key
            let directory = (fullPath as NSString).deletingLastPathComponent
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            try Data(buffer: data).write(to: URL(fileURLWithPath: fullPath))
            app.logger.info("StorageService: saved object locally")
        }
    }

    // MARK: - Download

    /// Downloads file data from storage.
    /// - Parameters:
    ///   - key: The storage key (no leading slash).
    ///   - app: The Vapor Application.
    /// - Returns: The raw file data, or `nil` if not found.
    static func download(key: String, app: Application) async throws -> Data? {
        switch backend {
        case .r2:
            do {
                let getRequest = S3.GetObjectRequest(bucket: bucketName, key: key)
                let response = try await _s3Client.getObject(getRequest)
                var buffer = try await response.body.collect(upTo: 50 * 1024 * 1024) // 50MB max
                return buffer.readData(length: buffer.readableBytes)
            } catch {
                let desc = String(describing: error)
                if desc.contains("NoSuchKey") || desc.contains("not found") || desc.contains("404") {
                    return nil
                }
                throw error
            }

        case .local:
            let fullPath = app.directory.publicDirectory + key
            return FileManager.default.contents(atPath: fullPath)
        }
    }

    // MARK: - Exists

    /// Checks whether a file exists in storage.
    /// - Parameters:
    ///   - key: The storage key (no leading slash).
    ///   - app: The Vapor Application.
    /// - Returns: `true` if the file exists.
    static func exists(key: String, app: Application) async throws -> Bool {
        switch backend {
        case .r2:
            do {
                let headRequest = S3.HeadObjectRequest(bucket: bucketName, key: key)
                _ = try await _s3Client.headObject(headRequest)
                return true
            } catch {
                return false
            }

        case .local:
            let fullPath = app.directory.publicDirectory + key
            return FileManager.default.fileExists(atPath: fullPath)
        }
    }

    /// Only app-owned synced-photo keys may be removed by snag deletion.
    static func deleteOwnedSyncedPhoto(key: String, app: Application) async throws {
        try refuseNamespaceMutation(key, app: app)
        let key = key.hasPrefix("/") ? String(key.dropFirst()) : key
        guard key.hasPrefix("uploads/synced-photos/"), !key.contains(".."), !key.contains("\\") else {
            throw Abort(.badRequest, reason: "Invalid synced-photo storage key")
        }
        switch backend {
        case .r2:
            _ = try await _s3Client.deleteObject(.init(bucket: bucketName, key: key))
        case .local:
            let url = URL(fileURLWithPath: app.directory.publicDirectory).appendingPathComponent(key)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Shutdown

    // MARK: - Private platform media

    /// Never fall back to the historical public bucket or Public directory.
    /// Deployment must keep both custom-domain and r2.dev access disabled on this
    /// separate bucket; the application never returns its object addresses.
    private static func privateBucket(app: Application) throws -> String? {
        if let bucket = Environment.get("R2_PRIVATE_BUCKET_NAME"), !bucket.isEmpty {
            guard bucket != Environment.get("R2_BUCKET_NAME"),
                  ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"].allSatisfy({ !(Environment.get($0) ?? "").isEmpty }) else {
                throw Abort(.serviceUnavailable, reason: "Private photo storage is not configured")
            }
            return bucket
        }
        guard app.environment == .testing || (app.environment == .development && Environment.get("PLATFORM_ENVIRONMENT") == "local") else {
            throw Abort(.serviceUnavailable, reason: "Private photo storage is not configured")
        }
        return nil
    }
    static func requirePrivateStorage(app: Application) throws { _ = try privateBucket(app: app) }

    /// Internal import-original transport only. Reuses the existing AWSClient and
    /// private bucket; no public/local fallback or generic caller-supplied key.
    /// Tests inject an in-memory/Soto HTTP test store. Real local disk transport
    /// and public upload routes require separate lifecycle/size-limit work.
    static func stagedImportOriginalStore(app: Application) throws -> SotoStagedImportOriginalStore {
        guard let bucket = try privateBucket(app: app) else {
            throw Abort(.serviceUnavailable, reason: "Private import original storage is not configured")
        }
        return .init(s3: _s3Client, privateBucket: bucket)
    }

    private static func privatePath(_ key: String, app: Application) throws -> URL {
        let parts = key.split(separator: "/")
        guard parts.count == 5, parts[0] == "platform", parts[1...3].allSatisfy({ UUID(uuidString: String($0)) != nil }),
              (parts[4] == "original" || String(parts[4]).range(of: "^view-[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil) else { throw Abort(.internalServerError, reason: "Invalid private media key") }
        return URL(fileURLWithPath: app.directory.workingDirectory).appendingPathComponent("PrivateMedia").appendingPathComponent(key)
    }
    /// Account-erasure manifests can contain the historical rendition placeholder
    /// produced at allocation time before any bytes were uploaded. It is deletion
    /// authority only; upload and download continue to use `privatePath`.
    private static func privateAccountDeletionPath(_ key: String, app: Application) throws -> URL {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "platform",
              parts[1...3].allSatisfy({ UUID(uuidString: String($0)) != nil }),
              parts[4] == "original" || parts[4] == "view.jpg" ||
                String(parts[4]).range(of: "^view-[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil else {
            throw Abort(.internalServerError, reason: "Invalid private media deletion key")
        }
        return URL(fileURLWithPath: app.directory.workingDirectory)
            .appendingPathComponent("PrivateMedia")
            .appendingPathComponent(key)
    }

    // The unconditional private writer is gone.
    //
    // `uploadPrivate` wrote a private media object with a plain `putObject` and no
    // `If-None-Match`, or, with no bucket configured, straight onto local disk. It
    // was the last writer that could put bytes at a create-only address without
    // being able to express "create only", and B2 removes it rather than guarding
    // it: a two-path controller is exactly the seam where a namespaced key meets
    // the wrong writer, and a guard is a rule four validators have to keep
    // agreeing on. Private media is now written only through
    // `PrivateObjectAllocationPolicy.write`, over
    // `PrivateContentStoreProvider.store(for:)`, where every PUT is conditional.
    //
    // `privatePath` stays, because `downloadPrivate` below still serves the
    // historical `platform/` address that `PrivateMediaReadService` routes to it.
    // Two consequences are deliberate and recorded: a deployment serving private
    // uploads now needs the namespace installed, and local development loses the
    // private-media disk path.

    static func downloadPrivate(key: String, app: Application) async throws -> Data {
        let path = try privatePath(key, app: app)
        if let bucket = try privateBucket(app: app) {
            let result = try await _s3Client.getObject(.init(bucket: bucket, key: key))
            let bytes = try await result.body.collect(upTo: PrivateImageProcessor.maximumBytes)
            return Data(buffer: bytes)
        }
        return try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next()) { try Data(contentsOf: path) }.get()
    }


    /// Only called with keys from a committed account-erasure manifest. Each
    /// namespace is revalidated; storage success never establishes graph erasure.
    static func deleteAccountObject(kind: String, key: String, app: Application) async throws {
        // A namespaced key is fenced or it is blocked; it is never physically
        // deleted, and the delete branch is never where that is decided.
        try refuseNamespaceMutation(key, app: app)
        if kind == "legacy_photo" {
            try await deleteOwnedSyncedPhoto(key: key, app: app)
            return
        }
        if kind == "legacy_drawing" {
            let normalized = key.hasPrefix("/") ? String(key.dropFirst()) : key
            let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "uploads", parts[1] == "synced-drawings",
                  !parts[2].isEmpty, !parts[2].contains(".."), !parts[2].contains("\\") else {
                throw Abort(.internalServerError, reason: "Invalid synced-drawing deletion key")
            }
            switch backend {
            case .r2: _ = try await _s3Client.deleteObject(.init(bucket: bucketName, key: normalized))
            case .local:
                let path = URL(fileURLWithPath: app.directory.publicDirectory).appendingPathComponent(normalized)
                try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next()) {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }.get()
            }
            return
        }
        if kind == "legacy_completion_photo" {
            let normalized = key.hasPrefix("/") ? String(key.dropFirst()) : key
            let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "uploads", parts[1] == "photos",
                  !parts[2].isEmpty, !parts[2].contains(".."), !parts[2].contains("\\"),
                  !normalized.contains(":"), !normalized.contains("\0") else {
                throw Abort(.internalServerError, reason: "Invalid completion-photo deletion key")
            }
            switch backend {
            case .r2: _ = try await _s3Client.deleteObject(.init(bucket: bucketName, key: normalized))
            case .local:
                let path = URL(fileURLWithPath: app.directory.publicDirectory).appendingPathComponent(normalized)
                try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next()) {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }.get()
            }
            return
        }
        let localPath: URL?
        switch kind {
        case "private_media":
            // Stated rather than left to the shape check inside the path helper: a
            // private-media deletion key is a historical `platform/` address and
            // nothing else. The namespace is fenced, and a key that is neither is
            // not an address this branch has ever been entitled to delete.
            guard key.hasPrefix(PrivateObjectAllocationPolicy.legacyMediaPrefix) else {
                throw Abort(.internalServerError, reason: "Invalid private media deletion key")
            }
            localPath = try privateAccountDeletionPath(key, app: app)
        case "private_import":
            _ = try ImportedObjectKey.stored(key)
            localPath = nil // Import transport has no real local-disk adapter.
        case "private_drawing":
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5 || parts.count == 7, parts[0] == "drawings",
                  parts[1...3].allSatisfy({ UUID(uuidString: String($0)) != nil }),
                  (parts.count == 5 && parts[4] == "original") ||
                  (parts.count == 7 && parts[4] == "pages" && UUID(uuidString: String(parts[5])) != nil &&
                   String(parts[6]).range(of: "^(thumb-)?[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil) else {
                throw Abort(.internalServerError, reason: "Invalid private drawing deletion key")
            }
            localPath = nil // No unverified guess at a historical local location.
        default: throw Abort(.internalServerError, reason: "Unknown deletion storage kind")
        }
        if let bucket = try privateBucket(app: app) {
            _ = try await _s3Client.deleteObject(.init(bucket: bucket, key: key))
        } else if let localPath {
            try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next()) {
                if FileManager.default.fileExists(atPath: localPath.path) {
                    try FileManager.default.removeItem(at: localPath)
                }
            }.get()
        } else {
            throw Abort(.serviceUnavailable, reason: "Private deletion storage is not configured")
        }
    }

    /// Cleanly shuts down the AWS HTTP client. Call before app shutdown.
    static func shutdown() async throws {
        if backend == .r2 || Environment.get("R2_PRIVATE_BUCKET_NAME") != nil {
            try await _awsClient.shutdown()
        }
    }
}
