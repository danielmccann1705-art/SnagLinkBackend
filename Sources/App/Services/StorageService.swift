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

    // MARK: - Upload

    /// Uploads data to storage.
    /// - Parameters:
    ///   - data: The file data to upload.
    ///   - key: The storage key (e.g. `uploads/photos/uuid.jpg`). No leading slash.
    ///   - contentType: MIME type of the file.
    ///   - app: The Vapor Application (used for local disk path).
    static func upload(data: ByteBuffer, key: String, contentType: String, app: Application) async throws {
        switch backend {
        case .r2:
            let putRequest = S3.PutObjectRequest(
                body: .init(buffer: data),
                bucket: bucketName,
                contentType: contentType,
                key: key
            )
            _ = try await _s3Client.putObject(putRequest)
            app.logger.info("StorageService: uploaded to R2 key=\(key)")

        case .local:
            let fullPath = app.directory.publicDirectory + key
            let directory = (fullPath as NSString).deletingLastPathComponent
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            try Data(buffer: data).write(to: URL(fileURLWithPath: fullPath))
            app.logger.info("StorageService: saved locally at \(fullPath)")
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

    // MARK: - Shutdown

    /// Cleanly shuts down the AWS HTTP client. Call before app shutdown.
    static func shutdown() async throws {
        if backend == .r2 {
            try await _awsClient.shutdown()
        }
    }
}
