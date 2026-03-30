import Vapor
import Foundation

/// Generates thumbnails from image data using ImageMagick.
/// Falls back gracefully if ImageMagick is not installed.
struct ThumbnailService {

    /// Generates a 300px-wide JPEG thumbnail from image data.
    /// - Parameters:
    ///   - imageData: The original image bytes
    ///   - maxWidth: Maximum width in pixels (default 300)
    ///   - quality: JPEG quality 0-100 (default 80)
    ///   - logger: Logger for diagnostics
    /// - Returns: Thumbnail JPEG data, or nil if generation failed
    static func generateThumbnail(
        from imageData: Data,
        maxWidth: Int = 300,
        quality: Int = 80,
        logger: Logger
    ) -> Data? {
        let uuid = UUID().uuidString
        let inputPath = NSTemporaryDirectory() + "\(uuid)_original"
        let outputPath = NSTemporaryDirectory() + "\(uuid)_thumb.jpg"

        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        do {
            try imageData.write(to: URL(fileURLWithPath: inputPath))
        } catch {
            logger.warning("ThumbnailService: Failed to write temp file: \(error)")
            return nil
        }

        // Find ImageMagick convert binary — check common locations
        let convertPaths = ["/usr/bin/convert", "/usr/local/bin/convert", "/opt/homebrew/bin/convert"]
        guard let convertPath = convertPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            logger.warning("ThumbnailService: ImageMagick 'convert' not found at any known path")
            return nil
        }

        // Use ImageMagick convert: resize to maxWidth, maintain aspect ratio, only shrink
        let process = Process()
        process.executableURL = URL(fileURLWithPath: convertPath)
        process.arguments = [
            inputPath,
            "-resize", "\(maxWidth)x>",
            "-quality", "\(quality)",
            "-strip",  // Remove EXIF metadata
            outputPath
        ]
        // Suppress stderr noise from ImageMagick policy warnings
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.warning("ThumbnailService: ImageMagick failed to launch: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logger.warning("ThumbnailService: ImageMagick exited with status \(process.terminationStatus)")
            return nil
        }

        return FileManager.default.contents(atPath: outputPath)
    }

    /// Generates a thumbnail and uploads it to storage.
    /// - Parameters:
    ///   - originalData: The original image data
    ///   - thumbnailKey: The storage key for the thumbnail (e.g. "uploads/photos/thumb_uuid.jpg")
    ///   - app: The Vapor Application
    ///   - logger: Logger
    /// - Returns: true if thumbnail was generated and uploaded, false otherwise
    static func generateAndUpload(
        originalData: Data,
        thumbnailKey: String,
        app: Application,
        logger: Logger
    ) async -> Bool {
        guard let thumbnailData = generateThumbnail(from: originalData, logger: logger) else {
            return false
        }

        do {
            var buffer = ByteBufferAllocator().buffer(capacity: thumbnailData.count)
            buffer.writeBytes(thumbnailData)
            try await StorageService.upload(
                data: buffer,
                key: thumbnailKey,
                contentType: "image/jpeg",
                app: app
            )
            logger.info("ThumbnailService: Uploaded thumbnail to \(thumbnailKey)")
            return true
        } catch {
            logger.warning("ThumbnailService: Failed to upload thumbnail: \(error)")
            return false
        }
    }
}
